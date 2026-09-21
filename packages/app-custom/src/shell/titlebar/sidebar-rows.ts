import { createMemo, createSelector, mapArray } from "solid-js"
import type { SessionInfo } from "@opencode/client/promise"
import type { ServerConnection } from "@/runtime/server/registry"
import type { Tab } from "@/shell/tabs/tabs"
import { resolvedChatIdentity } from "@/runtime/chats"
import { navigationSession, sessionAttention } from "@/shell/notifications/session-attention"
import { sessionKey, type SessionNavigationInfo, type SidebarSession } from "./sidebar-model"

export function createSidebarChatTabs(tabs: () => readonly Tab[]) {
  const keys = createMemo(
    () =>
      new Set(
        tabs().flatMap((tab) => (tab.type === "session" && tab.chat ? [sessionKey(tab.server, tab.sessionId)] : [])),
      ),
  )
  // Only changed membership notifies a row, even when unrelated tabs move or change.
  return createSelector(keys, (key: string, keys) => keys.has(key))
}

export function createSidebarRows(options: {
  server: ServerConnection.Key
  rows: () => Record<string, SessionNavigationInfo | undefined>
  fallback: () => readonly string[]
  cached: (id: string) => SessionInfo | undefined
  running: (id: string) => boolean
  rank: (id: string) => number | undefined
  project: () => (session: SessionInfo) => string
  chatRoot: () => string | undefined
  chatTab: (key: string) => boolean
  notifications: (id: string) => readonly { time: number; viewed: boolean }[]
  autoApprove: () => boolean
}) {
  const fallback = createSelector(
    () => new Set(options.fallback()),
    (id: string, ids) => ids.has(id),
  )
  const ids = createMemo(() => [...new Set([...Object.keys(options.rows()), ...options.fallback()])])
  const rows = mapArray(ids, (id) =>
    createMemo((): SidebarSession | undefined => {
      // Resolve snapshots inside the memo: reconciliation and cache replacement keep the ID's owner.
      const cached = options.cached(id)
      const row = options.rows()[id] ?? (fallback(id) && cached ? { session: cached } : undefined)
      if (!row) return
      const session = navigationSession(row, cached)
      const key = sessionKey(options.server, id)
      return {
        ...row,
        session,
        server: options.server,
        key,
        project: options.project()(session),
        running: options.running(id),
        recentRank: options.rank(id),
        chat: resolvedChatIdentity(session.location.directory, options.chatRoot(), options.chatTab(key)) || undefined,
        ...sessionAttention({
          ...row,
          session,
          notifications: options.notifications(id),
          autoApprove: options.autoApprove(),
        }),
      }
    }),
  )
  return createMemo(() =>
    rows().flatMap((row) => {
      const value = row()
      return value ? [value] : []
    }),
  )
}
