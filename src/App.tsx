import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type FormEvent,
  type PointerEvent as ReactPointerEvent,
} from 'react'
import {
  Archive,
  ArrowLeft,
  ArrowUpRight,
  Check,
  CheckCheck,
  Circle,
  CircleDashed,
  Ellipsis,
  FileText,
  LayoutDashboard,
  ListTodo,
  Plus,
  Search,
  Settings,
  Trash2,
  Undo2,
  Send,
  X,
} from 'lucide-react'
import logo from '../assets/opentalon-logo-black.svg'
import wordmark from '../assets/opentalon-wordmark.png'
import {
  action,
  SaveError,
  requestKey,
  statuses,
  priorities,
  storageKey,
  type Status,
  type Task,
  type Preview,
  type Workspace,
  type Priority,
} from './model'
import { Dashboard } from './Dashboard'
import { BoardIcon, BoardIconPicker } from './BoardIcon'
import type { BoardIconName } from './board-icon-names'
import { SendToAgentDialog } from './SendToAgentDialog'
import { TaskCardContent } from './TaskCardContent'
import {
  boardViewsKey,
  defaultBoardView,
  readBoardViews,
  selectTasks,
  dropEdge,
  dropPreviewBounds,
  reorderTaskIds,
  orderAllTasks,
  localDateKey,
  type DropEdge,
  type BoardSort,
  type PriorityFilter,
} from './task-view'
import { Modal } from './Modal'
import { SettingsDialog } from './SettingsDialog'
import { AboutDialog } from './ProductIdentity'
import { TaskPanel } from './TaskPanel'
import { CardWindow } from './CardWindow'

function isAgentSetupError(error: unknown) {
  return (
    error instanceof SaveError &&
    ['AGENT_SETUP_REQUIRED', 'AGENT_NOT_INSTALLED', 'MCP_DISABLED'].includes(error.code)
  )
}

function NewBoardDialog({
  onClose,
  onCreate,
  error,
}: {
  onClose: () => void
  onCreate: (name: string) => Promise<void>
  error: string
}) {
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  return (
    <Modal
      title="New project"
      onClose={() => {
        if (!busy) onClose()
      }}
      className="small-modal"
    >
      <form
        onSubmit={async (event) => {
          event.preventDefault()
          if (!name.trim() || busy) return
          setBusy(true)
          try {
            await onCreate(name.trim())
          } finally {
            setBusy(false)
          }
        }}
      >
        <p className="dialog-description">Give your next project a little space.</p>
        <label className="field-label" htmlFor="board-name">
          Project name
        </label>
        <input
          id="board-name"
          autoFocus
          maxLength={100}
          disabled={busy}
          placeholder="What are you working on?"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
        {error && (
          <p className="settings-feedback error-text" role="alert">
            {error}
          </p>
        )}
        <div className="modal-footer">
          <button type="button" className="secondary-button" disabled={busy} onClick={onClose}>
            Cancel
          </button>
          <button className="primary-button" disabled={busy || !name.trim()}>
            {busy ? 'Creating…' : 'Create project'}
          </button>
        </div>
      </form>
    </Modal>
  )
}

