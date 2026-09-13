import { expect, test } from "bun:test"
import { createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import type { SessionInfo } from "@opencode/client/promise"
import { createSessionViewed } from "@/shell/notifications/session-viewed"
import { sessionAttention } from "@/shell/notifications/session-attention"

test("opening an existing unread session acknowledges its idle clock once and preserves pending requests", async () => {
  const [state, setState] = createStore<{ session: SessionInfo }>({
    session: {
      id: "ses_root",
      projectID: "repo",
      location: { directory: "/repo" },
      time: { created: 1, updated: 1, idle: 20 },
      outcome: "succeeded",
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  })
  const calls: { sessionID: string; idle: number }[] = []
  const complete: (() => void)[] = []
  const dispose = createRoot((dispose) => {
    createSessionViewed({
      session: () => state.session,
      view: (input) => {
        calls.push(input)
        return new Promise<void>((resolve) => complete.push(resolve))
      },
      remember: (session) => setState("session", session),
    })
    return dispose
  })
  try {
    expect(calls).toEqual([{ sessionID: "ses_root", idle: 20 }])
    setState("session", "title", "Renamed")
    expect(calls).toHaveLength(1)
    setState("session", "time", "idle", 30)
    expect(calls).toHaveLength(2)
    complete[0]()
    await Promise.resolve()
    expect(state.session.time.viewed).toBe(20)
    expect(sessionAttention({ session: state.session, notifications: [] }).attention).toBe(30)
    complete[1]()
    await Promise.resolve()
    expect(sessionAttention({ session: state.session, notifications: [] }).attention).toBeUndefined()
    expect(sessionAttention({ session: state.session, notifications: [], questionAt: 10 }).attention).toBe(10)
    expect(state.session.title).toBe("Renamed")
  } finally {
    dispose()
  }
})
