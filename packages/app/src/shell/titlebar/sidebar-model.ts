import type { SessionNavigationInfo, SessionNavigationPage } from "@opencode/client/promise"
import type { ServerConnection } from "@/runtime/server/registry"
import { pathKey } from "@/workspaces/path-key"
import type { LocalProject } from "@/shell/state/layout"
import { displayName } from "@/shell/layout/helpers"
import { latestAttention } from "@/shell/notifications/session-attention"

export type SidebarSession = SessionNavigationInfo & {
  server: ServerConnection.Key
  key: string
  project: string
  attention?: number
  recentRank?: number
}

export function projectKey(server: string, project: { id?: string; worktree: string }) {
  return JSON.stringify([
    server,
    project.id && project.id !== "global" ? ["project", project.id] : ["directory", pathKey(project.worktree)],
  ])
}

export const sessionKey = (server: string, id: string) => JSON.stringify([server, id])

export function sidebarProjects(
  server: ServerConnection.Key,
  known: Omit<LocalProject, "expanded">[],
  sessions: SessionNavigationInfo[],
) {
  const eligible = new Set(
    sessions
      .filter((row) => !row.session.parentID && !row.session.time.archived)
      .map((row) => projectKey(server, { id: row.session.projectID, worktree: row.session.location.directory })),
  )
  const entries = [
    ...known.map((project) => ({
      project,
      metadata: project.id && project.id !== "global" ? { ...project, expanded: true } : undefined,
    })),
    ...sessions
      .filter((row) => !row.session.parentID && !row.session.time.archived)
      .map((row) => ({
        project: { id: row.session.projectID, worktree: row.session.location.directory },
        metadata: undefined,
      })),
  ]
  // The first known entry is canonical; session worktrees must not replace its destination or metadata.
  return [
    ...new Map(
      entries
        .map(({ project, metadata }) => {
          const key = projectKey(server, project)
          return [
            key,
            {
              key,
              server,
              directory: project.worktree,
              name: displayName(project),
              metadata,
              occupied: eligible.has(key),
            },
          ] as const
        })
        .reverse(),
    ).values(),
  ]
}

export function orderSidebarProjects<T extends { key: string; name: string; occupied: boolean }>(
  projects: T[],
  order: readonly string[],
) {
  return projects.toSorted((a, b) => {
    const ai = order.indexOf(a.key)
    const bi = order.indexOf(b.key)
    return (
      Number(b.occupied) - Number(a.occupied) ||
      (ai < 0 ? Infinity : ai) - (bi < 0 ? Infinity : bi) ||
      a.name.localeCompare(b.name) ||
      a.key.localeCompare(b.key)
    )
  })
}

export function rootSessions(rows: SidebarSession[], current?: string, fallback?: string) {
  const byKey = new Map(rows.map((row) => [row.key, row]))
  const root = (row: SidebarSession) => {
    const seen = new Set([row.key])
    while (row.session.parentID) {
      const parent = byKey.get(sessionKey(row.server, row.session.parentID))
      if (!parent || seen.has(parent.key)) return
      seen.add(parent.key)
      row = parent
    }
    return row
  }
  const currentRow = current ? byKey.get(current) : undefined
  const fallbackRow = fallback ? byKey.get(fallback) : undefined
  const currentRoot =
    (currentRow ? root(currentRow)?.key : undefined) ??
    (fallbackRow && !fallbackRow.session.parentID ? fallback : current)
  const attention = new Map<string, number>()
  byKey.forEach((row) => {
    if (row.session.time.archived) return
    const time = row.session.parentID ? latestAttention(row.permissionAt, row.questionAt) : row.attention
    const parent = root(row)
    if (time === undefined || !parent || parent.session.time.archived) return
    attention.set(parent.key, Math.max(attention.get(parent.key) ?? time, time))
  })
  return {
    current: currentRoot,
    rows: [...byKey.values()]
      .filter((row) => !row.session.time.archived && !row.session.parentID)
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

export function pinnedSessions(rows: SidebarSession[], pins: readonly string[]) {
  const byKey = new Map(rows.filter((row) => !row.session.time.archived).map((row) => [row.key, row]))
  return [...new Set(pins)].flatMap((key) => {
    const row = byKey.get(key)
    return row ? [row] : []
  })
}

export function attentionGroups(rows: SidebarSession[], now: number, current?: string, pins: readonly string[] = []) {
  const priority = rows
    .filter((row) => !row.session.parentID && !row.session.time.archived && row.attention !== undefined)
    .sort((a, b) => b.attention! - a.attention! || a.key.localeCompare(b.key))
  const pinned = pinnedSessions(rows, pins).filter((row) => row.attention === undefined)
  const keys = new Set(pinned.map((row) => row.key))
  const history = rows.filter((row) => row.attention === undefined && !keys.has(row.key))
  const days = localDays(now).map((day) => ({
    ...day,
    rows: history.filter((row) => row.messageAt !== undefined && row.messageAt >= day.start && row.messageAt < day.end),
  }))
  const visible = new Set([...priority, ...days.flatMap((day) => day.rows)].map((row) => row.key))
  return { priority, pinned, days, current: history.filter((row) => row.key === current && !visible.has(row.key)) }
}

export function visibleSessions(rows: SidebarSession[], limit: number, current?: string) {
  const visible = rows.slice(0, limit)
  const active = rows.find((row) => row.key === current)
  return active && !visible.includes(active) ? [...visible, active] : visible
}

export function recentSessions(rows: SidebarSession[]) {
  return rows.toSorted(
    (a, b) =>
      (b.recentRank ?? (b.session.time.updated || b.session.time.created)) -
        (a.recentRank ?? (a.session.time.updated || a.session.time.created)) || a.key.localeCompare(b.key),
  )
}

// Filter the complete, message-ordered root index before applying view limits.
export function searchSessions(rows: SidebarSession[], query: string, projects: { key: string; name: string }[]) {
  const value = normalizeSearch(query)
  if (!value) return rows
  const names = new Map(projects.map((project) => [project.key, normalizeSearch(project.name)]))
  return rows.filter(
    (row) =>
      normalizeSearch(row.session.title ?? "").includes(value) ||
      normalizeSearch(row.session.id).includes(value) ||
      names.get(row.project)?.includes(value),
  )
}

function normalizeSearch(value: string) {
  return value.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().trim()
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
