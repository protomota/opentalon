const string = (maxLength = 500) => ({ type: 'string', minLength: 1, maxLength })
const id = string(150)
const revision = { type: 'integer', minimum: 1 }
const agentModels = [
  { agent: 'claude-code', id: 'claude-fable-5-2', title: 'Claude Fable 5.2' },
  { agent: 'claude-code', id: 'claude-opus-5-5', title: 'Claude Opus 5.5' },
  { agent: 'claude-code', id: 'claude-sonnet-5-5', title: 'Claude Sonnet 5.5' },
  { agent: 'codex', id: 'gpt-6-astra', title: 'GPT-6 Astra' },
  { agent: 'codex', id: 'gpt-6.1-sol', title: 'GPT-6.1 Sol' },
  { agent: 'codex', id: 'gpt-6.1-terra', title: 'GPT-6.1 Terra' },
]
const agentSelection = {
  agent: { enum: ['claude-code', 'codex'] },
  model: string(100),
}
const dispatchComment = {
  ...string(10000),
  description: 'Optional task comment saved with the dispatch before the agent starts.',
}
const status = { enum: ['To do', 'Sent to agent', 'In progress', 'Done'] }
const priority = { enum: ['Urgent', 'High', 'Medium', 'Low', 'None'] }
const sort = { enum: ['manual', 'priority-desc', 'priority-asc'] }
const dueDate = {
  anyOf: [{ type: 'string', minLength: 10, maxLength: 10 }, { type: 'null' }],
  description: 'Due date as a local calendar date YYYY-MM-DD. Null clears it.',
}
const theme = { enum: ['graphite', 'warm-paper', 'native-light', 'system'] }
const boardIcons = [
  'activity',
  'bird',
  'book-open',
  'bot',
  'briefcase',
  'brush',
  'building',
  'calendar',
  'camera',
  'car',
  'chart-column',
  'chart-line',
  'cloud',
  'code',
  'coffee',
  'compass',
  'cpu',
  'database',
  'dollar-sign',
  'dumbbell',
  'feather',
  'flag',
  'flask',
  'gamepad',
  'gift',
  'globe',
  'graduation-cap',
  'hammer',
  'heart',
  'house',
  'image',
  'inbox',
  'leaf',
  'lightbulb',
  'lock',
  'mail',
  'map',
  'megaphone',
  'mic',
  'moon',
  'music',
  'newspaper',
  'notebook-pen',
  'package',
  'palette',
  'pen-tool',
  'plane',
  'plug',
  'rocket',
  'server',
  'shield',
  'shopping-cart',
  'smartphone',
  'sparkles',
  'star',
  'sun',
  'target',
  'terminal',
  'trophy',
  'user',
  'users',
  'utensils',
  'video',
  'wallet',
  'workflow',
  'wrench',
  'zap',
]
const boardIcon = {
  anyOf: [{ enum: boardIcons }, { type: 'null' }],
  description:
    'Sidebar icon for the board, chosen to suit its subject. Null uses the default board icon.',
}
const write = { requestKey: string(200) }
const taskWrite = { ...write, id, expectedRevision: revision }
function tool(name, description, properties = {}, required = [], mutates = false) {
  return {
    name,
    description,
    inputSchema: { type: 'object', properties, required, additionalProperties: false },
    mutates,
  }
}
const tools = [
  tool(
    'list_task_comments',
    'Read comments and screenshot IDs for a task in chronological order.',
    { taskId: id },
    ['taskId']
  ),
  tool('read_comment_image', 'Read one comment screenshot as an MCP image.', { imageId: id }, [
    'imageId',
  ]),
  tool(
    'add_task_comment',
    'Add a task comment. Agent-authored comments do not wake the agent unless notifyAgent is explicitly true. Up to three PNG/JPEG base64 images, each under 2 MB.',
    {
      ...write,
      taskId: id,
      text: { type: 'string', maxLength: 10000 },
      notifyAgent: { type: 'boolean' },
      images: {
        type: 'array',
        maxItems: 3,
        items: {
          type: 'object',
          properties: {
            name: string(200),
            mimeType: { enum: ['image/png', 'image/jpeg'] },
            data: string(2800000),
          },
          required: ['name', 'mimeType', 'data'],
          additionalProperties: false,
        },
      },
    },
    ['taskId', 'text', 'requestKey'],
    true
  ),
  tool(
    'report_agent_progress',
    'Update the task attached to an active dispatched run. Use working when starting, needs-input when blocked, or failed on failure. Done REQUIRES proof (concrete checks/results, artifact paths/links or screenshot IDs, and how the definition of done was met) plus definitionOfDoneMet true. The completion report is saved as a task comment atomically before Done. A completed turn alone does not complete the task.',
    {
      ...write,
      runId: id,
      state: { enum: ['working', 'needs-input', 'done', 'failed'] },
      summary: string(10000),
      proof: string(10000),
      definitionOfDoneMet: { type: 'boolean' },
    },
    ['runId', 'state', 'summary', 'requestKey'],
    true
  ),
  tool(
    'get_app_status',
    'Read local app availability, version, fixed statuses, data location and data revision. No connection credentials.'
  ),
  tool(
    'list_boards',
    'List all boards in sidebar order, each with its icon (null is the default).'
  ),
  tool(
    'create_board',
    'Create a named board. Pass an icon that suits the board; when omitted, one is chosen from the name where an obvious match exists. Reuse requestKey only for an identical retry.',
    { ...write, name: string(100), icon: boardIcon },
    ['name', 'requestKey'],
    true
  ),
  tool(
    'set_board_icon',
    'Set or clear a board icon using the board last-read revision. Choose the icon that best suits the board subject.',
    { ...taskWrite, icon: boardIcon },
    ['id', 'icon', 'expectedRevision', 'requestKey'],
    true
  ),
  tool(
    'rename_board',
    'Rename a board using its last-read revision.',
    { ...taskWrite, name: string(100) },
    ['id', 'name', 'expectedRevision', 'requestKey'],
    true
  ),
  tool(
    'delete_board',
    'Delete an empty board. Live and trashed tasks prevent deletion. Keep at least one board.',
    taskWrite,
    ['id', 'expectedRevision', 'requestKey'],
    true
  ),
  tool(
    'list_tasks',
    'Read tasks with priority and metadata. Optional priority filter and priority-desc (urgent first) or priority-asc (low first) sort within board/status; None stays last. Search titles and notes across boards by omitting boardId. Follow nextCursor until null.',
    {
      boardId: id,
      status,
      priority,
      issueType: { enum: ['Issue', 'Bug'] },
      sort,
      query: { type: 'string', maxLength: 500 },
      limit: { type: 'integer', minimum: 1, maximum: 200 },
      cursor: string(2000),
    }
  ),
  tool('get_task_history', 'Read saved task revisions, newest first. Follow nextBefore with beforeVersion for older revisions.',
    { id, beforeVersion: { type: 'integer', minimum: 1 }, limit: { type: 'integer', minimum: 1, maximum: 50 } }, ['id']),
  tool('restore_task_revision', 'Restore saved fields, plan, project and status as a new revision. Retains newer history and comments. Stops agent work; Sent to agent restores as To do. Requires an explicit user request and current task revision.',
    { ...taskWrite, historyID: id }, ['id', 'historyID', 'expectedRevision', 'requestKey'], true),
  tool('get_task', 'Read one task and its revision by UUID or project task ID (e.g. VOX-001), including a trashed task. Use the returned UUID for edits.', { id }, ['id']),
  tool(
    'create_task',
    'Create a task, normally in To do. Returns the committed task and revision.',
    {
      ...write,
      ...agentSelection,
      dispatchComment,
      boardId: id,
      title: string(),
      notes: { type: 'string', maxLength: 100000 },
      planMarkdown: { type: 'string', maxLength: 100000 },
      status,
      priority,
      issueType: { enum: ['Issue', 'Bug'] },
      definitionOfDone: { type: 'string', maxLength: 10000 },
      dueDate,
    },
    ['boardId', 'title', 'requestKey'],
    true
  ),
  tool(
    'update_task',
    'Patch supplied issueType (Issue or Bug), title, notes, priority, dueDate, definitionOfDone or status. Use last-read expectedRevision; conflicts return the current task. Dispatched agent runs must complete through report_agent_progress with proof, not by changing status.',
    {
      ...taskWrite,
      title: string(),
      notes: { type: 'string', maxLength: 100000 },
      planMarkdown: { type: 'string', maxLength: 100000 },
      status,
      priority,
      issueType: { enum: ['Issue', 'Bug'] },
      definitionOfDone: { type: 'string', maxLength: 10000 },
      dueDate,
    },
    ['id', 'expectedRevision', 'requestKey'],
    true
  ),
  tool('set_task_plan', 'Save the task’s Markdown plan against the exact previous Markdown. Preserve a conflicting draft for review.',
    { ...write, id, markdown: { type: 'string', maxLength: 100000 },
      expectedMarkdown: { type: 'string', maxLength: 100000 } },
    ['id', 'markdown', 'expectedMarkdown', 'requestKey'], true),
  tool(
    'move_task',
    'Move a task to a board/status, optionally beforeId OR afterId in that destination. Omit both to append. Last-read revision required.',
    { ...taskWrite, ...agentSelection, dispatchComment, boardId: id, status, beforeId: id, afterId: id },
    ['id', 'expectedRevision', 'requestKey'],
    true
  ),
  tool(
    'trash_task',
    'Recoverably delete a task. No automatic purge.',
    taskWrite,
    ['id', 'expectedRevision', 'requestKey'],
    true
  ),
  tool('list_trash', 'Read deleted tasks with pagination, optional board and text search.', {
    boardId: id,
    query: { type: 'string', maxLength: 500 },
    limit: { type: 'integer', minimum: 1, maximum: 200 },
    cursor: string(2000),
  }),
  tool(
    'restore_task',
    'Restore a trashed task to its board/status, using its former position when available, otherwise appending.',
    taskWrite,
    ['id', 'expectedRevision', 'requestKey'],
    true
  ),
  tool('get_preferences', 'Read appearance and selected board with the preference revision.'),
  tool(
    'set_preferences',
    'Update appearance and/or selected board. Cannot change connection enablement or credentials.',
    { ...write, expectedRevision: revision, theme, selectedBoard: id },
    ['expectedRevision', 'requestKey'],
    true
  ),
  tool(
    'create_backup',
    'Export all boards, tasks, Trash, ordering and appearance. Choose format json for a readable portable backup; sqlite is the backward-compatible default. Never overwrites files. Excludes credentials and replay receipts.',
    { ...write, destination: string(4000), format: { enum: ['json', 'sqlite'] } },
    ['requestKey'],
    true
  ),
  tool(
    'inspect_backup',
    'Validate a selected absolute backup path and report format, board/task/Trash counts and SHA-256. Does not replace data.',
    { path: string(4000) },
    ['path']
  ),
  tool(
    'preview_destructive_action',
    'Preview purge_tasks, purge_archived_tasks, empty_trash or restore_backup. Show this exact preview to the person and obtain explicit confirmation before confirm_destructive_action. Token expires in 5 minutes and binds current revision and backup hash.',
    {
      action: { enum: ['purge_tasks', 'purge_archived_tasks', 'empty_trash', 'restore_backup'] },
      taskIds: { type: 'array', items: id, minItems: 1, maxItems: 10000, uniqueItems: true },
      path: string(4000),
    },
    ['action']
  ),
  tool(
    'confirm_destructive_action',
    'Execute an explicitly approved preview token once. Stale previews are rejected. Reuse the same requestKey to recover an uncertain response.',
    { ...write, token: string(200) },
    ['token', 'requestKey'],
    true
  ),
]
const local = [
  tool('companion_organize_task', 'Apply an explicit companion Archive, Trash or restore action.',
    { ...write, id, destination: { enum: ['archive', 'trash', 'active'] } },
    ['id', 'destination', 'requestKey'], true),
  tool('force_complete_task', 'Apply an explicit user override to mark a task Done.', { ...write, id },
    ['id', 'requestKey'], true),
  tool('companion_set_task_field', 'Apply a companion field edit against its last seen value.',
    { ...write, ...agentSelection, dispatchComment, id,
      field: { enum: ['project', 'status', 'priority', 'dueDate', 'title', 'notes', 'definitionOfDone', 'issueType'] },
      value: { anyOf: [{ type: 'string', maxLength: 100000 }, { type: 'null' }] },
      expectedValue: { anyOf: [{ type: 'string', maxLength: 100000 }, { type: 'null' }] },
    }, ['id', 'field', 'value', 'expectedValue', 'requestKey'], true),
  tool('companion_delete_archived_task', 'Apply a confirmed companion Archive deletion.',
    taskWrite, ['id', 'expectedRevision', 'requestKey'], true),
  tool('companion_empty_trash', 'Apply a confirmed companion Trash deletion at the reviewed workspace revision.',
    { ...write, expectedRevision: revision }, ['expectedRevision', 'requestKey'], true),
  tool('companion_reorder_task', 'Place a task next to another task in the same project and status.',
    { ...write, id, boardId: id, status, anchorId: id, before: { type: 'boolean' } },
    ['id', 'boardId', 'status', 'anchorId', 'before', 'requestKey'], true),
  tool('manage_archived_tasks', 'Apply an explicitly confirmed bulk Archive action.',
    { ...write, expectedRevision: revision, permanently: { type: 'boolean' },
      taskIds: { type: 'array', items: id, minItems: 1, maxItems: 10000, uniqueItems: true } },
    ['expectedRevision', 'permanently', 'taskIds', 'requestKey'], true),
  tool('capture_task', 'Create a to-do in an existing or newly named project.', {
    ...tools.find(({ name }) => name === 'create_task').inputSchema.properties,
    newProjectName: string(100),
  }, ['boardId', 'title', 'requestKey'], true),
  tool(
    'reorder_tasks',
    'Save the full visible ordering of one column locally without changing task statuses or agent assignment.',
    {
      ...write,
      boardId: id,
      status,
      expectedRevision: revision,
      taskIds: { type: 'array', items: id, minItems: 1, maxItems: 10000, uniqueItems: true },
    },
    ['boardId', 'status', 'expectedRevision', 'taskIds', 'requestKey'],
    true
  ),
  tool(
    'reorder_all_tasks',
    'Save the full visible ordering of one All tasks column locally. One task may arrive from another column; each project keeps the same relative order.',
    {
      ...write,
      ...agentSelection,
      status,
      expectedRevision: revision,
      taskIds: { type: 'array', items: id, minItems: 1, maxItems: 10000, uniqueItems: true },
    },
    ['status', 'expectedRevision', 'taskIds', 'requestKey'],
    true
  ),
  tool(
    'retry_task_comment',
    'Requeue a comment after reviewing its conversation',
    { ...write, id },
    ['id', 'requestKey'],
    true
  ),
  tool('choose_comment_images', 'Attach up to three screenshot image files'),
  tool('paste_comment_image', 'Attach a screenshot from the clipboard'),
  tool('check_task_comments', 'Check pending comments now'),
  tool('get_agent_settings', 'Read the default task agent, working folder and permission mode'),
  tool(
    'set_agent_settings',
    'Save the default task agent and working folder, and optionally change the permission mode',
    {
      ...write,
      defaultAgent: { enum: ['claude-code', 'codex'] },
      workingFolder: { type: 'string', maxLength: 4000 },
      permissionMode: { enum: ['auto', 'manual', 'full-access'] },
    },
    ['defaultAgent', 'workingFolder', 'requestKey'],
    true
  ),
  tool('choose_agent_folder', 'Choose a folder for dispatched tasks'),
  tool('agent_runtime_status', 'Check installed agent launchers'),
  tool(
    'open_agent_install_guide',
    'Open official agent installation instructions',
    { agent: { enum: ['claude-code', 'codex'] } },
    ['agent']
  ),
  tool('stop_agent_run', 'Stop one dispatched run', { runId: id }, ['runId']),
  tool('open_agent_thread', 'Open an existing agent conversation', { runId: id }, ['runId']),
  tool(
    'answer_agent_approval',
    'Answer one pending agent permission request once',
    { runId: id, approvalId: id, allow: { type: 'boolean' } },
    ['runId', 'approvalId', 'allow']
  ),
  tool('snapshot', 'Local renderer state'),
  tool(
    'set_editor_dirty',
    'Protect unsaved editor text when closing the window',
    { dirty: { type: 'boolean' } },
    ['dirty']
  ),
  tool('connection_status', 'Local connection setup'),
  tool(
    'set_connection',
    'Enable or disable the embedded connector locally',
    { enabled: { type: 'boolean' } },
    ['enabled']
  ),
  tool('reset_connection_key', 'Reset the local connection key'),
  tool(
    'client_configuration',
    'Read private client setup locally',
    { transport: { enum: ['stdio', 'http'] } },
    ['transport']
  ),
  tool('show_data_folder', 'Open the local data folder'),
  tool('agent_setup_fields', 'Read desktop setup fields locally'),
  tool('copy_setup_field', 'Copy one desktop setup field', { id: string(100) }, ['id']),
  tool('save_claude_extension', 'Save a local Claude Desktop extension'),
  tool('save_project_connection', 'Save Claude setup in a selected working folder'),
  tool(
    'open_setup_app',
    'Open a supported desktop app',
    { app: { enum: ['codex', 'claude', 'terminal'] } },
    ['app']
  ),
  tool(
    'copy_terminal_setup',
    'Copy an optional registration command',
    { client: { enum: ['codex', 'claude-code'] } },
    ['client']
  ),
  tool('open_company_website', 'Visit Protomota'),
  tool('open_newsletter', 'Visit the Protomota newsletter in your browser'),
  tool(
    'open_support_link',
    'Open a Protomota support page',
    { kind: { enum: ['coffee', 'setup'] } },
    ['kind']
  ),
  tool(
    'open_setup_guide',
    'Open an official setup guide',
    { client: { enum: ['claude-code', 'codex', 'claude'] } },
    ['client']
  ),
  tool('choose_backup', 'Save through a native dialog'),
  tool('choose_restore', 'Inspect a backup through a native dialog'),
  tool(
    'import_prototype',
    'Preserve an earlier local prototype once',
    { workspace: { type: 'object' } },
    ['workspace']
  ),
]
class AppError extends Error {
  constructor(code, message, details) {
    super(message)
    this.code = code
    this.details = details
  }
}
function validate(schema, value, field = 'arguments') {
  if (schema.anyOf) {
    for (const rule of schema.anyOf) {
      try {
        validate(rule, value, field)
        return
      } catch (error) {
        if (!(error instanceof AppError)) throw error
      }
    }
    throw new AppError(
      'INVALID_ARGUMENT',
      schema.anyOf[0].enum
        ? `${field} must be null or one of: ${schema.anyOf[0].enum.join(', ')}.`
        : `${field} must be a date string or null.`
    )
  }
  if (schema.type === 'null' && value !== null)
    throw new AppError('INVALID_ARGUMENT', `${field} must be null.`)
  if (schema.enum && !schema.enum.includes(value))
    throw new AppError('INVALID_ARGUMENT', `${field} must be one of: ${schema.enum.join(', ')}.`)
  if (schema.type === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value))
      throw new AppError('INVALID_ARGUMENT', `${field} must be an object.`)
    for (const key of schema.required || [])
      if (value[key] === undefined)
        throw new AppError('INVALID_ARGUMENT', `${field}.${key} is required.`)
    if (schema.additionalProperties === false)
      for (const key of Object.keys(value))
        if (!Object.hasOwn(schema.properties, key))
          throw new AppError('INVALID_ARGUMENT', `Unknown argument: ${key}.`)
    for (const [key, rule] of Object.entries(schema.properties || {}))
      if (value[key] !== undefined) validate(rule, value[key], `${field}.${key}`)
  }
  if (
    schema.type === 'string' &&
    (typeof value !== 'string' ||
      value.length < (schema.minLength || 0) ||
      value.length > (schema.maxLength || Infinity))
  )
    throw new AppError('INVALID_ARGUMENT', `${field} has an invalid length or type.`)
  if (
    schema.type === 'integer' &&
    (!Number.isSafeInteger(value) ||
      value < (schema.minimum ?? -Infinity) ||
      value > (schema.maximum ?? Infinity))
  )
    throw new AppError('INVALID_ARGUMENT', `${field} must be an integer in range.`)
  if (schema.type === 'boolean' && typeof value !== 'boolean')
    throw new AppError('INVALID_ARGUMENT', `${field} must be true or false.`)
  if (schema.type === 'array') {
    if (
      !Array.isArray(value) ||
      value.length < (schema.minItems || 0) ||
      value.length > (schema.maxItems || Infinity) ||
      (schema.uniqueItems && new Set(value).size !== value.length)
    )
      throw new AppError('INVALID_ARGUMENT', `${field} must be a bounded array of unique values.`)
    value.forEach((item, index) => validate(schema.items, item, `${field}[${index}]`))
  }
}
function validateAction(name, input, allowLocal = false) {
  const contract = [...tools, ...(allowLocal ? local : [])].find((item) => item.name === name)
  if (!contract) throw new AppError('UNKNOWN_ACTION', 'This action is not available.')
  validate(contract.inputSchema, input)
  return contract
}
module.exports = { tools, AppError, validateAction, boardIcons, agentModels }
