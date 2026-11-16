const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const readline = require('node:readline')
const { randomUUID, randomBytes } = require('node:crypto')
const { spawn, execFile } = require('node:child_process')
const { once } = require('node:events')
const { promisify } = require('node:util')
const { setTimeout: pause } = require('node:timers/promises')
const { Store } = require('./runtime/store.cjs')
const { tools } = require('./runtime/contracts.cjs')
const { DailyBackup } = require('./daily-backup.cjs')

const root = process.env.OPENTALON_NATIVE_TEST_ROOT || os.tmpdir()
const bundle = process.env.OPENTALON_NATIVE_TEST_APP
const execute = promisify(execFile)
const pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2uoAAAAASUVORK5CYII='
function directory(t) {
  const folder = fs.mkdtempSync(path.join(root, 'opentalon-native-test-'))
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }))
  return folder
}
const request = (call, name, fields = {}) => call(name, { requestKey: randomUUID(), ...fields })

test('daily snapshots are dated, survive restart, can be restored, and recover after a destination reconnects', async (t) => {
  const parent = directory(t)
  const store = new Store(path.join(parent, 'native'))
  t.after(() => store.close())
  const call = store.dispatch.bind(store)
  const boardId = store.snapshot().boards[0].id
  const { task } = await request(call, 'create_task', { boardId, title: 'Original task' })
  let date = new Date(2026, 10, 11, 3)
  const schedule = new DailyBackup(store, { now: () => date })
  const first = await schedule.run()
  const firstPath = path.join(first.folder, 'OpenTalon-2026-11-11.json')
  assert.ok(fs.existsSync(firstPath))
  assert.equal(fs.statSync(firstPath).mode & 0o777, 0o600)

  await request(call, 'update_task', { id: task.id, expectedRevision: task.revision, title: 'Changed task' })
  const restarted = new DailyBackup(store, { now: () => date })
  await restarted.run()
  assert.equal(fs.readdirSync(first.folder).length, 1)
  assert.equal(JSON.parse(fs.readFileSync(firstPath)).tasks[0].title, 'Original task')

  date = new Date(2026, 10, 12, 3)
  await restarted.run()
  const secondPath = path.join(first.folder, 'OpenTalon-2026-11-12.json')
  assert.equal(JSON.parse(fs.readFileSync(secondPath)).tasks[0].title, 'Changed task')
  const preview = await call('preview_destructive_action', { action: 'restore_backup', path: firstPath })
  const restore = await request(call, 'confirm_destructive_action', { token: preview.token })
  assert.ok(fs.existsSync(restore.safetyBackup))
  assert.equal(store.snapshot().tasks[0].title, 'Original task')

  const separate = fs.mkdtempSync(path.join(parent, 'external-'))
  await restarted.configure({ folder: separate })
  fs.rmdirSync(separate)
  assert.match((await restarted.run()).lastError, /unavailable/)
  assert.ok(!fs.existsSync(separate))
  fs.mkdirSync(separate)
  assert.equal((await restarted.run()).lastError, '')
  assert.equal(fs.readdirSync(separate).length, 1)
  date = new Date(2026, 10, 13, 3)
  await restarted.configure({ enabled: false })
  await restarted.run()
  assert.equal(fs.readdirSync(separate).length, 1)
  await restarted.run({ force: true })
  assert.equal(fs.readdirSync(separate).length, 2)
})

