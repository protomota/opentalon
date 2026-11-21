const { AppError } = require('./contracts.cjs')
const { randomUUID } = require('node:crypto')
const MAX_IMAGE_BYTES = 2 * 1024 * 1024
function imageBytes(image) {
  if (
    !image ||
    typeof image.name !== 'string' ||
    image.name.length > 200 ||
    !['image/png', 'image/jpeg'].includes(image.mimeType) ||
    typeof image.data !== 'string' ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(image.data)
  )
    throw new AppError('INVALID_IMAGE', 'Attach a PNG or JPEG screenshot.')
  const bytes = Buffer.from(image.data, 'base64')
  const png = bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))
  const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff
  if (
    !bytes.length ||
    bytes.length > MAX_IMAGE_BYTES ||
    !(image.mimeType === 'image/png' ? png : jpeg)
  )
    throw new AppError('INVALID_IMAGE', 'Each screenshot must be a valid PNG or JPEG under 2 MB.')
  return bytes
}
function comments(store, taskId) {
  return store.db
    .prepare('SELECT * FROM task_comments WHERE task_id=? ORDER BY rowid')
    .all(taskId)
    .map((row) => ({
      id: row.id,
      taskId: row.task_id,
      ...JSON.parse(row.data),
      ...commentActivity(store, row),
      images: store.db
        .prepare('SELECT id,name,mime_type FROM comment_images WHERE comment_id=? ORDER BY rowid')
        .all(row.id)
        .map((image) => ({ id: image.id, name: image.name, mimeType: image.mime_type }))
    }))
}
function commentActivity(store, row) {
  const comment = JSON.parse(row.data)
  if (!store.activityReady || comment.source !== 'user') return {}
  let activity =
    comment.actedOnActivityID &&
    store.db
      .prepare(
        "SELECT id,saved_at FROM task_activity WHERE id=? AND task_id=? AND (json_extract(data,'$.commentID')=? OR EXISTS (SELECT 1 FROM json_each(data,'$.commentIDs') WHERE value=?))"
      )
      .get(comment.actedOnActivityID, row.task_id, row.id, row.id)
  const jobRow =
    comment.runId &&
    store.db
      .prepare('SELECT data FROM agent_jobs WHERE id=? AND task_id=?')
      .get(comment.runId, row.task_id)
  const job = jobRow ? JSON.parse(jobRow.data) : null
  if (
    !activity &&
    job?.requiresRevisionReceipts !== true &&
    comment.delivery === 'delivered' &&
    ['done', 'review'].includes(job?.state) &&
    job.summary?.trim() &&
    !/^The agent (ended its turn|finished its response)/.test(job.summary)
  )
    activity = store.db
      .prepare(
        "SELECT id,saved_at FROM task_activity WHERE task_id=? AND kind='agent' AND json_extract(data,'$.runId')=? ORDER BY sequence DESC LIMIT 1"
      )
      .get(row.task_id, comment.runId)
  return {
    activityState: job?.state || null,
    activityID: activity?.id || null,
    actedOnAt: activity?.saved_at || null
  }
}

