import { describe, expect, test } from "bun:test"
import type { SessionMessageAssistant, SessionMessageInfo } from "@opencode/client/promise"
import {
  dashboardFamily,
  dashboardPreview,
  dashboardStatus,
  dashboardWindow,
  filterDashboard,
  PREVIEW_LIMIT,
  RECENT_WINDOW,
  type DashboardRow,
} from "./model"

function row(id: string, status: DashboardRow["status"] = "idle", created = 1): DashboardRow {
  return {
    session: {
      id,
      projectID: "project-a",
      title: id,
      location: { directory: "/workspace/alpha" },
      time: { created, updated: created },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
    project: "project-a",
    projectName: "Alpha",
    branch: "agent-dashboard",
    status,
    children: 0,
  }
}

const filter = { status: "recent" as const, project: "", search: "" }

describe("agent dashboard state", () => {
  test("old active and pending sessions remain displayed beyond the card page", () => {
    const rows = [row("recent"), row("older"), row("active", "running"), row("pending", "attention")]
    expect(dashboardWindow(rows, 1).map((row) => row.session.id)).toEqual(["recent", "active", "pending"])
    expect(dashboardWindow(rows, 4)).toEqual(rows)
  })
  test("real pending requests override active and terminal states, then clear after reply", () => {
    const session = row("session")
    expect(dashboardStatus(session, false)).toBe("idle")
    expect(dashboardStatus(session, true)).toBe("running")
    session.session.outcome = "succeeded"
    expect(dashboardStatus(session, false)).toBe("completed")
    expect(dashboardStatus(session, true)).toBe("running")
    session.questionAt = 10
    expect(dashboardStatus(session, true)).toBe("attention")
    session.questionAt = undefined
    session.permissionAt = 0
    expect(dashboardStatus(session, false)).toBe("attention")
    session.permissionAt = undefined
    session.session.outcome = "failed"
    expect(dashboardStatus(session, false)).toBe("error")
    session.session.outcome = "interrupted"
    expect(dashboardStatus(session, false)).toBe("idle")
    session.unreadAt = 20
    expect(dashboardStatus(session, false)).toBe("idle")
  })

  test("active and attention sessions survive the 24h cutoff and recent-page boundaries", () => {
    const now = RECENT_WINDOW * 3
    const sessions = [
      row("old-active", "running"),
      row("old-attention", "attention"),
      row("old-completed", "completed"),
      row("boundary", "completed", now - RECENT_WINDOW),
      row("expired", "completed", now - RECENT_WINDOW - 1),
    ]
    expect(filterDashboard(sessions, filter, now).map((row) => row.session.id)).toEqual([
      "boundary",
      "old-active",
      "old-attention",
    ])
    expect(filterDashboard(sessions, { ...filter, status: "all" }, now)).toHaveLength(5)
  })

  test("rename does not revive old sessions; a new message or completion does", () => {
    const now = RECENT_WINDOW * 3
    const session = row("old", "completed")
    session.session.time.updated = now
    expect(filterDashboard([session], filter, now)).toHaveLength(0)
    session.messageAt = now
    expect(filterDashboard([session], filter, now)).toHaveLength(1)
    session.messageAt = 1
    session.session.time.idle = now
    expect(filterDashboard([session], filter, now)).toHaveLength(1)
  })

  test("filters title, project and directory independently of loaded branch data", () => {
    const session = row("Repair API", "running")
    for (const search of [" repair ", "ALPHA", "workspace"])
      expect(filterDashboard([session], { ...filter, search }, RECENT_WINDOW * 3)).toHaveLength(1)
    expect(filterDashboard([session], { ...filter, search: "agent-dashboard" }, 1)).toHaveLength(0)
    session.branch = undefined
    expect(filterDashboard([session], { ...filter, search: "workspace" }, 1)).toHaveLength(1)
    expect(filterDashboard([session], { ...filter, project: "other" }, 1)).toHaveLength(0)
    expect(filterDashboard([session], { ...filter, status: "completed" }, 1)).toHaveLength(0)
    expect(filterDashboard([session], { ...filter, search: "missing" }, 1)).toHaveLength(0)
  })

  test("content and lifecycle updates do not reorder existing cards", () => {
    const sessions = [row("a", "idle", 10), row("b", "running", 20), row("c", "attention", 20)]
    const ids = () => filterDashboard(sessions, { ...filter, status: "all" }, 100).map((row) => row.session.id)
    expect(ids()).toEqual(["b", "c", "a"])
    sessions[0].messageAt = 1000
    sessions[0].session.time.updated = 1000
    sessions[0].status = "attention"
    sessions[1].status = "completed"
    expect(ids()).toEqual(["b", "c", "a"])
  })

  test("top-level cards aggregate nested activity without treating child completion as root completion", () => {
    const root = row("root", "completed")
    const child = row("child", "running")
    child.session.parentID = "root"
    const grandchild = row("grandchild", "attention")
    grandchild.session.parentID = "child"
    expect(
      dashboardFamily([root, child, grandchild], false).map((row) => [row.session.id, row.status, row.children]),
    ).toEqual([["root", "attention", 2]])
    expect(root.status).toBe("completed")
    grandchild.status = "idle"
    expect(dashboardFamily([root, child, grandchild], false)[0].status).toBe("running")
    child.status = "completed"
    expect(dashboardFamily([root, child, grandchild], false)[0].status).toBe("completed")
    expect(dashboardFamily([root, child, grandchild], true)).toHaveLength(3)
    grandchild.session.time.archived = 5
    grandchild.status = "attention"
    expect(dashboardFamily([root, child, grandchild], false)[0]).toMatchObject({ status: "completed", children: 1 })
  })
})

describe("agent dashboard preview", () => {
  const assistant = (content: SessionMessageAssistant["content"], created = 2): SessionMessageAssistant => ({
    id: `msg-${created}`,
    type: "assistant",
    time: { created },
    content,
    agent: "build",
    model: { id: "test", providerID: "test" },
  })
  const user: SessionMessageInfo = { id: "user", type: "user", time: { created: 1 }, text: "Please fix the tests" }

  test("shows recent conversation text while excluding reasoning and tool payloads", () => {
    const messages = [
      user,
      assistant([
        { type: "reasoning", text: "private reasoning" },
        {
          type: "tool",
          id: "call",
          name: "shell",
          time: { created: 2 },
          state: { status: "running", input: { command: "secret" }, metadata: {} },
        },
      ]),
    ]
    expect(dashboardPreview(messages)).toEqual({ text: user.text, tool: "shell" })
    messages.push(assistant([{ type: "text", text: "Tests pass" }], 3))
    expect(dashboardPreview(messages)).toEqual({ text: "Tests pass", tool: undefined })
    expect(
      dashboardPreview([...messages, { ...user, id: "new-user", time: { created: 4 }, text: "Now commit" }]).text,
    ).toBe("Now commit")
  })

  test("caps retained text and has an explicit empty preview", () => {
    expect(dashboardPreview([assistant([{ type: "text", text: "a".repeat(2000) }])]).text).toHaveLength(PREVIEW_LIMIT)
    expect(dashboardPreview([assistant([{ type: "reasoning", text: "not shown" }])])).toEqual({
      text: "",
      tool: undefined,
    })
    expect(dashboardPreview([])).toEqual({ text: "", tool: undefined })
  })
})
