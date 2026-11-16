const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { DatabaseSync } = require('node:sqlite')
const { Store, FORMAT } = require('./store.cjs')
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'
fs.mkdirSync(base, { recursive: true })

test('companion field edits can interleave and repeat without losing unrelated changes', async (t) => {
  const { store, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { board } = await write('create_board', { name: 'Studio' })
  const { task } = await write('create_task', { boardId, title: 'Edit task fields' })
  const edit = (field, expectedValue, value) => write('companion_set_task_field', { id: task.id, field, expectedValue, value })
  await edit('dueDate', null, '2026-11-17')
  await edit('priority', 'None', 'High')
  await edit('project', boardId, board.id)
  await edit('status', 'To do', 'In progress')
  await edit('dueDate', '2026-11-17', '2026-11-20')
  await edit('dueDate', '2026-11-20', null)
  await edit('priority', 'High', 'Medium')
  await assert.rejects(edit('dueDate', '2026-11-20', '2026-11-21'), { code: 'CONFLICT' })
  const current = store.task(task.id)
  assert.equal(current.boardId, board.id)
  assert.equal(current.taskKey, 'STU-001')
  assert.throws(() => store.task(task.taskKey), { code: 'NOT_FOUND' })
  assert.equal(current.status, 'In progress')
  assert.equal(current.priority, 'Medium')
  assert.equal(current.dueDate, null)
})

test('companion dragging updates the shared order and rejects a moved anchor', async (t) => {
  const f = fixture(t)
  const boardId = f.store.boards()[0].id
  const create = async (title) => (await f.write('create_task', { boardId, title, priority: 'Medium' })).task
  const first = await create('First')
  const second = await create('Second')
  const third = await create('Third')
  const input = {
    id: third.id, boardId, status: 'To do', anchorId: first.id, before: true, requestKey: randomUUID(),
  }
  const result = await f.run('companion_reorder_task', input)
  await f.write('companion_reorder_task', { ...input, id: second.id, requestKey: randomUUID() })
  assert.deepEqual(await f.run('companion_reorder_task', input), result)
  f.restart()
  assert.deepEqual(
    (await f.run('list_tasks', { boardId, status: 'To do' })).tasks.map((task) => task.id),
    [third.id, second.id, first.id]
  )
  assert.equal(f.store.task(third.id).priority, 'Medium')
  assert.equal(f.store.agentJobs().length, 0)
  await f.write('move_task', { id: first.id, status: 'In progress', expectedRevision: f.store.task(first.id).revision })
  await assert.rejects(
    f.write('companion_reorder_task', { ...input, requestKey: randomUUID() }),
    { code: 'CONFLICT' }
  )
  assert.deepEqual(
    (await f.run('list_tasks', { boardId, status: 'To do' })).tasks.map((task) => task.id),
    [third.id, second.id]
  )
})

test('tasks archive after seven days in Done and can reopen with their history', async (t) => {
  const { store, run, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { task: original } = await write('create_task', { boardId, title: 'Completed task' })
  const { task } = await write('move_task', { id: original.id, status: 'Done', expectedRevision: original.revision })
  const { task: active } = await write('create_task', { boardId, title: 'Still open' })
  await write('add_task_comment', { taskId: task.id, text: 'Saved context' })
  const { task: edited } = await write('update_task', { id: task.id, title: 'Edited after completion', expectedRevision: store.task(task.id).revision })
  assert.equal(edited.completedAt, task.completedAt)
  const deadline = Date.parse(task.completedAt) + 7 * 86400_000
  assert.equal(store.archiveCompletedTasks(new Date(deadline - 1)), 0)
  const previousRevision = store.revision()
  assert.equal(store.archiveCompletedTasks(new Date(deadline)), 1)
  assert.equal(store.revision(), previousRevision + 1)
  assert.equal(store.archiveCompletedTasks(new Date(deadline)), 0)
  assert.equal(store.revision(), previousRevision + 1)
  const archived = store.task(task.taskKey)
  assert.equal(archived.archivedAt, new Date(deadline).toISOString())
  assert.equal(archived.deleted, false)
  assert.equal(store.task(active.id).archivedAt, null)
  assert.equal((await run('list_trash')).total, 0)
  await assert.rejects(run('preview_destructive_action', { action: 'purge_tasks', taskIds: [task.id] }), { code: 'INVALID_STATE' })
  for (const format of ['json', 'sqlite']) {
    const backup = await write('create_backup', { format })
    const preview = await run('preview_destructive_action', { action: 'restore_backup', path: backup.path })
    await write('confirm_destructive_action', { token: preview.token })
    assert.equal(store.task(task.taskKey).archivedAt, archived.archivedAt)
    assert.equal((await run('list_task_comments', { taskId: task.id })).comments[0].text, 'Saved context')
  }
  const { task: reopened } = await write('move_task', {
    id: task.id, status: 'To do', expectedRevision: store.task(task.id).revision,
  })
  assert.equal(reopened.archivedAt, null)
  assert.equal(reopened.completedAt, null)
  assert.equal(reopened.taskKey, task.taskKey)
  const { task: completedAgain } = await write('move_task', {
    id: task.id, status: 'Done', expectedRevision: reopened.revision,
  })
  assert.equal(completedAgain.completedAt, completedAgain.updatedAt)
  assert.equal(store.archiveCompletedTasks(new Date(Date.parse(completedAgain.completedAt) + 86400_000)), 0)
})

test('archive and trash deletion are scoped and stale companion requests preserve tasks', async (t) => {
  const { store, run, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { task: first } = await write('create_task', { boardId, title: 'Desktop archive task', status: 'Done' })
  const { task: second } = await write('create_task', { boardId, title: 'Phone archive task', status: 'Done' })
  const { task: third } = await write('create_task', { boardId, title: 'Recoverable archive task', status: 'Done' })
  const { task: active } = await write('create_task', { boardId, title: 'Keep active' })
  const sevenDaysLater = Date.parse(third.completedAt) + 7 * 86400_000
  assert.equal(store.archiveCompletedTasks(new Date(sevenDaysLater)), 3)
  await assert.rejects(run('preview_destructive_action', { action: 'purge_archived_tasks', taskIds: [active.id] }), { code: 'INVALID_STATE' })
  const { token } = await run('preview_destructive_action', { action: 'purge_archived_tasks', taskIds: [first.id] })
  await write('confirm_destructive_action', { token })
  await assert.rejects(run('get_task', { id: first.id }), { code: 'NOT_FOUND' })

  const deletion = { id: second.id, expectedRevision: second.revision, requestKey: randomUUID() }
  const deleted = await run('companion_delete_archived_task', deletion)
  assert.equal(deleted.permanentlyDeleted, 1)
  assert.deepEqual(await run('companion_delete_archived_task', deletion), deleted)
  await assert.rejects(write('companion_delete_archived_task', { id: active.id, expectedRevision: active.revision }), { code: 'INVALID_STATE' })

  const { task: trashed } = await write('trash_task', { id: third.id, expectedRevision: third.revision })
  const stale = { expectedRevision: store.revision() }
  const { task: restored } = await write('restore_task', { id: trashed.id, expectedRevision: trashed.revision })
  assert.equal(restored.archivedAt, trashed.archivedAt)
  await assert.rejects(write('companion_empty_trash', stale), { code: 'CONFLICT' })
  await write('trash_task', { id: restored.id, expectedRevision: restored.revision })
  assert.equal((await write('companion_empty_trash', { expectedRevision: store.revision() })).permanentlyDeleted, 1)
  assert.equal((await run('list_trash')).total, 0)
  assert.equal(store.task(active.id).title, 'Keep active')
})

test('bulk Archive actions affect only the reviewed archived tasks', async (t) => {
  const { store, write } = fixture(t)
  const boardId = store.boards()[0].id
  const { task: first } = await write('create_task', { boardId, title: 'Archive one', status: 'Done' })
  const { task: second } = await write('create_task', { boardId, title: 'Archive two', status: 'Done' })
  const { task: active } = await write('create_task', { boardId, title: 'Keep open' })
  assert.equal(store.archiveCompletedTasks(new Date(Date.parse(second.completedAt) + 7 * 86400_000)), 2)
  const review = { expectedRevision: store.revision(), permanently: false, taskIds: [first.id, second.id] }
  await assert.rejects(write('manage_archived_tasks', { ...review, taskIds: [first.id, active.id] }), { code: 'INVALID_STATE' })
  assert.equal(store.task(first.id).deleted, false)
  assert.equal((await write('manage_archived_tasks', review)).trashed, 2)
  assert.equal(store.task(first.id).deleted, true)
  assert.equal(store.task(second.id).deleted, true)
  await assert.rejects(write('manage_archived_tasks', { ...review, permanently: true }), { code: 'CONFLICT' })
  const { task: restored } = await write('restore_task', { id: first.id, expectedRevision: store.task(first.id).revision })
  assert.ok(restored.archivedAt)
  const result = await write('manage_archived_tasks', {
    expectedRevision: store.revision(), permanently: true, taskIds: [restored.id],
  })
  assert.equal(result.permanentlyDeleted, 1)
  assert.throws(() => store.task(first.id), { code: 'NOT_FOUND' })
  assert.equal(store.task(second.id).deleted, true)
  assert.equal(store.task(active.id).deleted, false)
})

test('project moves allocate the next destination task key and preserve task history through restores', async (t) => {
  const f = fixture(t)
  const fallback = f.store.boards()[0]
  const fields = { boardId: fallback.id, title: 'Review launch notes', newProjectName: 'Voxley', requestKey: randomUUID() }
  const { task: first } = await f.run('capture_task', fields)
  assert.equal(first.taskKey, 'VOX-001')
  assert.equal((await f.run('capture_task', fields)).task.id, first.id)
  const { task: second } = await f.write('capture_task', { ...fields, requestKey: randomUUID(), newProjectName: 'voxley' })
  assert.equal(second.boardId, first.boardId)
  assert.equal(second.taskKey, 'VOX-002')
  assert.equal(f.store.boards().length, 2)
  const { task: existing } = await f.write('create_task', { boardId: fallback.id, title: 'Existing task' })
  assert.equal(existing.taskKey, 'TAS-001')
  await f.write('trash_task', { id: existing.id, expectedRevision: existing.revision })
  await f.write('add_task_comment', { taskId: first.id, text: 'Keep this context' })
  const move = {
    id: first.id,
    boardId: fallback.id,
    expectedRevision: (await f.run('get_task', { id: first.id })).task.revision,
    requestKey: randomUUID(),
  }
  const result = await f.run('move_task', move)
  const { task: moved } = result
  assert.equal(moved.id, first.id)
  assert.equal(moved.boardId, fallback.id)
  assert.equal(moved.taskKey, 'TAS-002')
  assert.deepEqual(await f.run('move_task', move), result)
  await assert.rejects(f.run('get_task', { id: 'VOX-001' }), { code: 'NOT_FOUND' })
  const { task: completed } = await f.write('move_task', {
    id: moved.id,
    boardId: fallback.id,
    expectedRevision: moved.revision,
    status: 'Done',
  })
  assert.equal(completed.taskKey, moved.taskKey)
  for (const format of ['json', 'sqlite']) {
    const backup = await f.write('create_backup', { format })
    const preview = await f.run('preview_destructive_action', { action: 'restore_backup', path: backup.path })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.equal((await f.run('get_task', { id: 'tas-002' })).task.id, first.id)
    assert.equal((await f.run('list_task_comments', { taskId: first.id })).comments[0].text, 'Keep this context')
  }
  assert.equal((await f.write('create_task', { boardId: fallback.id, title: 'Next destination task' })).task.taskKey, 'TAS-003')
  assert.equal((await f.write('create_task', { boardId: second.boardId, title: 'Next task' })).task.taskKey, 'VOX-003')
})

function fixture(t) {
  const folder = fs.mkdtempSync(path.join(base, 'store-'))
  let store = new Store(folder)
  t.after(() => {
    store.close()
    fs.rmSync(folder, { recursive: true, force: true })
  })
  const run = (name, args = {}) => store.dispatch(name, args)
  const write = (name, args = {}) => run(name, { requestKey: randomUUID(), ...args })
  return {
    folder,
    run,
    write,
    get store() {
      return store
    },
    restart() {
      store.close()
      store = new Store(folder)
    },
  }
}
test('due dates survive editing, restart, both backup formats and v4 migration; invalid dates are rejected', async (t) => {
  const f = fixture(t)
  const boardId = f.store.boards()[0].id
  let task = (
    await f.write('create_task', { boardId, title: 'Due date task', dueDate: '2026-11-10' })
  ).task
  assert.equal(task.dueDate, '2026-11-10')
  for (const dueDate of [
    '2026-02-30',
    '2025-02-29',
    '2026-13-01',
    '2026-11-10T12:00:00Z',
    '',
    false,
  ])
    await assert.rejects(
      f.write('update_task', { id: task.id, expectedRevision: task.revision, dueDate }),
      { code: 'INVALID_ARGUMENT' }
    )
  task = (
    await f.write('update_task', {
      id: task.id,
      expectedRevision: task.revision,
      dueDate: '2028-02-29',
    })
  ).task
  f.restart()
  assert.equal(f.store.task(task.id).dueDate, '2028-02-29')
  for (const format of ['json', 'sqlite']) {
    const backup = await f.write('create_backup', { format })
    const preview = await f.run('preview_destructive_action', {
      action: 'restore_backup',
      path: backup.path,
    })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.equal(f.store.task(task.id).dueDate, '2028-02-29')
  }
  const backup = await f.write('create_backup', { format: 'sqlite' })
  const db = new DatabaseSync(backup.path)
  db.exec(
    'DROP TRIGGER tasks_record_completion_on_insert; DROP TRIGGER tasks_record_completion_on_move; ALTER TABLE tasks DROP COLUMN completed_at; ALTER TABLE tasks DROP COLUMN archived_at; DROP INDEX tasks_task_key; DROP INDEX boards_project_key; ALTER TABLE tasks DROP COLUMN task_key; ALTER TABLE boards DROP COLUMN project_key; ALTER TABLE boards DROP COLUMN next_task_number; ALTER TABLE tasks DROP COLUMN due_date; DELETE FROM schema_migrations WHERE version>=5; PRAGMA user_version=4;'
  )
  db.close()
  assert.equal((await f.store.inspect(backup.path)).tasks[0].due_date, null)
  const folder = path.join(f.folder, 'legacy-v4')
  fs.mkdirSync(folder)
  fs.copyFileSync(backup.path, path.join(folder, 'opentalon.sqlite'))
  const migrated = new Store(folder)
  assert.equal(migrated.task(task.id).dueDate, null)
  migrated.close()
  task = f.store.task(task.id)
  assert.equal(
    (await f.write('update_task', { id: task.id, expectedRevision: task.revision, dueDate: null }))
      .task.dueDate,
    null
  )
  assert.equal(f.store.agentJobs().length, 0)
})
test('drop preview stays inside the visible column while vertically or horizontally scrolled', async () => {
  const { dropPreviewBounds } = await import('../src/task-view.ts')
  const viewport = { left: 230, top: 44, right: 1100, bottom: 960 }
  assert.deepEqual(
    dropPreviewBounds({ left: 500, top: -9000, right: 750, bottom: 8000 }, viewport),
    { left: 505, top: 49, width: 240, height: 906 }
  )
  assert.deepEqual(
    dropPreviewBounds({ left: 1000, top: 240, right: 1250, bottom: 8000 }, viewport),
    { left: 1005, top: 245, width: 90, height: 710 }
  )
  assert.equal(
    dropPreviewBounds({ left: 1200, top: 240, right: 1450, bottom: 8000 }, viewport),
    null
  )
  assert.equal(
    dropPreviewBounds({ left: 500, top: 1000, right: 750, bottom: 1200 }, viewport),
    null
  )
})
test('calendar due dates become red today and stay overdue without UTC date shifts', async () => {
  const { dueDatePresentation, localDateKey } = await import('../src/task-view.ts')
  assert.equal(localDateKey(new Date(2026, 10, 10, 0, 1)), '2026-11-10')
  assert.deepEqual(dueDatePresentation(null, '2026-11-10'), {
    text: 'No due date',
    overdue: false,
    title: 'No due date set',
  })
  assert.equal(dueDatePresentation('2026-11-10', '2026-11-10').text, 'Due today')
  assert.equal(dueDatePresentation('2026-11-10', '2026-11-10').overdue, true)
  assert.equal(dueDatePresentation('2026-11-09', '2026-11-10').overdue, true)
  assert.match(dueDatePresentation('2026-11-09', '2026-11-10').text, /^Overdue/)
  assert.equal(dueDatePresentation('2026-11-10', '2026-11-11').overdue, true)
  assert.equal(dueDatePresentation('2026-11-11', '2026-11-10').overdue, false)
  assert.match(dueDatePresentation('2027-01-12', '2026-11-10').text, /2027/)
})
test('drag ordering preserves the displayed priority order, hidden tasks and manual tracking across restart', async (t) => {
  const f = fixture(t)
  const boardId = f.store.boards()[0].id
  const original = []
  for (const [title, priority] of [
    ['Low task', 'Low'],
    ['High task', 'High'],
    ['Urgent task', 'Urgent'],
    ['Other high', 'High'],
  ])
    original.push(
      (await f.write('create_task', { boardId, title, priority, notes: 'Preserve my details' }))
        .task
    )
  const { selectTasks, reorderTaskIds, dropEdge } = await import('../src/task-view.ts')
  const displayed = selectTasks(original, '', { priority: 'All', sort: 'priority-desc' })
  const orderedIds = reorderTaskIds(displayed, displayed[0].id, displayed[1].id, 'after')
  const input = {
    boardId,
    status: 'To do',
    taskIds: orderedIds,
    expectedRevision: f.store.revision(),
    requestKey: randomUUID(),
  }
  const result = await f.run('reorder_tasks', input)
  assert.deepEqual(await f.run('reorder_tasks', input), result)
  assert.deepEqual(
    (await f.run('list_tasks')).tasks.map((task) => task.id),
    orderedIds
  )
  f.restart()
  assert.deepEqual(
    (await f.run('list_tasks')).tasks.map((task) => task.id),
    orderedIds
  )
  for (const task of original) {
    const saved = f.store.task(task.id)
    assert.equal(saved.priority, task.priority)
    assert.equal(saved.status, 'To do')
    assert.equal(saved.notes, task.notes)
    assert.equal(f.store.assignedRun(task.id), null)
  }
  assert.equal(f.store.agentJobs().length, 0)
  await assert.rejects(f.write('reorder_tasks', { ...input, requestKey: randomUUID() }), {
    code: 'CONFLICT',
  })
  await assert.rejects(
    f.write('reorder_tasks', {
      ...input,
      taskIds: orderedIds.slice(1),
      expectedRevision: f.store.revision(),
      requestKey: randomUUID(),
    }),
    { code: 'INVALID_ARGUMENT' }
  )
  assert.deepEqual(
    (await f.run('list_tasks')).tasks.map((task) => task.id),
    orderedIds
  )
  assert.equal(dropEdge(110, 100, 100), 'before')
  assert.equal(dropEdge(190, 100, 100), 'after')
  assert.deepEqual(reorderTaskIds(displayed, displayed[0].id), [
    ...displayed.slice(1).map((task) => task.id),
    displayed[0].id,
  ])
  const high = (await f.run('list_tasks', { priority: 'High' })).tasks
  await f.write('move_task', {
    id: high[1].id,
    beforeId: high[0].id,
    expectedRevision: high[1].revision,
  })
  assert.equal((await f.run('list_tasks', { priority: 'High' })).tasks[0].id, high[1].id)
  assert.equal((await f.run('list_tasks')).tasks.length, 4, 'Filtering never drops hidden tasks')
})
test('priority filtering/sorting and definitions persist, restore and migrate from v3 safely', async (t) => {
  const f = fixture(t)
  const boardId = f.store.boards()[0].id
  for (const priority of ['None', 'Low', 'High', 'Urgent', 'Medium', 'High'])
    await f.write('create_task', {
      boardId,
      title: `Task ${priority}`,
      priority,
      definitionOfDone: 'Check the requested outcome.',
    })
  assert.deepEqual(
    (await f.run('list_tasks', { sort: 'priority-desc' })).tasks.map((t) => t.priority),
    ['Urgent', 'High', 'High', 'Medium', 'Low', 'None']
  )
  assert.deepEqual(
    (await f.run('list_tasks', { sort: 'priority-asc' })).tasks.map((t) => t.priority),
    ['Low', 'Medium', 'High', 'High', 'Urgent', 'None']
  )
  const filtered = await f.run('list_tasks', {
    boardId,
    priority: 'High',
    query: 'task',
    sort: 'priority-desc',
    limit: 1,
  })
  assert.equal(filtered.total, 2)
  assert.equal(
    (
      await f.run('list_tasks', {
        boardId,
        priority: 'High',
        query: 'task',
        sort: 'priority-desc',
        limit: 1,
        cursor: filtered.nextCursor,
      })
    ).tasks.length,
    1
  )
  await assert.rejects(f.run('list_tasks', { priority: 'Low', cursor: filtered.nextCursor }), {
    code: 'STALE_CURSOR',
  })
  await assert.rejects(
    f.write('create_task', { boardId, title: 'Invalid', priority: 'Critical' }),
    { code: 'INVALID_ARGUMENT' }
  )
  let task = filtered.tasks[0]
  task = (
    await f.write('update_task', {
      id: task.id,
      expectedRevision: task.revision,
      priority: 'Low',
      definitionOfDone: 'Reviewed result.',
    })
  ).task
  assert.equal(f.store.agentJobs().length, 0)
  assert.equal(f.store.assignedRun(task.id), null)
  f.restart()
  assert.equal(f.store.task(task.id).priority, 'Low')
  assert.equal(f.store.task(task.id).definitionOfDone, 'Reviewed result.')
  for (const format of ['json', 'sqlite']) {
    const backup = await f.write('create_backup', { format })
    const preview = await f.run('preview_destructive_action', {
      action: 'restore_backup',
      path: backup.path,
    })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.equal(f.store.task(task.id).priority, 'Low')
    assert.equal(f.store.task(task.id).definitionOfDone, 'Reviewed result.')
  }
  const backup = await f.write('create_backup', { format: 'sqlite' })
  const db = new DatabaseSync(backup.path)
  db.exec(
    'DROP TRIGGER tasks_record_completion_on_insert; DROP TRIGGER tasks_record_completion_on_move; ALTER TABLE tasks DROP COLUMN completed_at; ALTER TABLE tasks DROP COLUMN archived_at; DROP INDEX tasks_task_key; DROP INDEX boards_project_key; ALTER TABLE tasks DROP COLUMN task_key; ALTER TABLE boards DROP COLUMN project_key; ALTER TABLE boards DROP COLUMN next_task_number; ALTER TABLE tasks DROP COLUMN due_date; ALTER TABLE tasks DROP COLUMN priority; ALTER TABLE tasks DROP COLUMN definition_of_done; DELETE FROM schema_migrations WHERE version>=4; PRAGMA user_version=3;'
  )
  db.close()
  const legacy = await f.store.inspect(backup.path)
  assert.ok(legacy.tasks.every((t) => t.priority === 'None' && t.definition_of_done === ''))
  const migrationFolder = path.join(f.folder, 'v3-profile')
  fs.mkdirSync(migrationFolder)
  fs.copyFileSync(backup.path, path.join(migrationFolder, 'opentalon.sqlite'))
  const migrated = new Store(migrationFolder)
  assert.equal(migrated.task(task.id).priority, 'None')
  assert.equal(migrated.task(task.id).definitionOfDone, '')
  assert.equal(migrated.db.prepare('PRAGMA user_version').get().user_version, FORMAT)
  migrated.close()
})
test('board filtering combines search with priority and preserves manual order on ties', async () => {
  const { selectTasks, notesPreview, readBoardViews } = await import('../src/task-view.ts')
  const tasks = [
    { id: 'a', title: 'Résumé high', notes: 'context', priority: 'High', position: 1 },
    { id: 'b', title: 'Résumé urgent', notes: '', priority: 'Urgent', position: 3 },
    { id: 'c', title: 'Other high', notes: '', priority: 'High', position: 0 },
    { id: 'd', title: 'Résumé none', notes: '', priority: 'None', position: 2 },
  ]
  assert.deepEqual(
    selectTasks(tasks, 'résumé', { priority: 'All', sort: 'priority-desc' }).map((t) => t.id),
    ['b', 'a', 'd']
  )
  assert.deepEqual(
    selectTasks(tasks, '', { priority: 'High', sort: 'manual' }).map((t) => t.id),
    ['c', 'a']
  )
  assert.deepEqual(
    selectTasks(tasks, '', { priority: 'All', sort: 'priority-asc' }).map((t) => t.id),
    ['c', 'a', 'b', 'd']
  )
  assert.deepEqual(selectTasks(tasks, 'unmatched', { priority: 'High', sort: 'manual' }), [])
  assert.equal(
    notesPreview(
      'Imported from Daily Brief\nOriginal priority: High\n\nUseful details\n\nOriginal Daily Brief action (complete source record):\n{}'
    ),
    'Useful details'
  )
  assert.deepEqual(readBoardViews('{"x":{"priority":"High","sort":"priority-desc"},"bad":{}}'), {
    x: { priority: 'High', sort: 'priority-desc' },
  })
})
test('all tasks groups projects in project order and sorts priority across projects', async () => {
  const { selectTasks, orderAllTasks } = await import('../src/task-view.ts')
  const tasks = [
    {
      id: 'a',
      boardId: 'first',
      title: 'Ship docs',
      notes: '',
      priority: 'Low',
      position: 1,
      status: 'To do',
    },
    {
      id: 'b',
      boardId: 'second',
      title: 'Ship app',
      notes: '',
      priority: 'Urgent',
      position: 0,
      status: 'To do',
    },
    {
      id: 'c',
      boardId: 'first',
      title: 'Review',
      notes: '',
      priority: 'High',
      position: 0,
      status: 'To do',
    },
  ]
  const projectOrder = new Map([
    ['first', 0],
    ['second', 1],
  ])
  const ordered = orderAllTasks(tasks, projectOrder, [])
  const rank = new Map(ordered.map((task, index) => [task.id, index]))
  assert.deepEqual(
    selectTasks(tasks, '', { priority: 'All', sort: 'manual' }, rank).map((task) => task.id),
    ['c', 'a', 'b']
  )
  assert.deepEqual(
    selectTasks(tasks, 'ship', { priority: 'All', sort: 'priority-desc' }, rank).map(
      (task) => task.id
    ),
    ['b', 'a']
  )
})
test('all tasks order interleaves projects and refills each project in its board order', async () => {
  const { orderAllTasks } = await import('../src/task-view.ts')
  const task = (id, boardId, position, status = 'To do') => ({ id, boardId, position, status })
  const projectOrder = new Map([
    ['p', 0],
    ['q', 1],
  ])
  const ids = (tasks, order) => orderAllTasks(tasks, projectOrder, order).map((item) => item.id)
  const tasks = [task('p1', 'p', 0), task('p2', 'p', 1), task('q1', 'q', 0), task('q2', 'q', 1)]
  // No saved order: project order, then position.
  assert.deepEqual(ids(tasks, []), ['p1', 'p2', 'q1', 'q2'])
  // A saved interleaving is followed; unknown and duplicate ids are ignored.
  assert.deepEqual(ids(tasks, ['q1', 'gone', 'p1', 'q2', 'p2', 'q1']), ['q1', 'p1', 'q2', 'p2'])
  // A reorder on project p (positions swapped) refills p's slots without touching q's.
  const swapped = [task('p1', 'p', 1), task('p2', 'p', 0), task('q1', 'q', 0), task('q2', 'q', 1)]
  assert.deepEqual(ids(swapped, ['q1', 'p1', 'q2', 'p2']), ['q1', 'p2', 'q2', 'p1'])
  // Tasks the saved order has not seen go last in project order; columns stay separate.
  const more = [...tasks, task('q3', 'q', 2), task('p3', 'p', 2), task('d1', 'q', 0, 'Done')]
  assert.deepEqual(ids(more, ['q2', 'p1', 'q1', 'p2']), ['q1', 'p1', 'q2', 'p2', 'p3', 'q3', 'd1'])
})
test('reorder_all_tasks keeps project orders, status moves and the global order in step', async (t) => {
  const f = fixture(t)
  const { orderAllTasks } = await import('../src/task-view.ts')
  const p = f.store.boards()[0].id
  const q = (await f.write('create_board', { name: 'Second' })).board.id
  const add = async (boardId, title, status = 'To do') =>
    (await f.write('create_task', { boardId, title, status })).task.id
  const p1 = await add(p, 'p1')
  const p2 = await add(p, 'p2')
  const q1 = await add(q, 'q1')
  const q2 = await add(q, 'q2')
  const d1 = await add(q, 'd1', 'Done')
  const column = (status) => {
    const snapshot = f.store.snapshot()
    return orderAllTasks(
      snapshot.tasks.filter((task) => !task.deleted),
      new Map(snapshot.boards.map((board, index) => [board.id, index])),
      snapshot.allTasksOrder
    )
      .filter((task) => task.status === status)
      .map((task) => task.id)
  }
  const projectColumn = (boardId, status) =>
    f.store
      .snapshot()
      .tasks.filter((task) => !task.deleted && task.boardId === boardId && task.status === status)
      .sort((a, b) => a.position - b.position)
      .map((task) => task.id)
  const reorder = (status, taskIds, expectedRevision = f.store.revision()) =>
    f.write('reorder_all_tasks', { status, taskIds, expectedRevision })
  assert.deepEqual(column('To do'), [p1, p2, q1, q2])
  // Reorder within a column across two projects: both projects follow.
  await reorder('To do', [q2, p2, q1, p1])
  assert.deepEqual(column('To do'), [q2, p2, q1, p1])
  assert.deepEqual(projectColumn(p, 'To do'), [p2, p1])
  assert.deepEqual(projectColumn(q, 'To do'), [q2, q1])
  // A reorder on a project board shows up in All tasks without another global write.
  await f.write('reorder_tasks', {
    boardId: p,
    status: 'To do',
    taskIds: [p1, p2],
    expectedRevision: f.store.revision(),
  })
  assert.deepEqual(column('To do'), [q2, p1, q1, p2])
  // A card dragged in from another column changes status and lands at the chosen spot.
  await reorder('To do', [q2, d1, p1, q1, p2])
  assert.equal(f.store.task(d1).status, 'To do')
  assert.deepEqual(column('To do'), [q2, d1, p1, q1, p2])
  assert.deepEqual(projectColumn(q, 'To do'), [q2, d1, q1])
  assert.deepEqual(column('Done'), [])
  // Stale revisions and wrong id sets are rejected without changes.
  const before = f.store.revision()
  await assert.rejects(reorder('To do', [p1, p2, q1, q2, d1], before - 1), { code: 'CONFLICT' })
  await assert.rejects(reorder('To do', [p1, p2, q1, q2]), { code: 'INVALID_ARGUMENT' })
  await assert.rejects(reorder('To do', [p1, p2, q1, q2, d1, 'missing']), {
    code: 'INVALID_ARGUMENT',
  })
  const i1 = await add(p, 'i1', 'In progress')
  const i2 = await add(q, 'i2', 'In progress')
  await assert.rejects(reorder('To do', [p1, p2, q1, q2, d1, i1, i2]), {
    code: 'INVALID_ARGUMENT',
  })
  assert.deepEqual(column('To do'), [q2, d1, p1, q1, p2])
  // Trashed tasks drop out; the order survives a restart and both backup formats.
  const trashed = f.store.task(p2)
  await f.write('trash_task', { id: p2, expectedRevision: trashed.revision })
  await reorder('To do', [p1, q2, d1, q1])
  assert.ok(!f.store.allTasksOrder().includes(p2))
  f.restart()
  assert.deepEqual(column('To do'), [p1, q2, d1, q1])
  for (const format of ['json', 'sqlite']) {
    const exported = await f.write('create_backup', { format })
    await reorder('To do', [q1, d1, q2, p1])
    const preview = await f.run('preview_destructive_action', {
      action: 'restore_backup',
      path: exported.path,
    })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.deepEqual(column('To do'), [p1, q2, d1, q1])
  }
  assert.deepEqual(column('In progress'), [i1, i2])
})
test('empty launch; transactional CRUD, ordering, conflict, Unicode search and restart', async (t) => {
  const f = fixture(t),
    { run, write } = f
  const initial = await run('snapshot')
  assert.equal(initial.boards[0].name, 'Tasks')
  assert.deepEqual(initial.tasks, [])
  const boardId = initial.boards[0].id
  await assert.rejects(write('create_task', { boardId, title: '  ' }), { code: 'INVALID_ARGUMENT' })
  let a = (await write('create_task', { boardId, title: 'First', notes: 'Résumé context' })).task
  const b = (await write('create_task', { boardId, title: 'Second' })).task
  const c = (await write('create_task', { boardId, title: 'Third' })).task
  a = (await write('move_task', { id: a.id, expectedRevision: a.revision, afterId: c.id })).task
  assert.deepEqual(
    (await run('list_tasks')).tasks.map((task) => task.title),
    ['Second', 'Third', 'First']
  )
  await assert.rejects(write('update_task', { id: a.id, title: 'Stale', expectedRevision: 2 }), {
    code: 'CONFLICT',
  })
  a = (
    await write('update_task', {
      id: a.id,
      notes: 'ÉCRIRE',
      expectedRevision: a.revision,
      status: 'Done',
    })
  ).task
  assert.equal((await run('list_tasks', { query: 'écrire' })).tasks[0].id, a.id)
  const nextBoard = (await write('create_board', { name: 'Personal' })).board
  a = (await write('move_task', { id: a.id, expectedRevision: a.revision, boardId: nextBoard.id }))
    .task
  a = (await write('trash_task', { id: a.id, expectedRevision: a.revision })).task
  await assert.rejects(
    write('delete_board', { id: nextBoard.id, expectedRevision: nextBoard.revision }),
    { code: 'BOARD_NOT_EMPTY' }
  )
  a = (await write('restore_task', { id: a.id, expectedRevision: a.revision })).task
  const prefs = await run('get_preferences')
  await write('set_preferences', {
    theme: 'graphite',
    selectedBoard: nextBoard.id,
    expectedRevision: prefs.revision,
  })
  const saved = await run('snapshot')
  f.restart()
  assert.deepEqual(await run('snapshot'), saved)
  assert.equal(a.notes, 'ÉCRIRE')
  assert.equal(b.status, 'To do')
})
test('durable retry receipts and revision-bound pagination', async (t) => {
  const f = fixture(t),
    { run, write } = f,
    boardId = f.store.boards()[0].id
  const args = { boardId, title: 'Exactly once', requestKey: randomUUID() }
  const result = await run('create_task', args)
  f.restart()
  assert.deepEqual(await run('create_task', args), result)
  await assert.rejects(run('create_task', { ...args, title: 'Different' }), {
    code: 'REQUEST_KEY_REUSED',
  })
  await write('create_task', { boardId, title: 'Next' })
  const page = await run('list_tasks', { limit: 1 })
  assert.ok(page.nextCursor)
  assert.equal((await run('list_tasks', { limit: 1, cursor: page.nextCursor })).tasks.length, 1)
  await write('create_task', { boardId, title: 'Later' })
  await assert.rejects(run('list_tasks', { cursor: page.nextCursor }), { code: 'STALE_CURSOR' })
  const task = (await run('get_task', { id: result.task.id })).task
  const moveArgs = {
    id: task.id,
    status: 'Done',
    expectedRevision: task.revision,
    requestKey: randomUUID(),
  }
  const moved = await run('move_task', moveArgs)
  assert.deepEqual(await run('move_task', moveArgs), moved)
})
test('consistent portable backup; guarded restore, safety backup, corrupt and newer rejection', async (t) => {
  const f = fixture(t),
    { run, write } = f,
    boardId = f.store.boards()[0].id
  let task = (await write('create_task', { boardId, title: 'Keep', notes: 'All notes' })).task
  task = (await write('trash_task', { id: task.id, expectedRevision: task.revision })).task
  const before = await run('snapshot')
  const backup = await write('create_backup')
  const copy = new DatabaseSync(backup.path, { readOnly: true })
  assert.equal(copy.prepare('SELECT count(*) AS n FROM operation_receipts').get().n, 0)
  assert.equal(copy.prepare("SELECT count(*) AS n FROM settings WHERE key LIKE '%mcp%'").get().n, 0)
  copy.close()
  await assert.rejects(write('create_backup', { destination: backup.path }), {
    code: 'FILE_EXISTS',
  })
  let preview = await run('preview_destructive_action', {
    action: 'restore_backup',
    path: backup.path,
  })
  await write('create_task', { boardId, title: 'After backup' })
  await assert.rejects(write('confirm_destructive_action', { token: preview.token }), {
    code: 'STALE_PREVIEW',
  })
  preview = await run('preview_destructive_action', { action: 'restore_backup', path: backup.path })
  const restored = await write('confirm_destructive_action', { token: preview.token })
  assert.ok(fs.existsSync(restored.safetyBackup))
  const after = await run('snapshot')
  const portable = (snapshot) => ({
    theme: snapshot.theme,
    selectedBoard: snapshot.selectedBoard,
    boards: snapshot.boards.map(({ revision, ...board }) => board),
    tasks: snapshot.tasks.map(({ revision, ...task }) => task),
  })
  assert.deepEqual(portable(after), portable(before))
  const invalid = path.join(f.folder, 'invalid.opentalon')
  fs.writeFileSync(invalid, 'not sqlite')
  await assert.rejects(run('inspect_backup', { path: invalid }), { code: 'INVALID_BACKUP' })
  const newer = path.join(f.folder, 'newer.opentalon')
  fs.copyFileSync(backup.path, newer)
  const db = new DatabaseSync(newer)
  db.exec('PRAGMA user_version=999')
  db.close()
  await assert.rejects(run('inspect_backup', { path: newer }), { code: 'NEWER_BACKUP' })
  assert.deepEqual(await run('snapshot'), after)
  preview = await run('preview_destructive_action', { action: 'empty_trash' })
  await write('confirm_destructive_action', { token: preview.token })
  assert.equal((await run('list_trash')).total, 0)
})
test('changed backup invalidates preview and invalid existing database is never replaced', async (t) => {
  const f = fixture(t),
    { run, write } = f
  const backup = await write('create_backup')
  const preview = await run('preview_destructive_action', {
    action: 'restore_backup',
    path: backup.path,
  })
  const copy = new DatabaseSync(backup.path)
  copy.prepare('UPDATE boards SET name=?').run('Tampered')
  copy.close()
  await assert.rejects(write('confirm_destructive_action', { token: preview.token }), {
    code: 'STALE_PREVIEW',
  })
  const folder = fs.mkdtempSync(path.join(base, 'unreadable-'))
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }))
  const file = path.join(folder, 'opentalon.sqlite')
  fs.writeFileSync(file, 'preserve me')
  assert.throws(() => new Store(folder))
  assert.equal(fs.readFileSync(file, 'utf8'), 'preserve me')
})

