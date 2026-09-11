import { afterEach, expect, test } from "bun:test"
import { createEffect, createMemo, createRoot } from "solid-js"
import type { OpenCodeEvent, SessionInfo, SessionNavigationInfo, SessionNavigationPage } from "@opencode/client/promise"
import { createOpenCodeEventSource } from "@/runtime/server/client"
import { createSidebarIndex } from "@/shell/titlebar/sidebar-index"
import { dashboardStatus } from "@/agent-dashboard/model"

const cleanups: VoidFunction[] = []
afterEach(() => cleanups.splice(0).forEach((dispose) => dispose()))

const session: SessionInfo = {
  id: "ses_navigation_refresh",
  projectID: "project",
  title: "Resolved request",
  location: { directory: "/workspace/navigation" },
  outcome: "succeeded",
  time: { created: 1, updated: 2, idle: 2 },
  cost: 0,
  tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
}

function ready(condition: () => boolean) {
  return new Promise<void>((resolve) => {
    createRoot((dispose) => {
      cleanups.push(dispose)
      createEffect(() => {
        if (!condition()) return
        dispose()
        resolve()
      })
    })
  })
}

function fixture(initial: SessionNavigationInfo, next: SessionNavigationPage) {
  return createRoot((dispose) => {
    cleanups.push(dispose)
    const events = createOpenCodeEventSource()
    const snapshots: SessionNavigationPage[] = [{ data: [initial] }, next]
    const reads: (string | undefined)[] = []
    const remembered: SessionInfo[] = []
    const refreshed = Promise.withResolvers<void>()
    const index = createSidebarIndex({
      sdk: {
        connection: { status: () => "connected" },
        event: events.event,
        api: {
          session: {
            navigation: async (input) => {
              reads.push(input?.sessionID)
              return snapshots[reads.length - 1]
            },
          },
        },
      },
      data: {
        session: {
          remember: (info) => {
            remembered.push(info)
            if (remembered.length === 2) refreshed.resolve()
          },
        },
      },
    })
    const status = createMemo(() => {
      const row = index.state.rows[session.id]
      return row ? dashboardStatus(row, false) : undefined
    })
    return { index, status, reads, remembered, refreshed, publish: events.publish }
  })
}

const cases: { field: "questionAt" | "permissionAt"; event: OpenCodeEvent }[] = [
  {
    field: "questionAt",
    event: {
      id: "evt_question_replied",
      created: 3,
      type: "form.replied",
      data: { id: "frm_question", sessionID: session.id, answer: {} },
    },
  },
  {
    field: "permissionAt",
    event: {
      id: "evt_permission_replied",
      created: 3,
      type: "permission.replied",
      data: { sessionID: session.id, requestID: "per_request", reply: "once" },
    },
  },
]

for (const entry of cases) {
  test(`navigation refresh removes omitted ${entry.field} and unreadAt after the request is resolved`, async () => {
    const resolved = { session, messageAt: 1 }
    const view = fixture({ ...resolved, [entry.field]: 2, unreadAt: 2 }, { data: [resolved] })
    await ready(() => !view.index.state.loading)
    expect(view.status()).toBe("attention")
    expect(view.index.state.rows[session.id][entry.field]).toBe(2)
    view.publish(entry.event)
    await view.refreshed.promise
    expect(view.reads).toEqual([undefined, session.id])
    expect(view.index.state.rows[session.id]).not.toHaveProperty(entry.field)
    expect(view.index.state.rows[session.id]).not.toHaveProperty("unreadAt")
    expect(view.status()).toBe("completed")
    expect(view.index.state.rows[session.id].messageAt).toBe(1)
  })
}

test("navigation refresh removes a session whose snapshot no longer contains a row", async () => {
  const view = fixture({ session, questionAt: 2 }, { data: [] })
  await ready(() => !view.index.state.loading)
  expect(view.status()).toBe("attention")
  view.publish({
    id: "evt_session_deleted",
    created: 3,
    type: "session.deleted",
    durable: { aggregateID: session.id, seq: 1, version: 2 },
    data: { sessionID: session.id },
  })
  await ready(() => !view.index.state.rows[session.id])
  expect(view.reads).toEqual([undefined, session.id])
  expect(view.index.state.rows).not.toHaveProperty(session.id)
  expect(view.status()).toBeUndefined()
  expect(view.remembered).toHaveLength(1)
})
