import type { Session } from "@opencode/schema/session"

/** Work a Session started and moved to the background, such as a `shell` command or a `subagent`. */
export interface BackgroundJob {
  readonly id: string
  readonly type: string
  /** The Session that started the job and is notified when it ends. */
  readonly sessionID: Session.ID
  readonly title?: string
  readonly started: number
}
