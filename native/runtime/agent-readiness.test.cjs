const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { assertAgentReady } = require('./agent-readiness.cjs')
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'

test('dispatch preflight identifies missing folder, unavailable launcher and disabled MCP before queuing', () => {
  const runtimes = { 'claude-code': { installed: true }, codex: { installed: true } }
  const connection = { running: true }
  const settings = { defaultAgent: 'claude-code', workingFolder: '' }
  assert.throws(() => assertAgentReady(settings, runtimes, connection), {
    code: 'AGENT_SETUP_REQUIRED',
  })
  settings.workingFolder = '/nonexistent/opentalon-test-folder'
  assert.throws(() => assertAgentReady(settings, runtimes, connection), {
    code: 'AGENT_SETUP_REQUIRED',
  })
  settings.workingFolder = path.dirname(__filename)
  assert.doesNotThrow(() => assertAgentReady(settings, runtimes, connection))
  settings.defaultAgent = 'codex'
  assert.doesNotThrow(() => assertAgentReady(settings, runtimes, connection))
  assert.throws(() => assertAgentReady(settings, { codex: { installed: false } }, connection), {
    code: 'AGENT_NOT_INSTALLED',
  })
  assert.throws(() => assertAgentReady(settings, runtimes, { running: false }), {
    code: 'MCP_DISABLED',
  })
  assert.equal(fs.existsSync(settings.workingFolder), true)
})

test('failed dispatch leaves task and receipts unchanged; successful retry is durable after readiness changes', async (t) => {
  const { Store } = require('./store.cjs')
  const { randomUUID } = require('node:crypto')
  fs.mkdirSync(base, { recursive: true })
  const folder = fs.mkdtempSync(path.join(base, 'readiness-'))
  let running = false
  const store = new Store(folder, {
    agentReadiness: (settings) =>
      assertAgentReady(settings, { codex: { installed: true } }, { running }),
  })
  t.after(() => {
    store.close()
    fs.rmSync(folder, { recursive: true, force: true })
  })
  const write = (name, args) => store.dispatch(name, { requestKey: randomUUID(), ...args })
  await write('set_agent_settings', { defaultAgent: 'codex', workingFolder: folder })
  const task = (
    await write('create_task', { boardId: store.boards()[0].id, title: 'Only launch after setup' })
  ).task
  const input = {
    id: task.id,
    status: 'Sent to agent',
    expectedRevision: task.revision,
    requestKey: randomUUID(),
  }
  const revision = store.revision()
  await assert.rejects(store.dispatch('move_task', input), { code: 'MCP_DISABLED' })
  assert.equal(store.revision(), revision)
  assert.equal(store.task(task.id).status, 'To do')
  assert.equal(store.agentJobs().length, 0)
  running = true
  const sent = await store.dispatch('move_task', input)
  assert.equal(store.agentJobs().length, 1)
  running = false
  assert.deepEqual(await store.dispatch('move_task', input), sent)
  assert.equal(store.agentJobs().length, 1)
  await assert.rejects(
    write('create_task', {
      boardId: task.boardId,
      title: 'Not created on failed setup',
      status: 'Sent to agent',
    }),
    { code: 'MCP_DISABLED' }
  )
  assert.equal(store.list({}).tasks.length, 1)
})
