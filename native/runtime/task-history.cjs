const { randomUUID } = require('node:crypto')
const { AppError } = require('./contracts.cjs')

function state(store, task) {
  return {
    title: task.title, notes: task.notes, definitionOfDone: task.definitionOfDone,
    planMarkdown: task.planMarkdown, issueType: task.issueType,
    projectID: task.boardId, projectName: store.board(task.boardId).name,
    taskKey: task.taskKey, status: task.status, priority: task.priority, dueDate: task.dueDate,
    position: task.position, archived: !!task.archivedAt, trashed: task.deleted,
  }
}

function record(store, task, action, origin = 'Mac / connected agent', runId) {
  const value = state(store, task)
  const previous = store.db.prepare('SELECT state_json FROM task_history WHERE task_id=? ORDER BY version DESC LIMIT 1').get(task.id)
  const original = previous ? JSON.parse(previous.state_json) : null
  const changes = Object.keys(value).filter(key => JSON.stringify(value[key]) !== JSON.stringify(original?.[key]))
  if (!changes.length && action !== 'restore_task_revision') return
  const version = store.db.prepare('SELECT coalesce(max(version),0)+1 AS next FROM task_history WHERE task_id=?').get(task.id).next
  const id = randomUUID(), savedAt = new Date().toISOString()
  store.db.prepare('INSERT INTO task_history VALUES (?,?,?,?,?,?,?,?)').run(
    id, task.id, version, savedAt, action, origin,
    JSON.stringify(changes), JSON.stringify(value))
  if (store.activityReady) require('./task-activity.cjs').recordHistory(store, task.id, {id,savedAt,action,origin,runId: runId || (!origin.startsWith('You') && origin !== 'OpenTalon' ? store.assignedRun(task.id) : null)},value,original,changes)
}

function recordRevision(store, revision, action, origin, runId) {
  for (const row of store.db.prepare('SELECT id FROM tasks WHERE revision=?').all(revision))
    record(store, store.task(row.id), action, origin, runId)
}

function beginIfMissing(store, task) {
  if (!store.db.prepare('SELECT 1 FROM task_history WHERE task_id=? LIMIT 1').get(task.id))
    record(store, task, 'history_started', 'OpenTalon')
}

function recordedCompletions(store) {
  // Older databases and backups seeded completed_at from updated_at. Require a
  // recorded status change or creation before presenting it as a completion date.
  const rows = store.db.prepare(`
    SELECT task.id, task.completed_at FROM tasks AS task
    JOIN task_history AS entry ON entry.id = (
      SELECT history.id FROM task_history AS history
      WHERE history.task_id = task.id
        AND EXISTS (SELECT 1 FROM json_each(history.changes_json) WHERE value = 'status')
      ORDER BY history.version DESC LIMIT 1
    )
    WHERE task.status = 'Done' AND task.completed_at IS NOT NULL
      AND json_extract(entry.state_json, '$.status') = 'Done'
      AND entry.action <> 'history_started'
      AND (entry.version > 1 OR entry.action IN ('create_task', 'capture_task'))
  `).all()
  return new Map(rows.map(row => [row.id, row.completed_at]))
}

function migrate(store) {
  store.db.exec('BEGIN IMMEDIATE')
  try {
    store.db.exec(`CREATE TABLE task_history (
      id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
      version INTEGER NOT NULL CHECK(version>0), saved_at TEXT NOT NULL, action TEXT NOT NULL,
      origin TEXT NOT NULL, changes_json TEXT NOT NULL, state_json TEXT NOT NULL,
      UNIQUE(task_id,version)) STRICT;
      PRAGMA user_version=10;`)
    for (const row of store.db.prepare('SELECT id FROM tasks').all()) record(store, store.task(row.id), 'history_started', 'OpenTalon')
    store.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(10, new Date().toISOString())
    store.db.exec('COMMIT')
  } catch (error) { store.db.exec('ROLLBACK'); throw error }
}

function page(store, id, beforeVersion, limit = 30) {
  const task = store.task(id)
  const rows = store.db.prepare('SELECT * FROM task_history WHERE task_id=? AND version<? ORDER BY version DESC LIMIT ?')
    .all(task.id, beforeVersion ?? Number.MAX_SAFE_INTEGER, limit + 1)
  return {
    taskID: task.id, revision: task.revision,
    entries: rows.slice(0, limit).map(row => ({
      id: row.id, version: row.version, savedAt: row.saved_at, action: row.action, origin: row.origin,
      changedFields: JSON.parse(row.changes_json), state: JSON.parse(row.state_json),
    })),
    nextBefore: rows.length > limit ? rows[limit - 1].version : null,
  }
}

