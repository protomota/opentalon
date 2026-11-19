const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')

function fixture(t) {
  const root = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'
  fs.mkdirSync(root, { recursive: true })
  const folder = fs.mkdtempSync(path.join(root, 'history-'))
  const store = new Store(folder)
  t.after(() => { store.close(); fs.rmSync(folder, { recursive: true, force: true }) })
  const write = (name, input = {}) => store.dispatch(name, { ...input, requestKey: randomUUID() })
  return { store, folder, write }
}

test('Issue/Bug defaults, field edits, filters and history survive restarts and backups', async t => {
  const { store, folder, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { task } = await write('create_task', { boardId, title: 'Original issue', notes: 'Original notes', planMarkdown: '# Original plan' })
  assert.equal(task.issueType, 'Issue')
  const first = (await store.dispatch('get_task_history', { id: task.id })).entries[0]
  assert.equal(first.state.notes, 'Original notes')
  await write('companion_set_task_field', { id: task.id, field: 'issueType', expectedValue: 'Issue', value: 'Bug' })
  assert.equal(store.task(task.id).issueType, 'Bug')
  assert.equal((await store.dispatch('list_tasks', { issueType: 'Bug' })).tasks.length, 1)
  assert.equal((await store.dispatch('list_tasks', { issueType: 'Issue' })).tasks.length, 0)
  assert.equal(store.agentJobs().length, 0)
  await assert.rejects(write('create_task', { boardId, title: 'Invalid', issueType: 'Feature' }), { code: 'INVALID_ARGUMENT' })
  await write('update_task', { id: task.id, expectedRevision: store.task(task.id).revision, title: 'Revised', notes: 'New notes', priority: 'High', dueDate: '2026-12-03' })
  await write('set_task_plan', { id: task.id, expectedMarkdown: '# Original plan', markdown: '# New plan' })
  const before = await store.dispatch('get_task_history', { id: task.id })
  assert.equal(before.entries.length, 4)
  assert.ok(before.entries[0].changedFields.includes('planMarkdown'))
  for (const format of ['json', 'sqlite']) {
    const backup = await write('create_backup', { format })
    const preview = await store.dispatch('preview_destructive_action', { action: 'restore_backup', path: backup.path })
    await write('confirm_destructive_action', { token: preview.token })
    assert.equal(store.task(task.id).issueType, 'Bug')
    assert.equal(store.task(task.id).planMarkdown, '# New plan')
    assert.ok((await store.dispatch('get_task_history', { id: task.id })).entries.some(entry => entry.id === first.id))
  }
  const input = { id: task.id, historyID: first.id, expectedRevision: store.task(task.id).revision, requestKey: randomUUID() }
  const restored = await store.dispatch('restore_task_revision', input)
  assert.deepEqual(await store.dispatch('restore_task_revision', input), restored)
  assert.equal(restored.task.title, 'Original issue')
  assert.equal(restored.task.notes, 'Original notes')
  assert.equal(restored.task.planMarkdown, '# Original plan')
  assert.equal(restored.task.issueType, 'Issue')
  assert.equal(restored.task.dueDate, null)
  const history = await store.dispatch('get_task_history', { id: task.id })
  assert.equal(history.entries[0].action, 'restore_task_revision')
  assert.ok(history.entries.some(entry => entry.state.planMarkdown === '# New plan'))
  const other = new Store(folder)
  assert.deepEqual(await other.dispatch('get_task_history', { id: task.id }), history)
  other.close()
})

test('history pagination is stable, excludes unchanged saves and rejects stale or foreign restores', async t => {
  const { store, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { task } = await write('create_task', { boardId, title: 'Revision 1' })
  for (let index = 2; index <= 26; index++) await write('update_task', { id: task.id, expectedRevision: store.task(task.id).revision, title: `Revision ${index}` })
  const first = await store.dispatch('get_task_history', { id: task.id, limit: 10 })
  assert.deepEqual(first.entries.map(entry => entry.version), [26,25,24,23,22,21,20,19,18,17])
  const next = await store.dispatch('get_task_history', { id: task.id, limit: 20, beforeVersion: first.nextBefore })
  assert.equal(next.entries.length, 16)
  assert.equal(next.entries.at(-1).state.title, 'Revision 1')
  assert.equal(next.nextBefore, null)
  await write('update_task', { id: task.id, expectedRevision: store.task(task.id).revision, title: 'Revision 26' })
  assert.equal((await store.dispatch('get_task_history', { id: task.id })).entries.length, 26)
  await assert.rejects(write('restore_task_revision', { id: task.id, historyID: next.entries[0].id, expectedRevision: task.revision }), { code: 'CONFLICT' })
  const { task: other } = await write('create_task', { boardId, title: 'Other task' })
  await assert.rejects(write('restore_task_revision', { id: other.id, historyID: first.entries[0].id, expectedRevision: other.revision }), { code: 'NOT_FOUND' })
  assert.equal(store.task(task.id).title, 'Revision 26')
})

test('restoring an agent revision stops dispatch, retains comments, reopens Archive and respects project task keys', async t => {
  const { store, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { task } = await write('create_task', { boardId, title: 'Recover me', issueType: 'Bug' })
  const original = (await store.dispatch('get_task_history', { id: task.id })).entries[0]
  const { board } = await write('create_board', { name: 'Destination' })
  await write('move_task', { id: task.id, boardId: board.id, expectedRevision: task.revision, status: 'In progress' })
  await write('add_task_comment', { taskId: task.id, text: 'Keep this feedback' })
  await write('companion_organize_task', { id: task.id, destination: 'archive' })
  await write('restore_task_revision', { id: task.id, historyID: original.id, expectedRevision: store.task(task.id).revision })
  assert.equal(store.task(task.id).boardId, boardId)
  assert.equal(store.task(task.id).status, 'To do')
  assert.equal(store.task(task.id).archivedAt, null)
  assert.match(store.task(task.id).taskKey, /^[A-Z]{3}-\d+$/)
  assert.equal((await store.dispatch('list_task_comments', { taskId: task.id })).comments[0].text, 'Keep this feedback')
  // Simulate a persisted queued dispatch without launching an external agent.
  const history = require('./task-history.cjs')
  store.db.prepare("UPDATE tasks SET status='Sent to agent' WHERE id=?").run(task.id)
  history.record(store, store.task(task.id), 'move_task')
  store.saveAgentJob({ id: 'history-test-run', taskId: task.id, state: 'queued', agent: 'codex' })
  store.assignAgent(task.id, 'history-test-run')
  const sent = (await store.dispatch('get_task_history', { id: task.id })).entries[0]
  await write('restore_task_revision', { id: task.id, historyID: sent.id, expectedRevision: store.task(task.id).revision })
  assert.equal(store.task(task.id).status, 'To do')
  assert.equal(store.agentJobs()[0].state, 'canceled')
  assert.equal(store.assignedRun(task.id), null)
  await write('trash_task', { id: task.id, expectedRevision: store.task(task.id).revision })
  await assert.rejects(write('restore_task_revision', { id: task.id, historyID: original.id, expectedRevision: store.task(task.id).revision }), { code: 'IN_TRASH' })
})

test('corrupt revision history cannot replace a healthy workspace', async t => {
  const { store, write } = fixture(t)
  const { task } = await write('create_task', { boardId: store.boards()[0].id, title: 'Keep my current data' })
  const backup = await write('create_backup', { format: 'json' })
  const payload = JSON.parse(fs.readFileSync(backup.path))
  payload.taskHistory[0].state_json = JSON.stringify({ ...JSON.parse(payload.taskHistory[0].state_json), issueType: 'Invalid' })
  fs.writeFileSync(backup.path, JSON.stringify(payload))
  await assert.rejects(store.dispatch('inspect_backup', { path: backup.path }), { code: 'INVALID_BACKUP' })
  assert.equal(store.task(task.id).title, 'Keep my current data')
})