function BoardIconDialog({
  board,
  onClose,
  onSave,
}: {
  board: Workspace['boards'][number]
  onClose: () => void
  onSave: (icon: BoardIconName | null) => Promise<void>
}) {
  const [selection, setSelection] = useState<BoardIconName | null>()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const canSave = !busy && selection !== undefined && selection !== board.icon

  async function saveIcon() {
    if (!canSave) return
    setBusy(true)
    setError('')
    try {
      await onSave(selection)
      onClose()
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : 'Could not save the project icon.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Modal
      title={`Change icon for ${board.name}`}
      className="small-modal board-icon-modal"
      onClose={() => {
        if (!busy) onClose()
      }}
    >
      <BoardIconPicker
        value={selection === undefined ? board.icon : selection}
        disabled={busy}
        onChange={setSelection}
      />
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
      <div className="modal-footer">
        <button className="secondary-button" disabled={busy} onClick={onClose}>
          Cancel
        </button>
        <button className="primary-button" disabled={!canSave} onClick={saveIcon}>
          {busy ? 'Saving…' : 'Save icon'}
        </button>
      </div>
    </Modal>
  )
}

function QuickTask({
  onCreate,
  onCancel,
  defaultPriority,
  projects,
}: {
  onCreate: (title: string, priority: Priority, projectId?: string) => void
  onCancel: () => void
  defaultPriority: Priority
  projects?: Workspace['boards']
}) {
  const [title, setTitle] = useState('')
  const [priority, setPriority] = useState(defaultPriority)
  const [projectId, setProjectId] = useState('')
  const canCreate =
    !!title.trim() && (!projects || projects.some((project) => project.id === projectId))
  function submit(event: FormEvent) {
    event.preventDefault()
    if (canCreate) onCreate(title.trim(), priority, projects ? projectId : undefined)
  }
  return (
    <form
      className="quick-task"
      onSubmit={submit}
      onKeyDown={(event) => {
        if (event.key === 'Escape') {
          event.stopPropagation()
          onCancel()
        }
      }}
    >
      <input
        aria-label="New task title"
        autoFocus
        placeholder="What needs doing?"
        maxLength={500}
        value={title}
        onChange={(event) => setTitle(event.target.value)}
      />
      {projects && (
        <select
          className="quick-task-project"
          aria-label="New task project"
          value={projectId}
          onChange={(event) => setProjectId(event.target.value)}
          required
        >
          <option value="" disabled>
            Choose a project
          </option>
          {projects.map((project) => (
            <option key={project.id} value={project.id}>
              {project.name}
            </option>
          ))}
        </select>
      )}
      <select
        aria-label="New task priority"
        value={priority}
        onChange={(event) => setPriority(event.target.value as Priority)}
      >
        {priorities.map((level) => (
          <option key={level} value={level}>
            {level === 'None' ? 'No priority' : level}
          </option>
        ))}
      </select>
      <div>
        <span>Enter to add</span>
        <button
          className="icon-button"
          type="button"
          aria-label="Cancel new task"
          onClick={onCancel}
        >
          <X size={14} />
        </button>
        <button className="quick-add" aria-label="Create task" disabled={!canCreate}>
          <ArrowUpRight size={16} />
        </button>
      </div>
    </form>
  )
}

export function App() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null)
  const [error, setError] = useState('')
  const initialized = useRef<Promise<void> | null>(null)
  const refresh = useCallback(async () => {
    const next = await action<Workspace>('snapshot')
    setWorkspace((current) => (!current || next.revision >= current.revision ? next : current))
  }, [])
  useEffect(() => {
    initialized.current ||= (async () => {
      const previous = localStorage.getItem(storageKey)
      if (previous) {
        let value: unknown
        try {
          value = JSON.parse(previous)
        } catch {
          throw new Error(
            'The earlier prototype data could not be read. Its original data is preserved.'
          )
        }
        await action('import_prototype', { workspace: value })
      }
      await refresh()
    })()
    initialized.current.catch((failure) => setError(failure.message))
    return window.opentalon?.onChanged(() => {
      refresh().catch((failure) => setError(failure.message))
    })
  }, [refresh])
  if (!workspace)
    return (
      <div className="startup-screen">
        <h1>OpenTalon</h1>
        <p role="status">{error || 'Opening your local workspace…'}</p>
        {error && (
          <button
            className="secondary-button"
            onClick={() => {
              initialized.current = null
              location.reload()
            }}
          >
            Retry
          </button>
        )}
      </div>
    )
  return (
    <>
      <WorkspaceApp workspace={workspace} refresh={refresh} />
      {error && (
        <div className="connection-error" role="alert">
          Could not refresh local data: {error}
          <button
            className="text-button"
            onClick={() => {
              setError('')
              void refresh().catch((failure) => setError(failure.message))
            }}
          >
            Retry
          </button>
        </div>
      )}
    </>
  )
}
function WorkspaceApp({
  workspace,
  refresh,
}: {
  workspace: Workspace
  refresh: () => Promise<void>
}) {
  const [view, setView] = useState<'dashboard' | 'all' | 'board' | 'archive' | 'trash'>('dashboard')
  const [query, setQuery] = useState('')
  const [today, setToday] = useState(() => localDateKey())
  useEffect(() => {
    const updateToday = () => setToday(localDateKey())
    const timer = setInterval(updateToday, 60000)
    window.addEventListener('focus', updateToday)
    return () => {
      clearInterval(timer)
      window.removeEventListener('focus', updateToday)
    }
  }, [])
  const [boardViews, setBoardViews] = useState(() =>
    readBoardViews(localStorage.getItem(boardViewsKey))
  )
  const [selectedTask, setSelectedTask] = useState<string | null>(null)
  const saveSelectedTask = useCallback(
    async (
      revision: number,
      patch: {
        title?: string
        notes?: string
        priority?: Priority
        definitionOfDone?: string
        dueDate?: string | null
      }
    ) => {
      if (!selectedTask) throw new Error('No task is open.')
      const result = await action<{ task: Task }>('update_task', {
        id: selectedTask,
        ...patch,
        expectedRevision: revision,
        requestKey: requestKey(),
      })
      await refresh()
      return result.task
    },
    [selectedTask, refresh]
  )
  const [creating, setCreating] = useState<Status | null>(null)
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [aboutOpen, setAboutOpen] = useState(false)
  const [newBoardOpen, setNewBoardOpen] = useState(false)
  const [draggedId, setDraggedId] = useState<string | null>(null)
  const pointerDrag = useRef<{
    id: string
    x: number
    y: number
    active: boolean
  } | null>(null)
  const capturedPointer = useRef<{ element: HTMLButtonElement; id: number } | null>(null)
  const suppressClick = useRef(false)
  const dragLocation = useRef<{ x: number; y: number } | null>(null)
  const [dragPoint, setDragPoint] = useState<{ x: number; y: number } | null>(null)
  const [dropColumn, setDropColumn] = useState<Status | null>(null)
  const [dropArea, setDropArea] = useState<ReturnType<typeof dropPreviewBounds>>(null)
  const [dropBefore, setDropBefore] = useState<string | null>(null)
  const [dropPosition, setDropPosition] = useState<DropEdge>('before')
  const [boardMenu, setBoardMenu] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [iconPickerOpen, setIconPickerOpen] = useState(false)
  const [boardName, setBoardName] = useState('')
  const [confirmation, setConfirmation] = useState<Preview | null>(null)
  const [saveError, setSaveError] = useState('')
  const [pendingSend, setPendingSend] = useState<Record<string, unknown> | null>(null)
  const [toast, setToast] = useState('')
  const [confirmationKey, setConfirmationKey] = useState('')
  const dirty = useRef(false)
  const creatingRequest = useRef<{ fingerprint: string; key: string; pending: boolean } | null>(
    null
  )
  const onDirty = useCallback((value: boolean) => {
    dirty.current = value
    void action('set_editor_dirty', { dirty: value }).catch(() => {})
  }, [])
  const [systemDark, setSystemDark] = useState(
    () => matchMedia('(prefers-color-scheme: dark)').matches
  )
  useEffect(() => {
    const media = matchMedia('(prefers-color-scheme: dark)')
    const update = () => setSystemDark(media.matches)
    media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [])
  const theme =
    workspace.theme === 'system' ? (systemDark ? 'graphite' : 'native-light') : workspace.theme
  const searchRef = useRef<HTMLInputElement>(null)
  const board =
    workspace.boards.find((item) => item.id === workspace.selectedBoard) ?? workspace.boards[0]
  const allTasks = view === 'all'
  const kanbanOpen = allTasks || view === 'board'
  const viewKey = allTasks ? ':all-tasks' : board.id
  const savedTask = workspace.tasks.find((item) => item.id === selectedTask)
  const retainedTask = useRef<Task | undefined>(undefined)
  if (savedTask) retainedTask.current = savedTask
  const task =
    savedTask ||
    (dirty.current && retainedTask.current?.id === selectedTask ? retainedTask.current : undefined)
  const boardTasks = workspace.tasks.filter(
    (item) => !item.deleted && !item.archivedAt && (allTasks || item.boardId === board.id)
  )
  const projectNames = new Map(workspace.boards.map((project) => [project.id, project.name]))
  const trashedTasks = workspace.tasks.filter((item) => item.deleted)
  const archivedTasks = workspace.tasks.filter((item) => !item.deleted && item.archivedAt)
    .sort((a, b) => (b.archivedAt ?? '').localeCompare(a.archivedAt ?? ''))
  const needle = query.trim().toLowerCase()
  const boardView = boardViews[viewKey] || defaultBoardView
  const allTasksOrdered = allTasks
    ? orderAllTasks(
        boardTasks,
        new Map(workspace.boards.map((project, index) => [project.id, index])),
        workspace.allTasksOrder || []
      )
    : []
  const allTasksRank = new Map(allTasksOrdered.map((item, index) => [item.id, index]))
  const visibleTasks = selectTasks(
    boardTasks,
    query,
    boardView,
    allTasks ? allTasksRank : undefined
  )
  const filtered = !!needle || boardView.priority !== 'All'
  const customOrder = filtered || boardView.sort !== 'manual'
  const runsById = new Map(workspace.agentRuns.map((run) => [run.id, run]))
  function updateBoardView(patch: Partial<typeof boardView>) {
    const next = { ...boardViews, [viewKey]: { ...boardView, ...patch } }
    localStorage.setItem(boardViewsKey, JSON.stringify(next))
    setBoardViews(next)
  }

  useEffect(() => {
    document.documentElement.dataset.theme = theme
  }, [theme])
  useEffect(() => {
    if (!toast) return
    const timer = setTimeout(() => setToast(''), 2800)
    return () => clearTimeout(timer)
  }, [toast])
  useEffect(
    () =>
      window.opentalon?.onCommand((command) => {
        if (command === 'settings' && !dirty.current) setSettingsOpen(true)
        if (command === 'about') setAboutOpen(true)
        if (command === 'new-task') {
          setView((current) => (current === 'all' ? current : 'board'))
          setCreating('To do')
        }
        if (command === 'search') searchRef.current?.focus()
      }),
    []
  )
  useEffect(() => {
    function keyboard(event: KeyboardEvent) {
      if (iconPickerOpen) return
      const typing =
        event.target instanceof HTMLElement &&
        (['INPUT', 'TEXTAREA', 'SELECT'].includes(event.target.tagName) ||
          event.target.isContentEditable)
      if (event.key === 'Escape' && !settingsOpen && !newBoardOpen && !confirmation) {
        if (!dirty.current) setSelectedTask(null)
        pointerDrag.current = null
        setDraggedId(null)
        setDropColumn(null)
        setDropBefore(null)
        setDragPoint(null)
        setCreating(null)
        setBoardMenu(false)
      }
      if (!window.opentalon && (event.metaKey || event.ctrlKey)) {
        if (event.key === 'n') {
          event.preventDefault()
          setView((current) => (current === 'all' ? current : 'board'))
          setCreating('To do')
        }
        if (event.key === 'f') {
          event.preventDefault()
          searchRef.current?.focus()
        }
        if (event.key === ',') {
          event.preventDefault()
          setSettingsOpen(true)
        }
      }
      if (event.key === '/' && !typing && !settingsOpen && !newBoardOpen) {
        event.preventDefault()
        searchRef.current?.focus()
      }
    }
    document.addEventListener('keydown', keyboard)
    return () => document.removeEventListener('keydown', keyboard)
  }, [settingsOpen, newBoardOpen, confirmation, iconPickerOpen])

  async function run<T>(name: string, input: Record<string, unknown> = {}): Promise<T> {
    const result = await action<T>(name, input)
    await refresh()
    return result
  }
  async function safe(operation: () => Promise<void>) {
    setSaveError('')
    try {
      await operation()
    } catch (error) {
      setSaveError(
        error instanceof Error ? error.message : 'Could not save. Your data is preserved.'
      )
    }
  }
  function canLeave() {
    if (dirty.current) {
      setToast('Save the task text before leaving it.')
      return false
    }
    return true
  }
  async function preferences(patch: Record<string, unknown>) {
    await run('set_preferences', {
      ...patch,
      expectedRevision: workspace.preferencesRevision,
      requestKey: requestKey(),
    })
  }
  useEffect(() => {
    window.addEventListener('pointerup', finishDrag, true)
    window.addEventListener('pointercancel', finishDrag, true)
    window.addEventListener('mouseup', finishDrag, true)
    return () => {
      window.removeEventListener('pointerup', finishDrag, true)
      window.removeEventListener('pointercancel', finishDrag, true)
      window.removeEventListener('mouseup', finishDrag, true)
    }
  }, [workspace, viewKey, needle, boardView.priority, boardView.sort])
  useEffect(() => {
    if (!draggedId) return
    let frame: number
    function scrollDuringDrag() {
      const point = dragLocation.current
      if (point && pointerDrag.current?.active) {
        const target = document.elementFromPoint(point.x, point.y)
        const root = target?.closest<HTMLElement>('.virtual-card-list, .main-area')
        if (root) {
          const bounds = root.getBoundingClientRect()
          const top = Math.max(44, bounds.top)
          const bottom = Math.min(innerHeight, bounds.bottom)
          const delta =
            point.y < top + 60
              ? -Math.min(18, (top + 60 - point.y) / 3)
              : point.y > bottom - 60
                ? Math.min(18, (point.y - bottom + 60) / 3)
                : 0
          if (delta) {
            root.scrollTop += delta
          }
        }
        updateDropTarget(point.x, point.y)
      }
      frame = requestAnimationFrame(scrollDuringDrag)
    }
    frame = requestAnimationFrame(scrollDuringDrag)
    return () => cancelAnimationFrame(frame)
  }, [draggedId])
  function selectBoard(id: string) {
    if (!canLeave()) return
    void safe(async () => {
      if (id !== workspace.selectedBoard) await preferences({ selectedBoard: id })
      setView('board')
      setSelectedTask(null)
      setCreating(null)
      setQuery('')
      setBoardMenu(false)
      setRenaming(false)
    })
  }
  function showView(next: 'dashboard' | 'all' | 'archive' | 'trash') {
    if (!canLeave()) return
    setView(next)
    setSelectedTask(null)
    setCreating(null)
    setQuery('')
    setBoardMenu(false)
    setRenaming(false)
  }
  function createTask(title: string, priority: Priority, projectId = board.id) {
    if (creatingRequest.current?.pending) return
    const input = { boardId: projectId, title, priority, status: creating ?? 'To do' }
    const fingerprint = JSON.stringify(input)
    const request =
      creatingRequest.current?.fingerprint === fingerprint
        ? creatingRequest.current
        : { fingerprint, key: requestKey(), pending: false }
    creatingRequest.current = request
    request.pending = true
    void safe(async () => {
      try {
        try {
          await run('create_task', { ...input, requestKey: request.key })
        } catch (error) {
          if (isAgentSetupError(error)) {
            setPendingSend({ ...input, action: 'create_task', requestKey: request.key })
            setCreating(null)
            creatingRequest.current = null
            return
          }
          throw error
        }
        setCreating(null)
        creatingRequest.current = null
      } finally {
        request.pending = false
      }
    })
  }
  function move(id: string, status: Status, boardId: string, beforeId?: string, afterId?: string) {
    const item = workspace.tasks.find((item) => item.id === id)
    if (!item || !canLeave() || beforeId === id) return
    setDraggedId(null)
    setDropColumn(null)
    setDropBefore(null)
    void safe(async () => {
      const input = {
        id,
        status,
        boardId,
        ...(beforeId ? { beforeId } : {}),
        ...(afterId ? { afterId } : {}),
        expectedRevision: item.revision,
        requestKey: requestKey(),
      }
      try {
        await run('move_task', input)
      } catch (error) {
        if (isAgentSetupError(error)) {
          setPendingSend({ ...input, action: 'move_task' })
          return
        }
        throw error
      }
      if (!allTasks && boardId !== board.id) await preferences({ selectedBoard: boardId })
    })
  }
  function startDrag(event: ReactPointerEvent<HTMLButtonElement>, id: string) {
    if (dirty.current || event.button !== 0) return
    pointerDrag.current = { id, x: event.clientX, y: event.clientY, active: false }
    capturedPointer.current = { element: event.currentTarget, id: event.pointerId }
    event.currentTarget.setPointerCapture(event.pointerId)
  }
  function continueDrag(event: ReactPointerEvent<HTMLButtonElement>) {
    const drag = pointerDrag.current
    if (!drag) return
    if (!drag.active && Math.hypot(event.clientX - drag.x, event.clientY - drag.y) < 6) return
    event.preventDefault()
    drag.active = true
    setDraggedId(drag.id)
    setDragPoint({ x: event.clientX, y: event.clientY })
    dragLocation.current = { x: event.clientX, y: event.clientY }
    updateDropTarget(event.clientX, event.clientY)
  }
  function dropTarget(x: number, y: number) {
    const target = document.elementFromPoint(x, y)
    const column = target?.closest<HTMLElement>('[data-drop-status]')
    const status = column?.dataset.dropStatus as Status | undefined
    const slot = target?.closest<HTMLElement>('[data-task-slot]')
    const bounds = slot?.getBoundingClientRect()
    return {
      status,
      column,
      anchorId: slot?.dataset.taskSlot,
      edge: bounds ? dropEdge(y, bounds.top, bounds.height) : ('after' as DropEdge),
    }
  }
  function updateDropTarget(x: number, y: number) {
    const { status, column, anchorId, edge } = dropTarget(x, y)
    setDropColumn(status || null)
    const viewport = column?.closest<HTMLElement>('.main-area')?.getBoundingClientRect()
    const next =
      column && viewport
        ? dropPreviewBounds(column.getBoundingClientRect(), {
            left: Math.max(0, viewport.left),
            right: Math.min(innerWidth, viewport.right),
            top: Math.max(44, viewport.top),
            bottom: Math.min(innerHeight, viewport.bottom),
          })
        : null
    setDropArea((current) =>
      current &&
      next &&
      current.left === next.left &&
      current.top === next.top &&
      current.width === next.width &&
      current.height === next.height
        ? current
        : next
    )
    setDropBefore(anchorId || null)
    setDropPosition(edge)
  }
  function finishDrag(event: globalThis.PointerEvent | MouseEvent) {
    const drag = pointerDrag.current
    if (!drag) return
    pointerDrag.current = null
    dragLocation.current = null
    const capture = capturedPointer.current
    capturedPointer.current = null
    if (capture?.element.hasPointerCapture(capture.id))
      capture.element.releasePointerCapture(capture.id)
    if (
      (drag.active || Math.hypot(event.clientX - drag.x, event.clientY - drag.y) >= 6) &&
      (event.type === 'pointerup' || event.type === 'mouseup') &&
      !document.querySelector('dialog[open]')
    ) {
      suppressClick.current = true
      setTimeout(() => {
        suppressClick.current = false
      }, 0)
      const { status, anchorId, edge } = dropTarget(event.clientX, event.clientY)
      const item = workspace.tasks.find((item) => item.id === drag.id)
      if (status && anchorId !== drag.id && item && canLeave()) {
        if (allTasks) reorderAllTasks(item, status, anchorId, edge)
        else if (status === item.status && boardView.sort !== 'manual') {
          const column = selectTasks(
            boardTasks.filter((task) => task.status === status),
            '',
            { ...boardView, priority: 'All' }
          )
          const taskIds = reorderTaskIds(column, drag.id, anchorId, edge)
          void safe(async () => {
            await run('reorder_tasks', {
              boardId: board.id,
              status,
              taskIds,
              expectedRevision: workspace.revision,
              requestKey: requestKey(),
            })
            updateBoardView({ sort: 'manual' })
            setToast('Manual order saved')
          })
        } else {
          const anchor = boardView.sort === 'manual' ? anchorId : undefined
          move(
            drag.id,
            status,
            item.boardId,
            edge === 'before' ? anchor : undefined,
            edge === 'after' ? anchor : undefined
          )
        }
      }
    }
    setDraggedId(null)
    setDropColumn(null)
    setDropBefore(null)
    setDragPoint(null)
  }
  // Same rules as a project board: with a priority sort, a drag within a column saves the sorted
  // order and switches to manual; a drag into another column keeps the sort and appends.
  function reorderAllTasks(
    item: Task,
    status: Status,
    anchorId?: string,
    edge: DropEdge = 'after'
  ) {
    const sorted = status === item.status && boardView.sort !== 'manual'
    const column = selectTasks(
      allTasksOrdered.filter((task) => task.status === status && task.id !== item.id),
      '',
      { priority: 'All', sort: sorted ? boardView.sort : 'manual' },
      allTasksRank
    )
    const anchor = sorted || boardView.sort === 'manual' ? anchorId : undefined
    const taskIds = reorderTaskIds([...column, item], item.id, anchor, edge)
    setDraggedId(null)
    setDropColumn(null)
    setDropBefore(null)
    void safe(async () => {
      try {
        await run('reorder_all_tasks', {
          status,
          taskIds,
          expectedRevision: workspace.revision,
          requestKey: requestKey(),
        })
      } catch (error) {
        if (isAgentSetupError(error)) {
          // After setup, send it the simple way: the move appends to its project's column.
          setPendingSend({
            action: 'move_task',
            id: item.id,
            status,
            boardId: item.boardId,
            expectedRevision: item.revision,
            requestKey: requestKey(),
          })
          return
        }
        throw error
      }
      if (sorted) {
        updateBoardView({ sort: 'manual' })
        setToast('Order saved')
      }
    })
  }
  function trashTask(id: string) {
    const item = workspace.tasks.find((item) => item.id === id)
    if (!item || !canLeave()) return
    void safe(async () => {
      await run('trash_task', { id, expectedRevision: item.revision, requestKey: requestKey() })
      setSelectedTask(null)
      setToast('Task moved to Trash')
    })
  }
  function renameBoard(event: FormEvent) {
    event.preventDefault()
    if (boardName.trim())
      void safe(async () => {
        await run('rename_board', {
          id: board.id,
          name: boardName,
          expectedRevision: board.revision,
          requestKey: requestKey(),
        })
        setRenaming(false)
      })
  }
  function prepareRemoval(id?: string, archived = false) {
    void safe(async () => {
      setConfirmation(
        await action<Preview>(
          'preview_destructive_action',
          id ? { action: archived ? 'purge_archived_tasks' : 'purge_tasks', taskIds: [id] } : { action: 'empty_trash' }
        )
      )
      setConfirmationKey(requestKey())
    })
  }

  return (
    <div className={`app-shell theme-${theme}`}>
      <div className="window-titlebar">
        <span>OpenTalon</span>
      </div>
      <div className="workspace-shell">
        <aside className="sidebar">
          <div className="brand">
            <span className="logo-tile">
              <img src={logo} alt="OpenTalon logo" />
            </span>
            <span className="logo-type">
              <img src={wordmark} alt="OpenTalon" />
            </span>
          </div>
          <nav className="board-navigation" aria-label="Workspace">
            <button
              className={`board-link ${allTasks ? 'active' : ''}`}
              aria-current={allTasks ? 'page' : undefined}
              onClick={() => showView('all')}
            >
              <ListTodo size={17} strokeWidth={1.65} />
              <span>All tasks</span>
            </button>
            <button
              className={`board-link ${view === 'dashboard' ? 'active' : ''}`}
              aria-current={view === 'dashboard' ? 'page' : undefined}
              onClick={() => showView('dashboard')}
            >
              <LayoutDashboard size={17} strokeWidth={1.65} />
              <span>Dashboard</span>
            </button>
            <div className="nav-section-title">Projects</div>
            {workspace.boards.map((item) => (
              <button
                key={item.id}
                className={`board-link ${view === 'board' && item.id === board.id ? 'active' : ''}`}
                aria-current={view === 'board' && item.id === board.id ? 'page' : undefined}
                onClick={() => selectBoard(item.id)}
              >
                <BoardIcon icon={item.icon} />
                <span>{item.name}</span>
              </button>
            ))}
            <button
              className="add-board"
              onClick={() => {
                if (canLeave()) setNewBoardOpen(true)
              }}
            >
              <Plus size={17} /> Add project
            </button>
          </nav>
          <div className="sidebar-bottom">
            <button
              className={`sidebar-action ${view === 'archive' ? 'active' : ''}`}
              onClick={() => showView('archive')}
            >
              <Archive size={18} strokeWidth={1.6} /> Archive
            </button>
            <button
              className={`sidebar-action ${view === 'trash' ? 'active' : ''}`}
              onClick={() => showView('trash')}
            >
              <Trash2 size={18} strokeWidth={1.6} />
              Trash
              {trashedTasks.length > 0 && <span className="nav-count">{trashedTasks.length}</span>}
            </button>
            <button
              className="sidebar-action"
              onClick={() => {
                if (canLeave()) setSettingsOpen(true)
              }}
            >
              <Settings size={18} strokeWidth={1.6} />
              Settings<span className="shortcut-hint">⌘ ,</span>
            </button>
          </div>
        </aside>
        <main className={`main-area ${task && kanbanOpen ? 'panel-is-open' : ''}`}>
          {view === 'dashboard' ? (
            <Dashboard
              workspace={workspace}
              today={today}
              onBoard={selectBoard}
              onUpdate={async (item, patch) => {
                const result = await run<{ task: Task }>('update_task', {
                  id: item.id,
                  expectedRevision: item.revision,
                  ...patch,
                  requestKey: requestKey(),
                })
                return result.task
              }}
              onIgnore={async (item) => {
                const result = await run<{ task: Task }>('trash_task', {
                  id: item.id,
                  expectedRevision: item.revision,
                  requestKey: requestKey(),
                })
                return result.task
              }}
              onRestore={async (item) => {
                const result = await run<{ task: Task }>('restore_task', {
                  id: item.id,
                  expectedRevision: item.revision,
                  requestKey: requestKey(),
                })
                return result.task
              }}
              onTask={(item) => {
                if (!canLeave()) return
                void safe(async () => {
                  await preferences({ selectedBoard: item.boardId })
                  setQuery('')
                  setView('board')
                  setSelectedTask(item.id)
                  setCreating(null)
                })
              }}
            />
          ) : kanbanOpen ? (
            <>
              <header className="board-header">
                <div className="board-heading-group">
                  {allTasks ? (
                    <>
                      <span className="board-heading-icon">
                        <ListTodo size={22} strokeWidth={1.65} aria-hidden="true" />
                      </span>
                      <h1>All tasks</h1>
                    </>
                  ) : renaming ? (
                    <form onSubmit={renameBoard}>
                      <input
                        aria-label="Project title"
                        autoFocus
                        value={boardName}
                        onChange={(event) => setBoardName(event.target.value)}
                        onBlur={() => setRenaming(false)}
                        onKeyDown={(event) => {
                          if (event.key === 'Escape') setRenaming(false)
                        }}
                      />
                    </form>
                  ) : (
                    <>
                      <span className="board-heading-icon">
                        <BoardIcon icon={board.icon} size={22} />
                      </span>
                      <h1>{board.name}</h1>
                    </>
                  )}
                  {!allTasks && (
                    <div className="board-menu-wrap">
                      <button
                        className="icon-button board-menu-button"
                        aria-label="Project options"
                        title="Project options"
                        aria-expanded={boardMenu}
                        onClick={() => setBoardMenu(!boardMenu)}
                      >
                        <Ellipsis size={19} />
                      </button>
                      {boardMenu && (
                        <>
                          <button
                            className="menu-backdrop"
                            aria-label="Close project options"
                            onClick={() => setBoardMenu(false)}
                          />
                          <div className="context-menu">
                            <button
                              onClick={() => {
                                setBoardName(board.name)
                                setRenaming(true)
                                setBoardMenu(false)
                              }}
                            >
                              Rename project
                            </button>
                            <button
                              aria-haspopup="dialog"
                              onClick={() => {
                                setIconPickerOpen(true)
                                setBoardMenu(false)
                              }}
                            >
                              Change icon
                            </button>
                            {workspace.boards.length > 1 && (
                              <>
                                <button
                                  className="destructive"
                                  disabled={workspace.tasks.some(
                                    (item) => item.boardId === board.id
                                  )}
                                  onClick={() =>
                                    void safe(async () => {
                                      await run('delete_board', {
                                        id: board.id,
                                        expectedRevision: board.revision,
                                        requestKey: requestKey(),
                                      })
                                      setBoardMenu(false)
                                    })
                                  }
                                >
                                  Delete empty project
                                </button>
                                {workspace.tasks.some((item) => item.boardId === board.id) && (
                                  <p className="menu-help">
                                    Move or remove live and trashed tasks first.
                                  </p>
                                )}
                              </>
                            )}
                          </div>
                        </>
                      )}
                    </div>
                  )}
                </div>
                <div className="board-toolbar">
                  <div className="search-field">
                    <Search size={16} />
                    <input
                      ref={searchRef}
                      aria-label="Search tasks"
                      placeholder="Search tasks"
                      value={query}
                      onChange={(event) => setQuery(event.target.value)}
                    />
                    {query ? (
                      <button
                        className="icon-button clear-search"
                        aria-label="Clear search"
                        onClick={() => setQuery('')}
                      >
                        <X size={13} />
                      </button>
                    ) : (
                      <kbd>/</kbd>
                    )}
                  </div>
                  <button
                    className="primary-button add-task-button"
                    onClick={() => {
                      setCreating('To do')
                      setQuery('')
                    }}
                  >
                    <Plus size={17} /> Add task
                  </button>
                </div>
              </header>
              <div className="board-view-controls" aria-label="Task view controls">
                <label>
                  Priority
                  <select
                    aria-label="Filter by priority"
                    value={boardView.priority}
                    onChange={(event) =>
                      updateBoardView({ priority: event.target.value as PriorityFilter })
                    }
                  >
                    <option value="All">All priorities</option>
                    {priorities.map((level) => (
                      <option key={level} value={level}>
                        {level === 'None' ? 'No priority' : level} (
                        {boardTasks.filter((task) => task.priority === level).length})
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  Sort
                  <select
                    aria-label="Sort tasks"
                    value={boardView.sort}
                    onChange={(event) => updateBoardView({ sort: event.target.value as BoardSort })}
                  >
                    <option value="manual">Manual order</option>
                    <option value="priority-desc">Priority: urgent first</option>
                    <option value="priority-asc">Priority: low first</option>
                  </select>
                </label>
                <span className="view-task-count">
                  {visibleTasks.length} {filtered ? `of ${boardTasks.length} ` : ''}tasks
                </span>
                {filtered && (
                  <button
                    className="text-button"
                    onClick={() => {
                      setQuery('')
                      updateBoardView({ priority: 'All' })
                    }}
                  >
                    Clear filters
                  </button>
                )}
                <span className="view-order-hint">
                  {allTasks
                    ? boardView.sort !== 'manual'
                      ? 'Drag a card to set your own order. This switches to your order and updates each project.'
                      : 'Drag cards to reorder or change status. Each project keeps the same order.'
                    : boardView.sort !== 'manual'
                      ? 'Drag a card to set your own order. This switches to manual order.'
                      : 'Drag cards above or below each other to reorder. Changes save automatically.'}
                </span>
              </div>
              <div className="board-canvas">
                <div className={`kanban-grid ${draggedId ? 'is-dragging' : ''}`}>
                  {statuses.map((status) => {
                    const columnTasks = visibleTasks.filter((item) => item.status === status)
                    const total = boardTasks.filter((item) => item.status === status).length
                    const composer = creating === status && (
                      <QuickTask
                        projects={allTasks ? workspace.boards : undefined}
                        defaultPriority={boardView.priority === 'All' ? 'None' : boardView.priority}
                        onCreate={createTask}
                        onCancel={() => setCreating(null)}
                      />
                    )
                    const StatusIcon =
                      status === 'Done'
                        ? CheckCheck
                        : status === 'In progress'
                          ? CircleDashed
                          : status === 'Sent to agent'
                            ? Send
                            : Circle
                    return (
                      <section
                        key={status}
                        data-drop-status={status}
                        aria-label={`${status} column`}
                        className={`kanban-column ${dropColumn === status && draggedId ? 'drop-active' : ''}`}
                      >
                        <div className="column-heading">
                          <StatusIcon
                            className={`status-icon status-${status.replaceAll(' ', '-').toLowerCase()}`}
                            size={16}
                            strokeWidth={1.7}
                          />
                          <h2>{status}</h2>
                          <span className="column-count">
                            {filtered ? `${columnTasks.length}/${total}` : total}
                          </span>
                          <button
                            className="icon-button column-add"
                            aria-label={`Add task to ${status}`}
                            onClick={() => {
                              setCreating(status)
                              setQuery('')
                            }}
                          >
                            <Plus size={16} />
                          </button>
                        </div>
                        <div className="card-well">
                          {allTasks && composer}
                          <CardWindow
                            key={`${viewKey}-${status}-${needle}-${boardView.priority}-${boardView.sort}`}
                          >
                            {columnTasks.map((item) => (
                              <div
                                key={item.id}
                                data-task-slot={item.id}
                                className={`card-slot ${dropBefore === item.id && draggedId !== item.id ? `drop-${dropPosition}` : ''}`}
                              >
                                <button
                                  className={`task-card ${task?.id === item.id ? 'selected' : ''} ${draggedId === item.id ? 'dragged' : ''}`}
                                  data-task-id={item.id}
                                  title={'Drag to reorder or move; click to open'}
                                  onPointerDown={(event) => startDrag(event, item.id)}
                                  onPointerMove={continueDrag}
                                  onClick={() => {
                                    if (suppressClick.current || !canLeave()) return
                                    setSelectedTask(item.id)
                                    setCreating(null)
                                  }}
                                >
                                  <TaskCardContent
                                    task={item}
                                    today={today}
                                    run={runsById.get(workspace.agentAssignments[item.id])}
                                    projectName={
                                      allTasks ? projectNames.get(item.boardId) : undefined
                                    }
                                  />
                                </button>
                              </div>
                            ))}
                          </CardWindow>
                          {!allTasks && composer}
                          {!columnTasks.length && creating !== status && (
                            <div className="empty-column">
                              {filtered ? (
                                'No matching tasks'
                              ) : (
                                <button onClick={() => setCreating(status)}>
                                  <Plus size={15} /> Add a task
                                </button>
                              )}
                            </div>
                          )}
                        </div>
                      </section>
                    )
                  })}
                </div>
                {filtered && (
                  <div className="search-summary">
                    {visibleTasks.length} of {boardTasks.length} tasks match your filters
                    <button
                      className="text-button"
                      onClick={() => {
                        setQuery('')
                        updateBoardView({ priority: 'All' })
                      }}
                    >
                      Clear filters
                    </button>
                  </div>
                )}
              </div>
            </>
          ) : view === 'archive' ? (
            <div className="trash-view">
              <header className="trash-header">
                <div>
                  <h1>Archive</h1>
                  <p>Completed tasks move here after seven days.</p>
                </div>
              </header>
              {archivedTasks.length ? (
                <div className="trash-list">
                  {archivedTasks.map((item) => (
                    <div className="trash-row" key={item.id}>
                      <span className="trash-row-icon"><FileText size={17} /></span>
                      <div>
                        <button className="text-button" onClick={() => {
                          if (canLeave()) setSelectedTask(item.id)
                        }}>{item.title}</button>
                        <span>{projectNames.get(item.boardId)}</span>
                      </div>
                      <button
                        className="secondary-button restore-button"
                        onClick={() => {
                          if (!canLeave()) return
                          void safe(async () => {
                            await run('move_task', {
                              id: item.id,
                              status: 'To do',
                              expectedRevision: item.revision,
                              requestKey: requestKey(),
                            })
                            setToast('Task reopened')
                          })
                        }}
                      >
                        <Undo2 size={14} /> Reopen
                      </button>
                      <button className="secondary-button" onClick={() => trashTask(item.id)}>
                        <Trash2 size={14} /> Move to Trash
                      </button>
                      <button
                        className="icon-button"
                        aria-label={`Permanently delete ${item.title}`}
                        onClick={() => { if (canLeave()) prepareRemoval(item.id, true) }}
                      >
                        <X size={16} />
                      </button>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="empty-trash">
                  <span><Archive size={28} strokeWidth={1.3} /></span>
                  <h2>No archived tasks</h2>
                </div>
              )}
            </div>
          ) : (
            <div className="trash-view">
              <header className="trash-header">
                <div>
                  <h1>Trash</h1>
                  <p>Changed your mind? Bring a task back.</p>
                </div>
                {trashedTasks.length > 0 && (
                  <button className="secondary-button" onClick={() => prepareRemoval()}>
                    Empty trash
                  </button>
                )}
              </header>
              {trashedTasks.length ? (
                <div className="trash-list">
                  {trashedTasks.map((item) => (
                    <div className="trash-row" key={item.id}>
                      <span className="trash-row-icon">
                        <FileText size={17} />
                      </span>
                      <div>
                        <strong>{item.title}</strong>
                        <span>
                          {workspace.boards.find((entry) => entry.id === item.boardId)?.name}{' '}
                          <span className="quiet-separator">/</span> {item.status}
                        </span>
                      </div>
                      <button
                        className="secondary-button restore-button"
                        onClick={() =>
                          void safe(async () => {
                            await run('restore_task', {
                              id: item.id,
                              expectedRevision: item.revision,
                              requestKey: requestKey(),
                            })
                            setToast('Task restored')
                          })
                        }
                      >
                        <Undo2 size={14} />
                        Restore
                      </button>
                      <button
                        className="icon-button"
                        aria-label={`Permanently delete ${item.title}`}
                        onClick={() => prepareRemoval(item.id)}
                      >
                        <X size={16} />
                      </button>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="empty-trash">
                  <span>
                    <Trash2 size={28} strokeWidth={1.3} />
                  </span>
                  <h2>Nothing in the way.</h2>
                  <p>Deleted tasks will wait here until you need them.</p>
                  <button className="text-button" onClick={() => showView('all')}>
                    <ArrowLeft size={14} /> Back to all tasks
                  </button>
                </div>
              )}
            </div>
          )}
          {saveError && (
            <div className="save-error" role="alert">
              {saveError}
            </div>
          )}
        </main>
        {task && kanbanOpen && (
          <TaskPanel
            key={task.id}
            task={task}
            workspace={workspace}
            filtered={!allTasks && customOrder}
            onDirty={onDirty}
            onClose={() => setSelectedTask(null)}
            onSave={saveSelectedTask}
            onMove={(boardId, status, beforeId, afterId) =>
              move(task.id, status, boardId, beforeId, afterId)
            }
            onTrash={() => trashTask(task.id)}
          />
        )}
      </div>
      {aboutOpen && <AboutDialog onClose={() => setAboutOpen(false)} />}
      {settingsOpen && (
        <SettingsDialog
          theme={workspace.theme}
          onTheme={(theme) => preferences({ theme })}
          onClose={() => setSettingsOpen(false)}
          onRestored={async () => {
            setSelectedTask(null)
            setQuery('')
            await refresh()
          }}
        />
      )}
      {iconPickerOpen && (
        <BoardIconDialog
          key={board.id}
          board={board}
          onClose={() => setIconPickerOpen(false)}
          onSave={async (icon) => {
            await run('set_board_icon', {
              id: board.id,
              icon,
              expectedRevision: board.revision,
              requestKey: requestKey(),
            })
          }}
        />
      )}
      {newBoardOpen && (
        <NewBoardDialog
          onClose={() => setNewBoardOpen(false)}
          error={saveError}
          onCreate={(name) =>
            safe(async () => {
              const result = await run<{ board: { id: string } }>('create_board', {
                name,
                requestKey: requestKey(),
              })
              await preferences({ selectedBoard: result.board.id })
              setNewBoardOpen(false)
              setView('board')
              setQuery('')
              setSelectedTask(null)
            })
          }
        />
      )}
      {confirmation && (
        <Modal
          title={
            confirmation.action === 'empty_trash' ? 'Empty Trash?' : 'Permanently delete this task?'
          }
          className="small-modal"
          onClose={() => setConfirmation(null)}
        >
          <p className="dialog-description">
            Permanently remove {confirmation.summary.count}{' '}
            {confirmation.summary.count === 1 ? 'task' : 'tasks'} from{' '}
            {confirmation.action === 'purge_archived_tasks' ? 'Archive' : 'Trash'}. This cannot be undone.
          </p>
          <div className="modal-footer">
            <button className="secondary-button" onClick={() => setConfirmation(null)}>
              Cancel
            </button>
            <button
              className="danger-button"
              onClick={() =>
                void safe(async () => {
                  await run('confirm_destructive_action', {
                    token: confirmation.token,
                    requestKey: confirmationKey,
                  })
                  setConfirmation(null)
                })
              }
            >
              {confirmation.action === 'empty_trash' ? 'Empty Trash' : 'Delete permanently'}
            </button>
          </div>
          {saveError && (
            <p className="settings-feedback error-text" role="alert">
              {saveError}
            </p>
          )}
        </Modal>
      )}
      {draggedId && dragPoint && (
        <div
          className="drag-preview"
          style={{ left: dragPoint.x + 14, top: dragPoint.y + 14 }}
          aria-hidden="true"
        >
          {workspace.tasks.find((item) => item.id === draggedId)?.title}
          {dropColumn && <span className="drag-preview-destination">Drop in {dropColumn}</span>}
        </div>
      )}
      {draggedId && dropColumn && dropArea && (
        <div className="drop-column-preview" style={dropArea}>
          <span className="drop-column-label" role="status">
            Drop in {dropColumn}
          </span>
        </div>
      )}
      {pendingSend && (
        <SendToAgentDialog
          title={
            workspace.tasks.find((item) => item.id === pendingSend.id)?.title ||
            String(pendingSend.title || 'New task')
          }
          onClose={() => setPendingSend(null)}
          onSend={async () => {
            const { action: name, ...input } = pendingSend
            // Re-read before sending: an MCP client may have changed the task during setup.
            if (input.id) {
              const current = await action<{ task: Task }>('get_task', { id: input.id })
              if (current.task.deleted || current.task.status === 'Sent to agent')
                throw new Error(
                  'This task changed during setup. Close this dialog and review it before sending.'
                )
              input.expectedRevision = current.task.revision
            }
            await run(String(name), input)
            setPendingSend(null)
            setToast('Task sent to your agent')
          }}
        />
      )}
      {toast && (
        <div className="toast" role="status">
          <Check size={15} />
          {toast}
        </div>
      )}
    </div>
  )
}