function localService(folder) {
  const contents = path.join(bundle, 'Contents')
  const executable = path.join(contents, 'MacOS', 'OpenTalon')
  const child = spawn(path.join(contents, 'Helpers', 'node'), [
    path.join(contents, 'Resources', 'service', 'service.cjs'), folder, executable, '0.1.0',
  ], { stdio: ['pipe', 'pipe', 'inherit'] })
  const closed = once(child, 'close')
  const requests = new Map()
  const lines = readline.createInterface({ input: child.stdout })
  let ready
  let fail
  const started = new Promise((resolve, reject) => { ready = resolve; fail = reject })
  lines.on('line', (line) => {
    const response = JSON.parse(line)
    if (response.event === 'ready') ready()
    if (response.event === 'failed') fail(new Error(response.error.message))
    if (!requests.has(response.id)) return
    const { resolve, reject } = requests.get(response.id)
    requests.delete(response.id)
    if (response.error) reject(Object.assign(new Error(response.error.message), response.error))
    else resolve(response.data)
  })
  child.on('close', () => {
    fail(new Error('Local service exited.'))
    for (const { reject } of requests.values()) reject(new Error('Local service exited.'))
    requests.clear()
  })
  return {
    async call(name, input = {}) {
      await started
      return new Promise((resolve, reject) => {
        const id = randomUUID()
        requests.set(id, { resolve, reject })
        child.stdin.write(JSON.stringify({ id, name, input }) + '\n')
      })
    },
    async stop() { child.stdin.end(); await closed },
  }
}

test('packaged local service copies a live WAL database and restores portable JSON with screenshots and Trash', {
  skip: !bundle, timeout: 30000,
}, async (t) => {
  const parent = directory(t)
  const previous = new Store(path.join(parent, 'OpenTalon Prototype'))
  const old = previous.dispatch.bind(previous)
  const boardId = previous.snapshot().boards[0].id
  const { task } = await request(old, 'create_task', {
    boardId, title: 'Legacy task', notes: 'Old notes', priority: 'Urgent',
    definitionOfDone: 'Verify migration', dueDate: '2026-11-11',
  })
  const { task: discarded } = await request(old, 'create_task', { boardId, title: 'Recoverable' })
  await request(old, 'trash_task', { id: discarded.id, expectedRevision: discarded.revision })
  await request(old, 'add_task_comment', {
    taskId: task.id, text: 'Screenshot', images: [{ name: 'pixel.png', mimeType: 'image/png', data: pixel }],
  })
  assert.ok(fs.existsSync(previous.file + '-wal'))

  const local = localService(path.join(parent, 'OpenTalon Native'))
  t.after(async () => { await local.stop(); previous.close() })
  const call = local.call
  const preview = await call('native_preview_electron')
  assert.equal(preview.summary.tasks, 1)
  assert.equal(preview.summary.trash, 1)
  const restore = await request(call, 'confirm_destructive_action', { token: preview.token })
  assert.ok(fs.existsSync(restore.safetyBackup))
  assert.equal(previous.snapshot().tasks.length, 2)
  const state = await call('snapshot')
  assert.deepEqual(state.agentAssignments, {})
  assert.equal(state.tasks.find((item) => item.id === task.id).dueDate, '2026-11-11')
  const { comments } = await call('list_task_comments', { taskId: task.id })
  const image = await call('read_comment_image', { imageId: comments[0].images[0].id })
  assert.equal(image.data, pixel)
  const rejected = await call('get_task', { id: task.id })
  await assert.rejects(request(call, 'move_task', {
    id: task.id, expectedRevision: rejected.task.revision, status: 'Sent to agent',
  }), { code: 'AGENT_SETUP_REQUIRED' })
  const file = path.join(parent, 'portable.json')
  await request(call, 'create_backup', { destination: file, format: 'json' })
  assert.equal(JSON.parse(fs.readFileSync(file)).format, 'opentalon-backup')
  const imported = await call('preview_destructive_action', { action: 'restore_backup', path: file })
  await request(call, 'confirm_destructive_action', { token: imported.token })
  const removal = await call('preview_destructive_action', { action: 'empty_trash' })
  assert.equal(removal.summary.tasks[0].title, 'Recoverable')
  assert.equal((await call('snapshot')).tasks.length, 2)
})

test('Settings connection test uses the bundled MCP bridge and reports an unavailable configuration', {
  skip: !bundle, timeout: 30000,
}, async (t) => {
  const folder = fs.mkdtempSync(path.join(root, 'opentalon-native-test-'))
  const service = localService(folder)
  t.after(async () => {
    try { await service.stop() }
    finally { fs.rmSync(folder, { recursive: true, force: true }) }
  })
  await assert.rejects(service.call('native_test_connection'), { code: 'CONNECTION_DISABLED' })
  await service.call('set_connection', { enabled: true })
  const status = await service.call('get_app_status')
  assert.deepEqual(await service.call('native_test_connection'), {})
  assert.equal((await service.call('get_app_status')).revision, status.revision)
  fs.renameSync(path.join(folder, 'mcp.json'), path.join(folder, 'mcp.saved.json'))
  await assert.rejects(service.call('native_test_connection'), { code: 'CONNECTION_TEST_FAILED' })
})

