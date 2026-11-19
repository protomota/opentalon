const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { DatabaseSync } = require('node:sqlite')
const { Store, FORMAT } = require('./store.cjs')
const { AgentRunner } = require('./agent-runner.cjs')
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'
fs.mkdirSync(base, { recursive: true })
test('stopping a queued task leaves the active task connected; late process exits are harmless', async (t) => {
  const f = fixture(t)
  await f.settings('codex')
  const first = await f.task('Keep running'),
    second = await f.task('Cancel queued')
  await f.send(first)
  await f.runner.tick()
  const current = f.runner.current
  await f.send(second)
  const queued = f.store.agentJobs()[0]
  await f.runner.stop(queued.id)
  assert.equal(f.runner.current, current)
  assert.equal(f.launched[0].closed, false)
  const completed = f.store.agentJob(current.job.id)
  await f.runner.finish(completed.id, 'review', 'Finished')
  await f.launched[0].exit(new Error('Late exit'))
  assert.equal(f.store.agentJob(completed.id).state, 'review')
})
function fixture(t, { projectApiUnavailable = false, projectPageSize = 100 } = {}) {
  const folder = fs.mkdtempSync(path.join(base, 'agent-'))
  const store = new Store(folder)
  const launched = []
  const opened = []
  const projects = []
  const runner = new AgentRunner({
    store,
    connector: {
      status: () => ({ running: true }),
      configuration: () => ({
        mcpServers: {
          opentalon: {
            command: '/safe/app',
            args: ['/bridge.cjs'],
            env: { ELECTRON_RUN_AS_NODE: '1' },
          },
        },
      }),
    },
    openExternal: (url) => opened.push(url),
    resolveExecutable: (agent) => '/safe/' + agent,
    spawnTransport(file, args, cwd, message, exit) {
      const entry = {
        file,
        args,
        cwd,
        message,
        exit,
        written: [],
        closed: false,
        async request(method, params) {
          entry.written.push({ method, params })
          if (method === 'project/list') {
            if (projectApiUnavailable)
              throw Object.assign(new Error('Method not found'), { code: -32601 })
            const start = Number(params.cursor ?? 0)
            const end = start + projectPageSize
            return { data: projects.slice(start, end), nextCursor: end < projects.length ? String(end) : null }
          }
          if (method === 'project/create') {
            const project = { id: randomUUID(), roots: params.roots }
            projects.push(project)
            return { project }
          }
          if (method === 'thread/start') {
            return { thread: { id: randomUUID(), projectId: params.projectId } }
          }
          return {}
        },
        write(message) {
          entry.written.push(message)
        },
        close() {
          entry.closed = true
        },
      }
      launched.push(entry)
      return entry
    },
  })
  t.after(async () => {
    await runner.close()
    store.close()
    fs.rmSync(folder, { recursive: true, force: true })
  })
  const write = (name, input) => store.dispatch(name, { ...input, requestKey: randomUUID() })
  const settings = (defaultAgent, permissionMode) =>
    write('set_agent_settings', {
      defaultAgent,
      workingFolder: folder,
      ...(permissionMode === undefined ? {} : { permissionMode }),
    })
  const task = (title) =>
    write('create_task', { boardId: store.boards()[0].id, title }).then((result) => result.task)
  const send = (task) =>
    write('move_task', {
      id: task.id,
      expectedRevision: store.task(task.id).revision,
      status: 'Sent to agent',
    })
  return { folder, store, runner, launched, opened, projects, write, settings, task, send }
}
test('new Codex tasks share the local project for their selected folder across launches', async (t) => {
  const f = fixture(t, { projectPageSize: 1 })
  f.projects.push({ id: randomUUID(), roots: [{ path: path.dirname(f.folder) }] })
  await f.settings('codex')

  async function launch(title) {
    await f.send(await f.task(title))
    await f.runner.tick()
    const calls = f.launched.at(-1).written
    const { threadId } = f.runner.current.job
    await f.runner.stop(f.runner.current.job.id)
    return { calls, threadId, start: calls.find(({ method }) => method === 'thread/start').params }
  }

  const first = await launch('First task in the shared project')
  const second = await launch('Another task in the shared project')
  assert.notEqual(first.threadId, second.threadId)
  const creation = first.calls.find(({ method }) => method === 'project/create')
  assert.equal(creation.params.name, 'OpenTalon')
  assert.match(creation.params.idempotencyKey, /^opentalon:[a-f0-9]{64}$/)
  assert.equal(second.calls.filter(({ method }) => method === 'project/list').length, 2)
  assert.ok(!second.calls.some(({ method }) => method === 'project/create'))
  for (const launch of [first, second]) {
    assert.equal(launch.start.projectId, f.projects[1].id)
    assert.equal(launch.start.cwd, fs.realpathSync(f.folder))
    assert.deepEqual(launch.start.runtimeWorkspaceRoots, [launch.start.cwd])
    assert.equal(launch.start.ephemeral, false)
  }
})
test('older Codex launchers still start saved tasks in the selected folder', async (t) => {
  const f = fixture(t, { projectApiUnavailable: true })
  await f.settings('codex')
  await f.send(await f.task('Open a saved chat with an older launcher'))
  await f.runner.tick()
  const start = f.launched[0].written.find(({ method }) => method === 'thread/start').params
  assert.equal(start.cwd, fs.realpathSync(f.folder))
  assert.equal(start.ephemeral, false)
  assert.equal(start.projectId, undefined)
})
test('explicit models are bound to the chosen agent and passed to both runtimes', async (t) => {
  const f = fixture(t)
  await f.settings('codex')
  const claudeTask = await f.task('Use a chosen Claude model')
  const move = { id: claudeTask.id, expectedRevision: claudeTask.revision, status: 'Sent to agent' }
  await assert.rejects(f.write('move_task', { ...move, agent: 'codex', model: 'claude-fable-5-2' }), {
    code: 'INVALID_ARGUMENT',
  })
  assert.equal(f.store.task(claudeTask.id).status, 'To do')
  await f.write('move_task', { ...move, agent: 'claude-code', model: 'claude-fable-5-2' })
  assert.equal(f.store.agentJobs()[0].model, 'claude-fable-5-2')
  await f.runner.tick()
  const args = f.launched[0].args
  assert.equal(args[args.indexOf('--model') + 1], 'claude-fable-5-2')
  await f.runner.finish(f.store.agentJobs()[0].id, 'review', 'Finished')

  await f.write('create_task', {
    boardId: f.store.boards()[0].id,
    title: 'Use a chosen Codex model',
    status: 'Sent to agent',
    agent: 'codex',
    model: 'gpt-6.1-sol',
  })
  assert.equal(f.store.agentJobs()[0].model, 'gpt-6.1-sol')
  await f.runner.tick()
  assert.equal(f.launched[1].written.find(({ method }) => method === 'turn/start').params.model, 'gpt-6.1-sol')
})
test('dispatch saves the initial comment once and passes it to the chosen agent', async (t) => {
  const f = fixture(t)
  assert.equal(f.store.agentSettings().defaultAgent, 'codex')
  await f.settings('codex')
  const task = await f.task('Review the sync screenshots')
  const input = {
    id: task.id,
    expectedRevision: task.revision,
    status: 'Sent to agent',
    agent: 'claude-code',
    model: 'claude-sonnet-5-5',
    dispatchComment: 'Compare timestamps on both devices.',
    requestKey: randomUUID(),
  }
  await assert.rejects(f.store.dispatch('move_task', { ...input, status: 'In progress' }), {
    code: 'INVALID_ARGUMENT',
  })
  assert.equal(f.store.comments(task.id).length, 0)
  const sent = await f.store.dispatch('move_task', input)
  assert.deepEqual(await f.store.dispatch('move_task', input), sent)
  assert.equal(f.store.comments(task.id).length, 1)
  assert.equal(f.store.agentJobs().length, 1)
  await f.runner.tick()
  const claude = f.launched[0]
  assert.ok(!claude.args.includes('--no-session-persistence'))
  const message = claude.written.find(({ type }) => type === 'user')
  assert.ok(message.message.content[0].text.includes(input.dispatchComment))
  const firstJob = f.store.agentJobs()[0]
  assert.equal(f.store.comments(task.id)[0].delivery, 'queued')
  await claude.message({ type: 'system', subtype: 'init', session_id: firstJob.threadId })
  assert.equal(f.store.comments(task.id)[0].pickedUpAt, f.store.agentJob(firstJob.id).pickedUpAt)
  assert.equal(f.store.task(task.id).status, 'In progress')
  await f.runner.finish(f.store.agentJobs()[0].id, 'review', 'Finished')

  const created = await f.write('create_task', {
    boardId: f.store.boards()[0].id,
    title: 'Check the date picker',
    status: 'Sent to agent',
    dispatchComment: 'Check the unset date as well.',
  })
  assert.equal(f.store.comments(created.task.id)[0].text, 'Check the unset date as well.')
  await f.runner.tick()
  const codex = f.launched[1]
  assert.equal(codex.written.find(({ method }) => method === 'thread/start').params.ephemeral, false)
  assert.ok(codex.written.find(({ method }) => method === 'turn/start').params.input[0].text.includes('Check the unset date as well.'))
})
test('To do, In progress and Done are manual by default; only Sent to agent opts in', async (t) => {
  const f = fixture(t)
  for (const status of ['To do', 'In progress', 'Done']) {
    let task = (
      await f.write('create_task', {
        boardId: f.store.boards()[0].id,
        title: `Manual ${status}`,
        status,
      })
    ).task
    assert.equal(f.store.assignedRun(task.id), null)
    for (const next of ['In progress', 'Done', 'To do']) {
      task = (
        await f.write('move_task', { id: task.id, expectedRevision: task.revision, status: next })
      ).task
      assert.equal(f.store.assignedRun(task.id), null)
    }
    await f.write('add_task_comment', {
      taskId: task.id,
      text: 'A note for myself.',
      notifyAgent: true,
    })
  }
  await f.settings('codex')
  await f.store.queueCommentFollowups()
  await f.runner.tick()
  assert.equal(f.launched.length, 0)
  assert.equal(f.store.agentJobs().length, 0)
  const task = await f.task('Agent help only when I request it')
  await f.send(task)
  const job = f.store.agentJobs()[0]
  assert.equal(f.store.assignedRun(task.id), job.id)
  await f.runner.tick()
  await f.launched[0].message({ method: 'turn/started', params: { threadId: job.threadId } })
  assert.equal(f.store.task(task.id).status, 'In progress')
  assert.equal(f.store.assignedRun(task.id), job.id)
  const saved = f.store.task(task.id)
  await f.write('move_task', { id: task.id, expectedRevision: saved.revision, status: 'To do' })
  await f.write('move_task', {
    id: task.id,
    expectedRevision: f.store.task(task.id).revision,
    status: 'In progress',
  })
  assert.equal(f.store.assignedRun(task.id), null)
  await assert.rejects(
    f.write('report_agent_progress', {
      runId: job.id,
      state: 'done',
      summary: 'Stale agent update',
    }),
    { code: 'TASK_MANUAL' }
  )
  await f.runner.tick()
  assert.equal(f.launched[0].closed, true)
  assert.equal(f.store.task(task.id).status, 'In progress')
  await f.write('add_task_comment', {
    taskId: task.id,
    text: 'Still a manual task.',
    notifyAgent: true,
  })
  assert.equal((await f.store.queueCommentFollowups()).queued, 0)
})
for (const agent of ['claude-code', 'codex']) {
  test(`${agent} pickup moves the task automatically and ignores duplicate or stale start events`, async (t) => {
    const f = fixture(t)
    await f.settings(agent)
    const task = await f.task('Automatic pickup')
    const existing = (
      await f.write('create_task', {
        boardId: task.boardId,
        title: 'Already in progress',
        status: 'In progress',
      })
    ).task
    await f.send(task)
    await f.runner.tick()
    assert.equal(f.store.task(task.id).status, 'Sent to agent', 'Launching alone is not pickup')
    const job = f.store.agentJobs()[0]
    const pickup =
      agent === 'claude-code'
        ? { type: 'system', subtype: 'init', session_id: job.threadId }
        : {
            method: 'turn/started',
            params: { threadId: job.threadId, turn: { id: 'test-turn', status: 'inProgress' } },
          }
    await f.launched[0].message(pickup)
    const saved = f.store.task(task.id)
    assert.equal(saved.status, 'In progress', 'No MCP progress report is needed')
    assert.equal(saved.position, existing.position + 1)
    assert.equal(f.store.agentJob(job.id).state, 'working')
    assert.equal(saved.revision, f.store.revision(), 'Task and run commit together')
    const revision = f.store.revision()
    await f.launched[0].message(pickup)
    assert.equal(
      f.store.revision(),
      revision,
      'Duplicate start must not reorder or revise the task'
    )
    await f.write('move_task', { id: task.id, expectedRevision: saved.revision, status: 'To do' })
    await f.launched[0].message(pickup)
    assert.equal(f.store.task(task.id).status, 'To do', 'A late event cannot undo a user move')
    await f.runner.stop(job.id)
    await f.store.updateAgentJob(job.id, { state: 'working' }, { pickedUp: true })
    assert.equal(f.store.agentJob(job.id).state, 'canceled')
  })
}
test('both defaults route correctly, persist per run, launch once and keep In progress', async (t) => {
  const f = fixture(t)
  const task = await f.task('First Claude task')
  await assert.rejects(f.send(task), { code: 'AGENT_SETUP_REQUIRED' })
  assert.equal(f.store.task(task.id).status, 'To do')
  await f.settings('claude-code')
  const request = {
    id: task.id,
    expectedRevision: task.revision,
    status: 'Sent to agent',
    requestKey: randomUUID(),
  }
  await f.store.dispatch('move_task', request)
  await f.store.dispatch('move_task', request)
  assert.equal(f.store.agentJobs().length, 1)
  await f.runner.tick()
  await f.runner.tick()
  assert.equal(f.launched.length, 1)
  assert.equal(f.launched[0].file, '/safe/claude-code')
  assert.ok(f.launched[0].args.includes('--session-id'))
  assert.ok(!f.launched[0].args.some((arg) => /dangerously|bypassPermissions/.test(arg)))
  await f.settings('codex')
  assert.equal(f.store.agentJobs()[0].agent, 'claude-code')
  const firstJob = f.store.agentJobs()[0]
  await f.write('report_agent_progress', {
    runId: firstJob.id,
    state: 'working',
    summary: 'Started',
  })
  assert.equal(f.store.task(task.id).status, 'In progress')
  await f.launched[0].message({ type: 'result', is_error: false, result: 'I have a question.' })
  assert.equal(f.store.agentJob(firstJob.id).state, 'review')
  assert.equal(
    f.store.task(task.id).status,
    'In progress',
    'A successful turn does not mark a task done'
  )
  const second = await f.task('Next Codex task')
  await f.send(second)
  await f.runner.tick()
  assert.equal(f.launched.length, 2)
  assert.equal(f.launched[1].file, '/safe/codex')
  assert.equal(f.launched[1].written[1].method, 'initialized')
  assert.ok(f.launched[1].written.some(({ method }) => method === 'thread/start'))
  assert.equal(f.launched[1].written.at(-1).method, 'turn/start')
  const secondJob = f.store.agentJobs()[0]
  await f.write('report_agent_progress', {
    runId: secondJob.id,
    state: 'done',
    summary: 'Completed and verified.',
    proof:
      'The disposable task was read through MCP and its requested outcome was verified in the test fixture.',
    definitionOfDoneMet: true,
  })
  assert.equal(f.store.task(second.id).status, 'Done')
  await f.launched[1].message({
    method: 'turn/completed',
    params: { turn: { status: 'completed' } },
  })
  assert.equal(f.store.agentJob(secondJob.id).state, 'done')
  await f.runner.openThread(secondJob.id)
  assert.equal(f.opened[0], `codex://threads/${secondJob.threadId}`)
  assert.deepEqual(f.store.agentSettings(), {
    defaultAgent: 'codex', workingFolder: f.folder, permissionMode: 'auto',
  })
})
test('the saved permission mode controls future Claude and Codex launches', async (t) => {
  const f = fixture(t)
  for (const [mode, claudeMode, reviewer, policy, sandbox] of [
    [undefined, 'auto', 'auto_review', 'on-request', 'workspace-write'],
    ['manual', 'manual', 'user', 'on-request', 'workspace-write'],
    ['full-access', 'bypassPermissions', 'user', 'never', 'danger-full-access'],
  ]) {
    await f.settings('claude-code', mode)
    await f.send(await f.task('Claude permissions'))
    await f.runner.tick()
    const claude = f.launched.at(-1)
    assert.equal(claude.args[claude.args.indexOf('--permission-mode') + 1], claudeMode)
    await f.runner.stop(f.runner.current.job.id)

    await f.settings('codex')
    await f.send(await f.task('Codex permissions'))
    await f.runner.tick()
    const codex = f.launched.at(-1).written.find((message) => message.method === 'thread/start')
    assert.equal(codex.params.approvalsReviewer, reviewer)
    assert.equal(codex.params.approvalPolicy, policy)
    assert.equal(codex.params.sandbox, sandbox)
    await f.runner.stop(f.runner.current.job.id)
  }
})
test('Claude opens the saved session through Desktop after the run stops', async (t) => {
  const f = fixture(t)
  await f.settings('claude-code')
  await f.send(await f.task('Conversation handoff'))
  await f.runner.tick()
  const job = f.runner.current.job
  await assert.rejects(f.runner.openThread(job.id), { code: 'RUNNING_THREAD' })
  await f.runner.stop(job.id)

  const launcher = path.join(f.folder, 'claude')
  const requireTerminal = process.platform === 'darwin' ? '[ -t 1 ] || exit 47\n' : ''
  fs.writeFileSync(launcher, '#!/bin/sh\n' + requireTerminal + 'printf "%s\\n" "$PWD" "$@" > handoff.log\n', { mode: 0o700 })
  f.runner.resolveExecutable = () => launcher
  assert.deepEqual(await f.runner.openThread(job.id), { opened: true })
  const args = fs.readFileSync(path.join(f.folder, 'handoff.log'), 'utf8').trimEnd().split('\n')
  assert.deepEqual(args, [fs.realpathSync(f.folder), '--desktop', '--resume', job.threadId])

  fs.writeFileSync(launcher, '#!/bin/sh\nexit 47\n')
  await assert.rejects(f.runner.openThread(job.id), {
    code: 'THREAD_OPEN_FAILED',
    message: 'Claude Desktop could not open this conversation. Open the Claude CLI in the original working folder and paste /resume ' + job.threadId,
  })

  fs.writeFileSync(launcher, "#!/bin/sh\necho 'Session is open in another terminal. Run /desktop there instead.'\nexit 1\n")
  await assert.rejects(f.runner.openThread(job.id), { code: 'THREAD_IN_USE' })
})
test('approval requests retain their scope, concurrent prompts and declines; canceled jobs ignore callbacks', async (t) => {
  const f = fixture(t)
  await f.settings('claude-code')
  const task = await f.task('Permission test')
  await f.send(task)
  await f.runner.tick()
  const job = f.store.agentJobs()[0],
    transport = f.launched[0]
  const permission = (id, input) =>
    transport.message({
      type: 'control_request',
      request_id: id,
      request: { subtype: 'can_use_tool', tool_name: 'Bash', input },
    })
  await permission('first', { command: 'echo one' })
  await permission('second', { command: 'echo two' })
  assert.equal(f.store.agentJob(job.id).approval.id, 'first')
  await f.runner.answer(job.id, 'first', false)
  assert.equal(transport.written.at(-1).response.response.behavior, 'deny')
  assert.equal(f.store.agentJob(job.id).approval.id, 'second')
  await f.runner.answer(job.id, 'second', true)
  assert.deepEqual(transport.written.at(-1).response.response.updatedInput, { command: 'echo two' })
  assert.equal(f.store.agentJob(job.id).approval, null)
  await transport.message({
    type: 'control_request',
    request_id: 'own',
    request: {
      subtype: 'can_use_tool',
      tool_name: 'mcp__opentalon__report_agent_progress',
      input: { runId: job.id, state: 'working', summary: 'ok' },
    },
  })
  assert.equal(transport.written.at(-1).response.response.behavior, 'allow')
  await transport.message({
    type: 'control_request',
    request_id: 'other',
    request: {
      subtype: 'can_use_tool',
      tool_name: 'mcp__opentalon__report_agent_progress',
      input: { runId: 'other' },
    },
  })
  assert.equal(f.store.agentJob(job.id).state, 'needs-input')
  await f.runner.stop(job.id)
  await transport.exit(new Error('Stopped'))
  assert.equal(f.store.agentJob(job.id).state, 'canceled')
  await assert.rejects(
    f.write('report_agent_progress', { runId: job.id, state: 'done', summary: 'Too late' }),
    { code: 'INACTIVE_RUN' }
  )
})
test('queued moves cancel, restarts never replay uncertain work and restored jobs do not run', async (t) => {
  const f = fixture(t)
  await f.settings('codex')
  const task = await f.task('Persistent queue')
  await f.send(task)
  let saved = f.store.task(task.id)
  await f.write('move_task', { id: task.id, expectedRevision: saved.revision, status: 'To do' })
  assert.equal(f.store.agentJobs()[0].state, 'canceled')
  await f.send(task)
  const job = f.store.agentJobs()[0]
  await f.store.updateAgentJob(job.id, { state: 'starting', threadId: randomUUID() })
  await f.runner.start()
  assert.equal(f.store.agentJob(job.id).state, 'interrupted')
  assert.equal(f.launched.length, 0)
  saved = f.store.task(task.id)
  assert.equal(saved.status, 'To do')
  await f.write('move_task', {
    id: task.id,
    expectedRevision: saved.revision,
    status: 'Sent to agent',
  })
  const retry = f.store.agentJobs()[0]
  saved = f.store.task(task.id)
  await f.write('move_task', { id: task.id, expectedRevision: saved.revision, status: 'Sent to agent' })
  assert.equal(f.store.agentJobs().length, 3, 'Only the explicit resend creates a run')
  for (const format of ['json', 'sqlite']) {
    const backup = await f.write('create_backup', { format })
    const preview = await f.store.dispatch('preview_destructive_action', {
      action: 'restore_backup',
      path: backup.path,
    })
    await f.write('confirm_destructive_action', { token: preview.token })
    assert.equal(f.store.agentJob(retry.id).state, 'interrupted')
    await f.runner.tick()
    assert.equal(f.launched.length, 0)
    assert.equal(f.store.task(task.id).status, 'To do')
  }
})
test('completion requires proof and definition of done confirmation; report is atomic and idempotent', async (t) => {
  const f = fixture(t)
  await f.settings('codex')
  const task = (
    await f.write('create_task', {
      boardId: f.store.boards()[0].id,
      title: 'Deliver a reviewed document',
      definitionOfDone: 'Save the document and verify that it opens with the requested content.',
      priority: 'High',
    })
  ).task
  await f.send(task)
  await f.runner.tick()
  const job = f.store.agentJobs()[0]
  await f.write('report_agent_progress', {
    runId: job.id,
    state: 'working',
    summary: 'Reading requirements',
  })
  for (const input of [
    {},
    { proof: 'Done', definitionOfDoneMet: true },
    { proof: 'Saved the document and opened it for review.', definitionOfDoneMet: false },
  ]) {
    await assert.rejects(
      f.write('report_agent_progress', {
        runId: job.id,
        state: 'done',
        summary: 'Finished',
        ...input,
      }),
      { code: 'COMPLETION_PROOF_REQUIRED' }
    )
    assert.equal(f.store.task(task.id).status, 'In progress')
    assert.equal(f.store.comments(task.id).length, 0)
  }
  for (const name of ['move_task', 'update_task'])
    await assert.rejects(
      f.write(name, {
        id: task.id,
        expectedRevision: f.store.task(task.id).revision,
        status: 'Done',
      }),
      { code: 'COMPLETION_PROOF_REQUIRED' }
    )
  const input = {
    runId: job.id,
    state: 'done',
    summary: 'Document ready.',
    proof:
      'Saved /test/output.md, reopened it, and checked all requested sections against the definition of done.',
    definitionOfDoneMet: true,
    requestKey: randomUUID(),
  }
  const result = await f.store.dispatch('report_agent_progress', input)
  assert.deepEqual(await f.store.dispatch('report_agent_progress', input), result)
  assert.equal(f.store.task(task.id).status, 'Done')
  assert.equal(f.store.comments(task.id).length, 1)
  assert.match(result.completionReport.text, /Save the document and verify/)
  assert.match(result.completionReport.text, /\/test\/output.md/)
  assert.equal(result.completionReport.agent, 'codex')
  assert.equal(result.completionReport.delivery, 'local')
  assert.equal(f.store.task(task.id).commentCount, 1)
  const backup = await f.write('create_backup', { format: 'json' })
  assert.match((await f.store.inspect(backup.path)).comments[0].text, /Proof and verification/)
})

