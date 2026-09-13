import { afterEach, expect, test } from "bun:test"
import { createEffect, createMemo, createRoot } from "solid-js"
import type { OpenCodeEvent, SessionInfo } from "@opencode/client/promise"
import { createOpenCodeEventSource } from "@/runtime/server/client"
import { createSidebarIndex } from "@/shell/titlebar/sidebar-index"
import { dashboardStatus } from "@/agent-dashboard/model"
import { createRecentClock } from "@/shell/titlebar/sidebar-order"
import type { SessionNavigationInfo, SessionNavigationPage } from "@/shell/titlebar/sidebar-model"

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
          rpc: () => ({
            list: async (input: { sessionID?: string }) => {
              reads.push(input.sessionID)
              return snapshots[reads.length - 1]
            },
            events: { subscribe: () => ({}) },
          }),
          session: {
            active: async () => ({}),
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

function row(id: string, updated: number): SessionNavigationInfo {
  return {
    session: {
      id,
      title: id,
      projectID: "repo",
      location: { directory: "/repo" },
      time: { created: 1, updated },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}

function mount(session: {
  active: () => Promise<Record<string, { type: "running" }>>
  list: (input: { sessionID?: string }) => Promise<SessionNavigationPage>
}) {
  const listeners = new Set<(event: OpenCodeEvent) => void>()
  const cache = new Map<string, SessionInfo>()
  const remembered: SessionInfo[] = []
  const state = createRoot((dispose) => ({
    dispose,
    index: createSidebarIndex(
      {
        data: {
          session: {
            remember: (session) => {
              cache.set(session.id, session)
              remembered.push(session)
            },
          },
        },
        sdk: {
          api: {
            session: { active: session.active },
            rpc: () => ({ list: session.list, events: { subscribe: () => ({}) } }),
          },
          connection: { status: () => "connected" },
          event: {
            listen: (listener) => {
              listeners.add(listener)
              return () => {
                listeners.delete(listener)
              }
            },
          },
        },
      },
      createRecentClock(() => 100),
    ),
  }))
  return {
    ...state,
    cache,
    remembered,
    emit(type: "session.execution.started" | "session.execution.succeeded" | "session.deleted", sessionID: string) {
      const base = { id: `${type}:${sessionID}`, created: 100, data: { sessionID } }
      const event: OpenCodeEvent =
        type === "session.deleted"
          ? { ...base, type, durable: { aggregateID: sessionID, seq: 1, version: 2 } }
          : { ...base, type, durable: { aggregateID: sessionID, seq: 1, version: 1 } }
      listeners.forEach((listener) => listener(event))
    },
  }
}

test("active snapshot establishes A's phase before navigation: start B, settle A, then finish navigation", async () => {
  const navigation = Promise.withResolvers<SessionNavigationPage>()
  const rows = [row("a", 10), row("b", 20)]
  const ui = mount({
    active: async () => ({ a: { type: "running" } }),
    list: (input) =>
      input?.sessionID
        ? Promise.resolve({ data: rows.filter((row) => row.session.id === input.sessionID) })
        : navigation.promise,
  })
  try {
    await Bun.sleep(0) // active has resolved; navigation is still pending
    ui.emit("session.execution.started", "b")
    ui.emit("session.execution.succeeded", "a")
    navigation.resolve({ data: rows })
    await Bun.sleep(0)
    expect(ui.index.state.loading).toBe(false)
    expect(ui.index.ranks.b).toBe(100)
    expect(ui.index.ranks.a).toBe(101)
    expect(ui.index.state.rows.a.session.time.updated).toBe(10)
    ui.emit("session.execution.succeeded", "a")
    expect(ui.index.ranks.a).toBe(101)
  } finally {
    ui.dispose()
  }
})

test.each(["delete", "replace"] as const)(
  "old navigation response cannot undo a newer %s for the same ID",
  async (operation) => {
    const old = Promise.withResolvers<SessionNavigationPage>()
    const started = Promise.withResolvers<void>()
    const refreshed = Promise.withResolvers<void>()
    const original = row("a", 10)
    const stale = structuredClone(original)
    const current = { ...original, session: { ...original.session, title: "Current" } }
    const calls = { count: 0 }
    const ui = mount({
      active: async () => ({}),
      list: async (input) => {
        if (!input?.sessionID) return { data: [original] }
        calls.count++
        if (calls.count === 1) {
          started.resolve()
          return old.promise
        }
        refreshed.resolve()
        return { data: operation === "delete" ? [] : [current] }
      },
    })
    try {
      await Bun.sleep(0)
      ui.emit("session.execution.started", "a")
      await started.promise // first targeted navigation remains in flight
      if (operation === "delete") ui.cache.delete("a") // Client data handles the deletion event
      ui.emit(operation === "delete" ? "session.deleted" : "session.execution.succeeded", "a")
      await refreshed.promise
      await Bun.sleep(0)
      const rank = ui.index.ranks.a
      const writes = ui.remembered.length
      old.resolve({ data: [stale] })
      await Bun.sleep(0)
      expect(ui.index.state.rows.a?.session.title).toBe(operation === "delete" ? undefined : "Current")
      expect(ui.cache.get("a")?.title).toBe(operation === "delete" ? undefined : "Current")
      expect(ui.index.ranks.a).toBe(rank)
      expect(ui.remembered).toHaveLength(writes)
      if (operation === "delete") expect(rank).toBeUndefined()
    } finally {
      old.resolve({ data: [] })
      ui.dispose()
    }
  },
)

test("request resolution invalidates an older read before its replacement starts without reviving dashboard attention", async () => {
  const old = Promise.withResolvers<SessionNavigationPage>()
  const started = Promise.withResolvers<void>()
  const refreshed = Promise.withResolvers<void>()
  const resolved = { ...row("a", 10), session: { ...row("a", 10).session, outcome: "succeeded" as const } }
  const pending = { ...resolved, questionAt: 20, unreadAt: 20 }
  const calls = { count: 0 }
  const ui = mount({
    active: async () => ({}),
    list: async (input) => {
      if (!input?.sessionID) return { data: [pending] }
      calls.count++
      if (calls.count === 1) {
        started.resolve()
        return old.promise
      }
      refreshed.resolve()
      return { data: [resolved] }
    },
  })
  try {
    await Bun.sleep(0)
    expect(dashboardStatus(ui.index.state.rows.a, false)).toBe("attention")
    ui.emit("session.execution.started", "a")
    await started.promise
    ui.emit("session.execution.succeeded", "a")
    const writes = ui.remembered.length
    const rank = ui.index.ranks.a
    old.resolve({ data: [{ ...pending, session: { ...pending.session, title: "Stale" } }] })
    await Bun.sleep(0)
    expect(calls.count).toBe(1)
    expect(ui.remembered).toHaveLength(writes)
    expect(ui.index.state.rows.a.session.title).toBe("a")
    expect(ui.index.ranks.a).toBe(rank)
    await refreshed.promise
    await Bun.sleep(0)
    expect(ui.index.state.rows.a).not.toHaveProperty("questionAt")
    expect(ui.index.state.rows.a).not.toHaveProperty("unreadAt")
    expect(dashboardStatus(ui.index.state.rows.a, false)).toBe("completed")
    expect(ui.index.ranks.a).toBe(rank)
  } finally {
    old.resolve({ data: [] })
    ui.dispose()
  }
})
