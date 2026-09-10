import { describe, expect, test } from "bun:test"
import { ServerConnection } from "@/runtime/server/registry"
import {
  attentionGroups,
  firstAttention,
  loadNavigation,
  localDays,
  projectKey,
  rootSessions,
  sessionKey,
  visibleSessions,
  type SidebarSession,
} from "./sidebar-model"

const server = ServerConnection.Key.make("http://localhost:1234")
function row(id: string, messageAt?: number, attention?: number, parentID?: string): SidebarSession {
  return {
    key: sessionKey(server, id),
    server,
    project: projectKey(server, { id: "repo", worktree: "/repo" }),
    messageAt,
    attention,
    session: {
      id,
      parentID,
      projectID: "repo",
      title: id,
      location: { directory: "/repo" },
      time: { created: 1, updated: 9999999999999 },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}

describe("sidebar navigation", () => {
  test("seven local calendar dates include today, not a rolling 168-hour window", () => {
    const now = new Date(2026, 2, 10, 23, 59).getTime()
    const days = localDays(now)
    expect(days).toHaveLength(7)
    expect(new Date(days[0].start).getHours()).toBe(0)
    expect(new Date(days[6].start).getDate()).toBe(4)
    const input = rootSessions([row("old", days[6].start - 1), row("boundary", days[6].start), row("today", now)])
    const result = attentionGroups(input.rows, now)
    expect(result.days[0].rows.map((item) => item.session.id)).toEqual(["today"])
    expect(result.days[6].rows.map((item) => item.session.id)).toEqual(["boundary"])
  })

  test("pending children fold into one root, priority sorts by first outstanding clock and has no cutoff", () => {
    const now = Date.now()
    const input = rootSessions([row("a", 1, firstAttention(20, 30)), row("child", now, 10, "a"), row("b", now, 15)])
    expect(input.rows).toHaveLength(2)
    const groups = attentionGroups(input.rows, now)
    expect(groups.priority.map((item) => item.session.id)).toEqual(["a", "b"])
    expect(groups.days.flatMap((day) => day.rows)).toEqual([])
    expect(firstAttention(10, 20, 100)).toBe(10)
    expect(firstAttention(undefined, 20)).toBe(20)
    expect(firstAttention(undefined)).toBeUndefined()
  })

  test("reading a response removes it from priority, but a pending request survives", () => {
    const now = Date.now()
    const groups = attentionGroups([row("read", now), row("request", now, firstAttention(undefined, 20))], now)
    expect(groups.priority.map((item) => item.session.id)).toEqual(["request"])
    expect(groups.days[0].rows.map((item) => item.session.id)).toEqual(["read"])
  })

  test("message order ignores rename/metadata clocks, and current remains visible outside limits and dates", () => {
    const input = rootSessions(Array.from({ length: 10 }, (_, i) => row(`s${i}`, i)))
    expect(input.rows.map((item) => item.session.id)).toEqual(Array.from({ length: 10 }, (_, i) => `s${9 - i}`))
    const current = sessionKey(server, "s0")
    expect(visibleSessions(input.rows, 5, current).map((item) => item.session.id)).toEqual([
      "s9",
      "s8",
      "s7",
      "s6",
      "s5",
      "s0",
    ])
    expect(attentionGroups(input.rows, Date.now(), current).current.map((item) => item.session.id)).toEqual(["s0"])
    expect(visibleSessions(input.rows, 0, current).map((item) => item.session.id)).toEqual(["s0"])
  })

  test("current child keeps its root navigable and archived sessions are excluded", () => {
    const archived = row("archived", 100)
    archived.session.time.archived = 1
    const input = rootSessions(
      [row("parent", 1), row("child", 100, undefined, "parent"), archived],
      sessionKey(server, "child"),
    )
    expect(input.current).toBe(sessionKey(server, "parent"))
    expect(input.rows.map((row) => row.session.id)).toEqual(["parent"])
  })

  test("worktrees share stable project identity, while servers and non-git directories stay distinct", () => {
    expect(projectKey("one", { id: "repo", worktree: "/worktree-a" })).toBe(
      projectKey("one", { id: "repo", worktree: "/worktree-b" }),
    )
    expect(projectKey("one", { id: "repo", worktree: "/repo" })).not.toBe(
      projectKey("two", { id: "repo", worktree: "/repo" }),
    )
    expect(projectKey("one", { id: "global", worktree: "/one" })).not.toBe(
      projectKey("one", { id: "global", worktree: "/two" }),
    )
  })

  test("loads every page, including closed-tab sessions and an exact-size final page", async () => {
    const calls: (string | undefined)[] = []
    const result = await loadNavigation(async (input) => {
      calls.push(input.after)
      return input.after ? { data: [row("closed", 1)] } : { data: [row("open", 2)], next: "open" }
    })
    expect(calls).toEqual([undefined, "open"])
    expect(result.map((item) => item.session.id)).toEqual(["open", "closed"])
  })
})
