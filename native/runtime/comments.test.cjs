const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')
const { AgentRunner } = require('./agent-runner.cjs')
const { Connector } = require('./mcp.cjs')
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'
const image = {
  name: 'Screenshot.png',
  mimeType: 'image/png',
  data: fs
    .readFileSync(path.resolve(__dirname, '../assets/opentalon-logo-1024.png'))
    .toString('base64'),
}
function fixture(t) {
  fs.mkdirSync(base, { recursive: true })
  const folder = fs.mkdtempSync(path.join(base, 'comments-'))
  const store = new Store(folder)
  const cleanup = []
  t.after(async () => {
    for (const close of cleanup.reverse()) await close()
    store.close()
    fs.rmSync(folder, { recursive: true, force: true })
  })
  const write = (name, input) => store.dispatch(name, { ...input, requestKey: randomUUID() })
  const task = (title) =>
    write('create_task', { boardId: store.boards()[0].id, title, status: 'In progress' }).then(
      (result) => result.task
    )
  const previous = (task, agent = 'claude-code') => {
    const job = store.saveAgentJob({
      id: randomUUID(),
      taskId: task.id,
      agent,
      workingFolder: folder,
      threadId: randomUUID(),
      state: 'review',
      summary: 'First response',
      createdAt: new Date().toISOString(),
    })
    store.assignAgent(task.id, job.id)
    return job
  }
  const comment = (task, text = 'Please update this.', images = []) =>
    write('add_user_comment', { taskId: task.id, text, images, notifyAgent: true }).then(
      (result) => result.comment
    )
  return { store, write, task, previous, comment, folder, cleanup }
}
for (const agent of ['claude-code', 'codex'])
  test(`${agent} checks at five minutes, resumes the same conversation and passes screenshots`, async (t) => {
    const f = fixture(t),
      { task } = await f.write('create_task', {
        boardId: f.store.boards()[0].id, title: 'Feedback', status: 'Done',
      })
    const previous = f.previous(task, agent)
    const comment = await f.comment(task, 'Use this screenshot.', [image])
    await f.write('set_agent_settings', {
      defaultAgent: agent === 'codex' ? 'claude-code' : 'codex',
      workingFolder: base,
    })
    const launched = []
    const runner = new AgentRunner({
      store: f.store,
      connector: {
        status: () => ({ running: true }),
        configuration: () => ({
          mcpServers: { opentalon: { command: '/app', args: [], env: {} } },
        }),
      },
      openExternal: () => {},
      resolveExecutable: (agent) => agent,
      spawnTransport(file, args, cwd, message) {
        const transport = {
          file,
          args,
          cwd,
          message,
          messages: [],
          request: async (method, params) => {
            transport.messages.push({ method, params })
            return method === 'thread/resume' ? { thread: { id: params.threadId } } : {}
          },
          write: (value) => transport.messages.push(value),
          close() {},
        }
        launched.push(transport)
        return transport
      },
    })
    f.cleanup.push(() => runner.close())
    await runner.tick()
    assert.equal(launched.length, 0, 'No early wake-up before five minutes')
    runner.lastCommentCheck = Date.now() - 300001
    await runner.tick()
    assert.equal(launched.length, 1)
    const job = f.store.agentJobs()[0]
    assert.equal(job.agent, agent, 'Changing defaults must not switch an existing conversation')
    assert.equal(job.threadId, previous.threadId)
    assert.equal(job.workingFolder, previous.workingFolder)
    assert.deepEqual(job.commentIds, [comment.id])
    assert.equal(f.store.comments(task.id)[0].delivery, 'queued')
    assert.equal(f.store.task(task.id).status, 'Done', 'Queued does not mean the agent picked it up')
    await runner.tick()
    assert.equal(f.store.agentJob(job.id).state, 'starting')
    const transport = launched[0]
    if (agent === 'claude-code') {
      assert.equal(transport.args[transport.args.indexOf('--resume') + 1], previous.threadId)
      assert.ok(!transport.args.includes('--session-id'))
      assert.equal(transport.messages.at(-1).message.content[1].source.data, image.data)
      await transport.message({ type: 'system', subtype: 'init', session_id: previous.threadId })
    } else {
      assert.ok(transport.messages.some((message) => message.method === 'thread/resume'))
      assert.ok(!transport.messages.some((message) => message.method === 'thread/start'))
      assert.equal(
        transport.messages.at(-1).params.input[1].url,
        `data:image/png;base64,${image.data}`
      )
      await transport.message({ method: 'turn/started', params: { threadId: previous.threadId } })
    }
    assert.equal(f.store.comments(task.id)[0].delivery, 'delivered')
    const pickedUpAt = f.store.agentJob(job.id).pickedUpAt
    assert.ok(Number.isFinite(Date.parse(pickedUpAt)))
    assert.equal(f.store.comments(task.id)[0].pickedUpAt, pickedUpAt)
    assert.equal(f.store.task(task.id).status, 'In progress')
    await runner.finish(job.id, 'review', 'Comments addressed')
    runner.lastCommentCheck = Date.now() - 300001
    await runner.tick()
    assert.equal(launched.length, 1, 'A delivered comment must never be replayed')
  })