test('JSON export to a clean workspace restores every board, task, Trash, metadata, order and preference without duplicates', async (t) => {
  const source = fixture(t),
    target = fixture(t)
  const first = source.store.boards()[0]
  const second = (await source.write('create_board', { name: 'Personal 世界' })).board
  let a = (
    await source.write('create_task', {
      boardId: first.id,
      title: 'One',
      notes: 'Line one\nRésumé 🦉',
    })
  ).task
  const b = (await source.write('create_task', { boardId: first.id, title: 'Two' })).task
  await source.write('move_task', { id: b.id, expectedRevision: b.revision, beforeId: a.id })
  a = (
    await source.write('update_task', {
      id: a.id,
      expectedRevision: (await source.run('get_task', { id: a.id })).task.revision,
      status: 'In progress',
    })
  ).task
  await source.write('create_task', { boardId: second.id, title: 'Finished', status: 'Done' })
  const trashed = (
    await source.write('create_task', {
      boardId: second.id,
      title: 'Recover me',
      notes: 'Trash notes',
    })
  ).task
  await source.write('trash_task', { id: trashed.id, expectedRevision: trashed.revision })
  await source.write('set_preferences', {
    expectedRevision: (await source.run('get_preferences')).revision,
    theme: 'graphite',
    selectedBoard: second.id,
  })
  source.store.set('mcpToken', 'never-export-this-test-key')
  const before = await source.run('snapshot')
  const exported = await source.write('create_backup', { format: 'json' })
  const jsonText = fs.readFileSync(exported.path, 'utf8')
  const json = JSON.parse(jsonText)
  assert.equal(json.formatVersion, FORMAT)
  assert.deepEqual(json.columns, ['To do', 'Sent to agent', 'In progress', 'Done'])
  assert.ok(!jsonText.includes('never-export-this-test-key'))
  assert.ok(!jsonText.includes('operation_receipts'))
  assert.equal((await target.run('snapshot')).tasks.length, 0)
  const portable = (snapshot) => ({
    theme: snapshot.theme,
    selectedBoard: snapshot.selectedBoard,
    boards: snapshot.boards.map(({ revision, ...row }) => row),
    tasks: snapshot.tasks.map(({ revision, ...row }) => row),
  })
  const restore = async () => {
    const preview = await target.run('preview_destructive_action', {
      action: 'restore_backup',
      path: exported.path,
    })
    return target.write('confirm_destructive_action', { token: preview.token })
  }
  const result = await restore()
  assert.ok(fs.existsSync(result.safetyBackup))
  assert.deepEqual(portable(await target.run('snapshot')), portable(before))
  await restore()
  assert.deepEqual(portable(await target.run('snapshot')), portable(before))
  target.restart()
  assert.deepEqual(portable(await target.run('snapshot')), portable(before))
  await assert.rejects(
    source.write('create_backup', { format: 'json', destination: exported.path }),
    { code: 'FILE_EXISTS' }
  )
  const saved = await target.run('snapshot')
  const invalid = path.join(source.folder, 'broken.json')
  const cases = [
    '{broken',
    JSON.stringify({ ...json, formatVersion: 999 }),
    JSON.stringify({ ...json, tasks: [...json.tasks, json.tasks[0]] }),
    JSON.stringify({ ...json, tasks: [{ ...json.tasks[0], board_id: 'missing' }] }),
    JSON.stringify({ ...json, tasks: [{ ...json.tasks[0], status: 'Invalid' }] }),
    JSON.stringify({ ...json, tasks: [{ ...json.tasks[0], notes: null }] }),
    JSON.stringify({ ...json, preferences: { ...json.preferences, selectedBoard: 'missing' } }),
    JSON.stringify({ ...json, boards: [] }),
  ]
  for (const value of cases) {
    fs.writeFileSync(invalid, value)
    await assert.rejects(
      target.run('preview_destructive_action', { action: 'restore_backup', path: invalid })
    )
    assert.deepEqual(await target.run('snapshot'), saved)
  }
  const preview = await target.run('preview_destructive_action', {
    action: 'restore_backup',
    path: exported.path,
  })
  fs.appendFileSync(exported.path, '\n')
  await assert.rejects(target.write('confirm_destructive_action', { token: preview.token }), {
    code: 'STALE_PREVIEW',
  })
  assert.deepEqual(await target.run('snapshot'), saved)
})

