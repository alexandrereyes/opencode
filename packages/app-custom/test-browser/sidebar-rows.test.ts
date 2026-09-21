import { expect, test } from "bun:test"
import { createMemo, createRoot, mapArray } from "solid-js"
import { createStore, produce, reconcile } from "solid-js/store"
import type { SessionInfo } from "@opencode/client/promise"
import { ServerConnection } from "@/runtime/server/registry"
import type { Tab } from "@/shell/tabs/tabs"
import { createSidebarChatTabs, createSidebarRows } from "@/shell/titlebar/sidebar-rows"
import {
  projectKey,
  rootSessions,
  sessionKey,
  sidebarProjectInventory,
  type SessionNavigationInfo,
} from "@/shell/titlebar/sidebar-model"

const server = ServerConnection.Key.make("http://rows.test")
const other = ServerConnection.Key.make("http://other.test")
function session(id: string): SessionInfo {
  return {
    id,
    projectID: "foreign",
    location: { directory: "/repo/tree" },
    time: { created: 1, updated: 1 },
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
  }
}

function fixture(count = 500) {
  const [state, set] = createStore({
    rows: Object.fromEntries(
      Array.from({ length: count }, (_, i) => [`s${i}`, { session: session(`s${i}`) }]),
    ) as Record<string, SessionNavigationInfo | undefined>,
    cached: Object.fromEntries(Array.from({ length: count }, (_, i) => [`s${i}`, session(`s${i}`)])) as Record<
      string,
      SessionInfo | undefined
    >,
    running: {} as Record<string, boolean>,
    ranks: {} as Record<string, number>,
    notifications: {} as Record<string, { time: number; viewed: boolean }[]>,
    fallback: [] as string[],
    tabs: [] as Tab[],
    root: undefined as string | undefined,
    autoApprove: false,
    projects: [{ id: "global", worktree: "/repo", worktrees: [] as { directory: string }[] }],
    servers: [server],
  })
  const counts = new Map<string, number>()
  const chatTab = createSidebarChatTabs(() => state.tabs)
  const servers = mapArray(
    () => state.servers,
    (key) => {
      const project = createMemo(() => sidebarProjectInventory(key, state.projects))
      return createSidebarRows({
        server: key,
        rows: () => state.rows,
        fallback: () => state.fallback,
        cached: (id) => state.cached[id],
        running: (id) => {
          const k = sessionKey(key, id)
          counts.set(k, (counts.get(k) ?? 0) + 1)
          return state.running[id] ?? false
        },
        rank: (id) => state.ranks[id],
        project,
        chatRoot: () => state.root,
        chatTab,
        notifications: (id) => state.notifications[id] ?? [],
        autoApprove: () => state.autoApprove,
      })
    },
  )
  const rows = createMemo(() => servers().flatMap((rows) => rows()))
  return { state, set, rows, counts, total: () => [...counts.values()].reduce((a, b) => a + b, 0) }
}

test("500 production projections: one navigation/cache/status/unread/rank update rederives one row", () => {
  createRoot((dispose) => {
    const f = fixture()
    const initial = f.rows()
    expect(f.total()).toBe(500)
    f.set("rows", "s12", reconcile({ session: session("s12"), questionAt: 10, permissionAt: 9 }))
    expect(f.total()).toBe(501)
    expect(f.rows()[12].attention).toBe(10)
    f.set("cached", "s12", "title", "live")
    expect(f.rows()[12].session.title).toBe("live")
    expect(f.total()).toBe(502)
    f.set("running", "s12", true)
    f.set("notifications", "s12", [{ time: 20, viewed: false }])
    f.set("ranks", "s12", 3)
    expect(f.total()).toBe(505)
    expect(f.rows()[12]).toMatchObject({ running: true, unreadAt: 20, attention: 20, recentRank: 3 })
    expect(f.rows().filter((row, i) => row === initial[i])).toHaveLength(499)
    f.set("rows", "s12", reconcile({ session: session("s12") }))
    expect(f.rows()[12].questionAt).toBeUndefined()
    expect(f.rows()[12].permissionAt).toBeUndefined()
    const total = f.total()
    dispose()
    f.set("cached", "s12", "title", "disposed")
    f.set("tabs", [{ type: "session", id: "chat", server, sessionId: "s12", chat: true }])
    expect(f.total()).toBe(total)
  })
})

