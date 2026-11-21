const { DatabaseSync, backup } = require('node:sqlite')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID, createHash } = require('node:crypto')
const { AppError, validateAction, boardIcons, agentModels } = require('./contracts.cjs')
const {
  comments,
  insertComment,
  exportComments,
  validateComments,
  restoreComments,
} = require('./comments.cjs')

const taskHistory = require('./task-history.cjs')
const taskActivity = require('./task-activity.cjs')
const FORMAT = 12
// Older connectors copied Markdown documents into notes with explicit delimiters.
// Recover only complete blocks; never read a referenced filesystem path.
function legacyPlan(notes) {
  let latest = '', current = null, fence = null
  for (const line of (notes || '').match(/[^\n]*\n|[^\n]+$/g) || []) {
    const text = line.replace(/\r?\n$/, '')
    if (fence) {
      if (current) current.push(line)
      if (new RegExp('^ {0,3}' + fence.marker + '{' + fence.length + ',}[ \\t]*$').test(text)) fence = null
      continue
    }
    const opening = text.match(/^ {0,3}(`{3,}|~{3,})/)
    if (opening) {
      fence = { marker: opening[1][0], length: opening[1].length }
      if (current) current.push(line)
    } else if (/^--- Plan: [^\r\n]+\.md[^\r\n]* ---[ \t]*$/.test(text)) current = []
    else if (/^--- End plan ---[ \t]*$/.test(text) && current) {
      const markdown = current.join('')
      if (markdown.trim() && markdown.length <= 100000 && markdown.isWellFormed() && !markdown.includes('\0')) latest = markdown
      current = null
    } else if (current) current.push(line)
  }
  return latest
}
const archiveAfterMs = 7 * 24 * 60 * 60 * 1000
const taskKeyPattern = /^[A-Z]{3}-[0-9]{3,16}$/
const defaultAgentSettings = { defaultAgent: 'codex', workingFolder: '' }
function validDueDate(value) {
  if (value === null) return true
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false
  const date = new Date(`${value}T00:00:00Z`)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
}
const priorities = ['Urgent', 'High', 'Medium', 'Low', 'None']
const taskSelect = `SELECT tasks.*,
  (SELECT count(*) FROM task_comments WHERE task_id=tasks.id AND json_extract(data,'$.source')='user') AS comment_count,
  (SELECT count(*) FROM comment_images JOIN task_comments ON task_comments.id=comment_images.comment_id WHERE task_comments.task_id=tasks.id) AS image_count
  FROM tasks`
const APPLICATION_ID = 0x4f54414c
const legacyStatuses = ['To do', 'In progress', 'Done']
const statuses = ['To do', 'Sent to agent', 'In progress', 'Done']
const themes = ['graphite', 'warm-paper', 'native-light', 'system']
const hash = (value) => createHash('sha256').update(value).digest('hex')
async function fileHash(file) {
  const digest = createHash('sha256')
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk)
  return digest.digest('hex')
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object')
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])])
    )
  return value
}
const argumentHash = (value) => hash(JSON.stringify(canonical(value)))
const text = (value, name) => {
  const result = value.trim()
  if (!result) throw new AppError('INVALID_ARGUMENT', `${name} cannot be blank.`)
  return result
}
function absolute(value) {
  if (!path.isAbsolute(value) || value.includes('\0'))
    throw new AppError('INVALID_PATH', 'Choose an absolute backup file path.')
  return path.normalize(value)
}
function taskView(row) {
  return {
    id: row.id,
    taskKey: row.task_key ?? null,
    boardId: row.board_id,
    title: row.title,
    notes: row.notes,
    planMarkdown: row.plan_markdown || '',
    issueType: row.issue_type || 'Issue',
    status: row.status,
    priority: row.priority || 'None',
    definitionOfDone: row.definition_of_done || '',
    dueDate: row.due_date || null,
    commentCount: row.comment_count || 0,
    imageCount: row.image_count || 0,
    position: row.position,
    deleted: row.deleted_at !== null,
    deletedAt: row.deleted_at,
    completedAt: row.completed_at ?? null,
    archivedAt: row.archived_at ?? null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    revision: row.revision,
  }
}
function boardView(row, icons = {}) {
  return {
    id: row.id,
    name: row.name,
    icon: boardIcons.includes(icons[row.id]) ? icons[row.id] : null,
    position: row.position,
    createdAt: row.created_at,
    revision: row.revision,
  }
}
// Obvious name matches only; anything else keeps the default icon until someone picks one.
const iconHints = [
  ['house', /\b(home|house|hoa|family)\b/],
  ['briefcase', /\b(career|work|job|consulting|clients?|business)\b/],
  ['user', /\b(personal|me|private)\b/],
  ['wallet', /\b(finances?|money|budget|bills?|tax(es)?)\b/],
  ['chart-line', /\b(analytics|metrics|portfolio|reports?|stats)\b/],
  ['server', /\b(infrastructure|infra|servers?|devops|hosting|automation)\b/],
  ['plug', /\b(mcp|integrations?|connectors?|plugins?|api)\b/],
  ['bot', /\b(ai|agents?|bots?|llm)\b/],
  ['megaphone', /\b(marketing|ads?|campaigns?|launch|promo)\b/],
  ['newspaper', /\b(newsletter|news|blog|brief|press)\b/],
  ['plane', /\b(travel|trips?|vacation|flights?)\b/],
  ['book-open', /\b(reading|books?|study|learning|research)\b/],
  ['notebook-pen', /\b(notes?|journal|writing|drafts?)\b/],
  ['palette', /\b(design|art|brand|creative)\b/],
  ['video', /\b(video|film|youtube|reel)\b/],
  ['music', /\b(music|songs?|audio|album)\b/],
  ['mic', /\b(podcast|interviews?)\b/],
  ['code', /\b(code|dev|development|engineering|software)\b/],
  ['globe', /\b(website|web|site|seo)\b/],
  ['shopping-cart', /\b(shopping|store|shop|orders?)\b/],
  ['leaf', /\b(garden|plants?|yard)\b/],
  ['dumbbell', /\b(fitness|gym|health|workouts?)\b/],
  ['utensils', /\b(recipes?|meals?|food|cooking)\b/],
  ['graduation-cap', /\b(school|class|course|university)\b/],
  ['lightbulb', /\b(ideas?|someday|brainstorm)\b/],
  ['inbox', /\b(inbox|triage|backlog)\b/],
]
function suggestBoardIcon(name) {
  const lower = String(name).toLowerCase()
  return iconHints.find(([, pattern]) => pattern.test(lower))?.[0] || null
}

class Store {
  constructor(folder, { version = '0.1.0', changed = () => {}, agentReadiness = () => {} } = {}) {
    this.folder = folder
    this.file = path.join(folder, 'opentalon.sqlite')
    this.version = version
    this.changed = changed
    this.agentReadiness = agentReadiness
    this.previews = new Map()
    this.queue = Promise.resolve()
    fs.mkdirSync(folder, { recursive: true, mode: 0o700 })
    fs.chmodSync(folder, 0o700)
    const existed = fs.existsSync(this.file)
    this.db = new DatabaseSync(this.file)
    try {
      this.db.exec('PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;')
      const current = this.db.prepare('PRAGMA user_version').get().user_version
      if (current > FORMAT)
        throw new AppError(
          'NEWER_DATABASE',
          'This database needs a newer OpenTalon. Your existing data has not been replaced.'
        )
      if (
        existed &&
        (!current ||
          this.db.prepare('PRAGMA application_id').get().application_id !== APPLICATION_ID)
      )
        throw new AppError(
          'INVALID_DATABASE',
          'The existing file is not a supported OpenTalon database. It has not been replaced.'
        )
      if (this.db.prepare('PRAGMA quick_check').get().quick_check !== 'ok')
        throw new AppError(
          'DAMAGED_DATABASE',
          'SQLite found a problem in the existing database. It has not been replaced.'
        )
      if (!current) this.migrate()
      if (current < 2) this.migrateAgents()
      if (current < 3) this.migrateComments()
      if (current < 4) this.migratePriorities()
      if (current < 5) this.migrateDueDates()
      if (current < 6) this.migrateTaskKeys()
      if (current < 7) this.migrateArchive()
      if (current < 8) this.migratePlans()
      if (current < 9) this.migrateIssueTypes()
      if (current < 10) taskHistory.migrate(this)
      if (current < 11) taskActivity.migrate(this)
      this.activityReady = true
      if (current < 12) this.migrateLegacyPlans()
      this.db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;')
      fs.chmodSync(this.file, 0o600)
    } catch (error) {
      this.db.close()
      throw error
    }
  }
  migrate() {
    this.db.exec(`BEGIN IMMEDIATE;
      CREATE TABLE boards (id TEXT PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100), position INTEGER NOT NULL, created_at TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0)) STRICT;
      CREATE TABLE tasks (id TEXT PRIMARY KEY, board_id TEXT NOT NULL REFERENCES boards(id) ON DELETE RESTRICT, title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 500), notes TEXT NOT NULL CHECK(length(notes)<=100000), status TEXT NOT NULL CHECK(status IN ('To do','In progress','Done')), position INTEGER NOT NULL CHECK(position>=0), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL CHECK(revision>0)) STRICT;
      CREATE INDEX tasks_board_order ON tasks(board_id,deleted_at,status,position,id);
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
      CREATE TABLE operation_receipts (request_key TEXT PRIMARY KEY, argument_hash TEXT NOT NULL, result TEXT NOT NULL) STRICT;
      CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL) STRICT;
      PRAGMA application_id=${APPLICATION_ID}; PRAGMA user_version=1;`)
    const id = randomUUID()
    try {
      this.db
        .prepare('INSERT INTO boards VALUES (?,?,?,?,?)')
        .run(id, 'Tasks', 0, new Date().toISOString(), 1)
      for (const [key, value] of Object.entries({
        theme: 'system',
        selectedBoard: id,
        revision: 1,
        preferencesRevision: 1,
        prototypeImported: false,
      }))
        this.set(key, value)
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(1, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
  close() {
    this.db.close()
  }
  migratePriorities() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec(
        "ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'None' CHECK(priority IN ('Urgent','High','Medium','Low','None')); ALTER TABLE tasks ADD COLUMN definition_of_done TEXT NOT NULL DEFAULT '' CHECK(length(definition_of_done)<=10000); PRAGMA user_version=4;"
      )
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(4, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
  migrateDueDates() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec(
        'ALTER TABLE tasks ADD COLUMN due_date TEXT CHECK(due_date IS NULL OR length(due_date)=10); PRAGMA user_version=5;'
      )
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(5, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
  migrateTaskKeys() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec(`
        ALTER TABLE boards ADD COLUMN project_key TEXT;
        ALTER TABLE boards ADD COLUMN next_task_number INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE tasks ADD COLUMN task_key TEXT;
        CREATE UNIQUE INDEX boards_project_key ON boards(project_key);
        CREATE UNIQUE INDEX tasks_task_key ON tasks(task_key);
        PRAGMA user_version=6;
      `)
      this.backfillTaskKeys()
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(6, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }

  migrateArchive() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec(`
        ALTER TABLE tasks ADD COLUMN completed_at TEXT;
        ALTER TABLE tasks ADD COLUMN archived_at TEXT;
        UPDATE tasks SET completed_at=updated_at WHERE status='Done';
        CREATE TRIGGER tasks_record_completion_on_insert AFTER INSERT ON tasks
        WHEN NEW.status='Done' AND NEW.completed_at IS NULL
        BEGIN
          UPDATE tasks SET completed_at=NEW.updated_at WHERE id=NEW.id;
        END;
        CREATE TRIGGER tasks_record_completion_on_move AFTER UPDATE OF status ON tasks
        WHEN OLD.status<>NEW.status
        BEGIN
          UPDATE tasks SET completed_at=CASE WHEN NEW.status='Done' THEN NEW.updated_at END,
            archived_at=NULL WHERE id=NEW.id;
        END;
        PRAGMA user_version=7;
      `)
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(7, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }

  migratePlans() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec("ALTER TABLE tasks ADD COLUMN plan_markdown TEXT NOT NULL DEFAULT '' CHECK(length(plan_markdown)<=100000); PRAGMA user_version=8;")
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(8, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }

  migrateIssueTypes() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec("ALTER TABLE tasks ADD COLUMN issue_type TEXT NOT NULL DEFAULT 'Issue' CHECK(issue_type IN ('Issue','Bug')); PRAGMA user_version=9;")
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(9, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }

  migrateLegacyPlans() {
    this.db.exec('BEGIN IMMEDIATE')
    try {
      const revision = this.revision() + 1
      let recovered = 0
      for (const row of this.db.prepare("SELECT id,notes FROM tasks WHERE plan_markdown=''").all()) {
        const markdown = legacyPlan(row.notes)
        if (!markdown) continue
        this.db.prepare('UPDATE tasks SET plan_markdown=? WHERE id=?').run(markdown, row.id)
        const task = this.saveTask(this.task(row.id), revision)
        taskHistory.record(this, task, 'recover_task_plan', 'OpenTalon')
        recovered++
      }
      if (recovered) this.set('revision', revision)
      this.db.exec('PRAGMA user_version=12')
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(12, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) { this.db.exec('ROLLBACK'); throw error }
  }

  archiveCompletedTasks(now = new Date()) {
    const cutoff = new Date(now.getTime() - archiveAfterMs).toISOString()
    this.db.exec('BEGIN IMMEDIATE')
    const revision = this.revision() + 1
    let count
    try {
      const result = this.db.prepare(`
        UPDATE tasks SET archived_at=?,revision=?
        WHERE status='Done' AND deleted_at IS NULL AND archived_at IS NULL
          AND julianday(completed_at)<=julianday(?)
      `).run(now.toISOString(), revision, cutoff)
      count = result.changes
      if (count) {
        taskHistory.recordRevision(this, revision, 'automatic_archive', 'OpenTalon')
        this.set('revision', revision)
      }
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
    if (count) this.changed(revision)
    return count
  }

  scheduleAutoArchive() {
    this.archiveCompletedTasks()
    const timer = setInterval(() => {
      try { this.archiveCompletedTasks() }
      catch (error) { console.error('OpenTalon automatic archive:', error.message) }
    }, 60_000)
    timer.unref()
    return timer
  }

  allocateProjectKey(id, name) {
    const stem = name.normalize('NFKD').toUpperCase().replace(/[^A-Z]/g, '').slice(0, 3).padEnd(3, 'X')
    const occupied = new Set(this.db.prepare(`
      SELECT project_key AS key FROM boards WHERE project_key IS NOT NULL
      UNION SELECT substr(task_key,1,3) FROM tasks WHERE task_key IS NOT NULL
    `).all().map(({ key }) => key))
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    let key = [stem, ...Array.from(letters, (letter) => stem.slice(0, 2) + letter)]
      .find((candidate) => !occupied.has(candidate))
    for (let index = 0; !key && index < 26 ** 3; index++) {
      const candidate = letters[Math.floor(index / 676)] + letters[Math.floor(index / 26) % 26] + letters[index % 26]
      if (!occupied.has(candidate)) key = candidate
    }
    if (!key) throw new AppError('PROJECT_KEY_LIMIT', 'No project keys are available.')
    this.db.prepare('UPDATE boards SET project_key=? WHERE id=?').run(key, id)
  }

  assignTaskKey(id, boardId) {
    const board = this.db.prepare('SELECT project_key,next_task_number FROM boards WHERE id=?').get(boardId)
    const number = board.next_task_number
    const key = board.project_key + '-' + String(number).padStart(3, '0')
    this.db.prepare('UPDATE tasks SET task_key=? WHERE id=?').run(key, id)
    this.db.prepare('UPDATE boards SET next_task_number=? WHERE id=?').run(number + 1, boardId)
  }

  backfillTaskKeys() {
    for (const { id, name } of this.db.prepare('SELECT id,name FROM boards WHERE project_key IS NULL ORDER BY created_at,id').all())
      this.allocateProjectKey(id, name)
    for (const { id, board_id } of this.db.prepare('SELECT id,board_id FROM tasks WHERE task_key IS NULL ORDER BY created_at,rowid').all())
      this.assignTaskKey(id, board_id)
  }
  migrateAgents() {
    this.db.exec(`BEGIN IMMEDIATE;
      ALTER TABLE tasks RENAME TO tasks_v1;
      DROP INDEX tasks_board_order;
      CREATE TABLE tasks (id TEXT PRIMARY KEY, board_id TEXT NOT NULL REFERENCES boards(id) ON DELETE RESTRICT, title TEXT NOT NULL CHECK(length(trim(title)) BETWEEN 1 AND 500), notes TEXT NOT NULL CHECK(length(notes)<=100000), status TEXT NOT NULL CHECK(status IN ('To do','Sent to agent','In progress','Done')), position INTEGER NOT NULL CHECK(position>=0), created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, revision INTEGER NOT NULL CHECK(revision>0)) STRICT;
      INSERT INTO tasks SELECT * FROM tasks_v1;
      DROP TABLE tasks_v1;
      CREATE INDEX tasks_board_order ON tasks(board_id,deleted_at,status,position,id);
      CREATE TABLE agent_jobs (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, data TEXT NOT NULL) STRICT;
      PRAGMA user_version=2;`)
    try {
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(2, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
  agentSettings() {
    return {
      ...(this.get('agentSettings') || defaultAgentSettings),
      permissionMode: this.get('agentPermissionMode') ?? 'auto',
    }
  }
  agentAssignments() {
    return this.get('agentAssignments') || {}
  }
  assignedRun(taskId) {
    return this.agentAssignments()[taskId] || null
  }
  assignAgent(taskId, runId) {
    const assignments = this.agentAssignments()
    if (runId) assignments[taskId] = runId
    else delete assignments[taskId]
    this.set('agentAssignments', assignments)
  }
  migrateComments() {
    this.db.exec(`BEGIN IMMEDIATE;
      CREATE TABLE task_comments (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, data TEXT NOT NULL) STRICT;
      CREATE INDEX comments_task ON task_comments(task_id);
      CREATE TABLE comment_images (id TEXT PRIMARY KEY, comment_id TEXT NOT NULL REFERENCES task_comments(id) ON DELETE CASCADE, name TEXT NOT NULL, mime_type TEXT NOT NULL, bytes BLOB NOT NULL) STRICT;
      PRAGMA user_version=3;`)
    try {
      this.db.prepare('INSERT INTO schema_migrations VALUES (?,?)').run(3, new Date().toISOString())
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
  comments(taskId) {
    return comments(this, taskId)
  }
  commentImage(id) {
    const image = this.db.prepare('SELECT * FROM comment_images WHERE id=?').get(id) || this.db.prepare('SELECT * FROM activity_images WHERE id=?').get(id)
    if (!image) throw new AppError('NOT_FOUND', 'This screenshot no longer exists.')
    return {
      id: image.id,
      name: image.name,
      mimeType: image.mime_type,
      data: Buffer.from(image.bytes).toString('base64'),
    }
  }
  setCommentDelivery(runId, delivery, pickedUpAt) {
    for (const row of this.db.prepare('SELECT id,data FROM task_comments').all()) {
      const comment = JSON.parse(row.data)
      if (comment.runId === runId && comment.delivery === 'queued')
        this.db
          .prepare('UPDATE task_comments SET data=? WHERE id=?')
          .run(JSON.stringify({ ...comment, delivery, pickedUpAt }), row.id)
    }
  }
  markPendingCommentsForReview(taskId) {
    this.db.prepare(`
      UPDATE task_comments SET data=json_set(data, '$.delivery', 'needs-review')
      WHERE task_id=? AND json_extract(data, '$.delivery')='pending'
    `).run(taskId)
  }
  queueCommentFollowups() {
    const operation = this.queue.then(() => {
      this.db.exec('BEGIN IMMEDIATE')
      try {
        let count = 0
        const jobs = this.agentJobs()
        for (const task of this.snapshot().tasks.filter(
          (task) => !task.deleted && !task.archivedAt && ['In progress', 'Done'].includes(task.status)
        )) {
          if (
            jobs.some(
              (job) =>
                job.taskId === task.id &&
                ['queued', 'starting', 'working', 'needs-input'].includes(job.state)
            )
          )
            continue
          const previous = jobs.find((job) => job.taskId === task.id)
          if (
            !previous?.threadId ||
            previous.state === 'interrupted' ||
            this.assignedRun(task.id) !== previous.id
          )
            continue
          const pending = this.comments(task.id)
            .filter((comment) => comment.delivery === 'pending')
            .slice(0, 3)
          if (!pending.length) continue
          const job = this.saveAgentJob({
            id: randomUUID(),
            taskId: task.id,
            agent: previous.agent,
            model: previous.model,
            workingFolder: previous.workingFolder,
            threadId: previous.threadId,
            resumeThread: true,
            commentIds: pending.map((comment) => comment.id),
            state: 'queued',
            summary: 'Revision requests queued for the existing conversation.',
            createdAt: new Date().toISOString(),
          })
          this.assignAgent(task.id, job.id)
          for (const comment of pending) {
            const { id, taskId, images, ...data } = comment
            this.db
              .prepare('UPDATE task_comments SET data=? WHERE id=?')
              .run(
                JSON.stringify({ ...data, delivery: 'queued', runId: job.id, agent: job.agent }),
                id
              )
          }
          count++
        }
        if (count) this.set('revision', this.revision() + 1)
        this.db.exec('COMMIT')
        if (count) this.changed(this.revision())
        return { queued: count }
      } catch (error) {
        this.db.exec('ROLLBACK')
        throw error
      }
    })
    this.queue = operation.catch(() => {})
    return operation
  }
  agentJobs() {
    return this.db
      .prepare('SELECT data FROM agent_jobs ORDER BY rowid DESC')
      .all()
      .map((row) => JSON.parse(row.data))
  }
  agentJob(id) {
    const row = this.db.prepare('SELECT data FROM agent_jobs WHERE id=?').get(id)
    if (!row) throw new AppError('NOT_FOUND', 'This agent run no longer exists.')
    return JSON.parse(row.data)
  }
  saveAgentJob(job, {activity=true} = {}) {
    const previousRow = this.db.prepare('SELECT data FROM agent_jobs WHERE id=?').get(job.id)
    const previous = previousRow ? JSON.parse(previousRow.data) : null
    const saved = { ...job, updatedAt: new Date().toISOString() }
    this.db
      .prepare(
        'INSERT INTO agent_jobs VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data'
      )
      .run(saved.id, saved.taskId, JSON.stringify(saved))
    if (this.activityReady && activity && (!previous || previous.state !== saved.state || previous.summary !== saved.summary || previous.pickedUpAt !== saved.pickedUpAt || JSON.stringify(previous.approval) !== JSON.stringify(saved.approval))) {
      const agent = saved.agent === 'claude-code' ? 'Claude' : 'Codex'
      taskActivity.record(this,saved.taskId,{actor:'OpenTalon',kind:'agent',summary: saved.pickedUpAt && !previous?.pickedUpAt ? `${agent} picked up the task` : `${agent} run: ${saved.state}`,detail:saved.summary || '',data:{agent:saved.agent,runId:saved.id}})
    }
    return saved
  }
  updateAgentJob(id, patch, { pickedUp = false } = {}) {
    const operation = this.queue.then(() => {
      this.db.exec('BEGIN IMMEDIATE')
      try {
        const job = this.agentJob(id)
        const revision = this.revision() + 1
        const pickedUpAt = pickedUp ? new Date().toISOString() : job.pickedUpAt
        if (pickedUp) {
          const task = this.task(job.taskId)
          if (
            !['starting', 'working'].includes(job.state) ||
            this.assignedRun(job.taskId) !== id ||
            task.deleted ||
            !(['Sent to agent', 'In progress'].includes(task.status) || job.resumeThread && task.status === 'Done' && !task.archivedAt) ||
            job.pickedUpAt
          ) {
            this.db.exec('COMMIT')
            return job
          }
          if (task.status !== 'In progress')
            this.move(task, { status: 'In progress' }, revision, { agentUpdate: true })
        }
        const result = this.saveAgentJob({ ...job, ...patch, pickedUpAt })
        if (this.assignedRun(job.taskId) === id) {
          if (['failed', 'canceled', 'interrupted', 'review'].includes(patch.state)) {
            const task = this.task(job.taskId)
            if (!task.deleted && task.status === 'Sent to agent') {
              this.move(task, { status: 'To do' }, revision)
              this.markPendingCommentsForReview(job.taskId)
            }
          }
          if (patch.state === 'canceled') this.assignAgent(job.taskId, null)
        }
        if (pickedUp) this.setCommentDelivery(id, 'delivered', pickedUpAt)
        if (['failed', 'canceled', 'interrupted'].includes(patch.state))
          this.setCommentDelivery(id, 'needs-review')
        if (patch.state === 'canceled')
          this.markPendingCommentsForReview(job.taskId)
        taskHistory.recordRevision(this, revision, 'agent_update', 'Agent', id)
        this.set('revision', revision)
        this.db.exec('COMMIT')
        this.changed(revision)
        return result
      } catch (error) {
        this.db.exec('ROLLBACK')
        throw error
      }
    })
    this.queue = operation.catch(() => {})
    return operation
  }
  enqueueAgent(task, agent, model, dispatchComment) {
    if (model && !agentModels.some((option) => option.agent === agent && option.id === model))
      throw new AppError('INVALID_ARGUMENT', 'Choose a current model for the selected agent.')
    const settings = this.agentSettings()
    const resolvedAgent = this.agentReadiness({ ...settings, defaultAgent: agent || settings.defaultAgent }, agent)
    settings.defaultAgent = resolvedAgent || agent || settings.defaultAgent
    if (!settings.workingFolder)
      throw new AppError(
        'AGENT_SETUP_REQUIRED',
        'Choose a default agent and working folder in Settings before sending tasks.'
      )
    if (
      this.agentJobs().some(
        (job) =>
          job.taskId === task.id &&
          ['queued', 'starting', 'working', 'needs-input'].includes(job.state)
      )
    )
      throw new AppError(
        'AGENT_ALREADY_RUNNING',
        'This task already has an active agent run. Stop it before sending again.'
      )
    const dispatchCommentId = dispatchComment === undefined
      ? undefined
      : insertComment(this, task.id, dispatchComment).id
    const now = new Date().toISOString()
    const job = this.saveAgentJob({
      id: randomUUID(),
      taskId: task.id,
      agent: settings.defaultAgent,
      model,
      dispatchCommentId,
      workingFolder: settings.workingFolder,
      state: 'queued',
      threadId: null,
      summary: 'Waiting to start',
      createdAt: now,
    })
    if (dispatchCommentId)
      this.db.prepare("UPDATE task_comments SET data=json_set(data, '$.delivery', 'queued', '$.runId', ?) WHERE id=?")
        .run(job.id, dispatchCommentId)
    this.assignAgent(task.id, job.id)
    return job
  }
  get(key) {
    const row = this.db.prepare('SELECT value FROM settings WHERE key=?').get(key)
    return row ? JSON.parse(row.value) : undefined
  }

  recoverStalledDispatches() {
    this.db.exec('BEGIN IMMEDIATE')
    const revision = this.revision() + 1
    let recovered = 0
    try {
      const assignments = this.agentAssignments()
      const liveRuns = new Set(this.agentJobs()
        .filter((job) => ['queued', 'starting', 'working', 'needs-input'].includes(job.state))
        .map((job) => job.id))
      for (const task of this.snapshot().tasks) {
        if (!task.deleted && task.status === 'Sent to agent' && !liveRuns.has(assignments[task.id])) {
          this.move(task, { status: 'To do' }, revision)
          this.markPendingCommentsForReview(task.id)
          recovered++
        }
      }
      if (recovered) { taskHistory.recordRevision(this, revision, 'dispatch_recovered', 'OpenTalon'); this.set('revision', revision) }
      this.db.exec('COMMIT')
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
    if (recovered) this.changed(revision)
  }
  set(key, value) {
    this.db
      .prepare(
        'INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value'
      )
      .run(key, JSON.stringify(value))
  }
  revision() {
    return this.get('revision')
  }
  preferences() {
    return {
      theme: this.get('theme'),
      selectedBoard: this.get('selectedBoard'),
      revision: this.get('preferencesRevision'),
    }
  }
  boardIcons() {
    return this.get('boardIcons') || {}
  }
  setBoardIcon(id, icon) {
    const icons = this.boardIcons()
    if (icon) icons[id] = icon
    else delete icons[id]
    this.set('boardIcons', icons)
  }
  // Interleaving of tasks across projects in the All tasks view. Order within a project stays in
  // task positions; ids of trashed or purged tasks are dropped on the next save.
  allTasksOrder() {
    const order = this.get('allTasksOrder')
    return Array.isArray(order) ? order.filter((id) => typeof id === 'string') : []
  }
  boards() {
    const icons = this.boardIcons()
    return this.db
      .prepare('SELECT * FROM boards ORDER BY position,id')
      .all()
      .map((row) => boardView(row, icons))
  }
  task(id) {
    const row = this.db.prepare(`${taskSelect} WHERE tasks.id=?`).get(id) ??
      this.db.prepare(`${taskSelect} WHERE task_key=?`).get(id.toUpperCase())
    if (!row) throw new AppError('NOT_FOUND', 'Task no longer exists.')
    return taskView(row)
  }
  board(id) {
    const row = this.db.prepare('SELECT * FROM boards WHERE id=?').get(id)
    if (!row) throw new AppError('NOT_FOUND', 'Board no longer exists.')
    return boardView(row, this.boardIcons())
  }
  createBoard(name, revision, icon = suggestBoardIcon(name)) {
    const id = randomUUID()
    this.db.prepare('INSERT INTO boards (id,name,position,created_at,revision) VALUES (?,?,?,?,?)')
      .run(id, text(name, 'Board name'), this.db.prepare('SELECT coalesce(max(position),-1)+1 AS position FROM boards').get().position,
        new Date().toISOString(), revision)
    this.allocateProjectKey(id, name)
    this.setBoardIcon(id, icon)
    return this.board(id)
  }
  expect(record, expected) {
    if (record.revision !== expected)
      throw new AppError(
        'CONFLICT',
        'This item changed. Review the saved version before retrying your edit.',
        { current: record }
      )
  }
  snapshot({ includeRecordedCompletions = false } = {}) {
    const tasks = this.db.prepare(`${taskSelect} ORDER BY position,id`).all().map(taskView)
    if (includeRecordedCompletions) {
      const completions = taskHistory.recordedCompletions(this)
      for (const task of tasks) task.recordedCompletionAt = completions.get(task.id) ?? null
    }
    return {
      version: 1,
      ...this.preferences(),
      preferencesRevision: this.get('preferencesRevision'),
      revision: this.revision(),
      boards: this.boards(),
      tasks,
      agentRuns: this.agentJobs(),
      agentAssignments: this.agentAssignments(),
      allTasksOrder: this.allTasksOrder(),
    }
  }
  nextPosition(boardId, status) {
    return this.db
      .prepare(
        'SELECT coalesce(max(position),-1)+1 AS position FROM tasks WHERE board_id=? AND status=? AND deleted_at IS NULL AND archived_at IS NULL'
      )
      .get(boardId, status).position
  }
  liveColumn(boardId, status) {
    return this.db.prepare(
      'SELECT * FROM tasks WHERE board_id=? AND status=? AND deleted_at IS NULL AND archived_at IS NULL ORDER BY position,id'
    ).all(boardId, status).map(taskView)
  }
  saveColumnOrder(tasks, revision) {
    for (const [position, task] of tasks.entries()) {
      if (task.position !== position) this.saveTask({ ...task, position }, revision)
    }
  }
  saveTask(task, revision) {
    this.db
      .prepare(
        'UPDATE tasks SET board_id=?,title=?,notes=?,status=?,position=?,updated_at=?,deleted_at=?,revision=?,priority=?,definition_of_done=?,due_date=?,issue_type=? WHERE id=?'
      )
      .run(
        task.boardId,
        task.title,
        task.notes,
        task.status,
        task.position,
        new Date().toISOString(),
        task.deletedAt,
        revision,
        task.priority,
        task.definitionOfDone,
        task.dueDate,
        task.issueType || 'Issue',
        task.id
      )
    return this.task(task.id)
  }
  move(task, a, revision, { agentUpdate = false } = {}) {
    if (a.beforeId && a.afterId)
      throw new AppError('INVALID_ARGUMENT', 'Choose beforeId or afterId, not both.')
    if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task before moving it.')
    const boardId = a.boardId || task.boardId
    const status = a.status || task.status
    const sending = status === 'Sent to agent' && task.status !== status
    if ((a.agent || a.model || a.dispatchComment !== undefined) && !sending)
      throw new AppError('INVALID_ARGUMENT', 'Agent options and revision requests for dispatch require sending a task.')
    if (task.archivedAt && a.status !== undefined) {
      this.db.prepare('UPDATE tasks SET archived_at=NULL WHERE id=?').run(task.id)
      task = { ...task, archivedAt: null }
    }
    if (task.archivedAt && status === task.status) {
      if (a.beforeId || a.afterId)
        throw new AppError('INVALID_STATE', 'Reopen the archived task before reordering it.')
      this.board(boardId)
      if (boardId !== task.boardId) this.assignTaskKey(task.id, boardId)
      return this.saveTask({ ...task, boardId }, revision)
    }
    if (status === 'Done' && task.status !== 'Done' && this.assignedRun(task.id) && !agentUpdate)
      throw new AppError(
        'COMPLETION_PROOF_REQUIRED',
        'Agent tasks need a completion report with proof and a confirmed definition of done through report_agent_progress. Return to To do first if you want to track this task manually.'
      )
    if (sending) this.enqueueAgent(task, a.agent, a.model, a.dispatchComment)
    if (!agentUpdate && status !== 'Sent to agent' && status !== task.status)
      this.assignAgent(task.id, null)
    if (status !== 'Sent to agent')
      for (const job of this.agentJobs())
        if (job.taskId === task.id && job.state === 'queued')
          this.saveAgentJob({ ...job, state: 'canceled', summary: 'Task moved before dispatch.' })
    this.board(boardId)
    const column = this.db
      .prepare(
        'SELECT * FROM tasks WHERE board_id=? AND status=? AND deleted_at IS NULL AND archived_at IS NULL AND id<>? ORDER BY position,id'
      )
      .all(boardId, status, task.id)
      .map(taskView)
    const anchorId = a.beforeId || a.afterId
    if (anchorId === task.id)
      throw new AppError('INVALID_ARGUMENT', 'A task cannot be its own position anchor.')
    const anchor = anchorId ? column.findIndex((item) => item.id === anchorId) : -1
    if (anchorId && anchor < 0)
      throw new AppError(
        'INVALID_ARGUMENT',
        'The position anchor must be a live task in the destination column.'
      )
    column.splice(anchor < 0 ? column.length : anchor + (a.afterId ? 1 : 0), 0, {
      ...task,
      boardId,
      status,
    })
    if (status !== task.status) taskHistory.beginIfMissing(this, task)
    column.forEach((item, position) => {
      if (item.id === task.id || item.position !== position)
        this.saveTask({ ...item, position }, revision)
    })
    if (boardId !== task.boardId) this.assignTaskKey(task.id, boardId)
    return this.task(task.id)
  }
  list(a, trash = false) {
    if (a.boardId) this.board(a.boardId)
    const filter = {
      trash,
      boardId: a.boardId || null,
      status: a.status || null,
      query: (a.query || '').trim().toLowerCase(),
      priority: a.priority || null,
      issueType: a.issueType || null,
      sort: a.sort || 'manual',
    }
    const fingerprint = argumentHash(filter)
    let offset = 0
    if (a.cursor) {
      let cursor
      try {
        cursor = JSON.parse(Buffer.from(a.cursor, 'base64url').toString())
      } catch {
        throw new AppError('INVALID_CURSOR', 'Invalid continuation cursor.')
      }
      if (
        cursor.filter !== fingerprint ||
        cursor.revision !== this.revision() ||
        !Number.isSafeInteger(cursor.offset) ||
        cursor.offset < 0
      )
        throw new AppError(
          'STALE_CURSOR',
          'The results changed or filters differ. Start again without cursor.'
        )
      offset = cursor.offset
    }
    const where = ['deleted_at IS ' + (trash ? 'NOT NULL' : 'NULL')]
    const params = []
    if (filter.boardId) {
      where.push('board_id=?')
      params.push(filter.boardId)
    }
    if (filter.status) {
      where.push('status=?')
      params.push(filter.status)
    }
    if (filter.priority) {
      where.push('priority=?')
      params.push(filter.priority)
    }
    if (filter.issueType) {
      where.push('issue_type=?')
      params.push(filter.issueType)
    }
    // JS Unicode lowercasing keeps UI and MCP search identical, beyond SQLite's ASCII lower().
    const rows = this.db
      .prepare(
        `${taskSelect} WHERE ${where.join(' AND ')} ORDER BY board_id,CASE status WHEN 'To do' THEN 0 WHEN 'Sent to agent' THEN 1 WHEN 'In progress' THEN 2 ELSE 3 END,${filter.sort === 'manual' ? '' : `CASE priority WHEN 'Urgent' THEN ${filter.sort === 'priority-asc' ? 3 : 0} WHEN 'High' THEN ${filter.sort === 'priority-asc' ? 2 : 1} WHEN 'Medium' THEN ${filter.sort === 'priority-asc' ? 1 : 2} WHEN 'Low' THEN ${filter.sort === 'priority-asc' ? 0 : 3} ELSE 4 END,`}position,id`
      )
      .all(...params)
      .map(taskView)
      .filter(
        (item) =>
          !filter.query || `${item.taskKey ?? ''}\n${item.title}\n${item.notes}`.toLowerCase().includes(filter.query)
      )
    const limit = a.limit || 100
    return {
      tasks: rows.slice(offset, offset + limit),
      total: rows.length,
      revision: this.revision(),
      nextCursor:
        offset + limit < rows.length
          ? Buffer.from(
              JSON.stringify({
                filter: fingerprint,
                revision: this.revision(),
                offset: offset + limit,
              })
            ).toString('base64url')
          : null,
    }
  }
  dispatch(name, input = {}, origin = 'Connected agent') {
    const job = this.queue.then(() => this.execute(name, input, origin))
    this.queue = job.catch(() => {})
    return job
  }
  async execute(name, a, origin = 'Connected agent') {
    if (a.dispatchComment && !origin.startsWith('You')) throw new AppError('INVALID_ARGUMENT','Revision requests for dispatch are only for text entered by the user. Record agent context with add_task_activity.')
    const markdown = name === 'set_task_plan' ? a.markdown : a.planMarkdown
    if (markdown !== undefined && (typeof markdown !== 'string' || markdown.length > 100000 ||
        !markdown.isWellFormed() || markdown.includes('\0')))
      throw new AppError('INVALID_ARGUMENT', 'Use valid Markdown text with no more than 100,000 characters.')
    if (a.dueDate !== undefined && !validDueDate(a.dueDate))
      throw new AppError(
        'INVALID_ARGUMENT',
        'Choose a real due date in YYYY-MM-DD format, or null to clear it.'
      )
    const contract = validateAction(
      name,
      a,
      [
        'add_user_comment',
        'snapshot',
        'capture_task',
        'companion_organize_task',
        'import_prototype',
        'get_agent_settings',
        'set_agent_settings',
        'retry_task_comment',
        'reorder_tasks',
        'reorder_all_tasks',
        'companion_delete_archived_task',
        'companion_empty_trash',
        'companion_set_task_field',
        'companion_reorder_task',
        'force_complete_task',
        'manage_archived_tasks',
      ].includes(name)
    )
    if (name === 'snapshot') return this.snapshot()
    if (name === 'import_prototype') return this.importPrototype(a.workspace)
    if (name === 'get_app_status')
      return {
        available: true,
        version: this.version,
        statuses,
        dataLocation: this.folder,
        revision: this.revision(),
      }
    if (name === 'list_boards') return { boards: this.boards(), revision: this.revision() }
    if (name === 'get_task') return { task: this.task(a.id) }
    if (name === 'list_task_activity') return taskActivity.page(this, a.taskId, a.beforeSequence, a.limit, a.commentId)
    if (name === 'get_task_history') return taskHistory.page(this, a.id, a.beforeVersion, a.limit)
    if (name === 'list_tasks' || name === 'list_trash') return this.list(a, name === 'list_trash')
    if (name === 'get_preferences') return this.preferences()
    if (name === 'list_task_comments') {
      this.task(a.taskId)
      return { comments: this.comments(a.taskId).filter(comment => comment.source === 'user'), revision: this.revision() }
    }
    if (name === 'read_comment_image') return this.commentImage(a.imageId)
    if (name === 'get_agent_settings') return this.agentSettings()
    if (name === 'inspect_backup') return (await this.inspect(a.path)).summary
    if (name === 'preview_destructive_action') return this.preview(a)
    if (!contract.mutates) throw new AppError('UNKNOWN_ACTION', 'Unavailable action.')
    const digest = argumentHash({ name, ...a })
    const receipt = this.db
      .prepare('SELECT * FROM operation_receipts WHERE request_key=?')
      .get(a.requestKey)
    if (receipt) {
      if (receipt.argument_hash !== digest)
        throw new AppError(
          'REQUEST_KEY_REUSED',
          'This requestKey was already used with different arguments.'
        )
      return JSON.parse(receipt.result)
    }
    if (name === 'create_backup') {
      const result = await this.createBackup(a.destination, a.format)
      this.db
        .prepare('INSERT INTO operation_receipts VALUES (?,?,?)')
        .run(a.requestKey, digest, JSON.stringify(result))
      return result
    }
    let restore
    let preview
    if (name === 'confirm_destructive_action') {
      preview = this.previews.get(a.token)
      if (!preview || preview.expires < Date.now() || preview.revision !== this.revision())
        throw new AppError(
          'STALE_PREVIEW',
          'This confirmation expired or the workspace changed. Generate a new preview.'
        )
      if (preview.action === 'restore_backup') {
        restore = await this.inspect(preview.path)
        if (restore.summary.sha256 !== preview.sha256)
          throw new AppError('STALE_PREVIEW', 'The backup changed. Generate a new preview.')
        preview.safetyBackup = (await this.createBackup()).path
      }
    }
    this.db.exec('BEGIN IMMEDIATE')
    try {
      const revision = this.revision() + 1
      let result
      if (name === 'restore_task_revision') result = taskHistory.restore(this, a, revision)
      else if (name === 'reorder_tasks') {
        this.expect({ revision: this.revision() }, a.expectedRevision)
        this.board(a.boardId)
        const column = this.liveColumn(a.boardId, a.status)
        const byId = new Map(column.map((task) => [task.id, task]))
        if (a.taskIds.length !== column.length || a.taskIds.some((id) => !byId.has(id)))
          throw new AppError(
            'INVALID_ARGUMENT',
            'The order must include every current live task in this column exactly once.'
          )
        this.saveColumnOrder(a.taskIds.map((id) => byId.get(id)), revision)
        result = { reordered: a.taskIds.length, revision }
      } else if (name === 'companion_reorder_task') {
        if (a.id === a.anchorId)
          throw new AppError('INVALID_ARGUMENT', 'A task cannot be its own position anchor.')
        const column = this.liveColumn(a.boardId, a.status)
        const index = column.findIndex((task) => task.id === a.id)
        if (index < 0 || !column.some((task) => task.id === a.anchorId))
          throw new AppError('CONFLICT', 'One of the tasks moved. Check the current project order before retrying.')
        const [task] = column.splice(index, 1)
        const anchor = column.findIndex((item) => item.id === a.anchorId)
        column.splice(anchor + (a.before ? 0 : 1), 0, task)
        this.saveColumnOrder(column, revision)
        result = { task: this.task(a.id) }
      } else if (name === 'reorder_all_tasks') {
        this.expect({ revision: this.revision() }, a.expectedRevision)
        const live = new Map(
          this.db
            .prepare(`${taskSelect} WHERE deleted_at IS NULL AND archived_at IS NULL`)
            .all()
            .map((row) => [row.id, taskView(row)])
        )
        const arriving = a.taskIds.filter((id) => live.get(id)?.status !== a.status)
        const column = [...live.values()].filter((task) => task.status === a.status)
        if (
          a.taskIds.some((id) => !live.has(id)) ||
          arriving.length > 1 ||
          a.taskIds.length !== column.length + arriving.length
        )
          throw new AppError(
            'INVALID_ARGUMENT',
            'The order must include every current live task in this column exactly once, plus at most one task moved in from another column.'
          )
        // A card dragged in from another column changes status exactly as move_task would.
        if ((a.agent || a.model) && arriving.length !== 1)
          throw new AppError('INVALID_ARGUMENT', 'Choose an agent or model only when sending a task.')
        for (const id of arriving)
          this.move(live.get(id), { status: a.status, agent: a.agent, model: a.model }, revision)
        const projects = new Map()
        for (const id of a.taskIds) {
          const boardId = live.get(id).boardId
          projects.set(boardId, [...(projects.get(boardId) || []), id])
        }
        for (const ids of projects.values())
          for (const [position, id] of ids.entries()) {
            const task = this.task(id)
            if (task.position !== position) this.saveTask({ ...task, position }, revision)
          }
        const moved = new Set(a.taskIds)
        this.set('allTasksOrder', [
          ...this.allTasksOrder().filter((id) => live.has(id) && !moved.has(id)),
          ...a.taskIds,
        ])
        result = { reordered: a.taskIds.length, revision }
      } else if (name === 'retry_task_comment') {
        const row = this.db.prepare('SELECT * FROM task_comments WHERE id=?').get(a.id)
        if (!row) throw new AppError('NOT_FOUND', 'This revision request no longer exists.')
        if (!this.assignedRun(row.task_id))
          throw new AppError(
            'TASK_MANUAL',
            'This task is manual. Move it to Sent to agent before asking an agent to continue.'
          )
        const data = JSON.parse(row.data)
        if (data.delivery !== 'needs-review')
          throw new AppError('INVALID_STATE', 'This revision request is already queued or delivered.')
        const previous = this.agentJobs().find((job) => job.taskId === row.task_id)
        if (previous?.state === 'interrupted') this.saveAgentJob({ ...previous, state: 'review' })
        this.db
          .prepare('UPDATE task_comments SET data=? WHERE id=?')
          .run(JSON.stringify({ ...data, delivery: 'pending', runId: null }), a.id)
        result = { comment: this.comments(row.task_id).find((comment) => comment.id === a.id) }
      } else if (name === 'add_user_comment') {
        result = { comment: insertComment(this, a.taskId, a.text, a.images, a.notifyAgent, {actor:origin.startsWith('You') ? origin : 'You'}) }
      } else if (name === 'add_task_comment' || name === 'add_task_activity') {
        const task = this.task(a.taskId)
        if(task.deleted) throw new AppError('IN_TRASH','Restore the task before adding activity.')
        if(!a.text.trim() && !a.images?.length) throw new AppError('EMPTY_COMMENT','Write an activity update or attach a screenshot.')
        const comment = a.commentId && this.comments(a.taskId).find(comment => comment.id === a.commentId && comment.source === 'user')
        if (a.commentId && !comment) throw new AppError('NOT_FOUND','Choose a revision request on this task.')
        const runId = this.assignedRun(a.taskId)
        const activity = taskActivity.record(this,a.taskId,{actor:origin,kind:'agent',summary:comment?'Response to your revision request':'Agent update',detail:a.text,data:{...(runId?{runId}:{}),...(comment?{commentID:comment.id}:{})}},a.images || [])
        if (comment) this.db.prepare("UPDATE task_comments SET data=json_set(data,'$.actedOnActivityID',?) WHERE id=?").run(activity.id,comment.id)
        result = {activity,...(name === 'add_task_comment' ? {comment:activity,redirectedToActivity:true} : {})}
      } else if (name === 'set_agent_settings') {
        if (
          a.workingFolder &&
          (!path.isAbsolute(a.workingFolder) || !fs.statSync(a.workingFolder).isDirectory())
        )
          throw new AppError('INVALID_PATH', 'Choose an existing working folder.')
        this.set('agentSettings', { defaultAgent: a.defaultAgent, workingFolder: a.workingFolder })
        if (a.permissionMode !== undefined) this.set('agentPermissionMode', a.permissionMode)
        result = { settings: this.agentSettings() }
      } else if (name === 'report_agent_progress') {
        const job = this.agentJob(a.runId)
        if (!['starting', 'working', 'needs-input'].includes(job.state))
          throw new AppError('INACTIVE_RUN', 'This agent run is no longer active.')
        if (this.assignedRun(job.taskId) !== job.id)
          throw new AppError(
            'TASK_MANUAL',
            'This task is being tracked manually. Stop agent work on it.'
          )
        let task = this.task(job.taskId)
        if (task.deleted || !['Sent to agent', 'In progress'].includes(task.status))
          throw new AppError('TASK_MOVED', 'The task was moved or removed. Stop work on it.')
        let completionReport
        if (a.state === 'done') {
          if (
            a.definitionOfDoneMet !== true ||
            !a.proof ||
            a.proof.trim().length < 20 ||
            !a.summary.trim()
          )
            throw new AppError(
              'COMPLETION_PROOF_REQUIRED',
              'Before Done, provide proof describing concrete checks/results or deliverables, explain how the definition of done was met, and set definitionOfDoneMet true. Otherwise report needs-input or failed.'
            )
          const report = `${job.agent === 'claude-code' ? 'Claude' : 'Codex'} completion report\n\nOutcome\n${a.summary.trim()}\n\nDefinition of done: met\n${task.definitionOfDone || 'Complete the requested outcome, verify it with relevant checks, and post concrete proof on this task.'}\n\nProof and verification\n${a.proof.trim()}`
          if (report.length > 10000)
            throw new AppError(
              'INVALID_ARGUMENT',
              'Keep the completion report, proof and definition of done within 10,000 characters combined.'
            )
          completionReport = taskActivity.record(this, task.id, {actor:job.agent === 'codex' ? 'Codex' : 'Claude',kind:'agent',summary:'Completion report',detail:report,data:{agent:job.agent,runId:job.id}})
        }
        if (a.state !== 'done') taskActivity.record(this, task.id, {actor:job.agent === 'codex' ? 'Codex' : 'Claude',kind:'agent',summary:a.state === 'working' ? 'Agent progress' : a.state === 'needs-input' ? 'Agent needs your input' : 'Agent run failed',detail:a.summary,data:{agent:job.agent,runId:job.id}})
        const hasNewComments =
          a.state === 'done' &&
          this.comments(task.id).some((comment) => ['pending', 'queued'].includes(comment.delivery))
        const state = hasNewComments ? 'review' : a.state
        if (state === 'working' || state === 'done')
          task = this.move(task, { status: state === 'done' ? 'Done' : 'In progress' }, revision, {
            agentUpdate: true,
          })
        result = {
          run: this.saveAgentJob({
            ...job,
            state,
            summary:
              a.summary +
              (hasNewComments
                ? '\nNew comments are waiting for the next check; this task remains In progress.'
                : ''),
          }, {activity:false}),
          task,
          ...(completionReport ? { completionReport } : {}),
        }
      } else if (name === 'create_board') {
        result = { board: this.createBoard(a.name, revision, a.icon) }
      } else if (name === 'set_board_icon') {
        this.expect(this.board(a.id), a.expectedRevision)
        this.db.prepare('UPDATE boards SET revision=? WHERE id=?').run(revision, a.id)
        this.setBoardIcon(a.id, a.icon)
        result = { board: this.board(a.id) }
      } else if (name === 'rename_board' || name === 'delete_board') {
        const board = this.board(a.id)
        this.expect(board, a.expectedRevision)
        if (name === 'rename_board') {
          this.db
            .prepare('UPDATE boards SET name=?,revision=? WHERE id=?')
            .run(text(a.name, 'Board name'), revision, a.id)
          result = { board: this.board(a.id) }
          for (const task of this.db.prepare('SELECT id FROM tasks WHERE board_id=?').all(a.id))
            taskHistory.record(this,this.task(task.id),'rename_board',origin)
        } else {
          if (this.db.prepare('SELECT 1 FROM tasks WHERE board_id=? LIMIT 1').get(a.id))
            throw new AppError(
              'BOARD_NOT_EMPTY',
              'Move or remove all live and trashed tasks before deleting this board.'
            )
          if (this.boards().length === 1)
            throw new AppError('LAST_BOARD', 'Keep at least one board.')
          this.db.prepare('DELETE FROM boards WHERE id=?').run(a.id)
          this.setBoardIcon(a.id, null)
          if (this.get('selectedBoard') === a.id) {
            this.set('selectedBoard', this.boards()[0].id)
            this.set('preferencesRevision', revision)
          }
          result = { deletedBoardId: a.id }
        }
      } else if (name === 'set_preferences') {
        this.expect(this.preferences(), a.expectedRevision)
        if (a.theme !== undefined) this.set('theme', a.theme)
        if (a.selectedBoard !== undefined) {
          this.board(a.selectedBoard)
          this.set('selectedBoard', a.selectedBoard)
        }
        this.set('preferencesRevision', revision)
        result = { preferences: this.preferences() }
      } else if (name === 'create_task' || name === 'capture_task') {
        let boardId = a.boardId
        if (name === 'capture_task' && a.newProjectName) {
          const projectName = text(a.newProjectName, 'Project name')
          const existing = this.boards().find((board) => board.name.trim().toLowerCase() === projectName.toLowerCase())
          boardId = (existing ?? this.createBoard(projectName, revision)).id
        }
        this.board(boardId)
        const id = randomUUID(),
          now = new Date().toISOString(),
          status = a.status || 'To do'
        this.db
          .prepare(
            'INSERT INTO tasks (id,board_id,title,notes,status,position,created_at,updated_at,deleted_at,revision,priority,definition_of_done,due_date) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)'
          )
          .run(
            id,
            boardId,
            text(a.title, 'Title'),
            a.notes || '',
            status,
            this.nextPosition(boardId, status),
            now,
            now,
            null,
            revision,
            a.priority || 'None',
            a.definitionOfDone || '',
            a.dueDate || null
          )
        this.assignTaskKey(id, boardId)
        if (a.issueType !== undefined) this.db.prepare('UPDATE tasks SET issue_type=? WHERE id=?').run(a.issueType, id)
        this.db.prepare('UPDATE tasks SET plan_markdown=? WHERE id=?')
          .run(a.planMarkdown ?? legacyPlan(a.notes), id)
        result = { task: this.task(id) }
        if ((a.agent || a.model || a.dispatchComment !== undefined) && status !== 'Sent to agent')
          throw new AppError('INVALID_ARGUMENT', 'Agent options and revision requests for dispatch require sending a task.')
        if (status === 'Sent to agent') this.enqueueAgent(result.task, a.agent, a.model, a.dispatchComment)
      } else if (['update_task', 'move_task', 'trash_task', 'restore_task'].includes(name)) {
        let task = this.task(a.id)
        this.expect(task, a.expectedRevision)
        if (name === 'move_task') task = this.move(task, a, revision)
        else if (name === 'update_task') {
          if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task before editing it.')
          if (a.title !== undefined) {
            text(a.title, 'Title')
            task.title = a.title
          }
          if (a.notes !== undefined) task.notes = a.notes
          if (a.planMarkdown !== undefined)
            this.db.prepare('UPDATE tasks SET plan_markdown=? WHERE id=?').run(a.planMarkdown, task.id)
          else if (a.notes !== undefined && !task.planMarkdown)
            this.db.prepare('UPDATE tasks SET plan_markdown=? WHERE id=?').run(legacyPlan(a.notes), task.id)
          if (a.issueType !== undefined) task.issueType = a.issueType
          if (a.priority !== undefined) task.priority = a.priority
          if (a.definitionOfDone !== undefined) task.definitionOfDone = a.definitionOfDone
          if (a.dueDate !== undefined) task.dueDate = a.dueDate
          if (a.status !== undefined && a.status !== task.status)
            task = this.move(task, { status: a.status }, revision)
          task = this.saveTask(task, revision)
        } else {
          const deleted = name === 'trash_task'
          if (deleted) this.assignAgent(task.id, null)
          if (task.deleted === deleted)
            throw new AppError(
              'INVALID_STATE',
              deleted ? 'Task is already in Trash.' : 'Task is not in Trash.'
            )
          const occupied =
            !deleted &&
            this.db
              .prepare(
                'SELECT 1 FROM tasks WHERE board_id=? AND status=? AND deleted_at IS NULL AND position=? LIMIT 1'
              )
              .get(task.boardId, task.status, task.position)
          task = this.saveTask(
            {
              ...task,
              deletedAt: deleted ? new Date().toISOString() : null,
              position: occupied ? this.nextPosition(task.boardId, task.status) : task.position,
            },
            revision
          )
        }
        result = { task }
      } else if (name === 'set_task_plan') {
        const task = this.task(a.id)
        if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task before editing its plan.')
        if (task.planMarkdown !== a.expectedMarkdown)
          throw new AppError('CONFLICT', 'The plan changed on another device. Your draft is preserved; review both versions before saving.')
        this.db.prepare('UPDATE tasks SET plan_markdown=? WHERE id=?').run(a.markdown, task.id)
        result = { task: this.saveTask(task, revision) }
      } else if (name === 'companion_organize_task') {
        let task = this.task(a.id)
        if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task from Trash first.')
        if (a.destination === 'active') {
          if (!task.archivedAt) throw new AppError('INVALID_STATE', 'This task is no longer in Archive.')
          this.db.prepare('UPDATE tasks SET archived_at=NULL WHERE id=?').run(task.id)
          task = this.move({ ...task, archivedAt: null }, { status: 'To do' }, revision)
        } else {
          for (const job of this.agentJobs()) {
            if (job.taskId !== task.id || !['queued', 'starting', 'working', 'needs-input'].includes(job.state)) continue
            this.saveAgentJob({ ...job, state: 'canceled', approval: null,
              summary: a.destination === 'archive' ? 'Archived by the user.' : 'Moved to Trash by the user.' })
            this.setCommentDelivery(job.id, 'needs-review')
          }
          this.markPendingCommentsForReview(task.id)
          this.assignAgent(task.id, null)
          task = this.saveTask(task, revision)
          const now = new Date().toISOString()
          if (a.destination === 'archive')
            this.db.prepare('UPDATE tasks SET archived_at=? WHERE id=?').run(now, task.id)
          else this.db.prepare('UPDATE tasks SET deleted_at=? WHERE id=?').run(now, task.id)
        }
        result = { task: this.task(task.id) }
      } else if (name === 'companion_set_task_field') {
        const task = this.task(a.id)
        if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task before editing it.')
        const currentValue = a.field === 'project' ? task.boardId : task[a.field]
        if (currentValue !== a.expectedValue)
          throw new AppError('CONFLICT', 'This field changed on another device. Check its current value before retrying.')
        if (a.field === 'project' || a.field === 'status') {
          const move = { id: task.id, expectedRevision: task.revision, requestKey: a.requestKey }
          if (a.field === 'project') move.boardId = a.value
          else Object.assign(move, { status: a.value, agent: a.agent, model: a.model, dispatchComment: a.dispatchComment })
          validateAction('move_task', move)
          result = { task: this.move(task, move, revision) }
        } else {
          validateAction('update_task', { id: task.id, expectedRevision: task.revision, requestKey: a.requestKey, [a.field]: a.value })
          if (a.field === 'dueDate' && !validDueDate(a.value))
            throw new AppError('INVALID_ARGUMENT', 'Choose a valid due date.')
          result = { task: this.saveTask({ ...task, [a.field]: a.value }, revision) }
        }
      } else if (name === 'force_complete_task') {
        const task = this.task(a.id)
        if (task.deleted) throw new AppError('IN_TRASH', 'Restore the task before marking it done.')
        for (const job of this.agentJobs()) {
          if (job.taskId !== task.id || !['queued', 'starting', 'working', 'needs-input'].includes(job.state)) continue
          this.saveAgentJob({ ...job, state: 'canceled', approval: null, summary: 'Marked done by the user.' })
          this.setCommentDelivery(job.id, 'needs-review')
        }
        this.markPendingCommentsForReview(task.id)
        this.assignAgent(task.id, null)
        result = { task: task.status === 'Done' ? task : this.move(task, { status: 'Done' }, revision) }
      } else if (name === 'companion_delete_archived_task') {
        const task = this.task(a.id)
        this.expect(task, a.expectedRevision)
        if (!task.archivedAt || task.deleted)
          throw new AppError('INVALID_STATE', 'This task is no longer in Archive.')
        this.assignAgent(task.id, null)
        this.db.prepare('DELETE FROM tasks WHERE id=?').run(task.id)
        result = { permanentlyDeleted: 1 }
      } else if (name === 'companion_empty_trash') {
        this.expect({ revision: this.revision() }, a.expectedRevision)
        result = { permanentlyDeleted: this.db.prepare('DELETE FROM tasks WHERE deleted_at IS NOT NULL').run().changes }
      } else if (name === 'manage_archived_tasks') {
        this.expect({ revision: this.revision() }, a.expectedRevision)
        const tasks = a.taskIds.map((id) => this.task(id))
        if (tasks.some((task) => !task.archivedAt || task.deleted))
          throw new AppError('INVALID_STATE', 'Review the current Archive before applying this action.')
        const now = new Date().toISOString()
        const deleteTask = this.db.prepare('DELETE FROM tasks WHERE id=?')
        const assignments = this.agentAssignments()
        for (const task of tasks) {
          delete assignments[task.id]
          if (a.permanently) deleteTask.run(task.id)
          else this.saveTask({ ...task, deletedAt: now }, revision)
        }
        this.set('agentAssignments', assignments)
        result = a.permanently ? { permanentlyDeleted: tasks.length } : { trashed: tasks.length }
      } else if (name === 'confirm_destructive_action') {
        if (restore) {
          this.db.exec(
            'DELETE FROM agent_jobs; DELETE FROM tasks; DELETE FROM boards; DELETE FROM operation_receipts;'
          )
          for (const board of restore.boards)
            this.db
              .prepare('INSERT INTO boards VALUES (?,?,?,?,?,?,?)')
              .run(board.id, board.name, board.position, board.created_at, revision, board.project_key, board.next_task_number)
          for (const task of restore.tasks)
            this.db
              .prepare('INSERT INTO tasks VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)')
              .run(
                task.id,
                task.board_id,
                task.title,
                task.notes,
                task.status,
                task.position,
                task.created_at,
                task.updated_at,
                task.deleted_at,
                revision,
                task.priority,
                task.definition_of_done,
                task.due_date,
                task.task_key,
                task.completed_at,
                task.archived_at,
                task.plan_markdown || legacyPlan(task.notes),
                task.issue_type
              )
          this.backfillTaskKeys()
          for (const row of restore.taskHistory) this.db.prepare('INSERT INTO task_history VALUES (?,?,?,?,?,?,?,?)').run(row.id,row.task_id,row.version,row.saved_at,row.action,row.origin,row.changes_json,row.state_json)
          restoreComments(this, restore.comments, restore.commentImages)
          taskActivity.restoreRows(this, restore.activity, restore.activityImages)
          this.set('theme', restore.preferences.theme)
          this.set('selectedBoard', restore.preferences.selectedBoard)
          this.set('preferencesRevision', revision)
          this.set('boardIcons', restore.boardIcons)
          this.set('allTasksOrder', restore.allTasksOrder)
          this.set('agentSettings', restore.agentSettings)
          this.set('agentAssignments', {})
          for (const job of [...restore.agentRuns].reverse())
            this.saveAgentJob({
              ...job,
              state: ['done', 'failed', 'canceled', 'review'].includes(job.state)
                ? job.state
                : 'interrupted',
              approval: null,
              summary: ['done', 'failed', 'canceled', 'review'].includes(job.state)
                ? job.summary
                : 'Restored from backup. Review the existing thread before sending again.',
            }, {activity:false})
          for (const task of this.snapshot().tasks)
            if (!task.deleted && task.status === 'Sent to agent')
              this.move(task, { status: 'To do' }, revision)
          for (const task of this.db.prepare('SELECT id FROM tasks').all()) taskActivity.record(this,task.id,{actor:origin,kind:'restore',summary:'Workspace restored from backup',detail:'Task data, revision requests, activity and revision history were restored from the reviewed backup.'})
          result = { restored: restore.summary, safetyBackup: preview.safetyBackup }
        } else {
          const deletion = preview.action === 'purge_archived_tasks'
            ? this.db.prepare('DELETE FROM tasks WHERE id=? AND archived_at IS NOT NULL AND deleted_at IS NULL')
            : this.db.prepare('DELETE FROM tasks WHERE id=? AND deleted_at IS NOT NULL')
          for (const id of preview.taskIds) {
            if (preview.action === 'purge_archived_tasks') this.assignAgent(id, null)
            deletion.run(id)
          }
          result = { permanentlyDeleted: preview.taskIds.length }
        }
      } else throw new AppError('UNKNOWN_ACTION', 'Unavailable action.')
      taskHistory.recordRevision(this, revision, name, origin)
      this.set('revision', revision)
      result.revision = revision
      this.db
        .prepare('INSERT INTO operation_receipts VALUES (?,?,?)')
        .run(a.requestKey, digest, JSON.stringify(result))
      this.db.exec('COMMIT')
      if (preview) this.previews.delete(a.token)
      this.changed(revision)
      return result
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
  async createBackup(destination, format = 'sqlite') {
    const folder = path.join(this.folder, 'Backups')
    if (!destination) fs.mkdirSync(folder, { recursive: true, mode: 0o700 })
    const target = absolute(
      destination ||
        path.join(
          folder,
          `OpenTalon-${new Date().toISOString().replaceAll(':', '-')}-${randomUUID().slice(0, 8)}.${format === 'json' ? 'json' : 'opentalon'}`
        )
    )
    if (format === 'json') {
      const snapshot = this.snapshot()
      const payload = {
        format: 'opentalon-backup',
        formatVersion: FORMAT,
        appVersion: this.version,
        exportedAt: new Date().toISOString(),
        columns: statuses,
        preferences: { theme: snapshot.theme, selectedBoard: snapshot.selectedBoard },
        boardIcons: this.boardIcons(),
        allTasksOrder: this.allTasksOrder(),
        agentSettings: this.agentSettings(),
        agentRuns: this.agentJobs().map(({ approval, ...job }) => job),
        agentAssignments: this.agentAssignments(),
        ...exportComments(this),
        ...taskActivity.exportRows(this),
        boards: this.db.prepare('SELECT * FROM boards ORDER BY position,id').all(),
        tasks: this.db.prepare('SELECT * FROM tasks ORDER BY position,id').all(),
        taskHistory: this.db.prepare('SELECT * FROM task_history ORDER BY task_id,version').all(),
      }
      const stageFolder = fs.mkdtempSync(path.join(this.folder, '.backup-'))
      try {
        const stage = path.join(stageFolder, 'backup.json')
        fs.writeFileSync(stage, JSON.stringify(payload, null, 2) + '\n', { mode: 0o600 })
        fs.copyFileSync(stage, target, fs.constants.COPYFILE_EXCL)
        fs.chmodSync(target, 0o600)
        return {
          path: target,
          format: 'json',
          formatVersion: FORMAT,
          ...this.counts(),
          revision: this.revision(),
        }
      } catch (error) {
        if (error.code === 'EEXIST')
          throw new AppError(
            'FILE_EXISTS',
            'A file already exists at that destination. Choose another filename.'
          )
        throw error
      } finally {
        fs.rmSync(stageFolder, { recursive: true, force: true })
      }
    }
    const stageFolder = fs.mkdtempSync(path.join(this.folder, '.backup-'))
    const stage = path.join(stageFolder, 'backup.sqlite')
    try {
      await backup(this.db, stage)
      const copy = new DatabaseSync(stage)
      try {
        copy.exec('PRAGMA journal_mode=DELETE; DELETE FROM operation_receipts;')
        for (const row of copy.prepare('SELECT id,data FROM agent_jobs').all()) {
          const { approval, ...job } = JSON.parse(row.data)
          copy.prepare('UPDATE agent_jobs SET data=? WHERE id=?').run(JSON.stringify(job), row.id)
        }
        copy
          .prepare(
            "DELETE FROM settings WHERE key NOT IN ('theme','selectedBoard','revision','preferencesRevision','agentSettings','boardIcons','allTasksOrder')"
          )
          .run()
        copy.exec('VACUUM;')
      } finally {
        copy.close()
      }
      fs.copyFileSync(stage, target, fs.constants.COPYFILE_EXCL)
      fs.chmodSync(target, 0o600)
      return { path: target, formatVersion: FORMAT, ...this.counts(), revision: this.revision() }
    } catch (error) {
      if (error.code === 'EEXIST')
        throw new AppError(
          'FILE_EXISTS',
          'A file already exists at that destination. Choose another filename.'
        )
      throw error
    } finally {
      fs.rmSync(stageFolder, { recursive: true, force: true })
    }
  }
  counts() {
    return {
      boards: this.boards().length,
      tasks: this.db.prepare('SELECT count(*) AS n FROM tasks WHERE deleted_at IS NULL').get().n,
      trash: this.db.prepare('SELECT count(*) AS n FROM tasks WHERE deleted_at IS NOT NULL').get()
        .n,
    }
  }
  async inspect(file) {
    const source = absolute(file)
    if (source === this.file)
      throw new AppError(
        'INVALID_BACKUP',
        'Choose an exported backup, rather than the active workspace database.'
      )
    if (!fs.statSync(source).isFile())
      throw new AppError('INVALID_BACKUP', 'Choose a regular backup file.')
    const temp = fs.mkdtempSync(path.join(this.folder, '.inspect-'))
    let db
    try {
      const stage = path.join(temp, 'backup.sqlite')
      fs.copyFileSync(source, stage)
      const sha256 = await fileHash(stage)
      const descriptor = fs.openSync(stage, 'r')
      const header = Buffer.alloc(16)
      try {
        fs.readSync(descriptor, header, 0, 16, 0)
      } finally {
        fs.closeSync(descriptor)
      }
      let boards, tasks, settings, format
      let history = [], activity = [], activityImages = []
      let icons = {}
      let allTasksOrder = []
      let commentData = { comments: [], commentImages: [] }
      let agentSettings = defaultAgentSettings,
        agentRuns = []
      if (header.toString() !== 'SQLite format 3\0') {
        const payload = JSON.parse(fs.readFileSync(stage, 'utf8'))
        if (!payload || payload.format !== 'opentalon-backup')
          throw new AppError('INVALID_BACKUP', 'This is not an OpenTalon backup.')
        if (payload.formatVersion > FORMAT)
          throw new AppError(
            'NEWER_BACKUP',
            'This backup needs a newer OpenTalon. Current data is unchanged.'
          )
        if (
          ![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, FORMAT].includes(payload.formatVersion) ||
          !Array.isArray(payload.boards) ||
          !Array.isArray(payload.tasks) ||
          !payload.preferences ||
          JSON.stringify(payload.columns) !==
            JSON.stringify(payload.formatVersion === 1 ? legacyStatuses : statuses)
        )
          throw new AppError(
            'INVALID_BACKUP',
            'This backup has an unsupported format or invalid columns.'
          )
        boards = payload.boards
        tasks = payload.tasks
        history = payload.formatVersion >= 10 ? payload.taskHistory : []
        activity = payload.formatVersion >= 11 ? payload.activity : []
        activityImages = payload.formatVersion >= 11 ? payload.activityImages : []
        settings = payload.preferences
        icons = payload.boardIcons
        allTasksOrder = payload.allTasksOrder
        format = payload.formatVersion
        agentSettings = payload.agentSettings || agentSettings
        agentRuns = payload.agentRuns || []
        if (format >= 3)
          commentData = { comments: payload.comments, commentImages: payload.commentImages }
      } else {
        db = new DatabaseSync(stage, { readOnly: true })
        format = db.prepare('PRAGMA user_version').get().user_version
        if (format > FORMAT)
          throw new AppError(
            'NEWER_BACKUP',
            'This backup needs a newer OpenTalon. Current data is unchanged.'
          )
        if (
          ![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, FORMAT].includes(format) ||
          db.prepare('PRAGMA application_id').get().application_id !== APPLICATION_ID
        )
          throw new AppError('INVALID_BACKUP', 'This is not a supported OpenTalon backup.')
        if (
          db
            .prepare('PRAGMA integrity_check')
            .all()
            .some((row) => row.integrity_check !== 'ok') ||
          db.prepare('PRAGMA foreign_key_check').all().length
        )
          throw new AppError('INVALID_BACKUP', 'This backup failed SQLite integrity validation.')
        boards = db.prepare('SELECT * FROM boards ORDER BY position,id').all()
        tasks = db.prepare('SELECT * FROM tasks ORDER BY position,id').all()
        history = format >= 10 ? db.prepare('SELECT * FROM task_history ORDER BY task_id,version').all() : []
        if(format >= 11) {
          activity = db.prepare('SELECT * FROM task_activity ORDER BY sequence').all()
          activityImages = db.prepare('SELECT * FROM activity_images ORDER BY rowid').all().map(row=>({...row,data:Buffer.from(row.bytes).toString('base64'),bytes:undefined}))
        }
        settings = Object.fromEntries(
          db
            .prepare('SELECT key,value FROM settings')
            .all()
            .map((row) => [row.key, JSON.parse(row.value)])
        )
        agentSettings = settings.agentSettings || agentSettings
        icons = settings.boardIcons
        allTasksOrder = settings.allTasksOrder
        if (format >= 3) commentData = exportComments({ db })
        if (format >= 2)
          agentRuns = db
            .prepare('SELECT data FROM agent_jobs ORDER BY rowid DESC')
            .all()
            .map((row) => JSON.parse(row.data))
      }
      if (
        !boards.length ||
        !themes.includes(settings.theme) ||
        !boards.some((board) => board.id === settings.selectedBoard)
      )
        throw new AppError('INVALID_BACKUP', 'This backup has invalid preferences or no boards.')
      const ids = new Set(boards.map((board) => board.id))
      if (format < 6)
        boards = boards.map((board) => ({ ...board, project_key: null, next_task_number: 1 }))
      tasks = tasks.map((task) => ({
        ...task,
        priority: format < 4 ? 'None' : task?.priority,
        definition_of_done: format < 4 ? '' : task?.definition_of_done,
        due_date: format < 5 ? null : task?.due_date,
        task_key: format < 6 ? null : task?.task_key,
        completed_at: format < 7 ? (task?.status === 'Done' ? task.updated_at : null) : task?.completed_at,
        archived_at: format < 7 ? null : task?.archived_at,
        plan_markdown: format < 8 ? '' : task?.plan_markdown,
        issue_type: format < 9 ? 'Issue' : task?.issue_type,
      }))
      if (ids.size !== boards.length || new Set(tasks.map((task) => task.id)).size !== tasks.length)
        throw new AppError('INVALID_BACKUP', 'This backup contains duplicate record IDs.')
      for (const board of boards)
        if (
          !board ||
          typeof board.id !== 'string' ||
          !board.id.length ||
          board.id.length > 150 ||
          typeof board.name !== 'string' ||
          !board.name.trim() ||
          (format >= 6 && (typeof board.project_key !== 'string' || !/^[A-Z]{3}$/.test(board.project_key) ||
            !Number.isSafeInteger(board.next_task_number) || board.next_task_number < 1)) ||
          board.name.length > 100 ||
          !Number.isSafeInteger(board.position) ||
          board.position < 0 ||
          !Number.isSafeInteger(board.revision) ||
          board.revision < 1 ||
          typeof board.created_at !== 'string' ||
          !Number.isFinite(Date.parse(board.created_at))
        )
          throw new AppError('INVALID_BACKUP', 'This backup contains an invalid board.')
      for (const task of tasks)
        if (
          !task ||
          typeof task.id !== 'string' ||
          !task.id.length ||
          task.id.length > 150 ||
          !ids.has(task.board_id) ||
          (format >= 6 && (typeof task.task_key !== 'string' || !taskKeyPattern.test(task.task_key))) ||
          typeof task.title !== 'string' ||
          !task.title.trim() ||
          task.title.length > 500 ||
          typeof task.notes !== 'string' ||
          task.notes.length > 100000 ||
          typeof task.plan_markdown !== 'string' || task.plan_markdown.length > 100000 ||
          !task.plan_markdown.isWellFormed() || task.plan_markdown.includes('\0') ||
          !statuses.includes(task.status) ||
          !['Issue', 'Bug'].includes(task.issue_type) ||
          !priorities.includes(task.priority) ||
          typeof task.definition_of_done !== 'string' ||
          task.definition_of_done.length > 10000 ||
          !validDueDate(task.due_date) ||
          !Number.isSafeInteger(task.position) ||
          task.position < 0 ||
          !Number.isSafeInteger(task.revision) ||
          task.revision < 1 ||
          typeof task.created_at !== 'string' ||
          !Number.isFinite(Date.parse(task.created_at)) ||
          typeof task.updated_at !== 'string' ||
          !Number.isFinite(Date.parse(task.updated_at)) ||
          (task.completed_at !== null && (task.status !== 'Done' || typeof task.completed_at !== 'string' ||
            !Number.isFinite(Date.parse(task.completed_at)))) ||
          (task.archived_at !== null && (typeof task.archived_at !== 'string' ||
            !Number.isFinite(Date.parse(task.archived_at)))) ||
          !(
            task.deleted_at === null ||
            (typeof task.deleted_at === 'string' && Number.isFinite(Date.parse(task.deleted_at)))
          )
        )
          throw new AppError('INVALID_BACKUP', 'This backup contains an invalid task.')
      if (
        !['claude-code', 'codex'].includes(agentSettings.defaultAgent) ||
        typeof agentSettings.workingFolder !== 'string' ||
        agentSettings.workingFolder.length > 4000 ||
        !Array.isArray(agentRuns) ||
        new Set(agentRuns.map((job) => job?.id)).size !== agentRuns.length
      )
        throw new AppError('INVALID_BACKUP', 'This backup has invalid agent settings or history.')
      for (const job of agentRuns) {
        if (
          !job ||
          typeof job.id !== 'string' ||
          !job.id.length ||
          job.id.length > 150 ||
          !tasks.some((task) => task.id === job.taskId) ||
          !['claude-code', 'codex'].includes(job.agent) ||
          ![
            'queued',
            'starting',
            'working',
            'needs-input',
            'review',
            'done',
            'failed',
            'canceled',
            'interrupted',
          ].includes(job.state) ||
          typeof job.workingFolder !== 'string' ||
          job.workingFolder.length > 4000 ||
          typeof job.summary !== 'string' ||
          job.summary.length > 10000 ||
          !(
            job.threadId === null ||
            (typeof job.threadId === 'string' && /^[a-zA-Z0-9_-]{1,150}$/.test(job.threadId))
          ) ||
          !Number.isFinite(Date.parse(job.createdAt)) ||
          !Number.isFinite(Date.parse(job.updatedAt))
        )
          throw new AppError('INVALID_BACKUP', 'This backup contains invalid agent history.')
      }
      taskActivity.validateRows(activity, activityImages, tasks, commentData.comments)
      taskHistory.validateRows(history, tasks)
      validateComments(commentData.comments, commentData.commentImages, tasks)
      const taskIds = new Set(tasks.map((task) => task.id))
      return {
        boards,
        tasks,
        ...commentData,
        taskHistory: history, activity, activityImages,
        agentSettings,
        agentRuns: agentRuns.map(
          ({
            id,
            taskId,
            agent,
            workingFolder,
            state,
            threadId,
            summary,
            createdAt,
            updatedAt,
          }) => ({
            id,
            taskId,
            agent,
            workingFolder,
            state,
            threadId,
            summary,
            createdAt,
            updatedAt,
          })
        ),
        preferences: { theme: settings.theme, selectedBoard: settings.selectedBoard },
        // Icons are optional: older backups have none, and unknown values fall back to the default.
        boardIcons: Object.fromEntries(
          Object.entries(
            icons && typeof icons === 'object' && !Array.isArray(icons) ? icons : {}
          ).filter(([id, icon]) => ids.has(id) && boardIcons.includes(icon))
        ),
        // Optional too: keep only ids of tasks in this backup, once each.
        allTasksOrder: [
          ...new Set(
            (Array.isArray(allTasksOrder) ? allTasksOrder : []).filter((id) => taskIds.has(id))
          ),
        ],
        summary: {
          path: source,
          formatVersion: format,
          boards: boards.length,
          tasks: tasks.filter((task) => task.deleted_at === null).length,
          trash: tasks.filter((task) => task.deleted_at !== null).length,
          sha256,
        },
      }
    } catch (error) {
      if (error instanceof AppError) throw error
      throw new AppError(
        'INVALID_BACKUP',
        `Could not read this backup: ${error.message}. Current data is unchanged.`
      )
    } finally {
      db?.close()
      fs.rmSync(temp, { recursive: true, force: true })
    }
  }
  async preview(a) {
    if (a.action === 'restore_backup' && (!a.path || a.taskIds))
      throw new AppError('INVALID_ARGUMENT', 'Restore requires path and no taskIds.')
    if (['purge_tasks', 'purge_archived_tasks'].includes(a.action) && (!a.taskIds || a.path))
      throw new AppError('INVALID_ARGUMENT', 'Task removal requires taskIds and no path.')
    if (a.action === 'empty_trash' && (a.taskIds || a.path))
      throw new AppError('INVALID_ARGUMENT', 'Empty Trash takes no path or taskIds.')
    const token = randomUUID()
    const preview = {
      action: a.action,
      revision: this.revision(),
      expires: Date.now() + 5 * 60 * 1000,
    }
    let summary
    if (a.action === 'restore_backup') {
      summary = (await this.inspect(a.path)).summary
      Object.assign(preview, { path: summary.path, sha256: summary.sha256 })
    } else {
      const tasks =
        a.action === 'empty_trash'
          ? this.db.prepare('SELECT * FROM tasks WHERE deleted_at IS NOT NULL').all().map(taskView)
          : a.taskIds.map((id) => this.task(id))
      if (a.action === 'purge_archived_tasks') {
        if (tasks.some((task) => task.deleted || !task.archivedAt))
          throw new AppError('INVALID_STATE', 'Only tasks in Archive can be removed with this action.')
      } else if (tasks.some((task) => !task.deleted)) {
        throw new AppError('INVALID_STATE', 'Only tasks in Trash can be permanently removed.')
      }
      preview.taskIds = tasks.map((task) => task.id)
      summary = {
        count: tasks.length,
        tasks: tasks.map((task) => ({ id: task.id, title: task.title, boardId: task.boardId })),
      }
    }
    for (const [key, value] of this.previews)
      if (value.expires < Date.now()) this.previews.delete(key)
    if (this.previews.size > 100) this.previews.delete(this.previews.keys().next().value)
    this.previews.set(token, preview)
    return {
      token,
      action: a.action,
      summary,
      current: this.counts(),
      revision: preview.revision,
      expiresAt: new Date(preview.expires).toISOString(),
      requiresConfirmation: true,
    }
  }
  importPrototype(workspace) {
    if (this.get('prototypeImported')) return { imported: false }
    const fresh =
      this.revision() === 1 &&
      this.counts().tasks === 0 &&
      this.counts().trash === 0 &&
      this.boards().length === 1
    if (!fresh) return { imported: false }
    if (
      !workspace ||
      workspace.version !== 1 ||
      !Array.isArray(workspace.boards) ||
      !workspace.boards.length ||
      !Array.isArray(workspace.tasks) ||
      workspace.boards.length > 1000 ||
      workspace.tasks.length > 100000 ||
      !themes.includes(workspace.theme)
    )
      throw new AppError(
        'INVALID_PROTOTYPE',
        'The earlier prototype could not be imported. Its original data is preserved.'
      )
    const boards = workspace.boards.map((board, position) => ({
      id: board.id,
      name: board.name,
      position,
      created_at: new Date().toISOString(),
    }))
    const ids = new Set(boards.map((board) => board.id))
    if (
      ids.size !== boards.length ||
      boards.some(
        (board) =>
          typeof board.id !== 'string' ||
          !board.id ||
          board.id.length > 150 ||
          typeof board.name !== 'string' ||
          !board.name.trim() ||
          board.name.length > 100
      )
    )
      throw new AppError('INVALID_PROTOTYPE', 'Invalid prototype boards; original data preserved.')
    if (
      new Set(workspace.tasks.map((task) => task.id)).size !== workspace.tasks.length ||
      workspace.tasks.some(
        (task) =>
          typeof task.id !== 'string' ||
          !task.id ||
          task.id.length > 150 ||
          !ids.has(task.boardId) ||
          typeof task.title !== 'string' ||
          !task.title.trim() ||
          task.title.length > 500 ||
          typeof task.notes !== 'string' ||
          task.notes.length > 100000 ||
          !statuses.includes(task.status) ||
          !Number.isSafeInteger(task.position) ||
          task.position < 0 ||
          typeof task.deleted !== 'boolean'
      )
    )
      throw new AppError('INVALID_PROTOTYPE', 'Invalid prototype tasks; original data preserved.')
    this.db.exec('BEGIN IMMEDIATE')
    try {
      this.db.exec('DELETE FROM boards')
      for (const board of boards)
        this.db
          .prepare('INSERT INTO boards (id,name,position,created_at,revision) VALUES (?,?,?,?,?)')
          .run(board.id, board.name, board.position, board.created_at, 2)
      const now = new Date().toISOString()
      for (const task of workspace.tasks)
        this.db
          .prepare(
            'INSERT INTO tasks (id,board_id,title,notes,status,position,created_at,updated_at,deleted_at,revision) VALUES (?,?,?,?,?,?,?,?,?,?)'
          )
          .run(
            task.id,
            task.boardId,
            task.title.trim(),
            task.notes,
            task.status,
            task.position,
            now,
            now,
            task.deleted ? now : null,
            2
          )
      this.backfillTaskKeys()
      this.set('theme', workspace.theme)
      this.set(
        'selectedBoard',
        ids.has(workspace.selectedBoard) ? workspace.selectedBoard : boards[0].id
      )
      this.set('preferencesRevision', 2)
      this.set('revision', 2)
      taskHistory.recordRevision(this, 2, 'imported', 'OpenTalon')
      this.set('prototypeImported', true)
      this.db.exec('COMMIT')
      this.changed(2)
      return { imported: true }
    } catch (error) {
      this.db.exec('ROLLBACK')
      throw error
    }
  }
}
module.exports = { Store, statuses, FORMAT, APPLICATION_ID, argumentHash }