function restore(store, input, revision) {
  const task = store.task(input.id)
  store.expect(task, input.expectedRevision)
  if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task from Trash before restoring a revision.')
  const row = store.db.prepare('SELECT * FROM task_history WHERE id=? AND task_id=?').get(input.historyID, task.id)
  if (!row) throw new AppError('NOT_FOUND', 'This saved revision is no longer available.')
  const value = JSON.parse(row.state_json)
  store.board(value.projectID)
  for (const job of store.agentJobs()) {
    if (job.taskId !== task.id || !['queued', 'starting', 'working', 'needs-input'].includes(job.state)) continue
    store.saveAgentJob({ ...job, state: 'canceled', approval: null, summary: 'Stopped because the user restored a task revision.' })
    store.setCommentDelivery(job.id, 'needs-review')
  }
  store.assignAgent(task.id, null)
  store.markPendingCommentsForReview(task.id)
  store.db.prepare('UPDATE tasks SET archived_at=NULL,plan_markdown=? WHERE id=?').run(value.planMarkdown, task.id)
  const restored = store.move({ ...task, archivedAt: null }, {
    boardId: value.projectID, status: value.status === 'Sent to agent' ? 'To do' : value.status,
  }, revision)
  const updated = store.saveTask({ ...restored, title: value.title, notes: value.notes,
    definitionOfDone: value.definitionOfDone, issueType: value.issueType,
    priority: value.priority, dueDate: value.dueDate }, revision)
  const column = store.liveColumn(updated.boardId, updated.status).filter(item => item.id !== updated.id)
  column.splice(Math.min(value.position, column.length), 0, updated)
  store.saveColumnOrder(column, revision)
  return { task: store.task(task.id), restoredVersion: row.version }
}

function validateRows(rows, tasks) {
  if (!Array.isArray(rows)) throw new AppError('INVALID_BACKUP', 'This backup contains invalid task history.')
  const taskIDs = new Set(tasks.map(task => task.id)), ids = new Set(), versions = new Set()
  const text = (value, max) => typeof value === 'string' && value.length <= max && value.isWellFormed() && !value.includes('\0')
  for (const row of rows) {
    let value, changes
    try { value = JSON.parse(row.state_json); changes = JSON.parse(row.changes_json) } catch {}
    if (!row || !text(row.id, 150) || !row.id || ids.has(row.id) || !taskIDs.has(row.task_id) ||
        !Number.isSafeInteger(row.version) || row.version < 1 || versions.has(row.task_id + ':' + row.version) ||
        !text(row.saved_at, 100) || !Number.isFinite(Date.parse(row.saved_at)) || !text(row.action, 100) || !text(row.origin, 100) ||
        !Array.isArray(changes) || changes.some(field => !text(field, 100)) || !value ||
        !text(value.title, 500) || !value.title.trim() || !text(value.notes, 100000) ||
        !text(value.definitionOfDone, 10000) || !text(value.planMarkdown, 100000) ||
        !['Issue','Bug'].includes(value.issueType) || !['To do','Sent to agent','In progress','Done'].includes(value.status) ||
        !['Urgent','High','Medium','Low','None'].includes(value.priority) || !text(value.projectID, 150) || !value.projectID ||
        !text(value.projectName, 100) || !(value.taskKey === null || text(value.taskKey, 100)) ||
        !(value.dueDate === null || text(value.dueDate, 10) && /^\d{4}-\d{2}-\d{2}$/.test(value.dueDate) &&
          Number.isFinite(Date.parse(value.dueDate + 'T00:00:00Z')) && new Date(value.dueDate + 'T00:00:00Z').toISOString().slice(0,10) === value.dueDate) ||
        !Number.isSafeInteger(value.position) || value.position < 0 || typeof value.archived !== 'boolean' || typeof value.trashed !== 'boolean')
      throw new AppError('INVALID_BACKUP', 'This backup contains invalid task history.')
    ids.add(row.id); versions.add(row.task_id + ':' + row.version)
  }
}

module.exports = { migrate, record, recordRevision, beginIfMissing, recordedCompletions, page, restore, validateRows }
