import { tabKey, type SessionTab, type Tab } from "@/shell/tabs/tabs"
import type { SidebarSession } from "./sidebar-model"

export function mobileSessionTabs(tabs: Tab[], rows: SidebarSession[], pending: (tab: SessionTab) => boolean) {
  const transient = tabs.filter((tab) => tab.type === "draft" || pending(tab))
  const canonical = rows.map(
    (row) =>
      tabs.find((tab) => tab.type === "session" && tab.server === row.server && tab.sessionId === row.session.id) ?? {
        type: "session" as const,
        server: row.server,
        sessionId: row.session.id,
      },
  )
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
