import type { ModelInfo, SessionMessageInfo } from "@opencode/client/promise"

export function latestContextMessage(messages: readonly SessionMessageInfo[]) {
  // This is the last provider measurement, not an estimate of unmeasured input
  // or a compaction summary. A new streaming step does not yet have tokens.
  return messages
    .filter((message) => message.type === "assistant" && message.tokens !== undefined)
    .reduce<
      (typeof messages)[number] | undefined
    >((latest, message) => (!latest || message.time.created >= latest.time.created ? message : latest), undefined)
}

export function subagentContext(message: SessionMessageInfo | undefined, models: readonly ModelInfo[] = []) {
  if (message?.type !== "assistant" || !message.tokens) return
  const total =
    message.tokens.input +
    message.tokens.output +
    message.tokens.reasoning +
    message.tokens.cache.read +
    message.tokens.cache.write
  const model = models.find((model) => model.providerID === message.model.providerID && model.id === message.model.id)
  return {
    total,
    usage: model && model.limit.context > 0 ? Math.round((total / model.limit.context) * 1000) / 10 : null,
  }
}
