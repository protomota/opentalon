const { randomUUID } = require('node:crypto')
const { AppError } = require('./contracts.cjs')
const { imageBytes } = require('./comments.cjs')

function record(
  store,
  taskId,
  {
    id = randomUUID(),
    at = new Date().toISOString(),
    actor = 'OpenTalon',
    kind = 'update',
    summary,
    detail = '',
    legacyCommentID = null,
    data = {}
  },
  images = []
) {
  const normalized = images.map((image) => ({ ...image, bytes: imageBytes(image) }))
  const inserted = store.db
    .prepare(
      `INSERT OR IGNORE INTO task_activity
    (id,task_id,saved_at,actor,kind,summary,detail,legacy_comment_id,data) VALUES (?,?,?,?,?,?,?,?,?)`
    )
    .run(id, taskId, at, actor, kind, summary, detail, legacyCommentID, JSON.stringify(data))
  if (inserted.changes)
    for (const image of normalized)
      store.db
        .prepare('INSERT INTO activity_images VALUES (?,?,?,?,?)')
        .run(image.id || randomUUID(), id, image.name, image.mimeType, image.bytes)
  return entry(store, store.db.prepare('SELECT * FROM task_activity WHERE id=?').get(id))
}

function entry(store, row) {
  const images = store.db
    .prepare('SELECT id,name,mime_type FROM activity_images WHERE activity_id=?')
    .all(row.id)
  if (row.legacy_comment_id)
    images.push(
      ...store.db
        .prepare('SELECT id,name,mime_type FROM comment_images WHERE comment_id=?')
        .all(row.legacy_comment_id)
    )
  return {
    ...JSON.parse(row.data),
    id: row.id,
    taskId: row.task_id,
    sequence: row.sequence,
    createdAt: row.saved_at,
    actor: row.actor,
    kind: row.kind,
    summary: row.summary,
    detail: row.detail,
    text: row.detail,
    images: images.map((image) => ({ id: image.id, name: image.name, mimeType: image.mime_type }))
  }
}

function page(store, id, beforeSequence, limit = 20, commentID) {
  const task = store.task(id)
  let filter = '',
    parameters = []
  if (commentID) {
    const comment = store
      .comments(task.id)
      .find((item) => item.id === commentID && item.source === 'user')
    if (!comment) throw new AppError('NOT_FOUND', 'This user comment is no longer available.')
    // Only the comment's own assigned run and explicit responses belong in this drill-down.
    filter = " AND (json_extract(data,'$.commentID')=? OR json_extract(data,'$.runId')=? OR id=?)"
    parameters = [commentID, comment.runId || '', comment.activityID || '']
  }
  const rows = store.db
    .prepare(
      'SELECT * FROM task_activity WHERE task_id=? AND sequence<?' +
        filter +
        ' ORDER BY sequence DESC LIMIT ?'
    )
    .all(task.id, beforeSequence ?? Number.MAX_SAFE_INTEGER, ...parameters, limit + 1)
  return {
    taskID: task.id,
    revision: store.revision(),
    ...(commentID ? { commentID } : {}),
    entries: rows.slice(0, limit).map((row) => entry(store, row)),
    nextBefore: rows.length > limit ? rows[limit - 1].sequence : null
  }
}

