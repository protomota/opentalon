const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')

test('a version-seven workspace upgrades without changing existing tasks', async (t) => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'opentalon-plan-migration-'))
  let store = new Store(folder)
  t.after(() => { store.close(); fs.rmSync(folder, { recursive: true, force: true }) })
  const { task } = await store.dispatch('create_task', {
    requestKey: randomUUID(), boardId: store.boards()[0].id, title: 'Existing task', notes: 'Keep these notes', priority: 'High',
  })
  store.db.exec('DROP TABLE task_history; ALTER TABLE tasks DROP COLUMN issue_type; ALTER TABLE tasks DROP COLUMN plan_markdown; DELETE FROM schema_migrations WHERE version>=8; PRAGMA user_version=7;')
  store.close()
  store = new Store(folder)
  assert.equal(store.task(task.id).planMarkdown, '')
  assert.equal(store.task(task.id).notes, 'Keep these notes')
  assert.equal(store.task(task.id).taskKey, task.taskKey)
  assert.equal(store.task(task.id).priority, 'High')
  assert.equal(store.db.prepare('PRAGMA user_version').get().user_version, 10)
})

test('Markdown plans persist, detect document conflicts, follow project moves and survive both backup formats', async (t) => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'opentalon-plans-'))
  const store = new Store(folder)
  t.after(() => { store.close(); fs.rmSync(folder, { recursive: true, force: true }) })
  const write = (name, args) => store.dispatch(name, { requestKey: randomUUID(), ...args })
  const boardId = store.boards()[0].id
  const original = '# Launch\n\n- [ ] Verify the installer\n\n```swift\nprint("hello")\n```\n'
  let { task } = await write('create_task', { boardId, title: 'Review launch', planMarkdown: original })
  assert.equal(task.planMarkdown, original)
  const id = task.id
  const next = original + '\n- [ ] Check iCloud sync\n'
  const edit = { id, expectedMarkdown: original, markdown: next, requestKey: randomUUID() }
  // Editing unrelated metadata must not lock or invalidate an open plan editor.
  await write('update_task', { id, expectedRevision: task.revision, priority: 'High' })
  const applied = await store.dispatch('set_task_plan', edit)
  assert.deepEqual(await store.dispatch('set_task_plan', edit), applied)
  await assert.rejects(write('set_task_plan', { id, expectedMarkdown: original, markdown: 'Stale plan' }), { code: 'CONFLICT' })
  assert.equal(store.task(id).planMarkdown, next)
  const { board } = await write('create_board', { name: 'New project' })
  await write('move_task', { id, expectedRevision: store.task(id).revision, boardId: board.id })
  assert.equal(store.task(id).planMarkdown, next)
  await write('companion_organize_task', { id, destination: 'archive' })
  for (const format of ['json', 'sqlite']) {
    const backup = await write('create_backup', { format })
    const preview = await store.dispatch('preview_destructive_action', { action: 'restore_backup', path: backup.path })
    await write('confirm_destructive_action', { token: preview.token })
    assert.equal(store.task(id).planMarkdown, next)
    assert.ok(store.task(id).archivedAt)
  }
  await write('companion_organize_task', { id, destination: 'active' })
  await write('companion_organize_task', { id, destination: 'trash' })
  await write('restore_task', { id, expectedRevision: store.task(id).revision })
  assert.equal(store.task(id).planMarkdown, next)
  assert.equal(store.task(id).deleted, false)
  await assert.rejects(write('set_task_plan', { id, expectedMarkdown: next, markdown: 'x'.repeat(100001) }), { code: 'INVALID_ARGUMENT' })
  await assert.rejects(write('set_task_plan', { id, expectedMarkdown: next, markdown: 'Plan\0content' }), { code: 'INVALID_ARGUMENT' })
  assert.equal(store.task(id).planMarkdown, next)
})

test('assistant text edits compare only their own fields and validate all values', async (t) => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'opentalon-assistant-'))
  const store = new Store(folder)
  t.after(() => { store.close(); fs.rmSync(folder, { recursive: true, force: true }) })
  const write = (name, args) => store.dispatch(name, { requestKey: randomUUID(), ...args })
  const { task } = await write('create_task', { boardId: store.boards()[0].id, title: 'Original' })
  await write('companion_set_task_field', { id: task.id, field: 'notes', expectedValue: '', value: 'New notes' })
  await write('companion_set_task_field', { id: task.id, field: 'title', expectedValue: 'Original', value: 'Renamed' })
  await write('companion_set_task_field', { id: task.id, field: 'definitionOfDone', expectedValue: '', value: 'Verified' })
  assert.equal(store.task(task.id).notes, 'New notes')
  assert.equal(store.task(task.id).title, 'Renamed')
  assert.equal(store.task(task.id).definitionOfDone, 'Verified')
  await assert.rejects(write('companion_set_task_field', { id: task.id, field: 'title', expectedValue: 'Original', value: 'Stale' }), { code: 'CONFLICT' })
  await assert.rejects(write('companion_set_task_field', { id: task.id, field: 'title', expectedValue: 'Renamed', value: '' }), { code: 'INVALID_ARGUMENT' })
  await assert.rejects(write('companion_set_task_field', { id: task.id, field: 'deleted_at', expectedValue: null, value: 'now' }), { code: 'INVALID_ARGUMENT' })
})
