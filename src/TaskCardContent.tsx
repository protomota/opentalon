import { CalendarDays, MessageSquare, Paperclip, GripVertical } from 'lucide-react'
import { agentNames, type AgentRun, type Priority, type Task } from './model'
import { dueDatePresentation, notesPreview } from './task-view'

export function PriorityBadge({ priority }: { priority: Priority }) {
  return (
    <span className={`priority-badge priority-${priority.toLowerCase()}`}>
      <span className="priority-symbol" aria-hidden="true">
        {priority === 'Urgent'
          ? '!'
          : priority === 'None'
            ? '—'
            : priority === 'High'
              ? '▰▰▰'
              : priority === 'Medium'
                ? '▰▰'
                : '▰'}
      </span>
      {priority === 'None' ? 'No priority' : priority}
    </span>
  )
}
export function TaskCardContent({
  task,
  run,
  today,
  projectName,
}: {
  task: Task
  run?: AgentRun
  today: string
  projectName?: string
}) {
  const preview = notesPreview(task.notes)
  const source = task.notes.startsWith('Imported from Daily Brief\n') ? 'Daily Brief' : null
  const context = projectName || source
  const due = dueDatePresentation(task.dueDate, today)
  return (
    <span className="card-content">
      <span className="card-topline">
        <PriorityBadge priority={task.priority} />
        {context && (
          <span className="card-source" title={context}>
            {context}
          </span>
        )}
      </span>
      <span className="card-title">{task.title}</span>
      <span className="card-description">{preview || 'No notes yet'}</span>
      <span className="card-metadata">
        <GripVertical className="card-drag-handle" size={13} aria-hidden="true" />
        <span
          className={due.overdue ? 'card-due-date due-date-red' : 'card-due-date'}
          title={due.title}
        >
          <CalendarDays size={12} />
          <span>{due.text}</span>
        </span>
        {task.commentCount > 0 && (
          <span title={`${task.commentCount} comments`}>
            <MessageSquare size={12} />
            {task.commentCount}
          </span>
        )}
        {task.imageCount > 0 && (
          <span title={`${task.imageCount} screenshots`}>
            <Paperclip size={12} />
            {task.imageCount}
          </span>
        )}
        <span
          className="card-tracking"
          title={
            run
              ? `${agentNames[run.agent]}: ${run.state}`
              : 'Tracked manually'
          }
        >
          {run ? agentNames[run.agent] : 'Manual'}
        </span>
      </span>
      {run && (
        <span className="card-agent-state">
          {run.state === 'needs-input'
            ? 'Needs input'
            : run.state === 'review'
              ? 'Review result'
              : run.state}
        </span>
      )}
    </span>
  )
}
