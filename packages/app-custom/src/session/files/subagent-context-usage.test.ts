import { describe, expect, test } from "bun:test"
import type { ModelInfo, SessionMessageInfo } from "@opencode/client/promise"
import { cacheHitRate, latestContextMessage, measuredContext, subagentContext } from "./subagent-context-usage"

const message = (id: string, created: number, input?: number, model = "large"): SessionMessageInfo => ({
  id,
  type: "assistant",
  agent: "solmedium",
  model: { providerID: "test", id: model, variant: "medium" },
  content: [],
  time: { created },
  ...(input === undefined ? {} : { tokens: { input, output: 100, reasoning: 200, cache: { read: 500, write: 0 } } }),
})
const models = [
  { id: "large", providerID: "test", limit: { context: 1_048_576 } },
  { id: "small", providerID: "test", limit: { context: 100_000 } },
] as ModelInfo[]

describe("subagent measured context", () => {
  test("uses the last measured call, never the cumulative session consumption", () => {
    const measured = latestContextMessage([message("old", 1, 900_000), message("new", 2, 86_000)])
    expect(subagentContext(measuredContext(measured), models)).toEqual({ total: 86_800, usage: 8.3, cacheHit: 500 / 86_500 })
  })

  test("keeps distinct children and the measured model independent", () => {
    expect(subagentContext(measuredContext(message("one", 1, 86_000)), models)?.usage).toBe(8.3)
    expect(subagentContext(measuredContext(message("two", 2, 86_000, "small")), models)?.usage).toBe(86.8)
  })

  test("keeps the last measurement during streaming, then accepts a smaller post-compaction call", () => {
    const previous = message("previous", 1, 86_000)
    expect(latestContextMessage([previous, message("streaming", 2)])).toBe(previous)
    expect(subagentContext(measuredContext(latestContextMessage([previous, message("streaming", 2, 5_000)])), models)?.total).toBe(5_800)
  })

  test("unknown usage and unknown limits are not reported as zero percent", () => {
    expect(subagentContext(measuredContext(latestContextMessage([message("pending", 1)])), models)).toBeUndefined()
    expect(subagentContext(measuredContext(message("measured", 1, 86_000)))).toEqual({ total: 86_800, usage: null, cacheHit: 500 / 86_500 })
  })

  test("cache hit rate counts cache reads against the full prompt, including cache writes", () => {
    expect(cacheHitRate({ input: 100, output: 200, reasoning: 0, cache: { read: 900, write: 100 } })).toBe(900 / 1_100)
    expect(cacheHitRate({ input: 2_000, output: 10, reasoning: 0, cache: { read: 0, write: 2_000 } })).toBe(0)
    expect(cacheHitRate({ input: 0, output: 10, reasoning: 0, cache: { read: 0, write: 0 } })).toBeNull()
  })

  test("a live measurement wins over an older in-flight response regardless of array order", () => {
    const live = message("live", 2, 30_000)
    expect(latestContextMessage([live, message("response", 1, 90_000)])).toBe(live)
  })

  test("page context is the default and only a newer live message replaces it", () => {
    const paged = measuredContext(message("msg_2", 2, 90_000))!
    expect(measuredContext(undefined, paged)).toBe(paged)
    expect(measuredContext(message("msg_1", 1, 30_000), paged)).toBe(paged)
    expect(measuredContext(message("msg_3", 3), paged)).toBe(paged)
    expect(measuredContext(message("msg_3", 3, 30_000), paged)?.tokens.input).toBe(30_000)
  })
})
