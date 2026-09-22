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

test("carries current chat classification across canonical row updates without requiring an open tab", () => {
  const chat = { ...row("closed"), chat: true }
  const initial = mobileSessionTabs([], [chat], () => false)
  const updated = mobileSessionTabs([], [{ ...chat, session: { ...chat.session, title: "Updated" } }], () => false)

  expect(initial).toEqual([{ type: "session", server, sessionId: "closed", chat: true }])
  expect(updated).toEqual(initial)
})

test("current sidebar classification replaces stale open-tab flags in both directions", () => {
  const routed = { ...open, routeSessionId: "child", routeParentId: "open" }
  const chat = { ...row("open"), chat: true }
  const classified = mobileSessionTabs([routed], [chat], () => false)
  expect(classified).toEqual([{ ...routed, chat: true }])
  expect(routed).not.toHaveProperty("chat")

  const moved = mobileSessionTabs(classified, [row("open")], () => false)
  expect(moved).toEqual([routed])
  expect(classified).toEqual([{ ...routed, chat: true }])
  expect(mobileTabIsOpen(classified, moved[0])).toBe(true)
})

test("reuses open tabs when their chat classification matches the sidebar", () => {
  const chat = { ...open, chat: true }
  expect(mobileSessionTabs([chat], [{ ...row("open"), chat: true }], () => false)[0]).toBe(chat)
  expect(mobileSessionTabs([open], [row("open")], () => false)[0]).toBe(open)
})
