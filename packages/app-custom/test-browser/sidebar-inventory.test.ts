import { expect, test } from "bun:test"
import { createMemo, createRoot } from "solid-js"
import { createStore, produce } from "solid-js/store"
import type { SessionInfo } from "@opencode/client/promise"
import { ServerConnection } from "@/runtime/server/registry"
import { projectKey, sidebarProjectInventory } from "@/shell/titlebar/sidebar-model"

test("tracked inventory prepares only for project membership and identity changes", () => {
  createRoot((dispose) => {
    const server = ServerConnection.Key.make("http://inventory.test")
    const [state, setState] = createStore({
      projects: [
        {
          id: "global",
          name: "Notes",
          branch: "main",
          worktree: "/notes",
          worktrees: [{ directory: "/trees", strategy: "git" }],
          sandboxes: [] as string[],
        },
        {
          id: "global",
          worktree: "/notes/nested",
          name: "Nested notes",
          branch: "main",
          worktrees: [] as { directory: string; strategy?: string }[],
          sandboxes: [] as string[],
        },
      ],
      status: "idle",
      unread: 0,
      current: "s0",
      sessions: Array.from(
        { length: 487 },
        (_, index): SessionInfo => ({
          id: `s${index}`,
          projectID: "foreign",
          location: { directory: "/notes/nested/draft" },
          time: { created: 1, updated: 1 },
          cost: 0,
          tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
        }),
      ),
    })
    const counts = { preparations: 0, classifications: 0 }
    const inventory = createMemo(() => {
      counts.preparations++
      return sidebarProjectInventory(server, state.projects)
    })
    const classified = createMemo(() => {
      counts.classifications++
      return {
        status: state.status,
        unread: state.unread,
        current: state.current,
        projects: state.sessions.map(inventory()),
      }
    })
    const first = projectKey(server, state.projects[0])
    expect(classified().projects.every((key) => key === first)).toBe(true)
    setState("status", "running")
    expect(classified().status).toBe("running")
    setState("unread", 1)
    expect(classified().unread).toBe(1)
    setState("current", "s486")
    expect(classified().current).toBe("s486")
    expect(counts).toEqual({ preparations: 1, classifications: 4 })

    setState("projects", 0, "name", "Renamed notes")
    setState("projects", 0, "branch", "feature")
    setState("projects", 0, "worktrees", 0, "strategy", "custom")
    expect(classified().projects[0]).toBe(first)
    expect(counts).toEqual({ preparations: 1, classifications: 4 })

    setState("sessions", 0, "location", "directory", "/outside")
    expect(classified().projects[0]).toBe(projectKey(server, { id: "foreign", worktree: "/outside" }))
    setState("sessions", 0, "projectID", "changed")
    expect(classified().projects[0]).toBe(projectKey(server, { id: "changed", worktree: "/outside" }))
    setState("sessions", 0, "location", "directory", "/notes/nested/draft")
    expect(classified().projects[0]).toBe(first)
    expect(counts).toEqual({ preparations: 1, classifications: 7 })

    setState(
      "projects",
      produce((projects) => {
        projects.reverse()
      }),
    )
    expect(classified().projects[0]).toBe(projectKey(server, state.projects[0]))
    expect(counts.preparations).toBe(2)
    setState("projects", 0, "worktree", "/elsewhere")
    expect(classified().projects[0]).toBe(first)
    setState(
      "projects",
      0,
      "worktrees",
      produce((trees) => {
        trees.push({ directory: "/notes/nested" })
      }),
    )
    expect(classified().projects[0]).toBe(projectKey(server, state.projects[0]))
    setState("projects", 0, "id", "owner")
    expect(classified().projects[0]).toBe(projectKey(server, state.projects[0]))
    setState("projects", 0, "worktrees", 0, "directory", "/elsewhere/tree")
    expect(classified().projects[0]).toBe(first)
    setState(
      "projects",
      0,
      "sandboxes",
      produce((sandboxes) => {
        sandboxes.push("/notes/nested")
      }),
    )
    expect(classified().projects[0]).toBe(projectKey(server, state.projects[0]))
    setState(
      "projects",
      0,
      "sandboxes",
      produce((sandboxes) => {
        sandboxes.pop()
      }),
    )
    expect(classified().projects[0]).toBe(first)
    setState(
      "projects",
      0,
      "worktrees",
      produce((trees) => {
        trees.push({ directory: "/notes/nested" })
        trees.reverse()
      }),
    )
    expect(classified().projects[0]).toBe(projectKey(server, state.projects[0]))
    setState(
      "projects",
      0,
      "worktrees",
      produce((trees) => {
        trees.shift()
      }),
    )
    expect(classified().projects[0]).toBe(first)
    setState(
      "projects",
      produce((projects) => {
        projects.pop()
      }),
    )
    expect(classified().projects[0]).toBe(projectKey(server, { id: "changed", worktree: "/notes/nested/draft" }))
    expect(counts.preparations).toBe(11)
    dispose()
  })
})
