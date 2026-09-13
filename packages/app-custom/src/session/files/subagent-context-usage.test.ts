import { describe, expect, test } from "bun:test"
import type { ModelInfo, SessionMessageInfo } from "@opencode/client/promise"
import { latestContextMessage, subagentContext } from "./subagent-context-usage"

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
    expect(subagentContext(measured, models)).toEqual({ total: 86_800, usage: 8.3 })
  })

  test("keeps distinct children and the measured model independent", () => {
    expect(subagentContext(message("one", 1, 86_000), models)?.usage).toBe(8.3)
    expect(subagentContext(message("two", 2, 86_000, "small"), models)?.usage).toBe(86.8)
  })

  test("keeps the last measurement during streaming, then accepts a smaller post-compaction call", () => {
    const previous = message("previous", 1, 86_000)
    expect(latestContextMessage([previous, message("streaming", 2)])).toBe(previous)
    expect(subagentContext(latestContextMessage([previous, message("streaming", 2, 5_000)]), models)?.total).toBe(5_800)
  })

  test("unknown usage and unknown limits are not reported as zero percent", () => {
    expect(subagentContext(latestContextMessage([message("pending", 1)]), models)).toBeUndefined()
    expect(subagentContext(message("measured", 1, 86_000))).toEqual({ total: 86_800, usage: null })
  })

  test("a live measurement wins over an older in-flight response regardless of array order", () => {
    const live = message("live", 2, 30_000)
    expect(latestContextMessage([live, message("response", 1, 90_000)])).toBe(live)
  })
})