test('bundled stdio bridge starts the native application in the background and exposes the full tool contract', {
  skip: !bundle, timeout: 30000,
}, async (t) => {
  const folder = fs.mkdtempSync(path.join(root, 'opentalon-native-test-'))
  let appPID
  t.after(async () => {
    try {
      if (!appPID) return
      try { process.kill(appPID, 'SIGTERM') } catch { return }
      for (let attempt = 0; attempt < 40; attempt++) {
        try { process.kill(appPID, 0) } catch { return }
        await pause(50)
      }
      // Never leave an isolated app running if this test fails to shut it down.
      try { process.kill(appPID, 'SIGKILL') } catch {}
      assert.fail('The native background app did not shut down cleanly.')
    } finally {
      fs.rmSync(folder, { recursive: true, force: true })
    }
  })
  const contents = path.join(bundle, 'Contents')
  const executable = path.join(contents, 'MacOS', 'OpenTalon')
  const bridge = path.join(contents, 'Resources', 'service', 'mcp-bridge.cjs')
  const config = path.join(folder, 'mcp.json')
  const runtime = path.join(contents, 'Helpers', 'node')
  const store = new Store(folder)
  store.close()
  fs.writeFileSync(config, JSON.stringify({
    enabled: true, token: randomBytes(32).toString('hex'), port: 0, executable, launchArgs: [], profile: folder,
  }), { mode: 0o600 })
  const client = (messages) => new Promise((resolve, reject) => {
    const child = spawn(runtime, [bridge], {
      stdio: ['pipe', 'pipe', 'inherit'],
      env: { ...process.env, OPENTALON_MCP_CONFIG: config },
    })
    let output = ''
    child.stdout.on('data', (data) => { output += data })
    child.on('error', reject)
    child.on('close', (code) => {
      try {
        assert.equal(code, 0)
        resolve(output.trim().split('\n').map((line) => JSON.parse(line)))
      } catch (error) { reject(error) }
    })
    child.stdin.end(messages.map((message, index) => JSON.stringify({ jsonrpc: '2.0', id: index + 1, ...message })).join('\n') + '\n')
  })
  const [result, list] = await client([
    { method: 'tools/call', params: { name: 'get_app_status', arguments: {} } },
    { method: 'tools/list' },
  ])
  assert.ok(!result.error && !result.result.isError, JSON.stringify(result))
  const status = result.result.structuredContent
  assert.equal(status.dataLocation, folder)
  assert.ok(Number.isInteger(status.processId))
  appPID = status.processId
  assert.deepEqual(list.result.tools.map(tool => tool.name), tools.map(tool => tool.name))
  assert.equal(status.windowOpen, false)
})

test('native backup-only executable writes a daily file without touching MCP config', {
  skip: !bundle, timeout: 15000,
}, async (t) => {
  const folder = directory(t)
  const store = new Store(folder)
  const boardId = store.snapshot().boards[0].id
  await request(store.dispatch.bind(store), 'create_task', { boardId, title: 'Backup in the background' })
  store.close()
  const executable = path.join(bundle, 'Contents', 'MacOS', 'OpenTalon')
  await execute(executable, ['--daily-backup'], {
    env: { ...process.env, OPENTALON_PROFILE: folder },
  })
  const files = fs.readdirSync(path.join(folder, 'Backups', 'Daily'))
  assert.equal(files.length, 1)
  const backup = JSON.parse(fs.readFileSync(path.join(folder, 'Backups', 'Daily', files[0])))
  assert.equal(backup.tasks[0].title, 'Backup in the background')
  assert.equal(fs.existsSync(path.join(folder, 'mcp.json')), false)
})
