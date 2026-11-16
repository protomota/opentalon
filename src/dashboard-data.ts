import { priorities, statuses, type Board, type Task } from './model.ts'
export type AttentionFilter = 'all' | 'critical' | 'today' | 'overdue'
export function dashboardData(boards: Board[], tasks: Task[], today: string, boardId = '') {
  const active = tasks.filter((task) => !task.deleted && (!boardId || task.boardId === boardId))
  const open = active.filter((task) => task.status !== 'Done')
  const critical = (task: Task) => task.priority === 'Urgent' || task.priority === 'High'
  const dueToday = (task: Task) => task.dueDate === today
  const overdue = (task: Task) => !!task.dueDate && task.dueDate < today
  const matching = (task: Task, filter: AttentionFilter) =>
    filter === 'critical'
      ? critical(task)
      : filter === 'today'
        ? dueToday(task)
        : filter === 'overdue'
          ? overdue(task)
          : critical(task) || dueToday(task) || overdue(task)
  const attention = (filter: AttentionFilter) =>
    open
      .filter((task) => matching(task, filter))
      .sort(
        (a, b) =>
          priorities.indexOf(a.priority) - priorities.indexOf(b.priority) ||
          (a.dueDate || '9999').localeCompare(b.dueDate || '9999') ||
          a.position - b.position ||
          a.id.localeCompare(b.id)
      )
  const done = active.length - open.length
  return {
    open: open.length,
    critical: open.filter(critical).length,
    today: open.filter(dueToday).length,
    overdue: open.filter(overdue).length,
    done,
    total: active.length,
    completion: active.length ? Math.round((done / active.length) * 100) : 0,
    attention,
    boards: boards
      .filter((board) => !boardId || board.id === boardId)
      .map((board) => {
        const items = active.filter((task) => task.boardId === board.id)
        const counts = Object.fromEntries(
          statuses.map((status) => [status, items.filter((task) => task.status === status).length])
        ) as Record<Task['status'], number>
        return {
          board,
          total: items.length,
          counts,
          completion: items.length ? Math.round((counts.Done / items.length) * 100) : 0,
        }
      }),
  }
}