test("chat membership is selective, server scoped, and root identity overrides fallback", () => {
  createRoot((dispose) => {
    const f = fixture()
    f.set("servers", [server, other])
    const initial = f.rows()
    expect(f.total()).toBe(1000)
    f.set("tabs", [{ type: "session", id: "chat", server, sessionId: "s12", chat: true }])
    expect(f.total()).toBe(1001)
    expect(f.rows()[12].chat).toBe(true)
    expect(f.rows()[512].chat).toBeUndefined()
    f.set(
      "tabs",
      produce((tabs) => {
        tabs.push({ type: "session", id: "plain", server, sessionId: "s20" })
        tabs.reverse()
      }),
    )
    expect(f.total()).toBe(1001)
    f.set("tabs", 1, "sessionId", "s13")
    expect(f.total()).toBe(1003)
    expect(f.rows()[12].chat).toBeUndefined()
    expect(f.rows()[13].chat).toBe(true)
    expect(f.rows()[500]).toBe(initial[500])
    f.set("servers", [other, server])
    expect(f.total()).toBe(1003)
    expect(f.rows()[0]).toBe(initial[500])
    f.set("servers", [server])
    f.set("running", "s12", true)
    expect(f.total()).toBe(1004)
    const remaining = f.rows()[0]
    f.set("servers", [other, server])
    expect(f.total()).toBe(1504)
    expect(f.rows()[500]).toBe(remaining)
    f.set("servers", [server])
    f.set("root", "/chats")
    expect(f.rows()[13].chat).toBeUndefined()
    f.set("cached", "s13", "location", "directory", "/chats/chat")
    expect(f.rows()[13].chat).toBe(true)
    dispose()
  })
})

test("key lifecycle, undefined navigation entries, route/tab fallback and snapshot replacement", () => {
  createRoot((dispose) => {
    const f = fixture(3)
    const first = f.rows()[0]
    f.set("fallback", ["s0", "unknown"])
    expect(f.total()).toBe(3)
    expect(f.rows()).toHaveLength(3)
    f.set("cached", "unknown", session("unknown"))
    expect(f.rows()).toHaveLength(4)
    f.set("rows", "s1", undefined)
    expect(f.rows().map((r) => r.session.id)).toEqual(["s0", "s2", "unknown"])
    f.set("fallback", ["s1", "unknown"])
    expect(f.rows().map((r) => r.session.id)).toEqual(["s0", "s2", "s1", "unknown"])
    f.set("fallback", [])
    const total = f.total()
    f.set("cached", "unknown", "title", "removed")
    expect(f.total()).toBe(total)
    f.set("rows", "s1", { session: session("s1"), questionAt: 33 })
    expect(f.rows().find((r) => r.session.id === "s1")?.questionAt).toBe(33)
    expect(f.rows()[0]).toBe(first)
    f.set("rows", reconcile({ s0: { session: session("s0") }, s1: { session: session("s1"), permissionAt: 44 } }))
    expect(f.rows()).toHaveLength(2)
    expect(f.rows()[1].questionAt).toBeUndefined()
    expect(f.rows()[1].permissionAt).toBe(44)
    f.set("fallback", ["unknown"])
    expect(f.rows()).toHaveLength(3)
    f.set("cached", "unknown", undefined)
    expect(f.rows()).toHaveLength(2)
    dispose()
  })
})

test("live merge, descendant activity, selected inventory, and current root aggregation stay authoritative", () => {
  createRoot((dispose) => {
    const f = fixture(3)
    f.set("rows", "s1", {
      session: {
        ...session("s1"),
        parentID: "s0",
        outcome: "failed",
        time: { created: 1, updated: 1, idle: 30, viewed: 10 },
      },
      permissionAt: 40,
      questionAt: 50,
    })
    f.set("cached", "s1", {
      ...session("s1"),
      outcome: "succeeded",
      time: { created: 1, updated: 1, idle: 20, viewed: 35 },
    })
    f.set("running", "s1", true)
    f.set("notifications", "s1", [{ time: 100, viewed: false }])
    expect(f.rows()[1].session).toMatchObject({ parentID: "s0", outcome: "failed", time: { idle: 30, viewed: 35 } })
    expect(f.rows()[1].unreadAt).toBeUndefined()
    const roots = createMemo(() => rootSessions(f.rows(), sessionKey(server, "s1")))
    expect(roots().current).toBe(sessionKey(server, "s0"))
    expect(roots().rows[0]).toMatchObject({ running: true, attention: 50 })
    f.set("autoApprove", true)
    expect(f.rows()[1].permissionAt).toBeUndefined()
    f.set("rows", "s1", "questionAt", undefined)
    expect(roots().rows[0].attention).toBeUndefined()
    f.set("rows", "s0", "session", "time", "archived", 99)
    // Cached time cannot erase navigation's archived fact when omitted.
    expect(roots().rows.map((r) => r.session.id)).toEqual(["s2"])
    f.set("projects", [{ id: "global", worktree: "/elsewhere", worktrees: [{ directory: "/repo/tree" }] }])
    expect(f.rows()[2].project).toBe(projectKey(server, f.state.projects[0]))
    const stable = f.rows()[2]
    f.set("fallback", ["s2"])
    expect(f.rows()[2]).toBe(stable)
    expect(rootSessions(f.rows(), "missing", sessionKey(server, "s2")).current).toBe(sessionKey(server, "s2"))
    dispose()
  })
})

