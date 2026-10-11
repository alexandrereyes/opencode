import type { PromptFileAttachment } from "@opencode/client/promise"

export type SessionUserComment = {
  path: string
  comment: string
  selection?: {
    startLine: number
    endLine: number
  }
}

export type SessionUserQuote = {
  id: string
  text: string
  comment: string
}

/** An attachment delivered to the model as a server path instead of inline bytes. */
export type SessionUserAttachmentReference = {
  name: string
  mime: string
  path: string
}

export type SessionUserActions = {
  openAttachment?: (file: PromptFileAttachment) => void
  revert?: (input: { sessionID: string; messageID: string }) => Promise<void> | void
  fork?: (input: { sessionID: string; messageID: string }) => Promise<void> | void
  /**
   * An input the server has not delivered yet. Like the TUI, a pending steer can move to the queue or be deleted;
   * it shows as waiting only while `steering` behind delivered work or `stranded` by an execution that ended.
   */
  pending?: {
    status: (messageID: string) => "starting" | "steering" | "stranded" | "queued" | undefined
    queue: (input: { sessionID: string; messageID: string }) => Promise<void>
    remove: (input: { sessionID: string; messageID: string }) => Promise<void>
  }
}

export type SessionPendingStatus = ReturnType<NonNullable<SessionUserActions["pending"]>["status"]>

/**
 * A pending steer offers its queue and delete actions until the server delivers it; it reads as waiting, with its own
 * label and color, only behind delivered work (`steering`) or after an execution ended without it (`stranded`). A
 * `starting` steer is promoted at the next idle boundary and a `queued` item lives in the queue panel.
 */
export function pendingSteerPresentation(status: SessionPendingStatus) {
  return {
    actions: status !== undefined && status !== "queued",
    waiting: status === "steering" || status === "stranded",
  }
}
