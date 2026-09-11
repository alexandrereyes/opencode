import { expect, test } from "bun:test"
import { createRoot } from "solid-js"
import type { OpenCodeEvent, SessionInfo, SessionNavigationInfo, SessionNavigationPage } from "@opencode/client/promise"
import { createSidebarIndex } from "@/shell/titlebar/sidebar-index"
import { createRecentClock } from "@/shell/titlebar/sidebar-order"

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

function mount(session: Parameters<typeof createSidebarIndex>[0]["sdk"]["api"]["session"]) {
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
          api: { session },
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
    navigation: (input) =>
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
      navigation: async (input) => {
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
