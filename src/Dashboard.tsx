import { useRef, useState } from 'react'
import {
  ArrowUpRight,
  CalendarDays,
  Check,
  ChevronDown,
  Circle,
  CircleDashed,
  Send,
  Trash2,
} from 'lucide-react'
import { priorities, statuses, type Priority, type Task, type Workspace } from './model'
import { dueDatePresentation } from './task-view'
import { BoardIcon } from './BoardIcon'
import { dashboardData, type AttentionFilter } from './dashboard-data'

export function Dashboard({
  workspace,
  today,
  onTask,
  onBoard,
  onUpdate,
  onIgnore,
  onRestore,
}: {
  workspace: Workspace
  today: string
  onTask: (task: Task) => void
  onBoard: (id: string) => void
  onUpdate: (task: Task, patch: { priority?: Priority; status?: 'Done' }) => Promise<Task>
  onIgnore: (task: Task) => Promise<Task>
  onRestore: (task: Task) => Promise<Task>
}) {
  const [boardId, setBoardId] = useState('')
  const [filter, setFilter] = useState<AttentionFilter>('all')
  const [visibleCount, setVisibleCount] = useState(6)
  const [busy, setBusy] = useState(false)
  const pending = useRef(false)
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const [undoTask, setUndoTask] = useState<Task | null>(null)
  function chooseFilter(next: AttentionFilter) {
    setFilter(next)
    setVisibleCount(6)
  }
  async function perform(operation: () => Promise<void>) {
    if (pending.current) return
    pending.current = true
    setBusy(true)
    setError('')
    setNotice('')
    setUndoTask(null)
    try {
      await operation()
    } catch (error) {
      setError(error instanceof Error ? error.message : 'Could not save this change.')
    } finally {
      pending.current = false
      setBusy(false)
    }
  }
  const data = dashboardData(workspace.boards, workspace.tasks, today, boardId)
  const attention = data.attention(filter)
  const filters: { id: AttentionFilter; label: string; count: number; hint: string }[] = [
    {
      id: 'all',
      label: 'All',
      count: data.attention('all').length,
      hint: 'Everything below, counted once',
    },
    { id: 'overdue', label: 'Overdue', count: data.overdue, hint: 'Past the due date' },
    { id: 'today', label: 'Due today', count: data.today, hint: 'Due before tomorrow' },
    { id: 'critical', label: 'Critical', count: data.critical, hint: 'Urgent or High priority' },
  ]
  const flow = statuses.map((status) => ({
    status,
    slug: status.toLowerCase().replace(/ /g, '-'),
    count: data.boards.reduce((sum, item) => sum + item.counts[status], 0),
  }))
  const scope = workspace.boards.find((board) => board.id === boardId)
  return (
    <div className="dashboard">
      <header className="dashboard-header">
        <div>
          <p className="dashboard-date">
            {new Intl.DateTimeFormat(undefined, {
              weekday: 'long',
              month: 'long',
              day: 'numeric',
            }).format(new Date(`${today}T12:00:00`))}
          </p>
          <h1>Your day, at a glance.</h1>
          <p>
            {scope
              ? `What needs your attention on ${scope.name}.`
              : 'What needs your attention across all your projects.'}
          </p>
        </div>
        <label className="dashboard-board-filter">
          Project
          <select
            aria-label="Dashboard project"
            value={boardId}
            onChange={(event) => {
              setBoardId(event.target.value)
              setVisibleCount(6)
            }}
          >
            <option value="">All projects</option>
            {workspace.boards.map((board) => (
              <option key={board.id} value={board.id}>
                {board.name}
              </option>
            ))}
          </select>
        </label>
      </header>
      <section className="dashboard-overview" aria-label="Task overview">
        <div className="dashboard-overview-figure" aria-label={`Open tasks: ${data.open}`}>
          <strong>{data.open}</strong>
          <span>open {data.open === 1 ? 'task' : 'tasks'}</span>
        </div>
        <div className="dashboard-flow">
          <div
            className="dashboard-flow-bar"
            role="img"
            aria-label={`Tasks by status: ${flow.map((item) => `${item.status} ${item.count}`).join(', ')}`}
          >
            {flow.map(
              (item) =>
                item.count > 0 && (
                  <span
                    key={item.status}
                    className={`flow-${item.slug}`}
                    style={{ flexGrow: item.count }}
                  />
                )
            )}
          </div>
          <dl className="dashboard-flow-legend">
            {flow.map((item) => (
              <div key={item.status} aria-label={`${item.status}: ${item.count}`}>
                <dt>
                  <i className={`flow-${item.slug}`} aria-hidden="true" />
                  {item.status}
                </dt>
                <dd>{item.count}</dd>
              </div>
            ))}
            <div
              className="dashboard-flow-completion"
              aria-label={`Completion: ${data.completion}%`}
            >
              <dt>Completion</dt>
              <dd>{data.completion}%</dd>
            </div>
          </dl>
        </div>
      </section>
      <section className="dashboard-attention" aria-label="Tasks needing attention">
        <div className="dashboard-section-heading">
          <div>
            <h2>Needs attention</h2>
            <p>Critical means Urgent or High. Completed and trashed tasks are excluded.</p>
          </div>
        </div>
        <div className="dashboard-attention-card">
          <div className="dashboard-filters" role="group" aria-label="Attention filter">
            {filters.map((item) => (
              <button
                key={item.id}
                className={`${item.id === 'overdue' && item.count ? 'is-overdue' : ''} ${item.count ? '' : 'is-zero'}`}
                aria-pressed={filter === item.id}
                aria-label={`${item.label}: ${item.count}`}
                title={item.hint}
                onClick={() => chooseFilter(item.id)}
              >
                <strong>{item.count}</strong>
                <span>{item.label}</span>
              </button>
            ))}
          </div>
          {error && (
            <p className="dashboard-feedback error-text" role="alert">
              {error}
            </p>
          )}
          {notice && (
            <div className="dashboard-feedback" role="status">
              <span>{notice}</span>
              {undoTask && (
                <button
                  className="text-button"
                  disabled={busy}
                  onClick={() =>
                    void perform(async () => {
                      await onRestore(undoTask)
                      setNotice(`Restored “${undoTask.title}”.`)
                    })
                  }
                >
                  Undo
                </button>
              )}
            </div>
          )}
          {attention.length ? (
            <>
              <ul className="dashboard-task-list" aria-label="Attention tasks" aria-busy={busy}>
                {attention.slice(0, visibleCount).map((task) => {
                  const due = dueDatePresentation(task.dueDate, today)
                  const assigned = !!workspace.agentAssignments[task.id]
                  const StatusIcon =
                    task.status === 'Sent to agent'
                      ? Send
                      : task.status === 'In progress'
                        ? CircleDashed
                        : Circle
                  return (
                    <li className="dashboard-task-row" key={task.id}>
                      <button
                        className="dashboard-task-open"
                        disabled={busy}
                        aria-label={`Open ${task.title}`}
                        onClick={() => onTask(task)}
                      >
                        <StatusIcon
                          className="dashboard-task-status"
                          size={17}
                          strokeWidth={1.5}
                          aria-hidden="true"
                        />
                        <span className="dashboard-task-title">
                          <strong>{task.title}</strong>
                          <span className="dashboard-task-context">
                            <span>
                              {workspace.boards.find((board) => board.id === task.boardId)?.name}
                            </span>
                            <span>{task.status}</span>
                            {assigned && <span>Agent task</span>}
                          </span>
                        </span>
                        {task.dueDate && (
                          <span className={`dashboard-due ${due.overdue ? 'is-overdue' : ''}`}>
                            <CalendarDays size={13} />
                            {due.text}
                          </span>
                        )}
                        <ArrowUpRight
                          className="dashboard-open-arrow"
                          size={15}
                          aria-hidden="true"
                        />
                      </button>
                      <div className="dashboard-task-actions">
                        <span className="dashboard-priority-picker">
                          <select
                            className={`dashboard-priority priority-${task.priority.toLowerCase()}`}
                            aria-label={`Priority for ${task.title}`}
                            value={task.priority}
                            disabled={busy}
                            onChange={(event) => {
                              const priority = event.target.value as Priority
                              void perform(async () => {
                                await onUpdate(task, { priority })
                                setNotice(
                                  `Priority changed to ${priority === 'None' ? 'No priority' : priority}.`
                                )
                              })
                            }}
                          >
                            {priorities.map((priority) => (
                              <option key={priority} value={priority}>
                                {priority === 'None' ? 'No priority' : priority}
                              </option>
                            ))}
                          </select>
                          <ChevronDown size={11} aria-hidden="true" />
                        </span>
                        {assigned ? (
                          <button
                            className="dashboard-quick-action"
                            disabled={busy}
                            onClick={() => onTask(task)}
                            title="Review this agent’s completion proof in the task"
                          >
                            Review
                          </button>
                        ) : (
                          <button
                            className="dashboard-quick-action dashboard-complete"
                            disabled={busy}
                            aria-label={`Complete ${task.title}`}
                            onClick={() =>
                              void perform(async () => {
                                await onUpdate(task, { status: 'Done' })
                                setNotice(`Completed “${task.title}”.`)
                              })
                            }
                          >
                            <Check size={14} />
                            Complete
                          </button>
                        )}
                        <button
                          className="dashboard-quick-action dashboard-ignore"
                          disabled={busy}
                          aria-label={`Ignore ${task.title}`}
                          title={
                            assigned
                              ? 'Move to Trash and stop the agent run'
                              : 'Ignore: move to recoverable Trash'
                          }
                          onClick={() =>
                            void perform(async () => {
                              const trashed = await onIgnore(task)
                              setUndoTask(trashed)
                              setNotice(`Moved “${task.title}” to Trash.`)
                            })
                          }
                        >
                          <Trash2 size={14} />
                        </button>
                      </div>
                    </li>
                  )
                })}
              </ul>
              <div className="dashboard-list-footer">
                <span>Ignore moves a task to Trash. You can restore it later.</span>
                {visibleCount < attention.length ? (
                  <button
                    className="text-button"
                    onClick={() => setVisibleCount((count) => count + 6)}
                  >
                    Show more <span>({attention.length - visibleCount})</span>
                  </button>
                ) : (
                  visibleCount > 6 && (
                    <button className="text-button" onClick={() => setVisibleCount(6)}>
                      Show fewer
                    </button>
                  )
                )}
              </div>
            </>
          ) : (
            <div className="dashboard-empty">
              <strong>Nothing needs your attention here.</strong>
              <p>
                {filter === 'today'
                  ? 'No open tasks are due today.'
                  : filter === 'overdue'
                    ? 'No open tasks are overdue.'
                    : filter === 'critical'
                      ? 'No open Urgent or High tasks.'
                      : 'No critical, due-today or overdue tasks.'}
              </p>
            </div>
          )}
        </div>
      </section>
      <section className="dashboard-boards" aria-label="Project analytics">
        <div className="dashboard-section-heading">
          <div>
            <h2>Project overview</h2>
            <p>{data.total} current tasks · completion is Done divided by total tasks.</p>
          </div>
        </div>
        <div className="dashboard-table-wrap">
          <table>
            <thead>
              <tr>
                <th>Project</th>
                <th className="is-number">Tasks</th>
                <th>Status mix</th>
                {statuses.map((status) => (
                  <th key={status} className="is-number">
                    {status}
                  </th>
                ))}
                <th className="is-number">Completion</th>
              </tr>
            </thead>
            <tbody>
              {data.boards.map(({ board, total, counts, completion }) => (
                <tr key={board.id}>
                  <th>
                    <button className="text-button" onClick={() => onBoard(board.id)}>
                      <BoardIcon icon={board.icon} size={15} />
                      {board.name} <ArrowUpRight size={12} />
                    </button>
                  </th>
                  <td className={`is-number ${total ? '' : 'is-zero'}`}>{total}</td>
                  <td className="dashboard-mix">
                    <div
                      className="dashboard-flow-bar"
                      role="img"
                      aria-label={`${board.name} status mix: ${statuses.map((status) => `${status} ${counts[status]}`).join(', ')}`}
                    >
                      {statuses.map(
                        (status) =>
                          counts[status] > 0 && (
                            <span
                              key={status}
                              className={`flow-${status.toLowerCase().replace(/ /g, '-')}`}
                              style={{ flexGrow: counts[status] }}
                            />
                          )
                      )}
                    </div>
                  </td>
                  {statuses.map((status) => (
                    <td key={status} className={`is-number ${counts[status] ? '' : 'is-zero'}`}>
                      {counts[status]}
                    </td>
                  ))}
                  <td className={`is-number ${total ? '' : 'is-zero'}`}>{completion}%</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}
