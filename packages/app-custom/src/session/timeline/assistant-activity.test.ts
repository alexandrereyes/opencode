import { describe, expect, test } from "bun:test"
import type { SessionMessageAssistant, SessionMessageToolStateRunning } from "@opencode/client/promise"
import { assistantActivity, genericActivityCount, sameActivity } from "./assistant-activity"

type Content = SessionMessageAssistant["content"][number]

const assistant = (content: Content[], time: SessionMessageAssistant["time"] = { created: 1 }) =>
  ({
    id: "msg_assistant",
    type: "assistant",
    agent: "build",
    model: { id: "model", providerID: "provider" },
    content,
    time,
  }) satisfies SessionMessageAssistant

const tool = (name: string, state: Extract<Content, { type: "tool" }>["state"]): Content => ({
  type: "tool",
  id: `call_${name}`,
  name,
  state,
  time: { created: 1 },
})

const running = (metadata: SessionMessageToolStateRunning["metadata"] = {}): SessionMessageToolStateRunning => ({
  status: "running",
  input: {},
  metadata,
})

const activity = (value: SessionMessageAssistant | undefined, permission = false) =>
  assistantActivity({ assistant: value, permission, key: "ses_test:msg_assistant" })

describe("assistant activity", () => {
  test("names the running tool", () => {
    expect(activity(assistant([tool("read", running())]))).toEqual({ type: "tool", tool: "read" })
    expect(activity(assistant([tool("shell", { status: "streaming", input: "{" })]))).toEqual({
      type: "tool",
      tool: "shell",
    })
  })

  test("names the latest call of a running Code Mode script", () => {
    const calls = [
      { tool: "read", status: "completed" },
      { tool: "browser.tabs.open", status: "running" },
    ]
    expect(activity(assistant([tool("execute", running({ toolCalls: calls }))]))).toEqual({
      type: "calling",
      tool: "browser.tabs.open",
    })
    expect(activity(assistant([tool("execute", running({ toolCalls: [] }))]))).toEqual({
      type: "tool",
      tool: "execute",
    })
  })

  test("prefers the latest running content", () => {
    const content: Content[] = [
      { type: "reasoning", text: "Plan", time: { created: 1, completed: 2 } },
      tool("grep", running()),
      tool("glob", { status: "completed", input: {}, content: [{ type: "text", text: "src/a.ts" }] }),
    ]
    expect(activity(assistant(content))).toEqual({ type: "tool", tool: "grep" })
  })

  test("reports reasoning and streaming text until model output ends", () => {
    const reasoning: Content = { type: "reasoning", text: "", time: { created: 1 } }
    expect(activity(assistant([reasoning]))).toEqual({ type: "thinking" })
    expect(activity(assistant([{ type: "text", text: "Answer" }]))).toEqual({ type: "composing" })
    expect(activity(assistant([{ type: "text", text: "  " }]))?.type).toBe("generic")
    expect(activity(assistant([reasoning], { created: 1, streamed: 2 }))?.type).toBe("generic")
    expect(activity(assistant([{ type: "text", text: "Answer" }], { created: 1, streamed: 2 }))?.type).toBe("generic")
  })

  test("ignores completed responses and falls back to a stable generic phrase", () => {
    const completed = assistant([tool("read", running())], { created: 1, completed: 2 })
    const first = activity(completed)
    expect(first.type).toBe("generic")
    expect(activity(undefined)).toEqual(first)
    if (first.type !== "generic") throw new Error("expected a generic activity")
    expect(first.phrase).toBeGreaterThanOrEqual(0)
    expect(first.phrase).toBeLessThan(genericActivityCount)
  })

  test("reports a pending permission before any running work", () => {
    expect(activity(assistant([tool("shell", running())]), true)).toEqual({ type: "permission" })
  })

  test("compares activities by their visible identity", () => {
    expect(sameActivity({ type: "tool", tool: "read" }, { type: "tool", tool: "read" })).toBe(true)
    expect(sameActivity({ type: "tool", tool: "read" }, { type: "tool", tool: "grep" })).toBe(false)
    expect(sameActivity({ type: "tool", tool: "read" }, { type: "calling", tool: "read" })).toBe(false)
    expect(sameActivity({ type: "generic", phrase: 1 }, { type: "generic", phrase: 2 })).toBe(false)
    expect(sameActivity({ type: "thinking" }, { type: "thinking" })).toBe(true)
  })
})