function recordHistory(store, taskId, row, value, previous, changes) {
  const labels = {
    title: 'Title',
    notes: 'Notes',
    definitionOfDone: 'Definition of done',
    planMarkdown: 'Plan',
    issueType: 'Issue type',
    projectName: 'Project',
    status: 'Status',
    priority: 'Priority',
    dueDate: 'Due date',
    position: 'Order',
    archived: 'Archive',
    trashed: 'Trash'
  }
  let summary
  if (row.action === 'history_started') summary = 'Task history started'
  else if (!previous) summary = 'Task created'
  else if (row.action === 'rename_board') summary = 'Project renamed'
  else if (row.action === 'restore_task_revision') summary = 'Restored a previous revision'
  else if (changes.includes('trashed'))
    summary = value.trashed ? 'Moved task to Trash' : 'Restored task from Trash'
  else if (changes.includes('archived'))
    summary = value.archived ? 'Archived task' : 'Restored task from Archive'
  else if (changes.includes('projectID'))
    summary = `Moved from ${previous.projectName} to ${value.projectName}`
  else if (changes.includes('status')) summary = `Moved from ${previous.status} to ${value.status}`
  else
    summary =
      changes
        .filter((key) => labels[key])
        .map((key) => labels[key])
        .join(', ') + ' updated'
  const details = changes
    .filter((key) => labels[key])
    .map((key) => {
      if (['notes', 'definitionOfDone', 'planMarkdown'].includes(key))
        return labels[key] + ' edited. Previous versions remain in revision history.'
      if (key === 'position')
        return `Order: ${(previous?.position ?? 0) + 1} → ${value.position + 1}`
      const display = (v) => (v === null || v === undefined ? 'None' : String(v).slice(0, 500))
      return previous
        ? `${labels[key]}: ${display(previous[key])} → ${display(value[key])}`
        : `${labels[key]}: ${display(value[key])}`
    })
    .join('\n')
  record(store, taskId, {
    id: 'history:' + row.id,
    at: row.savedAt,
    actor: row.origin || 'OpenTalon',
    kind: 'change',
    summary,
    detail: details,
    data: {historyID: row.id, ...(row.runId ? {runId:row.runId} : {})}
  })
}

function migrateMessages(store) {
  for (const row of store.db.prepare('SELECT * FROM task_comments ORDER BY rowid').all()) {
    const comment = JSON.parse(row.data)
    if (comment.agent) {
      const images = store.db
        .prepare('SELECT * FROM comment_images WHERE comment_id=?')
        .all(row.id)
        .map((image) => ({
          id: image.id,
          name: image.name,
          mimeType: image.mime_type,
          data: Buffer.from(image.bytes).toString('base64')
        }))
      record(
        store,
        row.task_id,
        {
          id: 'message:' + row.id,
          at: comment.createdAt,
          actor: comment.agent === 'codex' ? 'Codex' : 'Claude',
          kind: 'agent',
          summary: 'Earlier agent report',
          detail: comment.text,
          data: { agent: comment.agent, runId: comment.runId }
        },
        images
      )
      store.db.prepare('DELETE FROM task_comments WHERE id=?').run(row.id)
    } else if (comment.source !== 'user') {
      record(store, row.task_id, {
        id: 'message:' + row.id,
        at: comment.createdAt,
        actor: 'Earlier message',
        kind: 'legacy',
        summary: 'Earlier task message',
        detail: comment.text,
        legacyCommentID: row.id
      })
      store.db
        .prepare('UPDATE task_comments SET data=? WHERE id=?')
        .run(JSON.stringify({ ...comment, source: 'legacy' }), row.id)
    }
  }
}

function backfillHistory(store) {
  const previous = new Map()
  for (const row of store.db
    .prepare('SELECT * FROM task_history ORDER BY saved_at,task_id,version')
    .all()) {
    const value = JSON.parse(row.state_json)
    recordHistory(
      store,
      row.task_id,
      { id: row.id, savedAt: row.saved_at, origin: row.origin, action: row.action },
      value,
      previous.get(row.task_id),
      JSON.parse(row.changes_json)
    )
    previous.set(row.task_id, value)
  }
}
function chronologicalOrder(store) {
  const rows = store.db.prepare('SELECT id FROM task_activity ORDER BY saved_at,sequence').all()
  store.db.exec('UPDATE task_activity SET sequence=-sequence')
  rows.forEach((row, index) =>
    store.db.prepare('UPDATE task_activity SET sequence=? WHERE id=?').run(index + 1, row.id)
  )
}

