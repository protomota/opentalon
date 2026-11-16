import type { ActionError } from './model'
export {}
declare global {
  interface Window {
    opentalon?: {
      platform: string
      action: (
        name: string,
        input?: Record<string, unknown>
      ) => Promise<{ ok: true; data: unknown } | { ok: false; error: ActionError }>
      onCommand: (callback: (command: string) => void) => () => void
      onChanged: (callback: () => void) => () => void
    }
  }
}
