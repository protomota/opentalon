import { priorities, type Priority, type Task } from './model.ts'

export type BoardSort = 'manual' | 'priority-desc' | 'priority-asc'
export type PriorityFilter = 'All' | Priority
export interface BoardView {
  priority: PriorityFilter
  sort: BoardSort
}
export const defaultBoardView: BoardView = { priority: 'All', sort: 'manual' }
export const boardViewsKey = 'opentalon-board-views-v1'
export function localDateKey(date = new Date()): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}
export function dueDatePresentation(dueDate: string | null, today: string) {
  if (!dueDate) return { text: 'No due date', overdue: false, title: 'No due date set' }
  const label = new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
    ...(dueDate.slice(0, 4) !== today.slice(0, 4) ? { year: 'numeric' as const } : {}),
  }).format(new Date(`${dueDate}T12:00:00`))
  return {
    text: dueDate === today ? 'Due today' : dueDate < today ? `Overdue · ${label}` : `Due ${label}`,
    overdue: dueDate <= today,
    title: `Due ${dueDate}${dueDate < today ? ' (overdue)' : dueDate === today ? ' (today)' : ''}`,
  }
}
export type DropEdge = 'before' | 'after'
type ViewBounds = { left: number; top: number; right: number; bottom: number }
export function dropPreviewBounds(column: ViewBounds, viewport: ViewBounds) {
  const left = Math.max(column.left, viewport.left) + 5
  const top = Math.max(column.top, viewport.top) + 5
  const right = Math.min(column.right, viewport.right) - 5
  const bottom = Math.min(column.bottom, viewport.bottom) - 5
  return right > left && bottom > top
    ? { left, top, width: right - left, height: bottom - top }
    : null
}
export function dropEdge(y: number, top: number, height: number): DropEdge {
  return y < top + height / 2 ? 'before' : 'after'
}
export function reorderTaskIds(
  tasks: Task[],
  draggedId: string,
  anchorId?: string,
  edge: DropEdge = 'before'
): string[] {
  const ids = tasks.map((task) => task.id)
  if (!ids.includes(draggedId) || anchorId === draggedId) return ids
  const remaining = ids.filter((id) => id !== draggedId)
  const anchor = anchorId ? remaining.indexOf(anchorId) : -1
  remaining.splice(
    anchor < 0 ? remaining.length : anchor + (edge === 'after' ? 1 : 0),
    0,
    draggedId
  )
  return remaining
}
export function readBoardViews(raw: string | null): Record<string, BoardView> {
  try {
    const parsed: unknown = JSON.parse(raw || '{}')
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {}
    return Object.fromEntries(
      Object.entries(parsed as Record<string, unknown>).filter(
        (entry): entry is [string, BoardView] => {
          const value = entry[1]
          if (!value || typeof value !== 'object') return false
          const view = value as Record<string, unknown>
          return (
            typeof view.priority === 'string' &&
            ['All', ...priorities].includes(view.priority) &&
            typeof view.sort === 'string' &&
            ['manual', 'priority-desc', 'priority-asc'].includes(view.sort)
          )
        }
      )
    )
  } catch {
    return {}
  }
}
// One column of the All tasks view. The saved global order decides which project fills each
// slot; each project then fills its own slots in its board order, so a reorder made on a project
// board shows up here without rewriting the global order. Unknown ids are ignored and tasks the
// global order has not seen yet go last, in project order.
export function orderAllTasks(
  tasks: Task[],
  projectOrder: ReadonlyMap<string, number>,
  globalOrder: readonly string[]
): Task[] {
  const byProjectPosition = (a: Task, b: Task) =>
    a.position - b.position || a.id.localeCompare(b.id)
  const ordered: Task[] = []
  for (const status of new Set(tasks.map((task) => task.status))) {
    const column = tasks.filter((task) => task.status === status)
    const byId = new Map(column.map((task) => [task.id, task]))
    const placed = new Set<string>()
    const slots: Task[] = []
    for (const id of globalOrder) {
      const task = byId.get(id)
      if (task && !placed.has(id)) {
        placed.add(id)
        slots.push(task)
      }
    }
    slots.push(
      ...column
        .filter((task) => !placed.has(task.id))
        .sort(
          (a, b) =>
            (projectOrder.get(a.boardId) ?? Infinity) - (projectOrder.get(b.boardId) ?? Infinity) ||
            a.boardId.localeCompare(b.boardId) ||
            byProjectPosition(a, b)
        )
    )
    const queues = new Map<string, Task[]>()
    for (const task of [...column].sort(byProjectPosition))
      queues.set(task.boardId, [...(queues.get(task.boardId) || []), task])
    for (const slot of slots) ordered.push(queues.get(slot.boardId)!.shift()!)
  }
  return ordered
}
export function selectTasks(
  tasks: Task[],
  query: string,
  view: BoardView,
  taskOrder?: ReadonlyMap<string, number>
): Task[] {
  const needle = query.trim().toLowerCase()
  return tasks
    .filter(
      (task) =>
        (view.priority === 'All' || task.priority === view.priority) &&
        `${task.title}\n${task.notes}`.toLowerCase().includes(needle)
    )
    .sort((a, b) => {
      if (view.sort !== 'manual') {
        const rank = (priority: Priority) =>
          priority === 'None'
            ? 4
            : view.sort === 'priority-asc'
              ? 3 - priorities.indexOf(priority)
              : priorities.indexOf(priority)
        const difference = rank(a.priority) - rank(b.priority)
        if (difference) return difference
      }
      if (taskOrder) {
        const difference = (taskOrder.get(a.id) ?? Infinity) - (taskOrder.get(b.id) ?? Infinity)
        if (difference) return difference
      }
      return a.position - b.position || a.id.localeCompare(b.id)
    })
}
export function notesPreview(notes: string): string {
  const content = notes.startsWith('Imported from Daily Brief\n')
    ? notes
        .split('\n\n')
        .slice(1)
        .join('\n\n')
        .split('Original Daily Brief action (complete source record):')[0]
    : notes
  return content.replace(/\s+/g, ' ').trim().slice(0, 220)
}
