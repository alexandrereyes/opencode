import { afterEach, expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import type { MessageListInput, SessionMessagesResponse } from "@opencode/client/promise"
import { createOpenCodeEventSource } from "@/runtime/server/client"
import { createDashboardPreview, createPreviewQueue } from "@/agent-dashboard/preview"

const disposers = new Set<() => void>()
afterEach(() => {
  disposers.forEach((dispose) => dispose())
  disposers.clear()
})

const sessionID = "ses_dashboard_preview"
const envelope = {
  id: "evt_dashboard_preview",
  created: 3,
  durable: { aggregateID: sessionID, seq: 1, version: 1 as const },
}
const textData = { sessionID, assistantMessageID: "msg_preview", ordinal: 0 }

function page(text: string, tool = false): SessionMessagesResponse {
  return {
    cursor: {},
    data: [
      {
        id: "msg_preview",
        type: "assistant",
        time: { created: 1 },
        agent: "build",
        model: { providerID: "test", id: "test" },
        content: [
          { type: "text", text },
          ...(tool
            ? [
                {
                  type: "tool" as const,
                  id: "tool_preview",
                  name: "shell",
                  time: { created: 2 },
                  state: { status: "streaming" as const, input: "" },
                },
              ]
            : []),
        ],
      },
    ],
  }
}

function fixture(count = 1) {
  return createRoot((dispose) => {
    disposers.add(dispose)
    const source = createOpenCodeEventSource()
    const [visibility, setVisibility] = createStore({ visible: true })
    const requests = Array.from({ length: count }, () => ({
      response: Promise.withResolvers<SessionMessagesResponse>(),
      started: Promise.withResolvers<void>(),
      finished: Promise.withResolvers<void>(),
      signal: undefined as AbortSignal | undefined,
      input: undefined as MessageListInput | undefined,
    }))
    const counters = { reads: 0, jobs: 0 }
    const queue = createPreviewQueue()
    const sdk: Parameters<typeof createDashboardPreview>[0]["sdk"] = {
      connection: { status: () => "connected" },
      event: source.event,
      api: {
        message: {
          list: (input, options) => {
            const request = requests[counters.reads++]
            request.input = input
            request.signal = options?.signal
            request.started.resolve()
            // Deliberately allow late responses even after abort, to exercise publication guards.
            return request.response.promise
          },
        },
      },
    }
    const state = createDashboardPreview({
      sdk,
      sessionID,
      visible: () => visibility.visible,
      enqueue: (task) => {
        const request = requests[counters.jobs++]
        queue(async () => {
          await task()
          request.finished.resolve()
        })
      },
    })
    return {
      state,
      requests,
      publish: source.publish,
      dispose,
      visible: (visible: boolean) => setVisibility("visible", visible),
    }
  })
}

test("preview bootstraps a bounded snapshot then follows text delta/ended without reasoning", async () => {
  const preview = fixture()
  const request = preview.requests[0]
  await request.started.promise
  expect(request.input).toEqual({ sessionID, limit: 3, order: "desc" })
  request.response.resolve(page("Hello"))
  await request.finished.promise
  expect(preview.state).toMatchObject({ text: "Hello", loading: false, error: false })
  preview.publish({ ...envelope, type: "session.text.delta", data: { ...textData, delta: " world" } })
  expect(preview.state.text).toBe("Hello world")
  preview.publish({ ...envelope, type: "session.reasoning.delta", data: { ...textData, delta: "private" } })
  expect(preview.state.text).toBe("Hello world")
  preview.publish({ ...envelope, type: "session.text.ended", data: { ...textData, text: "Hello world!" } })
  expect(preview.state.text).toBe("Hello world!")
  preview.publish({ ...envelope, type: "session.text.started", data: textData })
  preview.publish({ ...envelope, type: "session.text.delta", data: { ...textData, delta: "Next response" } })
  expect(preview.state.text).toBe("Next response")
})

test("an in-flight snapshot cannot overwrite newer SSE text or tool state", async () => {
  const preview = fixture()
  const request = preview.requests[0]
  await request.started.promise
  preview.publish({ ...envelope, type: "session.text.started", data: textData })
  preview.publish({ ...envelope, type: "session.text.ended", data: { ...textData, text: "New response" } })
  preview.publish({
    ...envelope,
    type: "session.tool.input.started",
    data: { sessionID, assistantMessageID: "msg_preview", id: "tool_new", name: "read" },
  })
  request.response.resolve(page("Stale response", true))
  await request.finished.promise
  expect(preview.state).toMatchObject({ text: "New response", tool: "read", loading: false, error: false })
})

test("a superseded read failure does not mark a newer live preview as failed", async () => {
  const preview = fixture()
  const request = preview.requests[0]
  await request.started.promise
  preview.publish({ ...envelope, type: "session.text.ended", data: { ...textData, text: "Live response" } })
  request.response.reject(new Error("Snapshot request failed"))
  await request.finished.promise
  expect(preview.state).toMatchObject({ text: "Live response", loading: false, error: false })
})

for (const outcome of ["succeeded", "interrupted"] as const) {
  test(`execution ${outcome} immediately clears the tool and refreshes the preview`, async () => {
    const preview = fixture(2)
    const initial = preview.requests[0]
    await initial.started.promise
    initial.response.resolve(page("Working", true))
    await initial.finished.promise
    expect(preview.state.tool).toBe("shell")
    preview.publish(
      outcome === "succeeded"
        ? { ...envelope, type: "session.execution.succeeded", data: { sessionID } }
        : { ...envelope, type: "session.execution.interrupted", data: { sessionID, reason: "user" } },
    )
    expect(preview.state.tool).toBeUndefined()
    const refresh = preview.requests[1]
    await refresh.started.promise
    refresh.response.resolve(page("Final response"))
    await refresh.finished.promise
    expect(preview.state).toMatchObject({ text: "Final response", loading: false, error: false })
    expect(preview.state.tool).toBeUndefined()
  })
}

for (const leave of ["viewport", "unmount"] as const) {
  test(`leaving ${leave} aborts the request and ignores late responses and events`, async () => {
    const preview = fixture()
    const request = preview.requests[0]
    await request.started.promise
    expect(request.signal?.aborted).toBe(false)
    preview.publish({ ...envelope, type: "session.text.ended", data: { ...textData, text: "Before leaving" } })
    if (leave === "viewport") preview.visible(false)
    if (leave === "unmount") preview.dispose()
    expect(request.signal?.aborted).toBe(true)
    preview.publish({ ...envelope, type: "session.text.ended", data: { ...textData, text: "After leaving" } })
    request.response.resolve(page("Late snapshot", true))
    await request.finished.promise
    expect(preview.state).toMatchObject({ text: "Before leaving", tool: undefined, error: false })
  })
}

test("returning to the viewport revalidates without accepting the previous visit's response", async () => {
  const preview = fixture(2)
  const first = preview.requests[0]
  await first.started.promise
  preview.visible(false)
  preview.visible(true)
  const second = preview.requests[1]
  await second.started.promise
  second.response.resolve(page("Current snapshot"))
  await second.finished.promise
  first.response.resolve(page("Previous visit", true))
  await first.finished.promise
  expect(preview.state).toMatchObject({ text: "Current snapshot", tool: undefined, loading: false, error: false })
})