test('comments are idempotent, defer busy tasks, hold completion for unread feedback and never wake on agent notes', async (t) => {
  const f = fixture(t),
    task = await f.task('Working')
  const job = f.previous(task)
  await f.store.updateAgentJob(job.id, { state: 'working' })
  const args = {
    taskId: task.id,
    text: 'New direction',
    images: [image],
    notifyAgent: true,
    requestKey: randomUUID(),
  }
  const saved = await f.store.dispatch('add_user_comment', args)
  assert.deepEqual(await f.store.dispatch('add_user_comment', args), saved)
  assert.equal(f.store.comments(task.id).length, 1)
  assert.equal((await f.store.queueCommentFollowups()).queued, 0)
  await f.write('report_agent_progress', {
    runId: job.id,
    state: 'done',
    summary: 'Earlier work complete',
    proof:
      'Earlier requested checks passed; newly pending feedback is still waiting and must keep this task open.',
    definitionOfDoneMet: true,
  })
  assert.equal(f.store.task(task.id).status, 'In progress', 'Unread feedback keeps the task open')
  assert.equal((await f.store.queueCommentFollowups()).queued, 1)
  const queued = f.store.agentJobs()[0]
  assert.equal((await f.store.queueCommentFollowups()).queued, 0)
  await f.store.updateAgentJob(queued.id, { state: 'failed' })
  assert.equal(f.store.comments(task.id)[0].delivery, 'needs-review')
  await f.write('retry_task_comment', { id: saved.comment.id })
  assert.equal((await f.store.queueCommentFollowups()).queued, 1)
  const agentNote = await f.write('add_task_activity', { taskId: task.id, text: 'Agent note' })
  assert.equal(agentNote.activity.kind, 'agent')
  assert.equal(f.store.commentImage(saved.comment.images[0].id).data, image.data)
  await assert.rejects(f.comment(task, '', []), { code: 'EMPTY_COMMENT' })
  await assert.rejects(
    f.comment(task, 'Bad image', [
      { ...image, data: Buffer.from('not an image').toString('base64') },
    ]),
    { code: 'INVALID_IMAGE' }
  )
  await assert.rejects(f.comment(task, 'Too many', [image, image, image, image]), {
    code: 'INVALID_ARGUMENT',
  })
  assert.equal(f.store.comments(task.id).length, 1, 'Only the user note belongs in Comments')
})
test('comments and screenshot bytes round-trip in JSON and SQLite; restored feedback is paused and legacy v2 imports', async (t) => {
  const f = fixture(t),
    target = fixture(t),
    task = await f.task('Portable comments')
  f.previous(task)
  const comment = await f.comment(task, 'Image retained after restore', [image])
  const trash = await f.task('Trashed with comments')
  await f.comment(trash, 'Keep this too')
  await f.write('trash_task', { id: trash.id, expectedRevision: trash.revision })
  for (const format of ['json', 'sqlite']) {
    const backup = await f.write('create_backup', { format })
    const preview = await target.store.dispatch('preview_destructive_action', {
      action: 'restore_backup',
      path: backup.path,
    })
    await target.write('confirm_destructive_action', { token: preview.token })
    assert.equal(target.store.comments(task.id)[0].text, comment.text)
    assert.equal(target.store.comments(task.id)[0].delivery, 'needs-review')
    assert.equal(target.store.commentImage(comment.images[0].id).data, image.data)
    assert.equal(target.store.comments(trash.id).length, 1)
    assert.equal((await target.store.queueCommentFollowups()).queued, 0)
  }
  const backup = await f.write('create_backup', { format: 'json' })
  const json = JSON.parse(fs.readFileSync(backup.path, 'utf8'))
  const legacy = path.join(f.folder, 'legacy-v2.json')
  fs.writeFileSync(
    legacy,
    JSON.stringify({ ...json, formatVersion: 2, comments: undefined, commentImages: undefined })
  )
  assert.equal((await f.store.inspect(legacy)).comments.length, 0)
  const invalid = path.join(f.folder, 'bad-comment.json')
  fs.writeFileSync(
    invalid,
    JSON.stringify({ ...json, commentImages: [{ ...json.commentImages[0], commentId: 'missing' }] })
  )
  await assert.rejects(f.store.inspect(invalid), { code: 'INVALID_BACKUP' })
})
test('MCP returns screenshot image content without duplicating base64 in structured metadata', async (t) => {
  const f = fixture(t),
    task = await f.task('Image tool')
  const comment = await f.comment(task, '', [image])
  const connector = new Connector({
    folder: f.folder,
    call: (name, args) => f.store.dispatch(name, args),
  })
  await connector.enable(true)
  f.cleanup.push(() => connector.stop())
  const response = await fetch(connector.status().endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${connector.config.token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json, text/event-stream',
    },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: 'read_comment_image', arguments: { imageId: comment.images[0].id } },
    }),
  })
  const data = await response.json()
  assert.equal(data.result.content[0].type, 'image')
  assert.equal(data.result.content[0].data, image.data)
  assert.ok(!data.result.structuredContent.data)
})