test('restoration preserves a free former position and appends when occupied; boards append after deletion', async (t) => {
  const f = fixture(t),
    { run, write } = f,
    boardId = f.store.boards()[0].id
  const a = (await write('create_task', { boardId, title: 'A' })).task
  let b = (await write('create_task', { boardId, title: 'B' })).task
  let c = (await write('create_task', { boardId, title: 'C' })).task
  b = (await write('trash_task', { id: b.id, expectedRevision: b.revision })).task
  b = (await write('restore_task', { id: b.id, expectedRevision: b.revision })).task
  assert.deepEqual(
    (await run('list_tasks')).tasks.map((task) => task.title),
    ['A', 'B', 'C']
  )
  b = (await write('trash_task', { id: b.id, expectedRevision: b.revision })).task
  c = (await write('move_task', { id: c.id, beforeId: a.id, expectedRevision: c.revision })).task
  await write('restore_task', { id: b.id, expectedRevision: b.revision })
  assert.deepEqual(
    (await run('list_tasks')).tasks.map((task) => task.title),
    ['C', 'A', 'B']
  )
  const one = (await write('create_board', { name: 'One' })).board
  const two = (await write('create_board', { name: 'Two' })).board
  await write('delete_board', { id: one.id, expectedRevision: one.revision })
  const three = (await write('create_board', { name: 'Three' })).board
  assert.deepEqual(
    (await run('list_boards')).boards.map((board) => board.id),
    [boardId, two.id, three.id]
  )
  const saved = (
    await write('update_task', { id: c.id, title: 'C ', expectedRevision: c.revision })
  ).task
  assert.equal(saved.title, 'C ')
})

