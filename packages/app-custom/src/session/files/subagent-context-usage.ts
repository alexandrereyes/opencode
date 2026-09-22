import type { ModelInfo, SessionMessageInfo } from "@opencode/client/promise"
import type { MeasuredContext } from "@/session/family"

export function latestContextMessage(messages: readonly SessionMessageInfo[]) {
  // This is the last provider measurement, not an estimate of unmeasured input
  // or a compaction summary. A new streaming step does not yet have tokens.
  return messages
    .filter((message) => message.type === "assistant" && message.tokens !== undefined)
    .reduce<
      (typeof messages)[number] | undefined
    >((latest, message) => (!latest || message.time.created >= latest.time.created ? message : latest), undefined)
}

/** The page carries the stored measurement; a cached live message only wins when it is newer. */
export function measuredContext(
  live: SessionMessageInfo | undefined,
  paged?: MeasuredContext,
): MeasuredContext | undefined {
  if (live?.type !== "assistant" || !live.tokens || (paged && live.id < paged.id)) return paged
  return { id: live.id, tokens: live.tokens, model: live.model }
}

export function subagentContext(context: MeasuredContext | undefined, models: readonly ModelInfo[] = []) {
  if (!context) return
  const total =
    context.tokens.input +
    context.tokens.output +
    context.tokens.reasoning +
    context.tokens.cache.read +
    context.tokens.cache.write
  const model = models.find((model) => model.providerID === context.model.providerID && model.id === context.model.id)
  return {
    total,
    usage: model && model.limit.context > 0 ? Math.round((total / model.limit.context) * 1000) / 10 : null,
  }
}
