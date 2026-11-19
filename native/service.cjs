const taskHistory = require('./task-history.cjs')
const taskActivity = require('./task-activity.cjs')
// Private JSON-line transport between the Swift application and the shared local service.
// The network-facing connector retains its own allowlist and authentication.
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const readline = require('node:readline')
const { backup, DatabaseSync } = require('node:sqlite')
const { randomUUID } = require('node:crypto')
const { DailyBackup } = require('./daily-backup.cjs')
const { execFile } = require('node:child_process')
const { promisify } = require('node:util')
const { Store } = require('./store.cjs')
const { AgentRunner, askAgent, draftTask } = require('./agent-runner.cjs')
const { assertAgentReady } = require('./agent-readiness.cjs')
const { Connector, errorView } = require('./mcp.cjs')
const { tools, validateAction, AppError, agentModels } = require('./contracts.cjs')
const { setupFields, terminalCommand, saveClaudeExtension, prepareProjectSetup, writeProjectSetup } =
  require('./agent-setup.cjs')

const runFile = promisify(execFile)
const [folder, executable, version, visibility] = process.argv.slice(2)
let windowOpen = visibility === 'visible'
const send = (value) => process.stdout.write(JSON.stringify(value) + '\n')
const changed = () => send({ event: 'changed' })
const local = (request) => connector.configuration(request)
const maxRequest = 20 * 1024 * 1024
let store, connector, runner, daily, migrationFolder
const projects = new Map()
let chatController
const chatTools = tools.filter(({ name }) => [
  'list_boards', 'create_board', 'rename_board', 'set_board_icon',
  'list_tasks', 'get_task', 'create_task', 'update_task', 'set_task_plan', 'get_task_history', 'restore_task_revision', 'move_task',
  'trash_task', 'list_trash', 'restore_task', 'list_task_comments', 'list_task_activity', 'add_task_activity',
].includes(name))

async function chat(input) {
  const { message, history, projectId, agent: selectedAgent } = input
  if (typeof message !== 'string' || !message.trim() || message.length > 4000 ||
      !Array.isArray(history) || history.length > 16 || history.some((entry) =>
        !['user', 'assistant'].includes(entry?.role) || typeof entry.text !== 'string' || entry.text.length > 16000))
    throw new AppError('INVALID_ARGUMENT', 'Enter a message up to 4,000 characters.')
  if (!connector.status().enabled || !connector.status().running)
    throw new AppError('CONNECTION_DISABLED', 'Turn on the local agent connection in Settings to start chatting.')
  const project = store.boards().find(({ id }) => id === projectId)?.name
  if (selectedAgent !== undefined && selectedAgent !== 'claude-code' && selectedAgent !== 'codex')
    throw new AppError('INVALID_ARGUMENT', 'Choose Claude or Codex for this chat.')
  const agent = selectedAgent ?? store.agentSettings().defaultAgent
  const controller = new AbortController()
  chatController = controller
  let directory, chatConnector
  try {
    directory = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'opentalon-chat-'))
    chatConnector = new Connector({
      folder: directory, executable, stdioCommand: process.execPath, version, toolCatalog: chatTools,
      call: async (name, args) => {
        if (controller.signal.aborted || !connector.status().running)
          throw new AppError('CONNECTION_DISABLED', 'This chat connection is closed.')
        if (args.status === 'Sent to agent' || args.notifyAgent === true || args.images?.length)
          throw new AppError('TOOL_UNAVAILABLE', 'Use the task’s Send to agent or attachment controls for this action.')
        const result = await dispatch(name, args)
        if (chatTools.find((tool) => tool.name === name)?.mutates) {
          const record = result.task ?? result.board ?? (name === 'add_task_activity' ? store.task(args.taskId) : null)
          send({ event: 'agent-chat-activity', name, title: record?.title ?? record?.name })
        }
        return result
      },
    })
    await chatConnector.enable(true)
    const config = chatConnector.configuration('stdio').mcpServers.opentalon
    config.env.OPENTALON_MCP_NO_LAUNCH = '1'
    return await askAgent(agent, {
      directory, config,
      message, history, project, signal: controller.signal,
    })
  } finally {
    await chatConnector?.stop().catch(() => {})
    if (directory) await fs.promises.rm(directory, { recursive: true, force: true }).catch(() => {})
    chatController = undefined
  }
}