test('selected Trash purge binds exact records, rejects live tasks, and replays safely', async (t) => {
  const f = fixture(t),
    { run, write } = f,
    boardId = f.store.boards()[0].id
  const live = (await write('create_task', { boardId, title: 'Keep live' })).task
  let first = (await write('create_task', { boardId, title: 'Remove selected' })).task
  let other = (await write('create_task', { boardId, title: 'Keep in Trash' })).task
  first = (await write('trash_task', { id: first.id, expectedRevision: first.revision })).task
  other = (await write('trash_task', { id: other.id, expectedRevision: other.revision })).task
  await assert.rejects(
    run('preview_destructive_action', { action: 'purge_tasks', taskIds: [live.id] }),
    { code: 'INVALID_STATE' }
  )
  let preview = await run('preview_destructive_action', {
    action: 'purge_tasks',
    taskIds: [first.id],
  })
  await write('update_task', {
    id: live.id,
    notes: 'Concurrent change',
    expectedRevision: live.revision,
  })
  await assert.rejects(write('confirm_destructive_action', { token: preview.token }), {
    code: 'STALE_PREVIEW',
  })
  preview = await run('preview_destructive_action', { action: 'purge_tasks', taskIds: [first.id] })
  const args = { token: preview.token, requestKey: randomUUID() }
  const result = await run('confirm_destructive_action', args)
  assert.equal(result.permanentlyDeleted, 1)
  assert.deepEqual(await run('confirm_destructive_action', args), result)
  assert.deepEqual(
    (await run('list_trash')).tasks.map((task) => task.id),
    [other.id]
  )
  assert.equal((await run('get_task', { id: live.id })).task.notes, 'Concurrent change')
  await assert.rejects(run('get_task', { id: first.id }), { code: 'NOT_FOUND' })
})