test("deleting a navigation key disposes only its projection; re-adding the same ID derives once", () => {
  createRoot((dispose) => {
    const f = fixture(3)
    const initial = f.rows()
    f.set(
      "rows",
      produce((rows) => {
        delete rows.s1
      }),
    )
    expect(f.rows().map((row) => row.session.id)).toEqual(["s0", "s2"])
    const count = f.total()
    f.set("cached", "s1", "title", "removed owner")
    f.set("running", "s1", true)
    f.set("notifications", "s1", [{ time: 100, viewed: false }])
    expect(f.total()).toBe(count)
    f.set("rows", "s1", { session: session("s1") })
    expect(f.total()).toBe(count + 1)
    expect(f.rows()[2]).toMatchObject({ running: true, unreadAt: 100, session: { title: "removed owner" } })
    expect(f.rows()[0]).toBe(initial[0])
    expect(f.rows()[1]).toBe(initial[2])
    dispose()
  })
})

test("cache replacement and fallback/navigation transitions preserve ID ownership and fresh merge authority", () => {
  createRoot((dispose) => {
    const f = fixture(2)
    f.set("fallback", ["s2"])
    f.set("cached", "s2", {
      ...session("s2"),
      title: "fallback",
      outcome: "succeeded",
      time: { created: 1, updated: 1, idle: 20, viewed: 12 },
    })
    const stable = f.rows().slice(0, 2)
    const count = f.total()
    expect(f.rows()[2].session.title).toBe("fallback")
    // Adding navigation for an existing fallback ID must update its one owner, not mount a second projection.
    f.set("rows", "s2", {
      session: {
        ...session("s2"),
        parentID: "s0",
        outcome: "failed",
        time: { created: 1, updated: 1, idle: 30, viewed: 10 },
      },
      questionAt: 40,
    })
    expect(f.total()).toBe(count + 1)
    expect(f.rows()[2].session).toMatchObject({ parentID: "s0", outcome: "failed", time: { idle: 30, viewed: 12 } })
    // Replace the cache object, including removal of a formerly present title, without retaining an old proxy.
    f.set(
      "cached",
      produce((cache) => {
        cache.s2 = { ...session("s2"), outcome: "succeeded", time: { created: 1, updated: 1, idle: 50, viewed: 35 } }
      }),
    )
    expect(f.total()).toBe(count + 2)
    expect(f.rows()[2].session).toMatchObject({ parentID: "s0", outcome: "succeeded", time: { idle: 50, viewed: 35 } })
    expect(f.rows()[2].session.title).toBeUndefined()
    f.set(
      "rows",
      produce((rows) => {
        rows.s2 = {
          session: {
            ...session("s2"),
            parentID: "s1",
            outcome: "failed",
            time: { created: 1, updated: 1, idle: 60, viewed: 40 },
          },
          permissionAt: 70,
        }
      }),
    )
    expect(f.total()).toBe(count + 3)
    expect(f.rows()[2].session).toMatchObject({ parentID: "s1", outcome: "failed", time: { idle: 60, viewed: 40 } })
    expect(f.rows()[2].questionAt).toBeUndefined()
    f.set(
      "rows",
      produce((rows) => {
        delete rows.s2
      }),
    )
    expect(f.total()).toBe(count + 4)
    expect(f.rows()[2].session).toMatchObject({ outcome: "succeeded", time: { idle: 50, viewed: 35 } })
    expect(f.rows()[2].session.parentID).toBeUndefined()
    expect(f.rows()[2].permissionAt).toBeUndefined()
    expect(f.rows()[0]).toBe(stable[0])
    expect(f.rows()[1]).toBe(stable[1])
    dispose()
  })
})