async function dispatch(name, input, origin = 'Connected agent') {
  validateAction(name, input, true)
  switch (name) {
    case 'check_task_comments':
      if (runner.suspended || runner.stopping)
        throw new AppError('BUSY', 'Try again after the current workspace operation.')
      return store.queueCommentFollowups()
    case 'add_user_comment': {
      const result = await store.dispatch(name, input, origin)
      if (input.notifyAgent)
        void store.queueCommentFollowups().catch((error) => console.error('OpenTalon comment dispatch:', error.message))
      return result
    }
    case 'agent_runtime_status': return runner.status()
    case 'stop_agent_run': return runner.stop(input.runId)
    case 'open_agent_thread': return runner.openThread(input.runId)
    case 'answer_agent_approval': return runner.answer(input.runId, input.approvalId, input.allow)
    case 'get_app_status':
      return { ...(await store.dispatch(name, input)), processId: process.ppid, windowOpen }
    case 'confirm_destructive_action':
      runner.suspended = true
      try {
        if (runner.current || runner.ticking)
          throw new AppError('AGENT_RUNNING', 'Stop the current agent run before continuing.')
        const result = await store.dispatch(name, input, origin)
        if (result.safetyBackup && daily?.status().enabled)
          void daily.run({ force: true }).catch(() => {})
        if (migrationFolder) discardMigration()
        return result
      } finally {
        runner.suspended = false
      }
    case 'connection_status': return connector.status()
    case 'set_connection':
      if (!input.enabled) chatController?.abort()
      return connector.enable(input.enabled)
    case 'reset_connection_key': return connector.reset()
    case 'agent_setup_fields': return setupFields(local('stdio'))
    case 'copy_terminal_setup': return { value: terminalCommand(local('stdio'), input.client) }
    case 'client_configuration': return { value: JSON.stringify(local(input.transport), null, 2) }
    default: return store.dispatch(name, input, origin)
  }
}

function discardMigration() {
  if (migrationFolder) fs.rmSync(migrationFolder, { recursive: true, force: true })
  migrationFolder = undefined
}

async function testConnection() {
  const setup = local('stdio').mcpServers.opentalon
  try {
    const request = runFile(setup.command, setup.args, {
      env: { ...process.env, ...setup.env },
      timeout: 5000,
      maxBuffer: 256 * 1024,
    })
    request.child.stdin.on('error', () => {})
    const messages = [
      {
        id: 1,
        method: 'initialize',
        params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'OpenTalon connection test', version } },
      },
      { method: 'notifications/initialized' },
      { id: 2, method: 'tools/call', params: { name: 'get_app_status', arguments: {} } },
    ]
    request.child.stdin.end(messages.map((message) => JSON.stringify({ jsonrpc: '2.0', ...message })).join('\n') + '\n')
    const { stdout } = await request
    const replies = stdout.trim().split('\n').map((line) => JSON.parse(line))
    const initialized = replies.find((reply) => reply.id === 1)?.result
    const status = replies.find((reply) => reply.id === 2)?.result
    if (initialized?.serverInfo?.name !== 'OpenTalon' || status?.isError ||
        status?.structuredContent?.available !== true || status.structuredContent.dataLocation !== folder)
      throw new Error('Unexpected response from the connector.')
    return {}
  } catch {
    throw new AppError('CONNECTION_TEST_FAILED', 'OpenTalon did not respond through its MCP connector. Reopen OpenTalon and try again.')
  }
}

