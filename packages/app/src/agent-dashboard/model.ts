import type { SessionMessageInfo, SessionNavigationInfo } from "@opencode/client/promise"

export type DashboardStatus = "running" | "attention" | "completed" | "error" | "idle"
export type DashboardFilter = "recent" | "all" | DashboardStatus
export type DashboardRow = SessionNavigationInfo & {
  status: DashboardStatus
  project: string
  projectName: string
  branch?: string
  children: number
}

export const RECENT_WINDOW = 24 * 60 * 60 * 1000
export const PREVIEW_LIMIT = 600

export function dashboardWindow(rows: DashboardRow[], limit: number) {
  return rows.filter((row, index) => index < limit || row.status === "running" || row.status === "attention")
}

export function dashboardStatus(row: SessionNavigationInfo, running: boolean): DashboardStatus {
  if (row.permissionAt !== undefined || row.questionAt !== undefined) return "attention"
  if (running) return "running"
  if (row.session.outcome === "failed") return "error"
  if (row.session.outcome === "succeeded") return "completed"
  return "idle"
}

export function dashboardFamily(rows: DashboardRow[], includeChildren: boolean) {
  const visible = rows.filter((row) => !row.session.time.archived)
  if (includeChildren) return visible
  const byID = new Map(visible.map((row) => [row.session.id, { ...row }]))
  visible.forEach((row) => {
    const seen = new Set([row.session.id])
    let parentID = row.session.parentID
    while (parentID && !seen.has(parentID)) {
      seen.add(parentID)
      const parent = byID.get(parentID)
      if (!parent) break
      parent.children++
      if (row.status === "attention") parent.status = "attention"
      if (row.status === "running" && parent.status !== "attention") parent.status = "running"
      parentID = parent.session.parentID
    }
  })
  return [...byID.values()].filter((row) => !row.session.parentID)
}

export function filterDashboard(
  rows: DashboardRow[],
  filter: { status: DashboardFilter; project: string; search: string },
  now: number,
) {
  const query = filter.search.trim().toLocaleLowerCase()
  return (
    rows
      .filter((row) => {
        if (row.session.time.archived) return false
        if (filter.project && row.project !== filter.project) return false
        if (
          query &&
          ![row.session.title, row.projectName, row.session.location.directory]
            .filter(Boolean)
            .join("\n")
            .toLocaleLowerCase()
            .includes(query)
        )
          return false
        if (filter.status === "all") return true
        if (filter.status !== "recent") return row.status === filter.status
        return (
          row.status === "running" ||
          row.status === "attention" ||
          Math.max(row.session.time.idle ?? 0, row.messageAt ?? row.session.time.created) >= now - RECENT_WINDOW
        )
      })
      // The creation clock never changes during a run, so SSE updates do not reshuffle cards.
      .sort((a, b) => b.session.time.created - a.session.time.created || a.session.id.localeCompare(b.session.id))
  )
}

export function dashboardPreview(messages: SessionMessageInfo[]) {
  const ordered = messages.toSorted((a, b) => b.time.created - a.time.created)
  const text = ordered.flatMap((message) => {
    if (message.type === "user") return message.text.trim() ? [message.text] : []
    if (message.type !== "assistant") return []
    const text = message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n")
    return text.trim() ? [text] : []
  })[0]
  const assistant = ordered.find((message) => message.type === "assistant")
  const tool = assistant?.content.findLast(
    (part) => part.type === "tool" && (part.state.status === "running" || part.state.status === "streaming"),
  )
  return {
    text: text?.slice(0, PREVIEW_LIMIT) ?? "",
    tool: tool?.type === "tool" ? tool.name : undefined,
  }
}
