import type { SessionMessageAssistant, SessionMessageInfo } from "./promise/index"

export function turnDuration(message: SessionMessageAssistant, messages: SessionMessageInfo[], position?: number) {
  if (message.time.completed === undefined) return 0
  const index = position ?? messages.findIndex((item) => item.id === message.id)
  const input = messages[inputIndex(messages, index === -1 ? messages.length : index)]
  return Math.max(0, message.time.completed - (input?.time.created ?? message.time.created))
}

export function turnTokensPerSecond(
  message: SessionMessageAssistant,
  messages: SessionMessageInfo[],
  position?: number,
) {
  const index = position ?? messages.findIndex((item) => item.id === message.id)
  const end = index === -1 ? messages.length : index + 1
  const start = inputIndex(messages, end)
  const steps = messages
    .slice(start + 1, end)
    .filter((item): item is SessionMessageAssistant => item.type === "assistant")
  const durations = steps.flatMap((step) =>
    step.time.streamed === undefined ? [] : [Math.max(0, step.time.streamed - step.time.created)],
  )
  if (steps.length === 0 || durations.length !== steps.length) return
  const output = steps.reduce((total, step) => total + (step.tokens?.output ?? 0), 0)
  const duration = durations.reduce((total, value) => total + value, 0)
  if (output <= 0 || duration <= 0) return
  return output / (duration / 1_000)
}

function inputIndex(messages: SessionMessageInfo[], end: number) {
  // Reading a sliced prefix subscribes every footer to unrelated historical messages.
  for (let index = end - 1; index >= 0; index--) {
    const message = messages[index]
    if (message.type === "user" || message.type === "synthetic") return index
  }
  return -1
}