test('failed starts recover and explicit local completion survives late pickup', async (t) => {
  const f = fixture(t)
  await f.settings('codex')
  const task = await f.task('Recover from a failed agent launch')
  await f.send(task)
  await f.runner.tick()
  let run = f.store.agentJobs()[0]
  await f.runner.finish(run.id, 'failed', 'The agent did not respond.')
  assert.equal(f.store.task(task.id).status, 'To do')
  assert.equal(f.store.agentJob(run.id).state, 'failed')

  await f.send(task)
  await f.runner.tick()
  run = f.store.agentJobs()[0]
  await f.write('force_complete_task', { id: task.id })
  assert.equal(f.store.task(task.id).status, 'Done')
  assert.equal(f.store.assignedRun(task.id), null)
  assert.equal(f.store.agentJob(run.id).state, 'canceled')
  await f.store.updateAgentJob(run.id, { state: 'working' }, { pickedUp: true })
  assert.equal(f.store.task(task.id).status, 'Done')
  await f.runner.tick()
  assert.equal(f.launched.at(-1).closed, true)
})
test('v1 database migration preserves records and v1 JSON/SQLite backups remain importable', async (t) => {
  const f = fixture(t)
  await f.task('Original data')
  const jsonBackup = await f.write('create_backup', { format: 'json' })
  const legacy = JSON.parse(fs.readFileSync(jsonBackup.path, 'utf8'))
  legacy.formatVersion = 1
  legacy.columns = ['To do', 'In progress', 'Done']
  delete legacy.agentSettings
  delete legacy.agentRuns
  const json = path.join(f.folder, 'legacy.json')
  fs.writeFileSync(json, JSON.stringify(legacy))
  assert.equal((await f.store.inspect(json)).summary.tasks, 1)
  const sqlite = await f.write('create_backup', {})
  const db = new DatabaseSync(sqlite.path)
  db.exec(
    'DROP TRIGGER tasks_record_completion_on_insert; DROP TRIGGER tasks_record_completion_on_move; DROP TABLE task_history; ALTER TABLE tasks DROP COLUMN issue_type; ALTER TABLE tasks DROP COLUMN plan_markdown; ALTER TABLE tasks DROP COLUMN completed_at; ALTER TABLE tasks DROP COLUMN archived_at; DROP INDEX tasks_task_key; DROP INDEX boards_project_key; ALTER TABLE tasks DROP COLUMN task_key; ALTER TABLE boards DROP COLUMN project_key; ALTER TABLE boards DROP COLUMN next_task_number; ALTER TABLE tasks DROP COLUMN due_date; ALTER TABLE tasks DROP COLUMN priority; ALTER TABLE tasks DROP COLUMN definition_of_done; DROP TABLE comment_images; DROP TABLE task_comments; DROP TABLE agent_jobs; DELETE FROM schema_migrations WHERE version>=2; PRAGMA user_version=1;'
  )
  db.close()
  assert.equal((await f.store.inspect(sqlite.path)).summary.tasks, 1)
  const folder = path.join(f.folder, 'legacy-profile')
  fs.mkdirSync(folder)
  fs.copyFileSync(sqlite.path, path.join(folder, 'opentalon.sqlite'))
  const migrated = new Store(folder)
  try {
    assert.equal(migrated.snapshot().tasks[0].title, 'Original data')
    assert.equal(migrated.db.prepare('PRAGMA user_version').get().user_version, FORMAT)
    assert.deepEqual(migrated.db.prepare('PRAGMA foreign_key_check').all(), [])
  } finally {
    migrated.close()
  }
})
