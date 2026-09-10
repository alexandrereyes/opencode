import { describe, expect, test } from "bun:test"
import { ServerConnection } from "@/runtime/server/registry"
import {
  attentionGroups,
  firstAttention,
  loadNavigation,
  localDays,
  pinnedSessions,
  projectKey,
  rootSessions,
  searchSessions,
  sessionKey,
  sidebarProjects,
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
  test("project groups keep canonical metadata ahead of local and session worktrees", () => {
    const worktree = row("worktree")
    worktree.session.location.directory = "/worktree"
    const known = [
      { id: "repo", worktree: "/canonical", name: "Canonical", sandboxes: ["/worktree"] },
      { id: "repo", worktree: "/worktree", name: "Local worktree" },
      { id: "global", worktree: "/plain" },
      { worktree: "/unresolved" },
    ]
    const groups = sidebarProjects(server, known, [worktree])
    expect(groups).toHaveLength(3)
    expect(groups.find((group) => group.metadata?.id === "repo")).toMatchObject({
      directory: "/canonical",
      name: "Canonical",
      metadata: { sandboxes: ["/worktree"] },
    })
    expect(groups.filter((group) => !group.metadata).map((group) => group.directory).sort()).toEqual([
      "/plain",
      "/unresolved",
    ])
    const remote = sidebarProjects(ServerConnection.Key.make("https://remote.test"), known, [worktree])
    expect(remote.map((group) => group.key)).not.toEqual(groups.map((group) => group.key))
  })
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

describe("sidebar pins", () => {
  test("pin order wins over message order, priority wins over pins, and history never repeats either", () => {
    const now = Date.now()
    const rows = rootSessions([row("old", 1), row("new", now), row("priority", now, 1), row("history", now)]).rows
    const pins = ["old", "priority", "new"].map((id) => sessionKey(server, id))
    const groups = attentionGroups(rows, now, pins[0], pins)
    expect(pinnedSessions(rows, pins).map((item) => item.session.id)).toEqual(["old", "priority", "new"])
    expect(groups.priority.map((item) => item.session.id)).toEqual(["priority"])
    expect(groups.pinned.map((item) => item.session.id)).toEqual(["old", "new"])
    expect(groups.days.flatMap((day) => day.rows).map((item) => item.session.id)).toEqual(["history"])
    expect(groups.current).toEqual([])
    expect(searchSessions(rows, "", [])).toHaveLength(4)
  })

  test("only eligible keys resolve, keeping server identity and retained unavailable preferences", () => {
    const local = row("same", 1)
    const remote = { ...local, server: ServerConnection.Key.make("remote"), key: sessionKey("remote", "same") }
    const archived = row("archived", 2)
    archived.session.time.archived = 1
    const pins = [remote.key, archived.key, sessionKey(server, "deleted"), local.key, local.key]
    expect(pinnedSessions(rootSessions([local, remote, archived]).rows, pins)).toEqual([remote, local])
    expect(pinnedSessions([archived], pins)).toEqual([])
    expect(pinnedSessions([local], pins)).toEqual([local])
    expect(pinnedSessions([], pins)).toEqual([])
    expect(pinnedSessions([local, remote], pins)).toEqual([remote, local])
    expect(pins).toHaveLength(5)
  })
})

describe("sidebar search", () => {
  test("matches title, full or partial ID, and project names with case and accent folding", () => {
    const title = row("ses_title", 30)
    title.session.title = "Revisão do CAFÉ"
    const project = row("ses_project", 20)
    project.project = projectKey(server, { id: "other", worktree: "/other" })
    const untitled = row("ses_A1B2C3", 10)
    untitled.session.title = undefined
    const rows = rootSessions([untitled, project, title]).rows
    const projects = [
      { key: title.project, name: "Main" },
      { key: project.project, name: "São Paulo" },
    ]

    expect(searchSessions(rows, "  REVISAO do cafe  ", projects)).toEqual([title])
    expect(searchSessions(rows, "cafe\u0301", projects)).toEqual([title])
    expect(searchSessions(rows, "SES_a1b2c3", projects)).toEqual([untitled])
    expect(searchSessions(rows, "a1B2", projects)).toEqual([untitled])
    expect(searchSessions(rows, "sao PAULO", projects)).toEqual([project])
    expect(searchSessions(rows, "not present", projects)).toEqual([])
  })

  test("search spans all loaded roots beyond dates, recent and collapsed-project limits, in message order", () => {
    const now = Date.now()
    const old = row("match-old", 1)
    const latest = row("match-latest", now, 100)
    const priority = row("match-priority", now - 1, 1)
    const current = row("current", 0)
    const rows = rootSessions([
      old,
      latest,
      priority,
      current,
      ...Array.from({ length: 8 }, (_, i) => row(`match-${i}`, now - 2 - i)),
    ]).rows
    expect(visibleSessions(rows, 5)).not.toContain(old)
    expect(visibleSessions(rows, 0, current.key)).toEqual([current])
    expect(attentionGroups(rows, now).days.flatMap((day) => day.rows)).not.toContain(old)
    expect(attentionGroups(rows, now).priority.map((item) => item.key)).toEqual([priority.key, latest.key])

    const results = searchSessions(rows, "match", [])
    expect(results).toHaveLength(11)
    expect(results[0]).toEqual(latest)
    expect(results[1]).toEqual(priority)
    expect(results.at(-1)).toEqual(old)
    expect(results).not.toContain(current)
  })

  test("deduplicates roots while keeping the same session ID on different servers distinct", () => {
    const parent = row("match-parent", 10)
    const child = row("match-child", 30, undefined, parent.session.id)
    const archived = row("match-archived", 40)
    archived.session.time.archived = 1
    const remote = {
      ...parent,
      server: ServerConnection.Key.make("http://localhost:5678"),
      key: sessionKey("http://localhost:5678", parent.session.id),
      project: projectKey("http://localhost:5678", { id: "repo", worktree: "/repo" }),
      messageAt: 20,
    }
    const roots = rootSessions([parent, child, archived, remote, parent], child.key)
    expect(roots.current).toBe(parent.key)
    expect(searchSessions(roots.rows, "match", []).map((item) => item.key)).toEqual([remote.key, parent.key])
    expect(searchSessions(roots.rows, child.session.id, [])).toEqual([])
    expect(searchSessions(roots.rows, "remote project", [{ key: remote.project, name: "Remote project" }])).toEqual([
      remote,
    ])
  })

  test("clearing restores the original index and leaves normal grouping and limits intact", () => {
    const now = Date.now()
    const current = row("current", 1)
    const rows = rootSessions([current, row("recent", now), row("pending", now - 1, now - 2)]).rows
    const before = {
      groups: attentionGroups(rows, now, current.key),
      recent: visibleSessions(rows, 1, current.key),
      collapsed: visibleSessions(rows, 0, current.key),
    }
    expect(searchSessions(rows, "recent", [])).toHaveLength(1)
    expect(searchSessions(rows, "missing", [])).toHaveLength(0)
    expect(searchSessions(rows, "", [])).toBe(rows)
    expect(searchSessions(rows, "  ", [])).toBe(rows)
    expect({
      groups: attentionGroups(rows, now, current.key),
      recent: visibleSessions(rows, 1, current.key),
      collapsed: visibleSessions(rows, 0, current.key),
    }).toEqual(before)
  })
})
