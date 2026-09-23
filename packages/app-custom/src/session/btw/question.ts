import type { Prompt } from "@/composer/state"
import { expandSnippets, isAttachment } from "@/composer/prompt-parts"
import { formatAppContext } from "@/composer/request"
import { formatSessionContexts } from "@/composer/session-reference"

// Generate accepts text only. Keep file/agent/skill mentions as textual
// references; omit binary attachments and never upload or read their contents.
export function btwQuestionText(prompt: Prompt) {
  const parts = expandSnippets(prompt).filter((part) => !isAttachment(part))
  return [
    parts.map((part) => ("content" in part ? part.content : "")).join(""),
    ...parts.filter((part) => part.type === "app").map(formatAppContext),
    ...formatSessionContexts(parts.filter((part) => part.type === "session")),
  ]
    .filter(Boolean)
    .join("\n\n")
}
