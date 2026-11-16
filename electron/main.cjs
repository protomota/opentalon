const {
  app,
  BrowserWindow,
  Menu,
  ipcMain,
  shell,
  dialog,
  clipboard,
  nativeImage,
} = require('electron')
const path = require('node:path')
const fs = require('node:fs')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')
const { AgentRunner } = require('./agent-runner.cjs')
const { assertAgentReady } = require('./agent-readiness.cjs')
const { MAX_IMAGE_BYTES } = require('./comments.cjs')
const { Connector, errorView } = require('./mcp.cjs')
const { validateAction, AppError } = require('./contracts.cjs')
const {
  setupFields,
  terminalCommand,
  saveClaudeExtension,
  prepareProjectSetup,
  writeProjectSetup,
} = require('./agent-setup.cjs')
const { execFile } = require('node:child_process')
const { promisify } = require('node:util')
const run = promisify(execFile)

app.setName('OpenTalon')
app.setPath(
  'userData',
  process.env.OPENTALON_PROFILE || path.join(app.getPath('appData'), 'OpenTalon Prototype')
)
let window, store, connector, agentRunner
let editorDirty = false
let quitting = false
const background = process.argv.includes('--background')
const renderer = () =>
  app.isPackaged
    ? path.join(process.resourcesPath, 'renderer', 'index.html')
    : path.join(__dirname, '..', 'dist', 'index.html')
