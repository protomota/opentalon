import { useEffect, useRef, useState } from 'react'
import { ArrowDown, ArrowUp, Check, FileText, Trash2, X } from 'lucide-react'
import {
  SaveError,
  priorities,
  statuses,
  type Priority,
  type Status,
  type Task,
  type Workspace,
} from './model'
import { PriorityBadge } from './TaskCardContent'
import { AgentRunDetails } from './AgentRunDetails'
import { TaskComments } from './TaskComments'

type Draft = {
  title: string
  notes: string
  savedTitle: string
  savedNotes: string
  priority: Priority
  savedPriority: Priority
  definitionOfDone: string
  savedDefinitionOfDone: string
  dueDate: string | null
  savedDueDate: string | null
  revision: number
}
const draftOf = (task: Task): Draft => ({
  title: task.title,
  notes: task.notes,
  savedTitle: task.title,
  savedNotes: task.notes,
  priority: task.priority,
  savedPriority: task.priority,
  definitionOfDone: task.definitionOfDone,
  savedDefinitionOfDone: task.definitionOfDone,
  dueDate: task.dueDate,
  savedDueDate: task.dueDate,
  revision: task.revision,
})
export function TaskPanel({
  task,
  workspace,
  onSave,
  onMove,
  onTrash,
  onClose,
  onDirty,
  filtered,
}: {
  task: Task
  workspace: Workspace
  filtered: boolean
  onSave: (
    revision: number,
    patch: {
      title?: string
      notes?: string
      priority?: Priority
      definitionOfDone?: string
      dueDate?: string | null
    }
  ) => Promise<Task>
  onMove: (boardId: string, status: Status, beforeId?: string, afterId?: string) => void
  onTrash: () => void
  onClose: () => void
  onDirty: (dirty: boolean) => void
}) {
  const [draft, setDraft] = useState(() => draftOf(task))
  const [saving, setSaving] = useState(false)
  const [commentDirty, setCommentDirty] = useState(false)
  const [closeWarning, setCloseWarning] = useState('')
  const [error, setError] = useState('')
  const [conflict, setConflict] = useState<Task | null>(null)
  const inFlight = useRef(false)
  const dirty =
    draft.title !== draft.savedTitle ||
    draft.notes !== draft.savedNotes ||
    draft.priority !== draft.savedPriority ||
    draft.definitionOfDone !== draft.savedDefinitionOfDone ||
    draft.dueDate !== draft.savedDueDate
  useEffect(() => {
    if (!commentDirty) setCloseWarning('')
  }, [commentDirty])
  useEffect(() => {
    onDirty(dirty || saving || commentDirty)
    return () => onDirty(false)
  }, [dirty, saving, commentDirty, onDirty])
  useEffect(() => {
    if (task.revision <= draft.revision || inFlight.current) return
    if (
      task.title === draft.title.trim() &&
      task.notes === draft.notes &&
      task.priority === draft.priority &&
      task.definitionOfDone === draft.definitionOfDone &&
      task.dueDate === draft.dueDate
    ) {
      setDraft(draftOf(task))
      setConflict(null)
      setError('')
      return
    }
    if (dirty) setConflict(task)
    else {
      setDraft(draftOf(task))
      setConflict(null)
      setError('')
    }
  }, [task, draft, dirty, saving])
  useEffect(() => {
    function escape(event: KeyboardEvent) {
      if (
        document.querySelector('dialog[open]') ||
        (event.target instanceof Element && event.target.closest('.quick-task'))
      )
        return
      if (event.key === 'Escape') {
        event.stopImmediatePropagation()
        event.preventDefault()
        if (commentDirty) setCloseWarning('Post or discard your comment draft before closing.')
        else if (dirty || saving) setError('Your text is still here. Save it before closing.')
        else onClose()
      }
    }
    document.addEventListener('keydown', escape, true)
    return () => document.removeEventListener('keydown', escape, true)
  }, [dirty, saving, commentDirty, onClose])
  useEffect(() => {
    if (!dirty || saving || conflict || error || !draft.title.trim()) return
    const timer = setTimeout(async () => {
      inFlight.current = true
      setSaving(true)
      const title = draft.title,
        notes = draft.notes,
        priority = draft.priority,
        definitionOfDone = draft.definitionOfDone,
        dueDate = draft.dueDate
      try {
        const saved = await onSave(draft.revision, {
          ...(title !== draft.savedTitle ? { title } : {}),
          ...(notes !== draft.savedNotes ? { notes } : {}),
          ...(priority !== draft.savedPriority ? { priority } : {}),
          ...(definitionOfDone !== draft.savedDefinitionOfDone ? { definitionOfDone } : {}),
          ...(dueDate !== draft.savedDueDate ? { dueDate } : {}),
        })
        setDraft((current) => ({
          ...current,
          title: current.title === title ? saved.title : current.title,
          savedTitle: saved.title,
          savedNotes: saved.notes,
          savedPriority: saved.priority,
          savedDefinitionOfDone: saved.definitionOfDone,
          savedDueDate: saved.dueDate,
          revision: saved.revision,
        }))
        setConflict(null)
        setError('')
      } catch (failure) {
        if (failure instanceof SaveError && failure.current) setConflict(failure.current)
        setError(
          failure instanceof Error ? failure.message : 'Could not save. Your text is still here.'
        )
      } finally {
        inFlight.current = false
        setSaving(false)
      }
    }, 250)
    return () => clearTimeout(timer)
  }, [dirty, saving, conflict, error, draft, onSave])
  const siblings = workspace.tasks
    .filter((item) => !item.deleted && item.boardId === task.boardId && item.status === task.status)
    .sort((a, b) => a.position - b.position)
  const index = siblings.findIndex((item) => item.id === task.id)
  const agentRun = workspace.agentRuns.find((run) => run.taskId === task.id)
  const close = () => {
    if (commentDirty) setCloseWarning('Post or discard your comment draft before closing.')
    else if (dirty || saving) setError('Your text is still here. Save it before closing.')
    else onClose()
  }
  return (
    <aside className="task-panel" aria-label="Task details">
      <div className="panel-top">
        <span>Task details</span>
        <button className="icon-button" aria-label="Close task details" onClick={close}>
          <X size={19} />
        </button>
      </div>
      {closeWarning && (
        <p className="error-text" role="alert">
          {closeWarning}
        </p>
      )}
      <textarea
        className="task-title-input"
        aria-label="Task title"
        rows={2}
        maxLength={500}
        value={draft.title}
        onChange={(event) => {
          setDraft((current) => ({ ...current, title: event.target.value }))
          if (!conflict) setError('')
        }}
      />
      {!draft.title.trim() && (
        <p className="error-text">A task needs a title. Your previous saved title is preserved.</p>
      )}
      <div className="task-properties">
        <label htmlFor="task-priority">Priority</label>
        <div className="priority-property">
          <select
            id="task-priority"
            value={draft.priority}
            onChange={(event) => {
              setDraft((current) => ({ ...current, priority: event.target.value as Priority }))
              if (!conflict) setError('')
            }}
          >
            {priorities.map((level) => (
              <option key={level} value={level}>
                {level === 'None' ? 'No priority' : level}
              </option>
            ))}
          </select>
          <PriorityBadge priority={draft.priority} />
        </div>
        <label htmlFor="task-due-date">Due date</label>
        <div className="due-date-property">
          <input
            id="task-due-date"
            type="date"
            value={draft.dueDate || ''}
            onChange={(event) => {
              setDraft((current) => ({ ...current, dueDate: event.target.value || null }))
              if (!conflict) setError('')
            }}
          />
          {draft.dueDate && (
            <button
              className="text-button"
              onClick={() => setDraft((current) => ({ ...current, dueDate: null }))}
            >
              Clear
            </button>
          )}
        </div>
        <label htmlFor="task-status">Status</label>
        <div className="select-wrap">
          <select
            id="task-status"
            disabled={dirty || saving}
            value={task.status}
            onChange={(event) => onMove(task.boardId, event.target.value as Status)}
          >
            {statuses.map((status) => (
              <option key={status}>{status}</option>
            ))}
          </select>
        </div>
        <label htmlFor="task-board">Project</label>
        <div className="select-wrap">
          <select
            id="task-board"
            disabled={dirty || saving}
            value={task.boardId}
            onChange={(event) => onMove(event.target.value, task.status)}
          >
            {workspace.boards.map((board) => (
              <option key={board.id} value={board.id}>
                {board.name}
              </option>
            ))}
          </select>
        </div>
        <span className="field-caption">Position</span>
        <div className="position-buttons">
          <button
            className="icon-button"
            aria-label="Move task earlier"
            disabled={filtered || dirty || saving || index <= 0}
            onClick={() => onMove(task.boardId, task.status, siblings[index - 1]?.id)}
          >
            <ArrowUp size={15} />
          </button>
          <button
            className="icon-button"
            aria-label="Move task later"
            disabled={filtered || dirty || saving || index < 0 || index === siblings.length - 1}
            onClick={() => onMove(task.boardId, task.status, undefined, siblings[index + 1]?.id)}
          >
            <ArrowDown size={15} />
          </button>
          {filtered && (
            <span className="field-caption">Use manual order and clear filters to reorder</span>
          )}
        </div>
      </div>
      <label className="notes-label" htmlFor="definition-of-done">
        Definition of done
      </label>
      <textarea
        id="definition-of-done"
        className="definition-of-done"
        rows={3}
        maxLength={10000}
        placeholder="What must be true before this task is complete?"
        value={draft.definitionOfDone}
        onChange={(event) => {
          setDraft((current) => ({ ...current, definitionOfDone: event.target.value }))
          if (!conflict) setError('')
        }}
      />
      <p className="field-caption">
        Agents must meet these criteria and post proof in Comments before Done. When blank, the
        requested outcome must be complete and verified with concrete evidence.
      </p>
      {!workspace.agentAssignments[task.id] && (
        <p className="field-caption">
          Manual task · Move to Sent to agent only when you want agent help.
        </p>
      )}
      {agentRun && (
        <>
          <p className="field-caption">
            {workspace.agentAssignments[task.id] ? 'Agent run' : 'Previous agent run'}
          </p>
          <AgentRunDetails key={agentRun.id} run={agentRun} />
        </>
      )}
      <label className="notes-label" htmlFor="task-notes">
        <FileText size={15} /> Notes
      </label>
      <textarea
        id="task-notes"
        className="task-notes"
        maxLength={100000}
        placeholder="A little context, if you need it…"
        value={draft.notes}
        onChange={(event) => {
          setDraft((current) => ({ ...current, notes: event.target.value }))
          if (!conflict) setError('')
        }}
      />
      {conflict && (
        <div className="conflict-message" role="alert">
          <strong>This task changed elsewhere.</strong>
          <p>Your text has been kept. Saved title: {conflict.title}</p>
          <details>
            <summary>View saved notes</summary>
            <pre>{conflict.notes || 'No notes'}</pre>
          </details>
          <div className="settings-actions">
            <button
              className="secondary-button"
              onClick={() => {
                setDraft(draftOf(conflict))
                setConflict(null)
                setError('')
              }}
            >
              Use saved version
            </button>
            <button
              className="secondary-button"
              onClick={() => {
                setDraft((current) => ({
                  ...current,
                  savedTitle: conflict.title,
                  savedNotes: conflict.notes,
                  savedPriority: conflict.priority,
                  savedDefinitionOfDone: conflict.definitionOfDone,
                  savedDueDate: conflict.dueDate,
                  revision: conflict.revision,
                }))
                setConflict(null)
                setError('')
              }}
            >
              Save my text
            </button>
          </div>
        </div>
      )}
      {error && !conflict && (
        <div role="alert">
          <p className="error-text">{error}</p>
          <button className="text-button" onClick={() => setError('')}>
            Retry save
          </button>
          <button
            className="text-button discard-edit"
            onClick={() => {
              setDraft(draftOf(task))
              setError('')
            }}
          >
            Use saved text
          </button>
        </div>
      )}
      <TaskComments
        key={task.id}
        taskId={task.id}
        revision={workspace.revision}
        inProgress={task.status === 'In progress'}
        agentAssigned={!!workspace.agentAssignments[task.id]}
        onDirty={setCommentDirty}
      />
      <div className="panel-footer">
        <span className="saved-label" role="status">
          {saving ? (
            'Saving…'
          ) : dirty ? (
            'Unsaved changes'
          ) : (
            <>
              <Check size={13} /> Saved
            </>
          )}
        </span>
        <button
          className="text-button delete-task"
          disabled={dirty || saving || commentDirty}
          onClick={onTrash}
        >
          <Trash2 size={14} /> Delete task
        </button>
      </div>
    </aside>
  )
}