function agentOptions() {
  const settings = store.agentSettings()
  const runtimes = runner.status()
  const availableAgents = Object.entries(runtimes).filter(([, runtime]) => runtime.installed).map(([agent]) => agent)
  const defaultAgent = availableAgents.length === 1 ? availableAgents[0] : settings.defaultAgent
  return {
    defaultAgent,
    availableAgents,
    agentModels: agentModels.filter(({ agent }) => availableAgents.includes(agent)),
    needsSetup: !settings.workingFolder || !availableAgents.length || !connector.status().running,
  }
}

async function privateAction(name, input) {
  switch (name) {
    case 'native_agent_options': return agentOptions()
    case 'native_phone_snapshot': {
      const workspace = store.snapshot()
      const commentsByTask = Object.create(null)
      const rows = store.db.prepare(`
        SELECT c.task_id, c.id, json_extract(c.data, '$.text') AS text,
          json_extract(c.data, '$.createdAt') AS created_at,
          json_extract(c.data, '$.delivery') AS delivery,
          json_extract(c.data, '$.pickedUpAt') AS picked_up_at
        FROM task_comments c JOIN tasks t ON t.id = c.task_id
        WHERE t.deleted_at IS NULL AND json_extract(c.data,'$.source')='user'
        ORDER BY c.rowid
      `).all()
      for (const row of rows) {
        (commentsByTask[row.task_id] ??= []).push({
          id: row.id, text: row.text, createdAt: row.created_at,
          delivery: row.delivery, pickedUpAt: row.picked_up_at,
        })
      }
      return {
        workspace, commentsByTask, activityByTask: Object.fromEntries(workspace.tasks.filter(task=>!task.deleted).map(task=>[task.id, taskActivity.page(store, task.id, undefined, 5)])), historyByTask: Object.fromEntries(workspace.tasks.filter(task => !task.deleted).map(task => [task.id, taskHistory.page(store, task.id, undefined, 1)])), ...agentOptions(),
      }
    }
    case 'native_test_connection': return testConnection()
    case 'native_stop_chat':
      chatController?.abort()
      return {}
    case 'native_window_state':
      windowOpen = input.visible === true
      return {}
    case 'native_daily_status': return daily.status()
    case 'native_daily_configure':
      try {
        const result = await daily.configure(input)
        void daily.run().catch(() => {})
        return result
      } catch (error) {
        throw new AppError('BACKUP_FOLDER', 'Could not save the daily backup settings. Choose an existing writable folder.')
      }
    case 'native_daily_run':
      try {
        return await daily.run({ force: true })
      } catch (error) {
        throw new AppError('BACKUP_FAILED', error.message)
      }
    case 'native_save_extension':
      local('stdio')
      return saveClaudeExtension(input.path, connector.file, version)
    case 'native_prepare_project': {
      const setup = prepareProjectSetup(input.path, local('stdio'))
      const id = randomUUID()
      projects.clear()
      projects.set(id, setup)
      return { id, replacing: setup.replacing }
    }
    case 'native_write_project': {
      const setup = projects.get(input.id)
      if (!setup) throw new AppError('INVALID_CONFIG', 'Choose the working folder again.')
      projects.delete(input.id)
      return writeProjectSetup(setup)
    }
    case 'native_cancel_restore':
      discardMigration()
      return {}
    case 'native_preview_electron': {
      // SQLite's online backup API includes committed WAL data without changing the source.
      discardMigration()
      const sourcePath = path.join(path.dirname(folder), 'OpenTalon Prototype', 'opentalon.sqlite')
      if (path.resolve(sourcePath) === path.resolve(store.file))
        throw new AppError('INVALID_BACKUP', 'Choose a different workspace to copy.')
      if (!fs.existsSync(sourcePath))
        throw new AppError('NO_ELECTRON_WORKSPACE', 'No existing Electron workspace was found.')
      migrationFolder = fs.mkdtempSync(path.join(folder, '.native-import-'))
      const destination = path.join(migrationFolder, 'previous.sqlite')
      try {
        const source = new DatabaseSync(sourcePath, { readOnly: true })
        try {
          await backup(source, destination)
        } finally {
          source.close()
        }
        return await dispatch('preview_destructive_action', { action: 'restore_backup', path: destination })
      } catch (error) {
        discardMigration()
        throw error
      }
    }
    default: return dispatch(name, input, input.requestKey?.startsWith('phone:') ? 'You · mobile' : 'You · Mac')
  }
}

