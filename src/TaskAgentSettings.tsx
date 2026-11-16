import { useEffect, useState } from 'react'
import { FolderOpen } from 'lucide-react'
import {
  action,
  agentNames,
  requestKey,
  type AgentSettings,
  type Connection,
  type TaskAgent,
} from './model'

export function TaskAgentSettings({
  onReadyChange,
}: { onReadyChange?: (ready: boolean) => void } = {}) {
  const [connection, setConnection] = useState<Connection | null>(null)
  const [settings, setSettings] = useState<AgentSettings | null>(null)
  const [installed, setInstalled] = useState<Record<TaskAgent, { installed: boolean }> | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    Promise.all([
      action<AgentSettings>('get_agent_settings'),
      action<Record<TaskAgent, { installed: boolean }>>('agent_runtime_status'),
      action<Connection>('connection_status'),
    ])
      .then(([settings, installed, connection]) => {
        setConnection(connection)
        setSettings(settings)
        setInstalled(installed)
      })
      .catch((error) => setError(error.message))
  }, [])
  useEffect(() => {
    onReadyChange?.(
      !!settings?.workingFolder &&
        !!installed?.[settings.defaultAgent].installed &&
        !!connection?.running &&
        !busy
    )
  }, [settings, installed, connection, busy, onReadyChange])
  async function save(next: AgentSettings) {
    setBusy(true)
    setError('')
    try {
      const result = await action<{ settings: AgentSettings }>('set_agent_settings', {
        ...next,
        requestKey: requestKey(),
      })
      setSettings(result.settings)
    } catch (error) {
      setError(error instanceof Error ? error.message : 'Could not save the task agent.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <section className="settings-section task-agent-settings">
      <h3>Task agent</h3>
      <p>
        Drop a task into <strong>Sent to agent</strong> to start a new conversation with your
        default agent. Tasks stay manual by default; this choice applies only when you use Sent to
        agent.
      </p>
      {settings && (
        <>
          <label className="agent-default-label" htmlFor="default-task-agent">
            Default agent
          </label>
          <select
            id="default-task-agent"
            disabled={busy}
            value={settings.defaultAgent}
            onChange={(event) =>
              void save({ ...settings, defaultAgent: event.target.value as TaskAgent })
            }
          >
            <option value="claude-code">{agentNames['claude-code']}</option>
            <option value="codex">Codex</option>
          </select>
          <p className="field-caption" role="status">
            {installed?.[settings.defaultAgent].installed
              ? `${agentNames[settings.defaultAgent]} launcher found on this Mac.`
              : `Install ${agentNames[settings.defaultAgent]}’s launcher and sign in before sending tasks.`}
          </p>
          {installed && !installed[settings.defaultAgent].installed && (
            <ol className="agent-install-steps">
              <li>
                Install {agentNames[settings.defaultAgent]} using its{' '}
                <button
                  className="text-button"
                  onClick={() =>
                    void action('open_agent_install_guide', { agent: settings.defaultAgent }).catch(
                      (error) => setError(error.message)
                    )
                  }
                >
                  official setup guide ↗
                </button>
                .
              </li>
              <li>Open the agent, sign in, and choose a working folder you trust.</li>
              <li>
                Reopen OpenTalon Settings to check the launcher, then enable the agent connection
                below.
              </li>
            </ol>
          )}
          <label className="agent-default-label">Working folder</label>
          <p className="agent-folder">
            {settings.workingFolder || 'Choose where your agent should work.'}
          </p>
          <button
            className="secondary-button"
            disabled={busy}
            onClick={async () => {
              setBusy(true)
              setError('')
              try {
                const result = await action<{ canceled?: boolean; path?: string }>(
                  'choose_agent_folder'
                )
                if (result.path) await save({ ...settings, workingFolder: result.path })
              } catch (error) {
                setError(error instanceof Error ? error.message : 'Could not choose a folder.')
              } finally {
                setBusy(false)
              }
            }}
          >
            <FolderOpen size={14} />
            {settings.workingFolder ? 'Change folder…' : 'Choose folder…'}
          </button>
        </>
      )}
      {onReadyChange && connection && (
        <label className="toggle-row">
          <input
            type="checkbox"
            checked={connection.enabled}
            disabled={busy}
            onChange={async (event) => {
              const enabled = event.target.checked
              setBusy(true)
              setError('')
              try {
                setConnection(await action<Connection>('set_connection', { enabled }))
              } catch (error) {
                setError(
                  error instanceof Error ? error.message : 'Could not enable the connection.'
                )
              } finally {
                setBusy(false)
              }
            }}
          />
          Enable local agent connection
        </label>
      )}
      <p className="field-caption">
        Comments on In progress tasks are checked every five minutes while OpenTalon is running and
        sent to that task’s existing agent conversation, including screenshots.
      </p>
      <p className="field-caption">
        OpenTalon runs one task at a time, using your existing agent sign-in and the MCP connection
        below. Permissions still apply. Task data stays on this Mac; agent work uses your provider’s
        connection and usage allowance.
      </p>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
