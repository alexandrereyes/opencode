import { describe, expect, test } from "bun:test"
import type { SessionInfo } from "@opencode/client/promise"
import { createRoot } from "solid-js"
import type { ServerConnection } from "@/runtime/server/registry"
import { createServerSessionEntries } from "./palette"

const server = "http://server" as ServerConnection.Key

function session(id: string, directory: string, archived?: number) {
  return {
    id,
    projectID: "proj_app",
    title: `Title ${id}`,
    location: { directory },
    time: { created: 1, updated: 2, ...(archived ? { archived } : {}) },
  } as unknown as SessionInfo
}

function entries(listed: SessionInfo[]) {
  const searches: string[] = []
  return createRoot((dispose) => ({
    searches,
    dispose,
    load: createServerSessionEntries({
      server,
      opened: () => [{ id: "proj_app", worktree: "/repo/app", expanded: true }],
      stored: () => [],
      load: async (search) => {
        searches.push(search)
        return { data: listed }
      },
      get: async () => {
        throw new Error("not requested")
      },
      untitled: () => "New session",
      category: () => "Session",
      recentCategory: () => "Recent sessions",
      chatRoot: () => "/chats",
      chatLabel: () => "Chats",
    }),
  }))
}

describe("command palette sessions", () => {
  test("an empty query lists the five most recent sessions with their project or chat identity", async () => {
    const palette = entries([
      session("ses_chat", "/chats/2026"),
      session("ses_archived", "/repo/app", 3),
      ...["a", "b", "c", "d", "e"].map((id) => session(`ses_${id}`, "/repo/app")),
    ])
    const result = await palette.load("  ")

    expect(palette.searches).toEqual([""])
    expect(result.map((entry) => entry.sessionID)).toEqual(["ses_chat", "ses_a", "ses_b", "ses_c", "ses_d"])
    expect(result.every((entry) => entry.category === "Recent sessions")).toBe(true)
    expect(result[0]).toMatchObject({ chat: true, description: "Chats", project: undefined })
    expect(result[1]).toMatchObject({ description: "app", project: { worktree: "/repo/app" } })
    palette.dispose()
  })

  test("a typed query keeps the session category and every result", async () => {
    const palette = entries(["a", "b", "c", "d", "e", "f"].map((id) => session(`ses_${id}`, "/repo/app")))
    const result = await palette.load("title")

    expect(palette.searches).toEqual(["title"])
    expect(result).toHaveLength(6)
    expect(result.every((entry) => entry.category === "Session")).toBe(true)
    palette.dispose()
  })
})
