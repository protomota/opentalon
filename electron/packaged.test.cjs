const test = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const fs = require('node:fs')
const { spawn } = require('node:child_process')
const { randomBytes, randomUUID } = require('node:crypto')
const executable =
  process.env.OPENTALON_EXECUTABLE ||
  '/Volumes/Expand/Codex Media/opentalon/prototype/release/mac-arm64/OpenTalon.app/Contents/MacOS/OpenTalon'
const bridge = path.resolve(executable, '../../Resources/app.asar/electron/mcp-bridge.cjs')
const enabled = process.env.OPENTALON_PACKAGED_TEST === '1'
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
function client(file, messages) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [bridge], {
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', OPENTALON_MCP_CONFIG: file },
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let output = '',
      error = ''
    child.stdout.on('data', (data) => (output += data))
    child.stderr.on('data', (data) => (error += data))
    child.on('error', reject)
    child.on('close', (code) => {
      if (code) reject(new Error(error))
      else {
        try {
          resolve(
            output
              .trim()
              .split('\n')
              .filter(Boolean)
              .map((line) => JSON.parse(line))
          )
        } catch (failure) {
          reject(failure)
        }
      }
    })
    child.stdin.end(messages.map((message) => JSON.stringify(message)).join('\n') + '\n')
  })
}
async function status(file) {
  const [response] = await client(file, [
    { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_app_status' } },
  ])
  return response
}

test(
  'packaged Electron runtime bridge auto-launches the embedded app in background; disabled stays disabled',
  { skip: !enabled, timeout: 45000 },
  async (t) => {
    const folder = fs.mkdtempSync('/Volumes/Expand/Codex Media/opentalon/tests/packaged-')
    const file = path.join(folder, 'mcp.json')
    fs.writeFileSync(
      file,
      JSON.stringify({
        enabled: true,
        token: randomBytes(32).toString('hex'),
        port: 0,
        executable,
        launchArgs: [],
        profile: folder,
      }),
      { mode: 0o600 }
    )
    let pid
    t.after(async () => {
      if (pid) {
        try {
          process.kill(pid, 'SIGTERM')
        } catch {}
        await pause(300)
      }
      fs.rmSync(folder, { recursive: true, force: true })
    })
    const connected = await status(file)
    assert.ok(!connected.error, JSON.stringify(connected.error))
    const app = connected.result.structuredContent
    assert.equal(app.dataLocation, folder)
    assert.equal(app.windowOpen, false)
    // Verify this process belongs only to our isolated test profile before stopping it.
    pid = app.processId
    assert.ok(Number.isInteger(pid))
    const call = async (name, args = {}) => {
      const [response] = await client(file, [
        {
          jsonrpc: '2.0',
          id: randomUUID(),
          method: 'tools/call',
          params: { name, arguments: args },
        },
      ])
      assert.ok(!response.error && !response.result.isError, JSON.stringify(response))
      return response.result.structuredContent
    }
    const boards = await call('list_boards')
    assert.equal(boards.boards[0].name, 'Tasks')
    const args = {
      boardId: boards.boards[0].id,
      title: 'Background persistence',
      requestKey: randomUUID(),
    }
    const created = await call('create_task', args)
    const previousPid = pid
    process.kill(pid, 'SIGTERM')
    pid = null
    await pause(500)
    assert.throws(() => process.kill(previousPid, 0), { code: 'ESRCH' })
    const reopened = await status(file)
    assert.ok(!reopened.error, JSON.stringify(reopened))
    pid = reopened.result.structuredContent.processId
    assert.notEqual(pid, previousPid)
    assert.equal(reopened.result.structuredContent.windowOpen, false)
    assert.deepEqual(await call('create_task', args), created)
    assert.equal((await call('list_tasks')).tasks[0].title, 'Background persistence')
    const write = (name, args = {}) => call(name, { requestKey: randomUUID(), ...args })
    let task = (await call('get_task', { id: created.task.id })).task
    const other = (await write('create_task', { boardId: task.boardId, title: 'Position anchor' }))
      .task
    task = (
      await write('move_task', { id: task.id, afterId: other.id, expectedRevision: task.revision })
    ).task
    task = (
      await write('update_task', {
        id: task.id,
        title: 'Edited in background',
        notes: 'Offline agent workflow',
        expectedRevision: task.revision,
      })
    ).task
    assert.equal((await call('list_tasks', { query: 'agent workflow' })).tasks[0].id, task.id)
    let board = (await write('create_board', { name: 'Background board' })).board
    board = (
      await write('rename_board', {
        id: board.id,
        name: 'Renamed background board',
        expectedRevision: board.revision,
      })
    ).board
    task = (
      await write('move_task', {
        id: task.id,
        boardId: board.id,
        status: 'In progress',
        expectedRevision: task.revision,
      })
    ).task
    for (const status of ['Done', 'To do'])
      task = (await write('update_task', { id: task.id, status, expectedRevision: task.revision }))
        .task
    task = (await write('trash_task', { id: task.id, expectedRevision: task.revision })).task
    assert.equal((await call('list_trash')).tasks[0].id, task.id)
    task = (await write('restore_task', { id: task.id, expectedRevision: task.revision })).task
    const preferences = await call('get_preferences')
    await write('set_preferences', {
      theme: 'graphite',
      selectedBoard: board.id,
      expectedRevision: preferences.revision,
    })
    const backup = await write('create_backup')
    assert.equal((await call('inspect_backup', { path: backup.path })).tasks, 2)
    const preview = await call('preview_destructive_action', {
      action: 'restore_backup',
      path: backup.path,
    })
    const restored = await write('confirm_destructive_action', { token: preview.token })
    assert.ok(fs.existsSync(restored.safetyBackup))
    assert.equal((await call('get_task', { id: task.id })).task.notes, 'Offline agent workflow')
    assert.equal((await call('get_app_status')).windowOpen, false)
    process.kill(pid, 'SIGTERM')
    pid = null
    await pause(500)
    const config = JSON.parse(fs.readFileSync(file, 'utf8'))
    config.enabled = false
    fs.writeFileSync(file, JSON.stringify(config), { mode: 0o600 })
    const disabled = await status(file)
    assert.match(disabled.error.message, /disabled/)
  }
)
