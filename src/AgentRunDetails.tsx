import { useState } from 'react'
import { action, agentNames, type AgentRun } from './model'
const labels: Record<AgentRun['state'], string> = {
  queued: 'Queued',
  starting: 'Starting',
  working: 'Working',
  'needs-input': 'Needs your input',
  review: 'Ready to review',
  done: 'Completed',
  failed: 'Could not finish',
  canceled: 'Stopped',
  interrupted: 'Review before continuing',
}
export function AgentRunDetails({ run }: { run: AgentRun }) {
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const active = ['queued', 'starting', 'working', 'needs-input'].includes(run.state)
  async function perform(name: string, input: Record<string, unknown> = {}) {
    setBusy(true)
    setError('')
    try {
      await action(name, { runId: run.id, ...input })
    } catch (error) {
      setError(error instanceof Error ? error.message : 'The operation failed.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <section className="agent-run-details" aria-label="Agent run">
      <div className="agent-run-heading">
        <strong>{agentNames[run.agent]}</strong>
        <span className="agent-run-state">{labels[run.state]}</span>
      </div>
      <p className="agent-run-summary">{run.summary}</p>
      {run.approval && (
        <div className="agent-permission">
          <strong>{run.approval.title}</strong>
          <pre>{run.approval.details}</pre>
          <div className="settings-actions">
            {run.approval.canApprove && (
              <button
                className="primary-button"
                disabled={busy}
                onClick={() =>
                  void perform('answer_agent_approval', {
                    approvalId: run.approval?.id,
                    allow: true,
                  })
                }
              >
                Allow once
              </button>
            )}
            <button
              className="secondary-button"
              disabled={busy}
              onClick={() =>
                void perform('answer_agent_approval', {
                  approvalId: run.approval?.id,
                  allow: false,
                })
              }
            >
              Decline
            </button>
          </div>
        </div>
      )}
      <div className="settings-actions">
        {active && (
          <button
            className="secondary-button"
            disabled={busy}
            onClick={() => void perform('stop_agent_run')}
          >
            Stop run
          </button>
        )}
        {run.threadId && (!active || run.agent === 'codex') && (
          <button
            className="secondary-button"
            disabled={busy}
            onClick={() => void perform('open_agent_thread')}
          >
            Open conversation ↗
          </button>
        )}
      </div>
      {active && run.agent === 'claude-code' && (
        <p className="field-caption">
          To continue in Claude, stop this run, then choose Open conversation.
        </p>
      )}
      {!active && run.state !== 'done' && (
        <p className="field-caption">
          Review the existing conversation before sending again. To start a new run, move this task
          to To do, then back to Sent to agent.
        </p>
      )}
      {run.threadId && (
        <details className="field-caption">
          <summary>Conversation details</summary>
          <p>{run.threadId}</p>
          <p>{run.workingFolder}</p>
        </details>
      )}
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
