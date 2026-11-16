export const statuses = ['To do', 'Sent to agent', 'In progress', 'Done'] as const
export type Status = (typeof statuses)[number]
export type Theme = 'graphite' | 'warm-paper' | 'native-light' | 'system'
export type TaskAgent = 'claude-code' | 'codex'
export const priorities = ['Urgent', 'High', 'Medium', 'Low', 'None'] as const
export type Priority = (typeof priorities)[number]
export const agentNames = { 'claude-code': 'Claude', codex: 'Codex' }
export interface AgentSettings {
  defaultAgent: TaskAgent
  workingFolder: string
}
export interface AgentRun {
  id: string
  taskId: string
  agent: TaskAgent
  workingFolder: string
  state:
    | 'queued'
    | 'starting'
    | 'working'
    | 'needs-input'
    | 'review'
    | 'done'
    | 'failed'
    | 'canceled'
    | 'interrupted'
  threadId: string | null
  summary: string
  approval?: { id: string; title: string; details: string; canApprove: boolean } | null
}
export interface CommentImage {
  id: string
  name: string
  mimeType: 'image/png' | 'image/jpeg'
}
export interface TaskComment {
  id: string
  taskId: string
  text: string
  createdAt: string
  delivery: 'pending' | 'queued' | 'delivered' | 'needs-review' | 'local'
  agent: TaskAgent | null
  images: CommentImage[]
}
export interface Board {
  id: string
  name: string
  icon: string | null
  position: number
  revision: number
  createdAt: string
}
export interface Task {
  id: string
  boardId: string
  title: string
  notes: string
  status: Status
  priority: Priority
  definitionOfDone: string
  dueDate: string | null
  commentCount: number
  imageCount: number
  position: number
  deleted: boolean
  deletedAt: string | null
  archivedAt?: string | null
  revision: number
  createdAt: string
  updatedAt: string
}
export interface Workspace {
  version: 1
  theme: Theme
  selectedBoard: string
  preferencesRevision: number
  revision: number
  boards: Board[]
  tasks: Task[]
  agentRuns: AgentRun[]
  agentAssignments: Record<string, string>
  allTasksOrder: string[]
}
export interface Connection {
  enabled: boolean
  running: boolean
  endpoint: string | null
  error: string
  configFile: string
}
export interface Preview {
  token: string
  action: string
  summary: { count?: number; boards?: number; tasks?: number; trash?: number; path?: string }
  revision: number
  expiresAt: string
}
export interface ActionError {
  code: string
  message: string
  details?: { current?: Task }
}
export class SaveError extends Error {
  readonly code: string
  readonly current?: Task
  constructor(error: ActionError) {
    super(error.message)
    this.code = error.code
    this.current = error.details?.current
  }
}
export async function action<T>(name: string, input: Record<string, unknown> = {}): Promise<T> {
  if (!window.opentalon)
    throw new Error('Open OpenTalon as a desktop app to use its local database.')
  const result = await window.opentalon.action(name, input)
  if (!result.ok) throw new SaveError(result.error)
  return result.data as T
}
export const requestKey = () => crypto.randomUUID()
export const storageKey = 'opentalon-prototype-v1'
