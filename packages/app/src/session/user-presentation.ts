import type { SessionMessageUser } from "@opencode/client/promise"
import type { SessionUserPresentation } from "@opencode/session-ui/timeline/row"
import { parseCommentNote, readPromptPresentation } from "@/composer/comment-note"
import { extractPromptSessions } from "@/composer/prompt"
import { formatSessionReferences } from "@/composer/session-reference"

export function userPresentation(message: SessionMessageUser): SessionUserPresentation {
  const value = readPromptPresentation(message.metadata)
  const parsed = value ? undefined : parseCommentNote(message.text)
  const sessions = extractPromptSessions(message.metadata)
  // Quotes are presentation data; copying still includes their complete model-visible context.
  const copyText = value?.quotes.length ? message.text : value?.displayText
  return {
    displayText: value?.displayText,
    copyText: copyText ? formatSessionReferences(copyText, sessions) : undefined,
    comments: value?.comments ?? (parsed ? [parsed] : []),
    quotes: value?.quotes,
    sessions: sessions.map((session) => ({ start: session.start, end: session.end })),
  }
}