const notify = () => window?.webContents.send('opentalon:changed')
function createWindow() {
  if (window) {
    window.show()
    window.focus()
    return window
  }
  window = new BrowserWindow({
    width: 1480,
    height: 960,
    minWidth: 1080,
    minHeight: 680,
    title: 'OpenTalon',
    backgroundColor: '#f5f2ec',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    trafficLightPosition: { x: 18, y: 15 },
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  window.webContents.on('will-navigate', (event) => event.preventDefault())
  window.webContents.on('will-attach-webview', (event) => event.preventDefault())
  window.webContents.on('console-message', (details) => {
    if (details.level !== 'error') return
    try {
      fs.writeFileSync(path.join(store.folder, 'last-renderer-error.log'), details.message, {
        mode: 0o600,
      })
    } catch {}
  })
  window.webContents.session.setPermissionRequestHandler((_contents, _permission, callback) =>
    callback(false)
  )
  window.loadFile(renderer())
  window.on('close', (event) => {
    if (editorDirty && !quitting) {
      event.preventDefault()
      dialog.showMessageBox(window, {
        type: 'info',
        title: 'Your task has unsaved text',
        message: 'Save the text or choose “Use saved text” in the task panel before closing.',
        buttons: ['Keep editing'],
      })
    }
  })
  window.on('closed', () => {
    window = null
  })
  return window
}
function command(name) {
  const existing = !!window
  const target = createWindow()
  if (existing) target.webContents.send('opentalon:command', name)
  else
    target.webContents.once('did-finish-load', () =>
      target.webContents.send('opentalon:command', name)
    )
}
async function localAction(name, input) {
  validateAction(name, input, true)
  if (name === 'choose_comment_images') {
    const selected = await dialog.showOpenDialog(window, {
      title: 'Attach screenshots to your comment',
      properties: ['openFile', 'multiSelections'],
      filters: [{ name: 'Screenshots', extensions: ['png', 'jpg', 'jpeg', 'webp'] }],
    })
    if (selected.canceled) return { images: [] }
    if (selected.filePaths.length > 3)
      throw new AppError('IMAGE_LIMIT', 'Attach up to three screenshots per comment.')
    const images = selected.filePaths.map((file) => {
      if (fs.statSync(file).size > 25 * 1024 * 1024)
        throw new AppError('IMAGE_LIMIT', 'Choose screenshots smaller than 25 MB.')
      return prepareCommentImage(
        nativeImage.createFromBuffer(fs.readFileSync(file)),
        path.basename(file)
      )
    })
    return { images }
  }
  if (name === 'paste_comment_image')
    return { images: [prepareCommentImage(clipboard.readImage(), 'Clipboard screenshot.png')] }
  if (name === 'check_task_comments') {
    if (agentRunner.suspended || agentRunner.stopping)
      throw new AppError('BUSY', 'Try again after the current workspace operation.')
    return store.queueCommentFollowups()
  }
  if (name === 'agent_runtime_status') return agentRunner.status()
  if (name === 'open_agent_install_guide') {
    await shell.openExternal(
      input.agent === 'claude-code'
        ? 'https://code.claude.com/docs/en/quickstart'
        : 'https://learn.chatgpt.com/docs/codex/cli'
    )
    return { opened: true }
  }
  if (name === 'stop_agent_run') return agentRunner.stop(input.runId)
  if (name === 'open_agent_thread') return agentRunner.openThread(input.runId)
  if (name === 'answer_agent_approval')
    return agentRunner.answer(input.runId, input.approvalId, input.allow)
  if (name === 'choose_agent_folder') {
    const result = await dialog.showOpenDialog(window, {
      title: 'Choose the working folder for agent tasks',
      buttonLabel: 'Use this folder',
      properties: ['openDirectory', 'createDirectory'],
    })
    return result.canceled ? { canceled: true } : { path: result.filePaths[0] }
  }
  if (name === 'confirm_destructive_action') {
    agentRunner.suspended = true
    try {
      if (agentRunner.current || agentRunner.ticking)
        throw new AppError(
          'AGENT_RUNNING',
          'Stop the current agent run before restoring a backup or permanently deleting tasks.'
        )
      return await store.dispatch(name, input)
    } finally {
      agentRunner.suspended = false
    }
  }
  if (name === 'set_editor_dirty') {
    editorDirty = input.dirty
    return { acknowledged: true }
  }
  if (name === 'get_app_status')
    return { ...(await store.dispatch(name, input)), windowOpen: !!window, processId: process.pid }
  if (name === 'connection_status') return connector.status()
  if (name === 'set_connection') return connector.enable(input.enabled)
  if (name === 'reset_connection_key') return connector.reset()
  if (name === 'agent_setup_fields') return setupFields(connector.configuration('stdio'))
  if (name === 'copy_setup_field') {
    const field = setupFields(connector.configuration('stdio')).find(
      (field) => field.id === input.id
    )
    if (!field) throw new AppError('INVALID_ARGUMENT', 'This setup field does not exist.')
    clipboard.writeText(field.value)
    return { copied: true }
  }
  if (name === 'copy_terminal_setup') {
    clipboard.writeText(terminalCommand(connector.configuration('stdio'), input.client))
    return { copied: true }
  }
  if (name === 'open_setup_app') {
    const bundles = {
      codex: 'com.openai.codex',
      claude: 'com.anthropic.claudefordesktop',
      terminal: 'com.apple.Terminal',
    }
    try {
      await run('/usr/bin/open', ['-b', bundles[input.app]])
    } catch {
      throw new AppError(
        'APP_NOT_FOUND',
        'This app could not be opened. Install it, then open it from Applications and follow the steps below.'
      )
    }
    return { opened: true }
  }
  if (name === 'open_company_website' || name === 'open_setup_guide') {
    const guides = {
      'claude-code': 'https://code.claude.com/docs/en/desktop#connect-external-tools',
      codex: 'https://learn.chatgpt.com/docs/extend/mcp?surface=desktop',
      claude:
        'https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop',
    }
    await shell.openExternal(
      name === 'open_company_website' ? 'https://protomota.com' : guides[input.client]
    )
    return { opened: true }
  }
  if (name === 'open_newsletter') {
    await shell.openExternal('https://newsletter.protomota.com/')
    return { opened: true }
  }
  if (name === 'open_support_link') {
    await shell.openExternal(
      input.kind === 'coffee'
        ? 'https://buymeacoffee.com/protomotalab'
        : 'https://protomota.com/support?app=opentalon'
    )
    return { opened: true }
  }
  if (name === 'save_claude_extension') {
    connector.configuration('stdio')
    const result = await dialog.showSaveDialog(window, {
      title: 'Save Claude Desktop extension',
      defaultPath: 'OpenTalon.mcpb',
      filters: [{ name: 'Claude Desktop extension', extensions: ['mcpb'] }],
    })
    if (result.canceled) return { canceled: true }
    const saved = await saveClaudeExtension(result.filePath, connector.file, app.getVersion())
    shell.showItemInFolder(saved.path)
    return saved
  }
  if (name === 'save_project_connection') {
    const config = connector.configuration('stdio')
    const selected = await dialog.showOpenDialog(window, {
      title: 'Choose your Claude working folder',
      buttonLabel: 'Save project connection',
      properties: ['openDirectory'],
    })
    if (selected.canceled || !selected.filePaths[0]) return { canceled: true }
    const setup = prepareProjectSetup(selected.filePaths[0], config)
    if (setup.replacing) {
      const review = await dialog.showMessageBox(window, {
        type: 'question',
        title: 'Replace this project’s OpenTalon connection?',
        message: 'This folder already has an OpenTalon MCP connection.',
        detail:
          'Replace only the OpenTalon entry. Other servers and settings will be preserved. Claude will ask you to trust the project connection when you open it.',
        buttons: ['Cancel', 'Replace OpenTalon connection'],
        defaultId: 0,
        cancelId: 0,
      })
      if (review.response !== 1) return { canceled: true }
    }
    return writeProjectSetup(setup)
  }
  if (name === 'client_configuration') {
    const config = connector.configuration(input.transport)
    clipboard.writeText(JSON.stringify(config, null, 2))
    return { copied: true }
  }
  if (name === 'show_data_folder') {
    const error = await shell.openPath(store.folder)
    if (error) throw new AppError('OPEN_FOLDER', error)
    return { opened: true }
  }
  if (name === 'choose_backup') {
    const result = await dialog.showSaveDialog(window, {
      title: 'Export OpenTalon Backup',
      defaultPath: `OpenTalon-${new Date().toISOString().slice(0, 10)}.json`,
      filters: [{ name: 'OpenTalon JSON backup', extensions: ['json'] }],
    })
    if (result.canceled) return { canceled: true }
    return store.dispatch('create_backup', {
      destination: result.filePath,
      format: 'json',
      requestKey: randomUUID(),
    })
  }
  if (name === 'choose_restore') {
    const result = await dialog.showOpenDialog(window, {
      title: 'Import / Restore OpenTalon Backup',
      properties: ['openFile'],
      filters: [{ name: 'OpenTalon backup', extensions: ['json', 'opentalon', 'sqlite'] }],
    })
    if (result.canceled) return { canceled: true }
    return store.dispatch('preview_destructive_action', {
      action: 'restore_backup',
      path: result.filePaths[0],
    })
  }
  return store.dispatch(name, input)
}
function prepareCommentImage(image, name) {
  if (image.isEmpty())
    throw new AppError(
      'INVALID_IMAGE',
      'Copy a screenshot first, or choose a PNG, JPEG or WebP file.'
    )
  const size = image.getSize()
  if (size.width > 5000 || size.height > 5000)
    image = image.resize(size.width >= size.height ? { width: 5000 } : { height: 5000 })
  let bytes = image.toPNG(),
    mimeType = 'image/png'
  if (bytes.length > MAX_IMAGE_BYTES) {
    bytes = image.toJPEG(85)
    mimeType = 'image/jpeg'
  }
  if (bytes.length > MAX_IMAGE_BYTES)
    throw new AppError(
      'IMAGE_LIMIT',
      'This screenshot is too large. Crop it or choose a smaller image.'
    )
  return {
    name: name.slice(0, 190).replace(/\.[^.]*$/, '') + (mimeType === 'image/png' ? '.png' : '.jpg'),
    mimeType,
    data: bytes.toString('base64'),
  }
}
let archiveTimer
const ownsInstance = app.requestSingleInstanceLock({ background })
if (!ownsInstance) app.quit()
else {
  app.on('second-instance', (_event, argv, _cwd, data) => {
    if (!data?.background && !argv.includes('--background') && store) createWindow()
  })
  app.whenReady().then(async () => {
    try {
      store = new Store(app.getPath('userData'), {
        version: app.getVersion(),
        changed: notify,
        agentReadiness: (settings) =>
          assertAgentReady(settings, agentRunner.status(), connector.status()),
      })
      connector = new Connector({
        folder: store.folder,
        call: localAction,
        launchArgs: app.isPackaged ? [] : [app.getAppPath()],
        version: app.getVersion(),
        changed: notify,
      })
      try {
        await connector.start()
      } catch (error) {
        console.error('MCP startup failed:', error.message)
      }
      agentRunner = new AgentRunner({
        store,
        connector,
        openExternal: (url) => shell.openExternal(url),
      })
      await agentRunner.start()
      archiveTimer = store.scheduleAutoArchive()
      ipcMain.handle('opentalon:action', async (event, name, input = {}) => {
        if (
          event.sender !== window?.webContents ||
          event.senderFrame !== window.webContents.mainFrame
        )
          return {
            ok: false,
            error: {
              code: 'INVALID_SENDER',
              message: 'This action is available only in OpenTalon.',
            },
          }
        try {
          if (
            typeof name !== 'string' ||
            Buffer.byteLength(JSON.stringify(input)) > 20 * 1024 * 1024
          )
            throw new AppError('INVALID_ARGUMENT', 'This request is too large.')
          return { ok: true, data: await localAction(name, input) }
        } catch (error) {
          try {
            fs.writeFileSync(
              path.join(store.folder, 'last-error.log'),
              `${new Date().toISOString()} ${name}: ${error.stack || error.message}\n`,
              { mode: 0o600 }
            )
          } catch {}
          return { ok: false, error: errorView(error) }
        }
      })
      Menu.setApplicationMenu(
        Menu.buildFromTemplate([
          {
            label: 'OpenTalon',
            submenu: [
              { label: 'About OpenTalon', click: () => command('about') },
              { label: 'Show OpenTalon', click: () => createWindow() },
              { type: 'separator' },
              { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: () => command('settings') },
              { type: 'separator' },
              { role: 'hide' },
              { role: 'hideOthers' },
              { role: 'unhide' },
              { type: 'separator' },
              { role: 'quit' },
            ],
          },
          {
            label: 'File',
            submenu: [
              { label: 'New task', accelerator: 'CmdOrCtrl+N', click: () => command('new-task') },
              { label: 'Find tasks', accelerator: 'CmdOrCtrl+F', click: () => command('search') },
              { type: 'separator' },
              { role: 'close' },
            ],
          },
          { role: 'editMenu' },
          {
            label: 'View',
            submenu: [
              { role: 'resetZoom' },
              { role: 'zoomIn' },
              { role: 'zoomOut' },
              { type: 'separator' },
              { role: 'togglefullscreen' },
            ],
          },
          { role: 'windowMenu' },
        ])
      )
      app.setAboutPanelOptions({
        applicationName: 'OpenTalon',
        applicationVersion: app.getVersion(),
        copyright: 'Protomota',
      })
      if (!background) createWindow()
      app.on('activate', () => createWindow())
    } catch (error) {
      fs.mkdirSync(app.getPath('userData'), { recursive: true, mode: 0o700 })
      fs.writeFileSync(
        path.join(app.getPath('userData'), 'startup-error.log'),
        `${new Date().toISOString()} ${error.message}\n`,
        { mode: 0o600 }
      )
      if (!background)
        dialog.showErrorBox(
          'OpenTalon could not open its data',
          `${error.message}\n\nYour existing database has not been replaced.\nData folder: ${app.getPath('userData')}`
        )
      app.quit()
    }
  })
  // Keep the embedded connector and single database writer alive when the window closes.
  app.on('window-all-closed', () => {})
  app.on('before-quit', (event) => {
    if (quitting || !store) return
    if (editorDirty && window) {
      event.preventDefault()
      dialog.showMessageBox(window, {
        type: 'info',
        title: 'Your task has unsaved text',
        message: 'Save the text or choose “Use saved text” in the task panel before quitting.',
        buttons: ['Keep editing'],
      })
      return
    }
    event.preventDefault()
    quitting = true
    clearInterval(archiveTimer)
    Promise.resolve(agentRunner?.close())
      .then(() => connector?.stop())
      .then(() => store.queue)
      .then(() => {
        store.close()
        process.exit(0)
      })
      .catch(() => process.exit(1))
  })
}
