import { useEffect, useState } from 'react'
import { ArrowUpRight, Check, FolderOpen } from 'lucide-react'
import { action, requestKey, type Connection, type Preview, type Theme } from './model'
import { Modal } from './Modal'
import { AgentSetup } from './AgentSetup'
import { ProductIdentity } from './ProductIdentity'
import { TaskAgentSettings } from './TaskAgentSettings'
const themeOptions: { id: Theme; name: string; description: string }[] = [
  { id: 'graphite', name: 'Graphite', description: 'Quiet focus. A darker canvas.' },
  { id: 'warm-paper', name: 'Warm Paper', description: 'A softer place to get things done.' },
  { id: 'native-light', name: 'Native Light', description: 'Crisp, clear, and familiar.' },
]
export function SettingsDialog({
  theme,
  onTheme,
  onClose,
  onRestored,
}: {
  theme: Theme
  onTheme: (theme: Theme) => Promise<void>
  onClose: () => void
  onRestored: () => Promise<void>
}) {
  const [connection, setConnection] = useState<Connection | null>(null)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<Preview | null>(null)
  const [resetting, setResetting] = useState(false)
  const [restoreKey, setRestoreKey] = useState('')
  useEffect(() => {
    if (!notice) return
    const timer = setTimeout(() => setNotice(''), 8000)
    return () => clearTimeout(timer)
  }, [notice])
  useEffect(() => {
    action<Connection>('connection_status')
      .then(setConnection)
      .catch((error) => setError(error.message))
  }, [])
  async function perform(operation: () => Promise<void>) {
    setBusy(true)
    setError('')
    setNotice('')
    try {
      await operation()
    } catch (error) {
      setError(error instanceof Error ? error.message : 'The operation failed.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <Modal
      title="Settings"
      onClose={() => {
        if (!busy) onClose()
      }}
      className="settings-modal"
    >
      <section className="appearance-section">
        <h3>Make yourself at home</h3>
        <p>Choose the canvas you like working in.</p>
        <div className="theme-options" role="radiogroup" aria-label="Appearance theme">
          {themeOptions.map((option) => (
            <button
              key={option.id}
              disabled={busy}
              role="radio"
              aria-checked={theme === option.id}
              aria-label={option.name}
              className={`theme-option ${theme === option.id ? 'selected' : ''}`}
              onClick={() => void perform(() => onTheme(option.id))}
            >
              <span className={`theme-miniature preview-${option.id}`} aria-hidden="true">
                <span className="mini-sidebar">
                  <i />
                  <i />
                  <i />
                </span>
                <span className="mini-main">
                  <i className="mini-heading" />
                  <span className="mini-columns">
                    {[0, 1, 2].map((column) => (
                      <span key={column}>
                        <i />
                        <i />
                        {column === 0 && <i />}
                      </span>
                    ))}
                  </span>
                </span>
              </span>
              <span className="theme-name">
                {option.name}
                <span className="selection-indicator">
                  {theme === option.id && <Check size={11} strokeWidth={3} />}
                </span>
              </span>
              <span className="theme-description">{option.description}</span>
            </button>
          ))}
        </div>
        <label className="toggle-row">
          <input
            type="checkbox"
            checked={theme === 'system'}
            disabled={busy}
            onChange={(event) =>
              void perform(() => onTheme(event.target.checked ? 'system' : 'native-light'))
            }
          />
          Follow macOS light/dark appearance
        </label>
      </section>
      <TaskAgentSettings />
      <section className="settings-section">
        <h3>Your data & backups</h3>
        <p>
          Export everything to one readable JSON file. Keep a copy outside this Mac so you can
          recover after data loss.
        </p>
        <div className="settings-actions">
          <button
            className="secondary-button"
            disabled={busy}
            onClick={() =>
              void perform(async () => {
                await action('show_data_folder')
              })
            }
          >
            <FolderOpen size={14} />
            Show data folder
            <ArrowUpRight size={12} />
          </button>
          <button
            className="secondary-button"
            disabled={busy}
            onClick={() =>
              void perform(async () => {
                const result = await action<{ canceled?: boolean; path?: string }>('choose_backup')
                if (!result.canceled) setNotice(`Backup saved: ${result.path}`)
              })
            }
          >
            Export Backup…
          </button>
          <button
            className="secondary-button"
            disabled={busy}
            onClick={() =>
              void perform(async () => {
                const result = await action<Preview & { canceled?: boolean }>('choose_restore')
                if (!result.canceled) {
                  setPreview(result)
                  setRestoreKey(requestKey())
                }
              })
            }
          >
            Import / Restore…
          </button>
        </div>
        <p className="settings-help">
          Includes every project, the four columns, tasks and notes, ordering, Trash, dates,
          appearance, comments, screenshots and agent-run history. No credentials or agent
          connection keys. Restored runs never start automatically. To recover, import your backup,
          review the contents, then confirm Restore. Restoring replaces the workspace instead of
          adding duplicates; a safety backup is saved first. Older OpenTalon backups also work.
        </p>
      </section>
      <AgentSetup
        connection={connection}
        setConnection={setConnection}
        busy={busy}
        perform={perform}
        notify={setNotice}
        onReset={() => setResetting(true)}
      />
      <ProductIdentity />
      {error && (
        <p className="settings-feedback error-text" role="alert">
          {error}
        </p>
      )}
      {notice && (
        <p className="settings-feedback" role="status">
          {notice}
        </p>
      )}
      <div className="modal-footer">
        <button className="primary-button" disabled={busy} onClick={onClose}>
          {busy ? 'Working…' : 'Done'}
        </button>
      </div>
      {preview && (
        <Modal
          title="Restore this backup?"
          className="small-modal"
          onClose={() => {
            if (!busy) setPreview(null)
          }}
        >
          <p className="dialog-description">
            Replace the current workspace with {preview.summary.boards} projects,{' '}
            {preview.summary.tasks} tasks and {preview.summary.trash} trashed tasks. A safety backup
            of current data will be saved first.
          </p>
          <p className="dialog-description backup-path">{preview.summary.path}</p>
          <div className="modal-footer">
            <button className="secondary-button" disabled={busy} onClick={() => setPreview(null)}>
              Cancel
            </button>
            <button
              className="danger-button"
              disabled={busy}
              onClick={() =>
                void perform(async () => {
                  const result = await action<{ safetyBackup: string }>(
                    'confirm_destructive_action',
                    { token: preview.token, requestKey: restoreKey }
                  )
                  await onRestored()
                  setPreview(null)
                  setNotice(`Restored. Previous data saved at ${result.safetyBackup}`)
                })
              }
            >
              Restore backup
            </button>
          </div>
          {error && (
            <p className="settings-feedback error-text" role="alert">
              {error}
            </p>
          )}
        </Modal>
      )}
      {resetting && (
        <Modal
          title="Reset connection key?"
          className="small-modal"
          onClose={() => setResetting(false)}
        >
          <p className="dialog-description">
            Direct HTTP clients will need updated setup. The local stdio bridge reads the new key
            automatically.
          </p>
          <div className="modal-footer">
            <button className="secondary-button" onClick={() => setResetting(false)}>
              Cancel
            </button>
            <button
              className="primary-button"
              disabled={busy}
              onClick={() =>
                void perform(async () => {
                  setConnection(await action<Connection>('reset_connection_key'))
                  setResetting(false)
                  setNotice('Connection key reset. Copy new HTTP setup for direct clients.')
                })
              }
            >
              Reset key
            </button>
          </div>
        </Modal>
      )}
    </Modal>
  )
}
