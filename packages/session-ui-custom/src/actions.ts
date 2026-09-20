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
}
