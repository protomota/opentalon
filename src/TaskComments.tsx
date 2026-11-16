import { useEffect, useState } from 'react'
import { ImagePlus, Clipboard, X } from 'lucide-react'
import { Modal } from './Modal'
import { action, agentNames, requestKey, type CommentImage, type TaskComment } from './model'
type DraftImage = { name: string; mimeType: 'image/png' | 'image/jpeg'; data: string }

function CommentScreenshot({ image }: { image: CommentImage }) {
  const [url, setUrl] = useState('')
  const [error, setError] = useState('')
  const [expanded, setExpanded] = useState(false)
  return (
    <div className="comment-screenshot">
      <button
        className="text-button"
        onClick={async () => {
          if (url) {
            setUrl('')
            return
          }
          try {
            const result = await action<DraftImage>('read_comment_image', { imageId: image.id })
            setUrl(`data:${result.mimeType};base64,${result.data}`)
          } catch (error) {
            setError(error instanceof Error ? error.message : 'Could not open this screenshot.')
          }
        }}
      >
        {url ? 'Hide' : 'View'} screenshot · {image.name}
      </button>
      {url && (
        <button
          className="comment-image-preview"
          aria-label={`Enlarge ${image.name}`}
          onClick={() => setExpanded(true)}
        >
          <img src={url} alt={image.name} />
        </button>
      )}
      {expanded && (
        <Modal
          title={image.name}
          onClose={() => setExpanded(false)}
          className="comment-image-modal"
        >
          <img src={url} alt={image.name} />
        </Modal>
      )}
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </div>
  )
}
export function TaskComments({
  taskId,
  revision,
  inProgress,
  agentAssigned,
  onDirty,
}: {
  taskId: string
  revision: number
  inProgress: boolean
  agentAssigned: boolean
  onDirty: (dirty: boolean) => void
}) {
  const [comments, setComments] = useState<TaskComment[]>([])
  const [text, setText] = useState('')
  const [images, setImages] = useState<DraftImage[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [pendingKey, setPendingKey] = useState(requestKey)
  useEffect(() => {
    let active = true
    action<{ comments: TaskComment[] }>('list_task_comments', { taskId })
      .then((result) => {
        if (active) setComments(result.comments)
      })
      .catch((error) => {
        if (active) setError(error.message)
      })
    return () => {
      active = false
    }
  }, [taskId, revision])
  useEffect(() => {
    onDirty(!!text || !!images.length || busy)
    return () => onDirty(false)
  }, [text, images.length, busy, onDirty])
  async function attach(name: 'choose_comment_images' | 'paste_comment_image') {
    setError('')
    setBusy(true)
    try {
      const result = await action<{ images: DraftImage[] }>(name)
      if (images.length + result.images.length > 3)
        throw new Error('Attach up to three screenshots per comment.')
      setImages((current) => [...current, ...result.images])
      setPendingKey(requestKey())
    } catch (error) {
      setError(error instanceof Error ? error.message : 'Could not attach the screenshot.')
    } finally {
      setBusy(false)
    }
  }
  return (
    <section className="task-comments" aria-label="Task comments">
      <h3>Comments</h3>
      <p className="field-caption">
        {agentAssigned
          ? 'Comments on this agent task are checked every five minutes while In progress. OpenTalon must be running.'
          : 'Your comments stay with this manual task. Move it to Sent to agent only when you want agent help.'}
      </p>
      <ol className="comment-list">
        {comments.map((comment) => (
          <li key={comment.id} className="task-comment">
            <p>{comment.text}</p>
            {comment.images.map((image) => (
              <CommentScreenshot key={image.id} image={image} />
            ))}
            <span className="field-caption">
              {new Date(comment.createdAt).toLocaleString()} ·{' '}
              {comment.delivery === 'delivered'
                ? `Sent to ${comment.agent ? agentNames[comment.agent] : 'agent'}`
                : comment.delivery === 'queued'
                  ? 'Queued for agent'
                  : comment.delivery === 'needs-review'
                    ? 'Review the conversation before resending'
                    : comment.delivery === 'local'
                      ? 'Saved'
                      : 'Waiting for the next check'}
            </span>
            {comment.delivery === 'needs-review' && (
              <button
                className="text-button"
                disabled={busy}
                onClick={async () => {
                  setBusy(true)
                  setError('')
                  try {
                    await action('retry_task_comment', { id: comment.id, requestKey: requestKey() })
                    setNotice(
                      'Queued for the next check. Resending may repeat work if the previous delivery was uncertain.'
                    )
                  } catch (error) {
                    setError(
                      error instanceof Error ? error.message : 'Could not requeue this comment.'
                    )
                  } finally {
                    setBusy(false)
                  }
                }}
              >
                I reviewed the conversation — queue again
              </button>
            )}
          </li>
        ))}
      </ol>
      <label htmlFor="task-comment-text">Leave a comment</label>
      <textarea
        id="task-comment-text"
        rows={3}
        maxLength={10000}
        value={text}
        disabled={busy}
        placeholder="Tell your agent what to change…"
        onChange={(event) => {
          setText(event.target.value)
          setPendingKey(requestKey())
          setError('')
        }}
        onPaste={(event) => {
          if ([...event.clipboardData.items].some((item) => item.type.startsWith('image/'))) {
            event.preventDefault()
            void attach('paste_comment_image')
          }
        }}
      />
      {images.length > 0 && (
        <div className="comment-draft-images">
          {images.map((image, index) => (
            <div key={index}>
              <img
                src={`data:${image.mimeType};base64,${image.data}`}
                alt={`Attached screenshot ${index + 1}`}
              />
              <button
                className="icon-button"
                disabled={busy}
                aria-label={`Remove screenshot ${index + 1}`}
                onClick={() => {
                  setImages((current) => current.filter((_, i) => i !== index))
                  setPendingKey(requestKey())
                }}
              >
                <X size={14} />
              </button>
            </div>
          ))}
        </div>
      )}
      <div className="settings-actions">
        <button
          className="secondary-button"
          disabled={busy || images.length >= 3}
          onClick={() => void attach('choose_comment_images')}
        >
          <ImagePlus size={14} />
          Attach screenshots
        </button>
        <button
          className="secondary-button"
          disabled={busy || images.length >= 3}
          onClick={() => void attach('paste_comment_image')}
        >
          <Clipboard size={14} />
          Paste screenshot
        </button>
        <button
          className="primary-button"
          disabled={busy || (!text.trim() && !images.length)}
          onClick={async () => {
            setBusy(true)
            setError('')
            setNotice('')
            try {
              const result = await action<{ comment: TaskComment }>('add_task_comment', {
                taskId,
                text,
                images,
                notifyAgent: agentAssigned,
                requestKey: pendingKey,
              })
              setComments((current) =>
                current.some((comment) => comment.id === result.comment.id)
                  ? current
                  : [...current, result.comment]
              )
              setText('')
              setImages([])
              setPendingKey(requestKey())
              setNotice(
                agentAssigned && inProgress
                  ? 'Comment saved for the next agent check.'
                  : 'Comment saved for you. This task will not run automatically.'
              )
            } catch (error) {
              setError(
                error instanceof Error
                  ? error.message
                  : 'Could not save. Your comment is still here.'
              )
            } finally {
              setBusy(false)
            }
          }}
        >
          Post comment
        </button>
        {agentAssigned &&
          inProgress &&
          comments.some((comment) => comment.delivery === 'pending') && (
            <button
              className="text-button"
              disabled={busy}
              onClick={async () => {
                setBusy(true)
                setError('')
                try {
                  const result = await action<{ queued: number }>('check_task_comments')
                  setNotice(
                    result.queued
                      ? 'Comments queued for the agent.'
                      : 'Waiting for the existing run to finish or for a resumable agent conversation.'
                  )
                } catch (error) {
                  setError(error instanceof Error ? error.message : 'Could not check comments.')
                } finally {
                  setBusy(false)
                }
              }}
            >
              Check now
            </button>
          )}
      </div>
      {!!text || !!images.length ? (
        <button
          className="text-button"
          disabled={busy}
          onClick={() => {
            setText('')
            setImages([])
            setPendingKey(requestKey())
            setError('')
          }}
        >
          Discard comment draft
        </button>
      ) : null}
      {notice && (
        <p className="field-caption" role="status">
          {notice}
        </p>
      )}
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </section>
  )
}
