const test = require('node:test')
const assert = require('node:assert/strict')
test('dashboard attention excludes Done and Trash, deduplicates overlapping reasons and scopes board analytics', async () => {
  const { dashboardData } = await import('../src/dashboard-data.ts')
  const boards = [
    { id: 'a', name: 'One' },
    { id: 'b', name: 'Two' },
    { id: 'empty', name: 'Empty' },
  ]
  const task = (id, patch = {}) => ({
    id,
    boardId: 'a',
    status: 'To do',
    priority: 'Medium',
    dueDate: null,
    deleted: false,
    position: 0,
    ...patch,
  })
  const tasks = [
    task('urgent', { priority: 'Urgent', dueDate: '2026-11-10' }),
    task('high', { priority: 'High', dueDate: '2026-11-09', status: 'In progress' }),
    task('today', { dueDate: '2026-11-10', boardId: 'b' }),
    task('done', { priority: 'Urgent', dueDate: '2026-11-09', status: 'Done' }),
    task('trash', { priority: 'High', dueDate: '2026-11-10', deleted: true }),
    task('queued', { status: 'Sent to agent' }),
    task('future', { dueDate: '2026-11-11' }),
  ]
  const data = dashboardData(boards, tasks, '2026-11-10')
  assert.deepEqual(
    [data.open, data.critical, data.today, data.overdue, data.done, data.total, data.completion],
    [5, 2, 2, 1, 1, 6, 17]
  )
  assert.deepEqual(
    data.attention('all').map((t) => t.id),
    ['urgent', 'high', 'today']
  )
  assert.equal(data.attention('critical').length, 2)
  assert.equal(data.attention('today').length, 2)
  assert.equal(data.attention('overdue')[0].id, 'high')
  assert.deepEqual(data.boards[0].counts, {
    'To do': 2,
    'Sent to agent': 1,
    'In progress': 1,
    Done: 1,
  })
  assert.equal(data.boards[0].completion, 20)
  assert.equal(data.boards[2].completion, 0)
  assert.equal(dashboardData(boards, tasks, '2026-11-11').today, 1)
  const scoped = dashboardData(boards, tasks, '2026-11-10', 'b')
  assert.equal(scoped.boards.length, 1)
  assert.equal(scoped.total, 1)
  assert.equal(scoped.critical, 0)
  assert.deepEqual(
    scoped.attention('all').map((t) => t.id),
    ['today']
  )
})
