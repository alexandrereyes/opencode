import { tabKey, type SessionTab, type Tab } from "@/shell/tabs/tabs"
import type { SidebarSession } from "./sidebar-model"

export function mobileSessionTabs(tabs: Tab[], rows: SidebarSession[], pending: (tab: SessionTab) => boolean) {
  const transient = tabs.filter((tab) => tab.type === "draft" || pending(tab))
  const canonical = rows.map((row) => {
    const tab = tabs.find(
      (tab): tab is SessionTab =>
        tab.type === "session" && tab.server === row.server && tab.sessionId === row.session.id,
    )
    if (tab && tab.chat === row.chat) return tab
    // Seed remounted items from the current sidebar classification, not a stale open-tab flag.
    return { type: "session" as const, server: row.server, sessionId: row.session.id, ...tab, chat: row.chat }
  })
  const seen = new Set<string>()
  return [...transient, ...canonical].filter((tab) => {
    const key = tabKey(tab)
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

export function mobileTabIsOpen(tabs: Tab[], tab: Tab) {
  return tabs.some((item) => tabKey(item) === tabKey(tab))
}