function migrate(store) {
  store.db.exec('BEGIN IMMEDIATE')
  try {
    store.db.exec(`CREATE TABLE task_activity (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
      task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, saved_at TEXT NOT NULL,
      actor TEXT NOT NULL,kind TEXT NOT NULL,summary TEXT NOT NULL,detail TEXT NOT NULL,
      legacy_comment_id TEXT REFERENCES task_comments(id) ON DELETE SET NULL,data TEXT NOT NULL) STRICT;
      CREATE INDEX activity_task ON task_activity(task_id,sequence);
      CREATE TABLE activity_images(id TEXT PRIMARY KEY,activity_id TEXT NOT NULL REFERENCES task_activity(id) ON DELETE CASCADE,name TEXT NOT NULL,mime_type TEXT NOT NULL,bytes BLOB NOT NULL) STRICT;
      PRAGMA user_version=11;`)
    backfillHistory(store)
    migrateMessages(store)
    chronologicalOrder(store)
    store.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(11, new Date().toISOString())
    store.db.exec('COMMIT')
  } catch (error) {
    store.db.exec('ROLLBACK')
    throw error
  }
}

function exportRows(store) {
  return {
    activity: store.db.prepare('SELECT * FROM task_activity ORDER BY sequence').all(),
    activityImages: store.db
      .prepare('SELECT * FROM activity_images ORDER BY rowid')
      .all()
      .map((row) => ({ ...row, data: Buffer.from(row.bytes).toString('base64'), bytes: undefined }))
  }
}

function validateRows(rows, images, tasks, comments) {
  const bad = () => {
    throw new AppError('INVALID_BACKUP', 'This backup contains invalid task activity.')
  }
  if (!Array.isArray(rows) || !Array.isArray(images)) bad()
  const taskIDs = new Set(tasks.map((task) => task.id)),
    commentIDs = new Map(comments.map((comment) => [comment.id, comment.taskId])),
    ids = new Set(),
    sequences = new Set(),
    imageIDs = new Set()
  const text = (v, max) =>
    typeof v === 'string' && v.length <= max && v.isWellFormed() && !v.includes('\0')
  for (const row of rows) {
    if (
      !row ||
      !text(row.id, 200) ||
      !row.id ||
      ids.has(row.id) ||
      !taskIDs.has(row.task_id) ||
      !Number.isSafeInteger(row.sequence) ||
      row.sequence < 1 ||
      sequences.has(row.sequence) ||
      !Number.isFinite(Date.parse(row.saved_at)) ||
      !text(row.actor, 100) ||
      !text(row.kind, 50) ||
      !text(row.summary, 1000) ||
      !text(row.detail, 10000) ||
      !(row.legacy_comment_id === null || commentIDs.get(row.legacy_comment_id) === row.task_id) ||
      !text(row.data, 20000)
    )
      bad()
    let data
    try {
      data = JSON.parse(row.data)
    } catch {
      bad()
    }
    if (
      !data ||
      Array.isArray(data) ||
      typeof data !== 'object' ||
      Object.entries(data).some(
        ([key, value]) =>
          !['agent', 'runId', 'historyID', 'commentID'].includes(key) ||
          !(value === null || text(value, 200))
      )
    )
      bad()
    if (data.commentID != null && commentIDs.get(data.commentID) !== row.task_id) bad()
    ids.add(row.id)
    sequences.add(row.sequence)
  }
  for (const image of images) {
    if (
      !image ||
      !ids.has(image.activity_id) ||
      !text(image.id, 150) ||
      !image.id ||
      imageIDs.has(image.id)
    )
      bad()
    imageBytes({ name: image.name, mimeType: image.mime_type, data: image.data })
    imageIDs.add(image.id)
  }
}

function restoreRows(store, rows, images) {
  for (const row of rows)
    store.db
      .prepare('INSERT INTO task_activity VALUES (?,?,?,?,?,?,?,?,?,?)')
      .run(
        row.sequence,
        row.id,
        row.task_id,
        row.saved_at,
        row.actor,
        row.kind,
        row.summary,
        row.detail,
        row.legacy_comment_id,
        row.data
      )
  for (const image of images)
    store.db
      .prepare('INSERT INTO activity_images VALUES (?,?,?,?,?)')
      .run(
        image.id,
        image.activity_id,
        image.name,
        image.mime_type,
        imageBytes({ name: image.name, mimeType: image.mime_type, data: image.data })
      )
  backfillHistory(store)
  migrateMessages(store)
  chronologicalOrder(store)
}
module.exports = {
  record,
  recordHistory,
  page,
  migrate,
  exportRows,
  validateRows,
  restoreRows,
  migrateMessages
}