function insertComment(store, taskId, text, images = [], notifyAgent = false, author = {}) {
  const task = store.task(taskId)
  if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task before sending a revision request.')
  if (!text.trim() && !images.length)
    throw new AppError('EMPTY_COMMENT', 'Describe the change you want or attach a screenshot.')
  const normalized = images.map((image) => ({ ...image, bytes: imageBytes(image) }))
  const id = randomUUID()
  store.db.prepare('INSERT INTO task_comments VALUES (?,?,?)').run(
    id,
    taskId,
    JSON.stringify({
      text,
      source: 'user',
      createdAt: new Date().toISOString(),
      delivery: notifyAgent && !task.archivedAt && store.assignedRun(taskId) ? 'pending' : 'local',
      runId: author.runId || null,
      agent: author.agent || null
    })
  )
  for (const image of normalized)
    store.db
      .prepare('INSERT INTO comment_images VALUES (?,?,?,?,?)')
      .run(randomUUID(), id, image.name, image.mimeType, image.bytes)
  if (store.activityReady)
    require('./task-activity.cjs').record(store, taskId, {
      actor: author.actor || 'You',
      kind: 'comment',
      summary: 'Saved a revision request'
    })
  return comments(store, taskId).find((comment) => comment.id === id)
}
function exportComments(store) {
  return {
    comments: store.db
      .prepare('SELECT * FROM task_comments ORDER BY rowid')
      .all()
      .map((row) => ({ id: row.id, taskId: row.task_id, ...JSON.parse(row.data) })),
    commentImages: store.db
      .prepare('SELECT * FROM comment_images ORDER BY rowid')
      .all()
      .map((row) => ({
        id: row.id,
        commentId: row.comment_id,
        name: row.name,
        mimeType: row.mime_type,
        data: Buffer.from(row.bytes).toString('base64')
      }))
  }
}
function validateComments(records, images, tasks) {
  if (
    !Array.isArray(records) ||
    !Array.isArray(images) ||
    new Set(records.map((row) => row?.id)).size !== records.length ||
    new Set(images.map((row) => row?.id)).size !== images.length
  )
    throw new AppError('INVALID_BACKUP', 'Invalid revision request or screenshot records.')
  const taskIds = new Set(tasks.map((task) => task.id))
  const ids = new Set()
  for (const row of records) {
    if (
      !row ||
      typeof row.id !== 'string' ||
      !row.id.length ||
      row.id.length > 150 ||
      !taskIds.has(row.taskId) ||
      typeof row.text !== 'string' ||
      row.text.length > 10000 ||
      !Number.isFinite(Date.parse(row.createdAt)) ||
      !(row.source === undefined || ['user', 'legacy'].includes(row.source)) ||
      !(
        row.actedOnActivityID === undefined ||
        (typeof row.actedOnActivityID === 'string' && row.actedOnActivityID.length <= 200)
      ) ||
      !['pending', 'queued', 'delivered', 'needs-review', 'local'].includes(row.delivery) ||
      !(row.runId === null || typeof row.runId === 'string') ||
      !(row.agent === null || ['claude-code', 'codex'].includes(row.agent))
    )
      throw new AppError('INVALID_BACKUP', 'Invalid revision request data.')
    ids.add(row.id)
  }
  const counts = new Map()
  for (const image of images) {
    if (
      !image ||
      typeof image.id !== 'string' ||
      !image.id.length ||
      image.id.length > 150 ||
      !ids.has(image.commentId)
    )
      throw new AppError('INVALID_BACKUP', 'A screenshot has no matching revision request.')
    imageBytes(image)
    counts.set(image.commentId, (counts.get(image.commentId) || 0) + 1)
    if (counts.get(image.commentId) > 3)
      throw new AppError('INVALID_BACKUP', 'A revision request has too many screenshots.')
  }
}
function restoreComments(store, records, images) {
  for (const row of records)
    store.db.prepare('INSERT INTO task_comments VALUES (?,?,?)').run(
      row.id,
      row.taskId,
      JSON.stringify({
        text: row.text,
        source: row.source,
        actedOnActivityID: row.actedOnActivityID,
        createdAt: row.createdAt,
        delivery: ['pending', 'queued'].includes(row.delivery) ? 'needs-review' : row.delivery,
        runId: row.runId,
        agent: row.agent
      })
    )
  for (const image of images)
    store.db
      .prepare('INSERT INTO comment_images VALUES (?,?,?,?,?)')
      .run(image.id, image.commentId, image.name, image.mimeType, imageBytes(image))
}
module.exports = {
  comments,
  insertComment,
  exportComments,
  validateComments,
  restoreComments,
  imageBytes,
  MAX_IMAGE_BYTES
}