async function main() {
  if (!path.isAbsolute(folder) || !path.isAbsolute(executable)) throw new Error('Invalid app profile.')
  store = new Store(folder, {
    version, changed,
    agentReadiness: (settings, requestedAgent) => {
      const runtimes = runner.status()
      const available = Object.keys(runtimes).filter((agent) => runtimes[agent].installed)
      const agent = requestedAgent || (available.length === 1 ? available[0] : settings.defaultAgent)
      assertAgentReady({ ...settings, defaultAgent: agent }, runtimes, connector.status())
      return agent
    },
  })
  connector = new Connector({
    folder, executable, stdioCommand: process.execPath, version, changed, call: dispatch,
  })
  runner = new AgentRunner({
    store, connector, openExternal: (url) => runFile('/usr/bin/open', [url]),
  })
  try {
    await connector.start()
  } catch (error) {
    console.error('OpenTalon MCP startup:', error.message)
  }
  await runner.start()
  const archiveTimer = store.scheduleAutoArchive()
  daily = new DailyBackup(store, { changed: () => send({ event: 'backup-changed' }) })
  const dailyTimer = setInterval(() => void daily.run().catch(() => {}), 5 * 60 * 1000)
  send({ event: 'ready' })
  void daily.run().catch(() => {})
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity })
  let queue = Promise.resolve()
  let drafting
  let chatting
  for await (const line of lines) {
    const handle = async () => {
      let id
      try {
        if (Buffer.byteLength(line) > maxRequest)
          throw new AppError('INVALID_ARGUMENT', 'This request is too large.')
        const request = JSON.parse(line)
        id = request.id
        if (request.name === 'native_agent_chat') {
          if (chatting) throw new AppError('BUSY', 'Wait for the current reply to finish.')
          chatting = chat(request.input || {})
            .then((data) => send({ id, data }))
            .catch((error) => send({ id, error: errorView(error) }))
            .finally(() => { chatting = undefined })
          return
        }
        if (request.name === 'native_draft_task') {
          const idea = request.input?.idea
          if (typeof idea !== 'string' || !idea.trim() || idea.length > 2000)
            throw new AppError('INVALID_ARGUMENT', 'Enter an idea up to 2,000 characters.')
          if (drafting) throw new AppError('BUSY', 'A task is already being drafted.')
          // Drafting produces text only. Leave the workspace available while the agent responds.
          drafting = (async () => {
            try {
              const data = await draftTask(store.agentSettings().defaultAgent, idea, {
                autoProject: request.input.autoProject === true,
                projects: request.input.autoProject === true ? store.boards() : [],
                priorities: request.input.autoPriority === true ? ['Urgent', 'High', 'Medium', 'Low', 'None'] : [],
              })
              send({ id, data })
            } catch (error) {
              send({ id, error: errorView(error) })
            } finally {
              drafting = undefined
            }
          })()
          return
        }
        const data = await privateAction(request.name, request.input || {})
        send({ id, data })
      } catch (error) {
        send({ id, error: errorView(error) })
      }
    }
    // Every native request is ordered; MCP requests use the store's own queue.
    queue = queue.then(handle)
  }
  clearInterval(dailyTimer)
  clearInterval(archiveTimer)
  await queue
  chatController?.abort()
  await chatting
  await drafting
  await daily.running?.catch(() => {})
  await runner.close()
  await connector.stop()
  await store.queue
  discardMigration()
  store.close()
}

main().catch((error) => {
  send({ event: 'failed', error: errorView(error) })
  process.exitCode = 1
})
