const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const http = require('node:http')
const { spawn } = require('node:child_process')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')
const { Connector } = require('./mcp.cjs')
const { forward } = require('./mcp-bridge.cjs')
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'
async function fixture(t) {
  fs.mkdirSync(base, { recursive: true })
  const folder = fs.mkdtempSync(path.join(base, 'mcp-'))
  let changes = 0
  const store = new Store(folder, { changed: () => changes++ })
  const connector = new Connector({ folder, call: (name, args) => store.dispatch(name, args) })
  await connector.enable(true)
  t.after(async () => {
    await connector.stop()
    await store.queue
    store.close()
    fs.rmSync(folder, { recursive: true, force: true })
  })
  const config = JSON.parse(fs.readFileSync(connector.file, 'utf8'))
  const headers = {
    'Content-Type': 'application/json',
    Accept: 'application/json, text/event-stream',
    Authorization: `Bearer ${config.token}`,
  }
  const rpc = async (message, extraHeaders = {}, body) =>
    fetch(connector.status().endpoint, {
      method: 'POST',
      headers: { ...headers, ...extraHeaders },
      body: body || JSON.stringify(message),
    })
  const call = async (name, args = {}) => {
    const response = await rpc({
      jsonrpc: '2.0',
      id: randomUUID(),
      method: 'tools/call',
      params: { name, arguments: args },
    })
    const result = (await response.json()).result
    if (result.isError) {
      const error = new Error(result.structuredContent.message)
      error.code = result.structuredContent.code
      throw error
    }
    return result.structuredContent
  }
  const write = (name, args = {}) => call(name, { requestKey: randomUUID(), ...args })
  return {
    folder,
    store,
    connector,
    rpc,
    call,
    write,
    get changes() {
      return changes
    },
  }
}

test('real HTTP MCP handshake, discovery, shared actions and guarded recovery', async (t) => {
  const f = await fixture(t),
    { call, write, rpc, store } = f
  const initialized = await rpc({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2025-11-25',
      capabilities: {},
      clientInfo: { name: 'OpenTalon integration test', version: '1' },
    },
  })
  assert.equal((await initialized.json()).result.serverInfo.name, 'OpenTalon')
  const notification = await rpc({ jsonrpc: '2.0', method: 'notifications/initialized' })
  assert.equal(notification.status, 202)
  const discovery = await rpc({ jsonrpc: '2.0', id: 2, method: 'tools/list' })
  assert.equal((await discovery.json()).result.tools.length, 24)
  let board = (await write('create_board', { name: 'From agent' })).board
  board = (
    await write('rename_board', { id: board.id, name: 'Renamed', expectedRevision: board.revision })
  ).board
  let a = (
    await write('create_task', {
      boardId: board.id,
      title: 'Agent task',
      notes: 'Searchable context',
    })
  ).task
  const b = (await write('create_task', { boardId: board.id, title: 'Other task' })).task
  a = (await write('move_task', { id: a.id, afterId: b.id, expectedRevision: a.revision })).task
  assert.equal((await call('list_tasks', { query: 'Searchable' })).tasks[0].id, a.id)
  assert.equal(store.task(a.id).notes, 'Searchable context')
  a = (
    await store.dispatch('update_task', {
      id: a.id,
      title: 'UI path',
      expectedRevision: a.revision,
      requestKey: randomUUID(),
    })
  ).task
  assert.equal((await call('get_task', { id: a.id })).task.title, 'UI path')
  a = (await write('update_task', { id: a.id, status: 'Done', expectedRevision: a.revision })).task
  a = (
    await write('move_task', {
      id: a.id,
      boardId: store.boards()[0].id,
      status: 'In progress',
      expectedRevision: a.revision,
    })
  ).task
  a = (await write('trash_task', { id: a.id, expectedRevision: a.revision })).task
  a = (await write('restore_task', { id: a.id, expectedRevision: a.revision })).task
  const backup = await write('create_backup')
  const inspected = await call('inspect_backup', { path: backup.path })
  assert.equal(inspected.tasks, 2)
  const preview = await call('preview_destructive_action', {
    action: 'restore_backup',
    path: backup.path,
  })
  await write('confirm_destructive_action', { token: preview.token })
  assert.ok(f.changes >= 10)
  assert.ok(!JSON.stringify(await call('get_app_status')).includes('token'))
  const bridged = await forward(
    {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: { name: 'get_task', arguments: { id: a.id } },
    },
    f.connector.file
  )
  assert.equal(bridged.result.structuredContent.task.title, 'UI path')
})

test('connection protection, bounded requests, disabled listener, independent ports', async (t) => {
  const f = await fixture(t),
    { rpc, connector } = f
  const ping = { jsonrpc: '2.0', id: 1, method: 'ping' }
  assert.equal((await rpc(ping, { Authorization: 'Bearer wrong' })).status, 401)
  assert.equal((await rpc(ping, { Origin: 'https://example.com' })).status, 403)
  const foreignHost = await new Promise((resolve, reject) => {
    const request = http.request(
      connector.status().endpoint,
      { method: 'POST', headers: { Host: 'evil.example' } },
      (response) => {
        response.resume()
        resolve(response.statusCode)
      }
    )
    request.on('error', reject)
    request.end(JSON.stringify(ping))
  })
  assert.equal(foreignHost, 403)
  assert.equal((await rpc(ping, {}, 'x'.repeat(1024 * 1024 + 1))).status, 413)
  assert.equal((await rpc(ping, {}, '[{}]')).status, 400)
  assert.equal(fs.statSync(connector.file).mode & 0o777, 0o600)
  const oldConfig = JSON.parse(fs.readFileSync(connector.file, 'utf8'))
  connector.reset()
  assert.notEqual(JSON.parse(fs.readFileSync(connector.file, 'utf8')).token, oldConfig.token)
  assert.equal((await rpc(ping)).status, 401)
  const other = await fixture(t)
  assert.notEqual(connector.config.port, other.connector.config.port)
  await connector.enable(false)
  const disabled = await forward(ping, connector.file)
  assert.match(disabled.error.message, /disabled/)
  assert.equal(connector.status().running, false)
})

test('stdio bridge sends only valid JSON-RPC and uses no standalone server', async (t) => {
  const f = await fixture(t)
  const input = [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'list_boards' } },
  ]
  const child = spawn(process.execPath, [path.join(__dirname, 'mcp-bridge.cjs')], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', OPENTALON_MCP_CONFIG: f.connector.file },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  let stdout = '',
    stderr = ''
  child.stdout.on('data', (data) => (stdout += data))
  child.stderr.on('data', (data) => (stderr += data))
  child.stdin.end(input.map((message) => JSON.stringify(message)).join('\n') + '\n')
  await new Promise((resolve, reject) => {
    child.on('error', reject)
    child.on('close', (code) => (code ? reject(new Error(stderr)) : resolve()))
  })
  const responses = stdout
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line))
  assert.equal(responses.length, 2)
  assert.equal(responses[1].result.structuredContent.boards[0].name, 'Tasks')
})
