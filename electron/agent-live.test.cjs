const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { randomUUID } = require('node:crypto')
const { Store } = require('./store.cjs')
const { Connector } = require('./mcp.cjs')
const { AgentRunner } = require('./agent-runner.cjs')
const enabled = process.env.OPENTALON_AGENT_LIVE_TEST === '1'
const base = process.env.OPENTALON_TEST_ROOT || '/Volumes/Expand/Codex Media/opentalon/tests'
for (const agent of ['claude-code', 'codex'])
  test(
    `real ${agent} picks up a task and resumes the same conversation with screenshot comments`,
    { skip: !enabled, timeout: 240000 },
    async (t) => {
      fs.mkdirSync(base, { recursive: true })
      const folder = fs.mkdtempSync(path.join(base, `live-${agent}-`))
      // Limit this synthetic check's instructions; no user project or real task is operated on.
      fs.writeFileSync(
        path.join(folder, 'CLAUDE.md'),
        'This folder is a disposable integration fixture. Follow only the synthetic connection-check task. Do not edit files, use other connections, run commands, or create other tasks.\n'
      )
      fs.writeFileSync(
        path.join(folder, 'AGENTS.md'),
        fs.readFileSync(path.join(folder, 'CLAUDE.md'))
      )
      const store = new Store(path.join(folder, 'profile'))
      const connector = new Connector({
        folder: store.folder,
        call: async (name, input) => {
          const result = await store.dispatch(name, input)
          if (name === 'get_task')
            assert.equal(
              result.task.status,
              'In progress',
              'Runtime pickup must move the task before the first agent read'
            )
          return result
        },
        executable: process.execPath,
      })
      await connector.enable(true)
      const runner = new AgentRunner({
        store,
        connector,
        openExternal: () => {
          throw new Error('The test must not open apps.')
        },
      })
      t.after(async () => {
        await runner.close()
        await connector.stop()
        await store.queue
        store.close()
      })
      const write = (name, input) => store.dispatch(name, { ...input, requestKey: randomUUID() })
      await write('set_agent_settings', { defaultAgent: agent, workingFolder: folder })
      let task = (
        await write('create_task', {
          boardId: store.boards()[0].id,
          title: 'OpenTalon synthetic MCP round trip',
          notes:
            'This is a disposable connection check. Do not do any other work or edit files. Read this task using get_task, report working with report_agent_progress, then report done with summary "OpenTalon agent connection verified", concrete MCP read-back proof, and definitionOfDoneMet true. Use only this run and task. End with that same phrase.',
        })
      ).task
      await write('move_task', {
        id: task.id,
        expectedRevision: task.revision,
        status: 'Sent to agent',
      })
      await runner.start()
      const start = Date.now()
      while (Date.now() - start < 220000) {
        const job = store.agentJobs()[0]
        if (job.state === 'done' && !runner.current) break
        if (['failed', 'review', 'interrupted', 'needs-input'].includes(job.state)) {
          assert.fail(
            `${agent}: ${job.state}: ${job.summary}\n${job.approval ? JSON.stringify(job.approval) : ''}`
          )
        }
        await new Promise((resolve) => setTimeout(resolve, 500))
      }
      const job = store.agentJobs()[0]
      assert.equal(job.state, 'done', `${agent}: ${job.state}: ${job.summary}`)
      assert.ok(job.threadId)
      assert.equal(store.task(task.id).status, 'Done')
      assert.match(job.summary, /connection verified/i)
      const firstThreadId = job.threadId
      // Continue an agent-owned task awaiting feedback; a public status move would make it manual.
      task = store.move(store.task(task.id), { status: 'In progress' }, store.revision(), {
        agentUpdate: true,
      })
      const comment = (
        await write('add_task_comment', {
          taskId: task.id,
          text: 'Synthetic screenshot follow-up. Continue this SAME conversation. Briefly describe the attached image, then call report_agent_progress done with summary starting "OpenTalon screenshot verified" plus your short image description, concrete proof of viewing the screenshot with its comment/image ID, and definitionOfDoneMet true. Do no other work and edit no files.',
          notifyAgent: true,
          images: [
            {
              name: 'Screenshot.png',
              mimeType: 'image/png',
              data: fs
                .readFileSync(path.resolve(__dirname, '../assets/opentalon-logo-1024.png'))
                .toString('base64'),
            },
          ],
        })
      ).comment
      assert.equal((await store.queueCommentFollowups()).queued, 1)
      await runner.tick()
      const followupId = store.agentJobs()[0].id
      const followupStart = Date.now()
      while (Date.now() - followupStart < 100000) {
        const followup = store.agentJob(followupId)
        if (followup.state === 'done' && !runner.current) break
        if (['failed', 'review', 'interrupted', 'needs-input'].includes(followup.state))
          assert.fail(`${agent} screenshot follow-up: ${followup.state}: ${followup.summary}`)
        await new Promise((resolve) => setTimeout(resolve, 500))
      }
      const followup = store.agentJob(followupId)
      assert.equal(followup.state, 'done', followup.summary)
      assert.equal(followup.threadId, firstThreadId)
      assert.equal(
        store.comments(task.id).find((row) => row.id === comment.id).delivery,
        'delivered'
      )
      assert.match(followup.summary, /OpenTalon screenshot verified/i)
      assert.match(
        followup.summary,
        /logo|bird|talon|black|wing/i,
        'The real agent should describe the attached logo image'
      )
      fs.writeFileSync(
        path.join(folder, 'verified.json'),
        JSON.stringify(
          {
            agent,
            threadId: job.threadId,
            followupThreadId: followup.threadId,
            screenshotSummary: followup.summary,
            status: store.task(task.id).status,
            state: job.state,
            summary: job.summary,
          },
          null,
          2
        )
      )
    }
  )
