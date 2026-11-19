const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')
const { Connector } = require('./mcp.cjs')
function fixture(t) {
  const folder = fs.mkdtempSync('/Volumes/Expand/Codex Media/opentalon/tests/activity-')
  let store = new Store(folder)
  const cleanup = []
  t.after(async () => {
    for (const close of cleanup) await close()
    store.close()
    fs.rmSync(folder, { recursive: true, force: true })
  })
  const write = (name, input = {}) =>
    store.dispatch(name, { requestKey: randomUUID(), ...input }, 'You · test')
  return {
    folder,
    cleanup,
    get store() {
      return store
    },
    write,
    reopen() {
      store.close()
      store = new Store(folder)
    }
  }
}
const png = {
  name: 'proof.png',
  mimeType: 'image/png',
  data: fs
    .readFileSync(path.join(__dirname, '../assets/opentalon-logo-1024.png'))
    .toString('base64')
}
const activity = (f, id, extra = {}) =>
  f.store.dispatch('list_task_activity', { taskId: id, limit: 50, ...extra })
test('public MCP reports and legacy comment calls write Activity; only the private UI writes Comments', async (t) => {
  const f = fixture(t),
    { task } = await f.write('create_task', {
      boardId: f.store.boards()[0].id,
      title: 'Verify Activity'
    })
  const connector = new Connector({
    folder: f.folder,
    call: (name, args) => f.store.dispatch(name, args)
  })
  await connector.enable(true)
  f.cleanup.push(() => connector.stop())
  const { token } = JSON.parse(fs.readFileSync(connector.file))
  const rpc = async (name, args) => {
    const response = await fetch(connector.status().endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream',
        Authorization: 'Bearer ' + token
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'tools/call',
        params: { name, arguments: args }
      })
    })
    return (await response.json()).result
  }
  const input = {
    taskId: task.id,
    text: 'Agent verification passed',
    images: [png],
    requestKey: randomUUID()
  }
  const result = await rpc('add_task_activity', input)
  assert.notEqual(result.isError, true)
  assert.deepEqual(await rpc('add_task_activity', input), result)
  const old = await rpc('add_task_comment', {
    taskId: task.id,
    text: 'Older agent client',
    requestKey: randomUUID(),
    notifyAgent: true
  })
  assert.equal(old.structuredContent.redirectedToActivity, true)
  const hidden = await rpc('add_user_comment', {
    taskId: task.id,
    text: 'Should be rejected',
    requestKey: randomUUID()
  })
  assert.equal(hidden.isError, true)
  assert.equal(f.store.comments(task.id).length, 0)
  assert.equal(f.store.task(task.id).commentCount, 0)
  assert.equal(f.store.agentJobs().length, 0)
  const image = result.structuredContent.activity.images[0]
  assert.equal((await f.store.dispatch('read_comment_image', { imageId: image.id })).data, png.data)
  await f.write('add_user_comment', {
    taskId: task.id,
    text: 'Please check the Mac build too.',
    notifyAgent: false
  })
  assert.deepEqual(
    f.store.comments(task.id).map((c) => c.text),
    ['Please check the Mac build too.']
  )
  const entries = (await activity(f, task.id)).entries
  assert.equal(entries.filter((e) => e.kind === 'agent').length, 2)
  assert.equal(entries[0].summary, 'Added a comment')
  assert.equal(entries[0].detail, '')
  assert.equal(entries[0].actor, 'You · test')
  await assert.rejects(
    f.store.dispatch('move_task', {
      id: task.id,
      expectedRevision: f.store.task(task.id).revision,
      status: 'Sent to agent',
      dispatchComment: 'Pretend user comment',
      requestKey: randomUUID()
    }),
    { code: 'INVALID_ARGUMENT' }
  )
})
test('edits, moves, order, agent pickup and lifecycle changes persist in paginated activity and both backups', async (t) => {
  const f = fixture(t),
    { task } = await f.write('create_task', { boardId: f.store.boards()[0].id, title: 'Original' })
  for (let n = 0; n < 24; n++)
    await f.write('update_task', {
      id: task.id,
      expectedRevision: f.store.task(task.id).revision,
      title: 'Edit ' + n
    })
  const first = await activity(f, task.id, { limit: 10 }),
    older = await activity(f, task.id, { limit: 50, beforeSequence: first.nextBefore })
  assert.equal(first.entries.length, 10)
  assert.equal(older.entries.length, 15)
  assert.equal(older.nextBefore, null)
  assert.equal(new Set([...first.entries, ...older.entries].map((e) => e.id)).size, 25)
  const { board } = await f.write('create_board', { name: 'Destination' })
  await f.write('move_task', {
    id: task.id,
    boardId: board.id,
    status: 'In progress',
    expectedRevision: f.store.task(task.id).revision
  })
  await f.write('rename_board', {
    id: board.id,
    expectedRevision: f.store.board(board.id).revision,
    name: 'Renamed destination'
  })
  assert.ok(
    (await activity(f, task.id)).entries.some((entry) => entry.summary === 'Project renamed')
  )
  await f.write('set_task_plan', {
    id: task.id,
    expectedMarkdown: '',
    markdown: '# Check everything'
  })
  f.store.saveAgentJob({
    id: 'activity-run',
    taskId: task.id,
    agent: 'codex',
    state: 'queued',
    workingFolder: f.folder,
    threadId: null,
    createdAt: new Date().toISOString(),
    summary: 'Waiting for Mac'
  })
  f.store.saveAgentJob({
    id: 'activity-run',
    taskId: task.id,
    agent: 'codex',
    state: 'working',
    workingFolder: f.folder,
    threadId: null,
    createdAt: new Date().toISOString(),
    summary: 'Checking the build',
    pickedUpAt: new Date().toISOString()
  })
  await f.write('companion_organize_task', { id: task.id, destination: 'archive' })
  await f.write('companion_organize_task', { id: task.id, destination: 'active' })
  await f.write('trash_task', { id: task.id, expectedRevision: f.store.task(task.id).revision })
  await f.write('restore_task', { id: task.id, expectedRevision: f.store.task(task.id).revision })
  const entries = (await activity(f, task.id)).entries
  for (const phrase of [
    'Moved from',
    'Plan updated',
    'Codex picked up',
    'Archived task',
    'Restored task from Archive',
    'Moved task to Trash',
    'Restored task from Trash'
  ])
    assert.ok(
      entries.some((e) => e.summary.includes(phrase)),
      phrase
    )
  f.reopen()
  assert.deepEqual((await activity(f, task.id)).entries, entries)
  for (const format of ['json', 'sqlite']) {
    const backup = await f.write('create_backup', { format }),
      preview = await f.store.dispatch('preview_destructive_action', {
        action: 'restore_backup',
        path: backup.path
      })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.ok((await activity(f, task.id)).entries.some((e) => e.id === entries[0].id))
    assert.equal((await activity(f, task.id)).entries[0].kind, 'restore')
  }
})
test('version ten upgrades preserve old reports, user feedback and screenshot IDs without inventing authorship', async (t) => {
  const f = fixture(t),
    { task } = await f.write('create_task', {
      boardId: f.store.boards()[0].id,
      title: 'Earlier task'
    })
  await f.write('add_user_comment', {
    taskId: task.id,
    text: 'Earlier unknown message',
    images: [png],
    notifyAgent: true
  })
  const comment = f.store.comments(task.id)[0],
    imageID = comment.images[0].id
  const original = { ...comment }
  delete original.source
  f.store.db
    .prepare('UPDATE task_comments SET data=? WHERE id=?')
    .run(JSON.stringify(original), comment.id)
  const agentID = randomUUID(),
    createdAt = new Date().toISOString()
  f.store.db.prepare('INSERT INTO task_comments VALUES (?,?,?)').run(
    agentID,
    task.id,
    JSON.stringify({
      id: agentID,
      taskId: task.id,
      text: 'Earlier agent report',
      createdAt,
      agent: 'codex',
      runId: 'old-run'
    })
  )
  f.store.db.exec(
    'DROP TABLE activity_images; DROP TABLE task_activity; DELETE FROM schema_migrations WHERE version=11; PRAGMA user_version=10'
  )
  f.reopen()
  assert.equal(f.store.task(task.id).commentCount, 0)
  assert.equal(f.store.comments(task.id).length, 1)
  assert.equal(f.store.comments(task.id)[0].source, 'legacy')
  assert.equal(f.store.comments(task.id)[0].delivery, 'local')
  let entries = (await activity(f, task.id)).entries
  assert.ok(entries.some((e) => e.actor === 'Codex' && e.detail === 'Earlier agent report'))
  assert.ok(entries.some((e) => e.actor === 'Earlier message' && e.images[0]?.id === imageID))
  assert.equal((await f.store.dispatch('read_comment_image', { imageId: imageID })).data, png.data)
  f.reopen()
  assert.deepEqual((await activity(f, task.id)).entries, entries)
})
test('invalid Activity backup is rejected before replacing the current workspace', async (t) => {
  const f = fixture(t),
    { task } = await f.write('create_task', {
      boardId: f.store.boards()[0].id,
      title: 'Keep current task'
    })
  await f.store.dispatch('add_task_activity', {
    taskId: task.id,
    text: 'Saved report',
    images: [png],
    requestKey: randomUUID()
  })
  const backup = await f.write('create_backup', { format: 'json' }),
    payload = JSON.parse(fs.readFileSync(backup.path))
  assert.equal(payload.activityImages.length, 1)
  const bad = structuredClone(payload)
  bad.activity[0].task_id = 'missing'
  fs.writeFileSync(backup.path, JSON.stringify(bad))
  await assert.rejects(f.store.dispatch('inspect_backup', { path: backup.path }), {
    code: 'INVALID_BACKUP'
  })
  assert.equal(f.store.task(task.id).title, 'Keep current task')
  fs.writeFileSync(backup.path, JSON.stringify(payload))
  const preview = await f.store.dispatch('preview_destructive_action', {
    action: 'restore_backup',
    path: backup.path
  })
  await f.write('confirm_destructive_action', { token: preview.token })
  const report = (await activity(f, task.id)).entries.find((e) => e.detail === 'Saved report')
  assert.equal(
    (await f.store.dispatch('read_comment_image', { imageId: report.images[0].id })).data,
    png.data
  )
})
