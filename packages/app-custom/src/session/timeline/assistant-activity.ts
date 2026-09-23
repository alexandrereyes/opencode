import type { SessionMessageAssistant } from "@opencode/client/promise"

export const genericActivityCount = 14

export type AssistantActivity =
  | { type: "permission" }
  | { type: "thinking" }
  | { type: "composing" }
  | { type: "tool"; tool: string }
  | { type: "calling"; tool: string }
  | { type: "generic"; phrase: number }

/** Describes what the assistant is doing now from the latest response to the active prompt. */
export function assistantActivity(input: {
  assistant: SessionMessageAssistant | undefined
  permission: boolean
  key: string
}): AssistantActivity {
  if (input.permission) return { type: "permission" }
  const assistant = input.assistant
  const content = assistant && assistant.time.completed === undefined ? assistant.content : []
  // `streamed` marks the end of model output; tools can keep running after it.
  const streaming = assistant?.time.streamed === undefined
  const active = content.findLast((item, index) => {
    if (item.type === "tool") return item.state.status === "streaming" || item.state.status === "running"
    if (item.type === "reasoning") return streaming && item.time?.completed === undefined
    return streaming && index === content.length - 1 && item.text.trim() !== ""
  })
  if (active?.type === "reasoning") return { type: "thinking" }
  if (active?.type === "text") return { type: "composing" }
  if (active?.type === "tool") {
    const tool =
      active.name === "execute" && active.state.status === "running" ? calledTool(active.state.metadata) : undefined
    return tool ? { type: "calling", tool } : { type: "tool", tool: active.name }
  }
  return { type: "generic", phrase: hash(input.key) % genericActivityCount }
}

export function sameActivity(a: AssistantActivity, b: AssistantActivity) {
  if (a.type !== b.type) return false
  if (a.type === "tool" || a.type === "calling") return a.tool === (b as typeof a).tool
  if (a.type === "generic") return a.phrase === (b as typeof a).phrase
  return true
}

function calledTool(metadata: Record<string, unknown>) {
  // Code Mode reports the calls its script made so far; the latest one is the current work.
  const calls = metadata.toolCalls
  const last = Array.isArray(calls) ? calls.at(-1) : undefined
  if (!last || typeof last !== "object" || !("tool" in last) || typeof last.tool !== "string") return
  return last.tool
}

function hash(value: string) {
  return Math.abs([...value].reduce((result, char) => ((result << 5) - result + char.charCodeAt(0)) | 0, 0))
}
