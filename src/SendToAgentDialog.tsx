import { useState } from 'react'
import { Modal } from './Modal'
import { TaskAgentSettings } from './TaskAgentSettings'

export function SendToAgentDialog({
  title,
  onClose,
  onSend,
}: {
  title: string
  onClose: () => void
  onSend: () => Promise<void>
}) {
  const [ready, setReady] = useState(false)
  const [sending, setSending] = useState(false)
  const [error, setError] = useState('')
  return (
    <Modal
      title="Set up and send to agent"
      className="settings-modal"
      onClose={() => {
        if (!sending) onClose()
      }}
    >
      <p className="dialog-description">
        Ready to send: <strong>{title}</strong>. Choose a working folder and check your agent
        connection below. Your task stays where it is until you send it.
      </p>
      <TaskAgentSettings onReadyChange={setReady} />
      {error && (
        <p className="settings-feedback error-text" role="alert">
          {error}
        </p>
      )}
      <div className="modal-footer">
        <button className="secondary-button" disabled={sending} onClick={onClose}>
          Cancel
        </button>
        <button
          className="primary-button"
          disabled={!ready || sending}
          onClick={async () => {
            setSending(true)
            setError('')
            try {
              await onSend()
            } catch (error) {
              setError(error instanceof Error ? error.message : 'Could not send this task.')
            } finally {
              setSending(false)
            }
          }}
        >
          {sending ? 'Sending…' : 'Send to agent'}
        </button>
      </div>
    </Modal>
  )
}
