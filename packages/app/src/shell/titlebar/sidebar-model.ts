import type { SessionNavigationInfo, SessionNavigationPage } from "@opencode/client/promise"
import type { ServerConnection } from "@/runtime/server/registry"
import { pathKey } from "@/workspaces/path-key"

export type SidebarSession = SessionNavigationInfo & {
  server: ServerConnection.Key
  key: string
  project: string
  attention?: number
}

export function projectKey(server: string, project: { id?: string; worktree: string }) {
  return JSON.stringify([
    server,
    project.id && project.id !== "global" ? ["project", project.id] : ["directory", pathKey(project.worktree)],
  ])
}

export const sessionKey = (server: string, id: string) => JSON.stringify([server, id])

export function firstAttention(...times: (number | undefined)[]) {
  const pending = times.filter((time): time is number => time !== undefined)
  return pending.length ? Math.min(...pending) : undefined
}

export function rootSessions(rows: SidebarSession[], current?: string) {
  const byKey = new Map(rows.map((row) => [row.key, row]))
  const root = (row: SidebarSession) => {
    const seen = new Set([row.key])
    while (row.session.parentID) {
      const parent = byKey.get(sessionKey(row.server, row.session.parentID))
      if (!parent || seen.has(parent.key)) break
      seen.add(parent.key)
      row = parent
    }
    return row
  }
  const currentRow = current ? byKey.get(current) : undefined
  const currentRoot = currentRow ? root(currentRow).key : current
  const attention = new Map<string, number>()
  rows.forEach((row) => {
    if (row.attention === undefined) return
    const key = root(row).key
    attention.set(key, Math.min(attention.get(key) ?? row.attention, row.attention))
  })
  return {
    current: currentRoot,
    rows: rows
      .filter((row) => !row.session.time.archived && (!row.session.parentID || row.key === currentRoot))
      .map((row) => ({ ...row, attention: attention.get(row.key) }))
      .sort((a, b) => (b.messageAt ?? 0) - (a.messageAt ?? 0) || a.key.localeCompare(b.key)),
  }
}

export function localDays(now: number) {
  const today = new Date(now)
  return Array.from({ length: 7 }, (_, index) => {
    const start = new Date(today.getFullYear(), today.getMonth(), today.getDate() - index)
    const end = new Date(today.getFullYear(), today.getMonth(), today.getDate() - index + 1)
    return { start: start.getTime(), end: end.getTime(), index }
  })
}

export function attentionGroups(rows: SidebarSession[], now: number, current?: string) {
  const priority = rows
    .filter((row) => row.attention !== undefined)
    .sort((a, b) => a.attention! - b.attention! || a.key.localeCompare(b.key))
  const history = rows.filter((row) => row.attention === undefined)
  const days = localDays(now).map((day) => ({
    ...day,
    rows: history.filter((row) => row.messageAt !== undefined && row.messageAt >= day.start && row.messageAt < day.end),
  }))
  const visible = new Set([...priority, ...days.flatMap((day) => day.rows)].map((row) => row.key))
  return { priority, days, current: history.filter((row) => row.key === current && !visible.has(row.key)) }
}

export function visibleSessions(rows: SidebarSession[], limit: number, current?: string) {
  const visible = rows.slice(0, limit)
  const active = rows.find((row) => row.key === current)
  return active && !visible.includes(active) ? [...visible, active] : visible
}

export async function loadNavigation(
  list: (input: { after?: string; limit: number }, options: { signal?: AbortSignal }) => Promise<SessionNavigationPage>,
  signal?: AbortSignal,
) {
  const rows = new Map<string, SessionNavigationInfo>()
  let after: string | undefined
  for (;;) {
    const page = await list({ after, limit: 500 }, { signal })
    page.data.forEach((row) => rows.set(row.session.id, row))
    if (!page.next || page.next === after) return [...rows.values()]
    after = page.next
  }
}
