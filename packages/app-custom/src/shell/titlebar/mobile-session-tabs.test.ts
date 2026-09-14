import { expect, test } from "bun:test"
import { ServerConnection } from "@/runtime/server/registry"
import type { Tab } from "@/shell/tabs/tabs"
import { projectKey, sessionKey, type SidebarSession } from "./sidebar-model"
import { mobileSessionTabs, mobileTabIsOpen } from "./mobile-session-tabs"

const server = ServerConnection.Key.make("http://localhost:1234")
const draft = { type: "draft" as const, draftID: "draft", server, directory: "/repo" }
const pending = { type: "session" as const, server, sessionId: "pending" }
const open = { type: "session" as const, server, sessionId: "open" }

function row(id: string): SidebarSession {
  return {
    key: sessionKey(server, id),
    server,
    project: projectKey(server, { id: "repo", worktree: "/repo" }),
    session: {
      id,
      projectID: "repo",
      title: id,
      location: { directory: "/repo" },
      time: { created: 1, updated: 1 },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}

test("keeps transient tabs reachable before canonical sidebar sessions and preserves canonical order", () => {
  const tabs: Tab[] = [open, draft, pending]
  const result = mobileSessionTabs(tabs, [row("closed"), row("open")], (tab) => tab.sessionId === "pending")

  expect(result).toEqual([draft, pending, { type: "session", server, sessionId: "closed" }, open])
  expect(new Set(result.map((tab) => (tab.type === "draft" ? tab.draftID : tab.sessionId))).size).toBe(result.length)
})

test("only open tabs are closable", () => {
  const tabs: Tab[] = [draft, open]
  expect(mobileTabIsOpen(tabs, draft)).toBe(true)
  expect(mobileTabIsOpen(tabs, open)).toBe(true)
  expect(mobileTabIsOpen(tabs, { type: "session", server, sessionId: "closed" })).toBe(false)
})