test('board icons: suggested on create, set and cleared by revision, validated, and kept across restart and both backup formats', async (t) => {
  const f = fixture(t)
  const { boardIcons } = require('./contracts.cjs')
  const { boardIconNames } = await import('../src/board-icon-names.ts')
  assert.deepEqual([...boardIconNames], boardIcons)
  assert.equal(f.store.boards()[0].icon, null)
  assert.equal((await f.write('create_board', { name: 'Home & HOA' })).board.icon, 'house')
  assert.equal((await f.write('create_board', { name: 'Zxqv' })).board.icon, null)
  assert.equal((await f.write('create_board', { name: 'Home', icon: null })).board.icon, null)
  let board = (await f.write('create_board', { name: 'Night work', icon: 'moon' })).board
  assert.equal(board.icon, 'moon')
  await assert.rejects(f.write('create_board', { name: 'Bad', icon: 'not-an-icon' }), {
    code: 'INVALID_ARGUMENT',
  })
  await assert.rejects(
    f.write('set_board_icon', { id: board.id, icon: 'rocket', expectedRevision: 1 }),
    { code: 'CONFLICT' }
  )
  const updated = (
    await f.write('set_board_icon', {
      id: board.id,
      icon: 'rocket',
      expectedRevision: board.revision,
    })
  ).board
  assert.equal(updated.icon, 'rocket')
  assert.ok(updated.revision > board.revision)
  board = (
    await f.write('rename_board', {
      id: board.id,
      name: 'Launch',
      expectedRevision: updated.revision,
    })
  ).board
  assert.equal(board.icon, 'rocket')
  f.restart()
  assert.equal(f.store.board(board.id).icon, 'rocket')
  const icons = () => Object.fromEntries(f.store.boards().map((item) => [item.name, item.icon]))
  const expected = icons()
  for (const format of ['json', 'sqlite']) {
    const exported = await f.write('create_backup', { format })
    const current = f.store.board(board.id)
    await f.write('set_board_icon', {
      id: board.id,
      icon: null,
      expectedRevision: current.revision,
    })
    assert.equal(f.store.board(board.id).icon, null)
    const preview = await f.run('preview_destructive_action', {
      action: 'restore_backup',
      path: exported.path,
    })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.deepEqual(icons(), expected)
  }
  const removable = f.store.boards().find((item) => item.name === 'Home & HOA')
  await f.write('delete_board', { id: removable.id, expectedRevision: removable.revision })
  assert.equal(f.store.boardIcons()[removable.id], undefined)
})
