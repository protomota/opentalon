import { useEffect, useState } from 'react'
import { ArrowUpRight, Copy, Download } from 'lucide-react'
import { action, type Connection } from './model'

type SetupField = { id: string; label: string; value: string }
export function AgentSetup({
  connection,
  setConnection,
  busy,
  perform,
  notify,
  onReset,
}: {
  connection: Connection | null
  setConnection: (connection: Connection) => void
  busy: boolean
  perform: (operation: () => Promise<void>) => Promise<void>
  notify: (message: string) => void
  onReset: () => void
}) {
  const [client, setClient] = useState<'claude-code' | 'codex' | 'claude'>('claude-code')
  const [savedFile, setSavedFile] = useState('')
  const [fields, setFields] = useState<SetupField[]>([])
  const [fieldError, setFieldError] = useState('')
  const [terminalClient, setTerminalClient] = useState<'claude-code' | 'codex'>('claude-code')
  useEffect(() => {
    let active = true
    setFields([])
    setFieldError('')
    if (connection?.running) {
      action<SetupField[]>('agent_setup_fields')
        .then((result) => {
          if (active) setFields(result)
        })
        .catch((error: Error) => {
          if (active) setFieldError(error.message)
        })
    }
    return () => {
      active = false
    }
  }, [connection])
  const run = (operation: () => Promise<void>) => void perform(operation)
  const openApp = (app: 'codex' | 'claude' | 'terminal') =>
    run(async () => {
      await action('open_setup_app', { app })
    })
  return (
    <section className="settings-section agent-setup">
      <div className="section-heading">
        <h3>Work with your AI agent.</h3>
        <span className="connection-badge">
          {connection?.running ? 'Available on this Mac' : 'Off'}
        </span>
      </div>
      <p>
        Connect Claude or the Codex app through MCP. Your agent can
        read, create and update your projects and tasks. Set it up from the apps. No Terminal
        required.
      </p>
      <label className="toggle-row">
        <input
          type="checkbox"
          aria-label="Enable MCP connection"
          checked={connection?.enabled || false}
          disabled={busy || !connection}
          onChange={(event) => {
            const enabled = event.target.checked
            run(async () => setConnection(await action<Connection>('set_connection', { enabled })))
          }}
        />
        Let my agent use OpenTalon
      </label>
      <p className="settings-help">
        Connected agents can read and change every project and task. Your task database stays on this
        Mac; your agent handles its own model connection.
      </p>
      {connection?.enabled && (
        <>
          {connection.error && (
            <p role="alert" className="error-text">
              {connection.error}
            </p>
          )}
          <div className="agent-client-picker" role="group" aria-label="Choose your desktop app">
            {(
              [
                ['claude-code', 'Claude'],
                ['codex', 'Codex app'],
                ['claude', 'Claude chat · advanced'],
              ] as const
            ).map(([id, label]) => (
              <button
                key={id}
                className={client === id ? 'selected' : ''}
                aria-pressed={client === id}
                onClick={() => setClient(id)}
              >
                {label}
              </button>
            ))}
          </div>
          <div className="setup-guide">
            <div className="section-heading">
              <h4>
                {client === 'claude-code'
                  ? 'Connect Claude'
                  : client === 'codex'
                    ? 'Connect the Codex app'
                    : 'Claude desktop chat · advanced setup'}
              </h4>
              <span className="setup-caption">No Terminal needed</span>
            </div>
            {client === 'claude-code' ? (
              <>
                <ol className="setup-steps">
                  <li>
                    Select <strong>Save project connection</strong> below. Choose the working folder
                    you will open in Claude. OpenTalon creates or updates its{' '}
                    <strong>.mcp.json</strong>, preserving other connections.
                  </li>
                  <li>
                    In the Claude desktop app, choose the <strong>Code</strong> tab. Start a new{' '}
                    <strong>local</strong> session in that same folder on{' '}
                    <strong>This computer</strong>.
                  </li>
                  <li>
                    Review Claude’s project MCP trust prompt. Approve the OpenTalon connection if
                    you want it to access this workspace.
                  </li>
                  <li>
                    Open the session’s <strong>Connectors</strong> panel to check OpenTalon, then
                    ask the agent to list your projects. Start a new session if it was already open.
                  </li>
                </ol>
                <div className="settings-actions">
                  <button
                    className="secondary-button"
                    disabled={busy || !connection.running}
                    onClick={() =>
                      run(async () => {
                        const result = await action<{ canceled?: boolean; file?: string }>(
                          'save_project_connection'
                        )
                        if (!result.canceled && result.file) {
                          setSavedFile(result.file)
                          notify(
                            'Project connection saved. Open this folder in Claude and review its MCP permission prompt.'
                          )
                        }
                      })
                    }
                  >
                    <Download size={14} />
                    Save project connection
                  </button>
                  <button
                    className="secondary-button"
                    disabled={busy}
                    onClick={() => openApp('claude')}
                  >
                    Open Claude <ArrowUpRight size={13} />
                  </button>
                </div>
                {savedFile && (
                  <p className="connection-endpoint" role="status">
                    Saved: {savedFile}
                  </p>
                )}
                <p>
                  This is a local project connection. A cloud session or remote computer cannot
                  reach this copy of OpenTalon. If you already configured an OpenTalon server
                  globally or in Claude chat, review that existing connection: Claude may give it
                  priority over this project file.
                </p>
              </>
            ) : client === 'codex' ? (
              <ol className="setup-steps">
                <li>
                  <strong>Open Codex → Settings → MCP servers.</strong>
                  <p>
                    Choose <b>Add server</b>. Some versions label the desktop app ChatGPT. Enter{' '}
                    <b>opentalon</b> as the name and choose <b>STDIO</b>.
                  </p>
                  <button
                    className="secondary-button"
                    disabled={busy}
                    onClick={() => openApp('codex')}
                  >
                    Open Codex <ArrowUpRight size={13} />
                  </button>
                </li>
                <li>
                  <strong>Copy these values into the matching fields.</strong>
                  <p>
                    Paste each value without adding quotes. Add the argument as one entry, then add
                    both environment variables with their exact names.
                  </p>
                  {fieldError && (
                    <p className="error-text" role="alert">
                      {fieldError}
                    </p>
                  )}
                  <div className="setup-fields">
                    {fields
                      .filter((field) => field.id !== 'name')
                      .map((field) => (
                        <div className="setup-field" key={field.id}>
                          <span>{field.label}</span>
                          <code>{field.value}</code>
                          <button
                            className="icon-button"
                            aria-label={`Copy ${field.label}`}
                            disabled={busy}
                            onClick={() =>
                              run(async () => {
                                await action('copy_setup_field', { id: field.id })
                                notify(`${field.label} copied. Paste it into that field in Codex.`)
                              })
                            }
                          >
                            <Copy size={14} />
                          </button>
                        </div>
                      ))}
                  </div>
                </li>
                <li>
                  <strong>Save, then select Restart.</strong>
                  <p>
                    Start a new local chat. Type <b>/mcp</b> to check that <b>opentalon</b> is
                    connected.
                  </p>
                </li>
              </ol>
            ) : (
              <ol className="setup-steps">
                <li>
                  <strong>Save the OpenTalon extension.</strong>
                  <p>
                    Choose a folder you can find, such as Downloads. This small file connects Claude
                    to this Mac’s OpenTalon installation.
                  </p>
                  <button
                    className="secondary-button"
                    disabled={busy || !connection.running}
                    onClick={() =>
                      run(async () => {
                        const result = await action<{ canceled?: boolean; path?: string }>(
                          'save_claude_extension'
                        )
                        if (!result.canceled)
                          notify(`Extension saved: ${result.path}. Open Claude and follow step 2.`)
                      })
                    }
                  >
                    <Download size={14} />
                    Save Claude extension…
                  </button>
                </li>
                <li>
                  <strong>Install it inside Claude Desktop.</strong>
                  <p>
                    Open <b>Settings → Desktop app → Extensions → Manage</b>. Choose{' '}
                    <b>Advanced settings → Install Extension…</b>, select <b>OpenTalon.mcpb</b>,
                    then follow the installation prompts. In older versions, start at{' '}
                    <b>Settings → Extensions</b>.
                  </p>
                  <button
                    className="secondary-button"
                    disabled={busy}
                    onClick={() => openApp('claude')}
                  >
                    Open Claude <ArrowUpRight size={13} />
                  </button>
                </li>
                <li>
                  <strong>Enable it in your chat.</strong>
                  <p>
                    Start a new chat, click <b>+ → Connectors</b>, and check that OpenTalon and its
                    tools are enabled. If it is missing, quit Claude with <b>⌘Q</b> and reopen it.
                  </p>
                </li>
              </ol>
            )}
            <button
              className="text-button"
              disabled={busy}
              onClick={() =>
                run(async () => {
                  await action('open_setup_guide', { client })
                })
              }
            >
              Open{' '}
              {client === 'claude-code'
                ? 'Claude'
                : client === 'codex'
                  ? 'Codex'
                  : 'Claude chat'}{' '}
              setup guide <ArrowUpRight size={12} />
            </button>
          </div>
          <div className="agent-examples">
            <h4>Check reading and writing in your agent app</h4>
            <p>
              Ask your agent: <q>Use OpenTalon to list my projects and tasks.</q> Its answer should
              match the app. Then try:
            </p>
            <ul>
              <li>“Add ‘Order supplies’ to my OpenTalon project.”</li>
              <li>“Move ‘Order supplies’ to In progress.”</li>
              <li>“Mark ‘Order supplies’ as Done.”</li>
            </ul>
            <p>
              If your agent asks, approve access to OpenTalon’s tools. You can close this window and
              keep working from chat. The connection above means OpenTalon is available; check your
              agent’s own connector list to confirm it is connected.
            </p>
          </div>
          <details className="setup-advanced">
            <summary>Advanced: other clients, HTTP & Terminal</summary>
            <p>
              For another local MCP app, choose STDIO and use the fields above, or paste the JSON
              into its MCP configuration editor. JSON is configuration, not a Terminal command.
            </p>
            <div className="settings-actions">
              {(['stdio', 'http'] as const).map((transport) => (
                <button
                  key={transport}
                  className="secondary-button"
                  disabled={busy || !connection.running}
                  onClick={() =>
                    run(async () => {
                      await action('client_configuration', { transport })
                      notify(
                        transport === 'stdio'
                          ? 'STDIO JSON copied. Paste it into your client’s MCP configuration editor.'
                          : 'Private HTTP JSON copied. Paste it into your client’s MCP configuration editor; keep its authorization key private.'
                      )
                    })
                  }
                >
                  Copy {transport === 'stdio' ? 'STDIO' : 'HTTP'} JSON
                </button>
              ))}
            </div>
            <p>
              Direct HTTP requires OpenTalon to be running. Its address can change after restart;
              copy fresh setup if it stops connecting. The STDIO bridge starts OpenTalon in the
              background when needed.
            </p>
            <h4>Optional command-line setup</h4>
            <p>
              Use this only if you already have the selected CLI installed. Desktop-app setup above
              does not require it.
            </p>
            <label className="terminal-client-label">
              Command for{' '}
              <select
                value={terminalClient}
                onChange={(event) =>
                  setTerminalClient(event.target.value as 'codex' | 'claude-code')
                }
              >
                <option value="claude-code">Claude</option>
                <option value="codex">Codex CLI</option>
              </select>
            </label>
            <button
              className="secondary-button"
              disabled={busy || !connection.running}
              onClick={() =>
                run(async () => {
                  await action('copy_terminal_setup', { client: terminalClient })
                  await action('open_setup_app', { app: 'terminal' })
                  notify(
                    'Command copied and Terminal opened. Click its prompt, press ⌘V, review the command, then press Return. Nothing has run yet.'
                  )
                })
              }
            >
              <Copy size={14} />
              Copy command & open Terminal
            </button>
            <p>
              In Terminal, click the prompt, press <b>⌘V</b>, review the command, then press{' '}
              <b>Return</b>. Opening Terminal does not paste or run anything. After registration,
              restart the connector in your agent app.
            </p>
            <button className="text-button" disabled={busy} onClick={() => openApp('terminal')}>
              Open Terminal
            </button>
            <hr />
            <button className="text-button" disabled={busy} onClick={onReset}>
              Reset connection key…
            </button>
          </details>
        </>
      )}
    </section>
  )
}
