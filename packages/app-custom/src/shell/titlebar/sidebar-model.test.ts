import { describe, expect, test } from "bun:test"
import { ServerConnection } from "@/runtime/server/registry"
import {
  attentionGroups,
  orderSidebarProjects,
  sidebarSelectableSessions,
  loadNavigation,
  localDays,
  pinnedSessions,
  projectKey,
  recentSessions,
  rootSessions,
  searchSessions,
  sessionKey,
  sidebarProjects,
  sidebarSessionProject,
  visibleSessions,
  type SidebarSession,
} from "./sidebar-model"
import { latestAttention, navigationSession, sessionAttention } from "@/shell/notifications/session-attention"

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
  test("occupied projects precede empty ones while each block retains manual order as sessions arrive and leave", () => {
    const known = ["a", "b", "c", "d"].map((id) => ({ id, worktree: `/${id}` }))
    const session = (id: string) => ({
      ...row(id),
      project: projectKey(server, { id, worktree: `/${id}` }),
      session: { ...row(id).session, projectID: id, location: { directory: `/${id}` } },
    })
    const manual = ["d", "c", "b", "a"].map((id) => projectKey(server, { id, worktree: `/${id}` }))
    const ordered = (ids: string[]) =>
      orderSidebarProjects(sidebarProjects(server, known, ids.map(session)), manual).map(
        (project) => project.metadata?.id,
      )
    expect(ordered(["a", "c"])).toEqual(["c", "a", "d", "b"])
    expect(ordered(["a", "b", "c"])).toEqual(["c", "b", "a", "d"])
    expect(ordered(["b", "c"])).toEqual(["c", "b", "d", "a"])
    expect(ordered([])).toEqual(["d", "c", "b", "a"])
    expect(manual).toEqual(["d", "c", "b", "a"].map((id) => projectKey(server, { id, worktree: `/${id}` })))
  })
  test("Recent alone uses lifecycle rank and deterministic server/session ties", () => {
    const rows = rootSessions([row("a", 30, 10), row("b", 20, 20), row("c", 10)]).rows
    rows.forEach((row) => {
      row.recentRank = row.session.id === "c" ? 50 : 40
    })
    expect(recentSessions(rows).map((row) => row.session.id)).toEqual(["c", "a", "b"])
    expect(rows.map((row) => row.session.id)).toEqual(["a", "b", "c"])
    expect(attentionGroups(rows, 100).priority.map((row) => row.session.id)).toEqual(["b", "a"])
    expect(pinnedSessions(rows, [rows[1].key, rows[0].key]).map((row) => row.session.id)).toEqual(["b", "a"])
    const remote = { ...rows[0], key: sessionKey("remote", "a") }
    expect(recentSessions([remote, rows[0]]).map((row) => row.key)).toEqual([rows[0].key, remote.key].sort())
  })

  test("projects mode uses pinned, recent and rendered project order with first-occurrence membership", () => {
    const pinned = row("pinned", 40)
    const current = row("current", 30)
    const recent = row("recent", 20)
    const project = row("project", 10)

    expect(
      sidebarSelectableSessions({
        mode: "projects",
        pinned: [pinned],
        recent: [current, recent, pinned],
        projects: [[recent, project], [current]],
      }).map((item) => item.session.id),
    ).toEqual(["pinned", "current", "recent", "project"])
  })

  test("attention mode uses priority, pinned, day rows and current fallback with first-occurrence membership", () => {
    const priority = row("priority", 40, 40)
    const pinned = row("pinned", 30)
    const today = row("today", 20)
    const current = row("current", 10)

    expect(
      sidebarSelectableSessions({
        mode: "attention",
        priority: [priority],
        pinned: [pinned, priority],
        days: [{ rows: [today, pinned] }, { rows: [current] }],
        current: [current],
      }).map((item) => item.session.id),
    ).toEqual(["priority", "pinned", "today", "current"])
  })

  test("Recent windows preserve rank order, exclude pins/children and retain current across five-row pages", () => {
    const rows = Array.from({ length: 13 }, (_, i) => ({ ...row(`s${i}`, i), recentRank: 13 - i }))
    const pin = row("pinned", 100)
    const archived = row("archived", 200)
    archived.session.time.archived = 1
    const roots = rootSessions(
      [...rows, pin, row("child", 300, undefined, "s12"), archived],
      sessionKey(server, "child"),
    )
    const recent = recentSessions(roots.rows.filter((item) => item.key !== pin.key))
    expect(recent.map((item) => item.key)).toEqual(rows.map((item) => item.key))
    expect(visibleSessions(recent, 5, roots.current).map((item) => item.key)).toEqual([
      ...rows.slice(0, 5).map((item) => item.key),
      rows[12].key,
    ])
    expect(visibleSessions(recent, 10, roots.current)).toHaveLength(11)
    expect(visibleSessions(recent, 15, roots.current)).toEqual(recent)
    expect(visibleSessions(recent, 5, rows[0].key)).toHaveLength(5)
    expect(visibleSessions(recent, 5, pin.key)).toHaveLength(5)
    expect(visibleSessions(recent.slice(0, 6), 5, rows[5].key)).toEqual(recent.slice(0, 6))
    expect(visibleSessions(recent, 5, roots.current)).toHaveLength(6)
    expect(pinnedSessions(roots.rows, [pin.key])).toEqual([pin])
    expect(searchSessions(roots.rows, "s", [])).toHaveLength(13)
  })

  test("only selected projects remain visible and selected projects without sessions stay available", () => {
    const archived = row("archived")
    archived.session.projectID = "archive-project"
    archived.session.time.archived = 10
    const child = row("child", 20, 20, "missing")
    child.session.projectID = "child-project"
    const live = row("root", 1)
    const known = ["empty", "repo"].map((id) => ({ id, worktree: `/${id}` }))
    const projects = sidebarProjects(server, known, [archived, child, live])
    expect(projects.map((project) => project.metadata?.id).sort((a, b) => (a ?? "").localeCompare(b ?? ""))).toEqual([
      "empty",
      "repo",
    ])
    expect(projects.filter((project) => project.occupied).map((project) => project.metadata?.id)).toEqual(["repo"])
    expect(projects.find((project) => project.metadata?.id === "empty")?.occupied).toBe(false)
    const roots = rootSessions([live]).rows
    expect(visibleSessions(roots, 0)).toEqual([])
    expect(sidebarProjects(server, known, roots)).toHaveLength(2)
  })

  test("selected project identity owns canonical subdirectories and worktrees without adopting foreign history", () => {
    const selected = [
      { id: "repo", worktree: "/repo", worktrees: [{ directory: "/trees/feature" }] },
      { worktree: "/notes" },
    ]
    expect(sidebarSessionProject(server, row("repo").session, selected)).toBe(projectKey(server, selected[0]))
    const worktree = row("worktree").session
    worktree.location.directory = "/trees/feature/src"
    expect(sidebarSessionProject(server, worktree, selected)).toBe(projectKey(server, selected[0]))
    const note = row("note").session
    note.projectID = "global"
    note.location.directory = "/notes/drafts"
    expect(sidebarSessionProject(server, note, selected)).toBe(projectKey(server, selected[1]))
    const foreign = row("foreign").session
    foreign.projectID = "other"
    foreign.location.directory = "/elsewhere"
    const foreignKey = sidebarSessionProject(server, foreign, selected)
    expect(foreignKey).not.toBe(projectKey(server, selected[0]))
    expect(foreignKey).not.toBe(projectKey(server, selected[1]))
    const projects = sidebarProjects(server, selected, [{ ...row("foreign"), project: foreignKey, session: foreign }])
    expect(projects.map((project) => project.key).toSorted()).toEqual(
      selected.map((project) => projectKey(server, project)).toSorted(),
    )
    expect(projects.every((project) => !project.occupied)).toBe(true)
  })

  test("orphan/current children and their completions never become Priority rows", () => {
    const parent = row("root", 1)
    const child = row("child", 100, 100, "root")
    const orphan = { ...row("orphan", 200, 200, "missing"), questionAt: 200 }
    const roots = rootSessions([parent, child, orphan], orphan.key, parent.key)
    expect(roots.current).toBe(parent.key)
    expect(roots.rows.map((row) => row.key)).toEqual([parent.key])
    expect(attentionGroups(roots.rows, Date.now()).priority).toEqual([])
    expect(attentionGroups([child, orphan], Date.now(), orphan.key).priority).toEqual([])
    const requests = rootSessions([parent, { ...child, questionAt: 300 }], child.key)
    expect(requests.current).toBe(parent.key)
    expect(attentionGroups(requests.rows, Date.now()).priority.map((row) => [row.key, row.attention])).toEqual([
      [parent.key, 300],
    ])
  })

  test("partial cache updates preserve navigation ancestry and durable read watermarks", () => {
    const child = row("child", 50, undefined, "root")
    child.session.time.idle = 30
    child.session.time.viewed = 20
    const cached = { ...child.session, parentID: undefined, title: "updated", time: { created: 1, updated: 100 } }
    const merged = navigationSession(child, cached)
    expect(merged.parentID).toBe("root")
    expect(merged.title).toBe("updated")
    expect(merged.time.idle).toBe(30)
    expect(merged.time.viewed).toBe(20)
    expect(rootSessions([{ ...child, session: merged }], child.key).rows).toEqual([])
  })

  test("unseen notifications, durable unread and confirmed requests use the same latest clock", () => {
    const session = row("root").session
    session.time.idle = 40
    session.time.viewed = 10
    session.outcome = "succeeded"
    const notifications = [
      { time: 30, viewed: false },
      { time: 50, viewed: false },
      { time: 80, viewed: true },
    ]
    expect(sessionAttention({ session, unreadAt: 20, notifications }).attention).toBe(50)
    expect(sessionAttention({ session, notifications: [] }).attention).toBe(40)
    const pending = sessionAttention({ session, notifications, permissionAt: 70 })
    expect(pending.attention).toBe(70)
    const read = { ...session, time: { ...session.time, viewed: 80 } }
    expect(sessionAttention({ session: read, unreadAt: 40, notifications }).attention).toBeUndefined()
    expect(sessionAttention({ session: read, notifications, permissionAt: 70 }).attention).toBe(70)
    expect(
      sessionAttention({ session: read, notifications, permissionAt: 70, autoApprove: true }).attention,
    ).toBeUndefined()
    const legacy = row("legacy").session
    expect(sessionAttention({ session: legacy, notifications }).attention).toBe(50)
    expect(
      sessionAttention({ session: { ...legacy, parentID: "root" }, unreadAt: 40, notifications }).attention,
    ).toBeUndefined()
  })

  test("a newer pending notification moves its root ahead in DESC order", () => {
    const older = row("older", 1, 10)
    const newer = row("newer", 1, 20)
    expect(attentionGroups(rootSessions([older, newer]).rows, Date.now()).priority.map((row) => row.key)).toEqual([
      newer.key,
      older.key,
    ])
    expect(
      attentionGroups(rootSessions([{ ...older, attention: 30 }, newer]).rows, Date.now()).priority.map(
        (row) => row.key,
      ),
    ).toEqual([older.key, newer.key])
  })

  test("project groups deduplicate selected project identity without deriving entries from sessions", () => {
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
    expect(
      groups
        .filter((group) => !group.metadata)
        .map((group) => group.directory)
        .sort(),
    ).toEqual(["/plain", "/unresolved"])
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

  test("pending requests fold into one root, priority sorts by latest outstanding clock and has no cutoff", () => {
    const now = Date.now()
    const child = { ...row("child", now, 40, "a"), permissionAt: 40 }
    const input = rootSessions([row("a", 1, latestAttention(20, 30)), child, row("b", now, 35)])
    expect(input.rows).toHaveLength(2)
    const groups = attentionGroups(input.rows, now)
    expect(groups.priority.map((item) => item.session.id)).toEqual(["a", "b"])
    expect(groups.days.flatMap((day) => day.rows)).toEqual([])
    expect(groups.priority.map((item) => item.attention)).toEqual([40, 35])
    expect(latestAttention(10, 20, 100)).toBe(100)
    expect(latestAttention(undefined, 20)).toBe(20)
    expect(latestAttention(undefined)).toBeUndefined()
  })

  test("reading a response removes it from priority, but a pending request survives", () => {
    const now = Date.now()
    const groups = attentionGroups([row("read", now), row("request", now, latestAttention(undefined, 20))], now)
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
    expect(attentionGroups(rows, now).priority.map((item) => item.key)).toEqual([latest.key, priority.key])

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
