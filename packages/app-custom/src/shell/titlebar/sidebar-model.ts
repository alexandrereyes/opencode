import type { Navigation } from "@opencode/plugin-app-custom/navigation/rpc"
import type { SessionInfo, WorktreeDirectory } from "@opencode/client/promise"
import type { Types } from "effect"
import type { ServerConnection } from "@/runtime/server/registry"
import { pathKey } from "@/workspaces/path-key"
import type { LocalProject } from "@/shell/state/layout"
import { displayName } from "@/shell/layout/helpers"
import { latestAttention } from "@/shell/notifications/session-attention"
import { containsDirectory, directoryKey, sameDirectory } from "@/workspaces/paths"
import { isChatDirectory } from "@/runtime/chats"

export { isChatDirectory }

export type SessionNavigationInfo = Omit<Types.DeepMutable<Navigation.Info>, "session"> & { session: SessionInfo }
export interface SessionNavigationPage {
  data: SessionNavigationInfo[]
  next?: string
}

/** The RPC payload is JSON-compatible; client state owns mutability after this boundary. */
export function navigationPage(page: Navigation.Page): SessionNavigationPage {
  // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion
  return page as SessionNavigationPage
}

export type SidebarSession = SessionNavigationInfo & {
  server: ServerConnection.Key
  key: string
  project: string
  running?: boolean
  attention?: number
  recentRank?: number
  chat?: boolean
}

export function projectKey(server: string, project: { id?: string; worktree: string }) {
  return JSON.stringify([
    server,
    project.id && project.id !== "global" ? ["project", project.id] : ["directory", pathKey(project.worktree)],
  ])
}

export const sessionKey = (server: string, id: string) => JSON.stringify([server, id])

export function chatActionServer<T extends string>(preferred: T | undefined, roots: ReadonlyMap<T, string | undefined>) {
  if (preferred && roots.get(preferred)) return preferred
  return [...roots].find(([, root]) => !!root)?.[0]
}

export function sidebarProjectWorkspaces(project: {
  worktree: string
  worktrees?: readonly WorktreeDirectory[]
  sandboxes?: readonly string[]
}): WorktreeDirectory[] {
  const seen = new Set([directoryKey(project.worktree)])
  return [
    ...(project.worktrees ?? []),
    ...(project.sandboxes ?? []).map((directory): WorktreeDirectory => ({ directory })),
  ].filter((workspace) => {
    const key = directoryKey(workspace.directory)
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

export function sidebarExplicitWorkspace<
  T extends { key: string; directory: string; workspaces: readonly WorktreeDirectory[] },
>(directory: string, projects: readonly T[]) {
  return projects
    .flatMap((project) =>
      project.workspaces
        .filter((workspace) => !sameDirectory(workspace.directory, project.directory))
        .filter((workspace) => containsDirectory(workspace.directory, directory))
        .map((workspace) => ({ project, directory: workspace.directory })),
    )
    .toSorted(
      (a, b) =>
        pathKey(b.directory).length - pathKey(a.directory).length ||
        a.project.key.localeCompare(b.project.key) ||
        pathKey(a.directory).localeCompare(pathKey(b.directory)),
    )[0]
}

export function sidebarSessionProject(
  server: ServerConnection.Key,
  session: SessionInfo,
  projects: Omit<LocalProject, "expanded">[],
) {
  return sidebarProjectInventory(server, projects)(session)
}

// Prepare once per server inventory, independently of session status, attention and navigation.
export function sidebarProjectInventory(
  server: ServerConnection.Key,
  projects: readonly Omit<LocalProject, "expanded">[],
) {
  const entries = projects.map((project) => ({
    id: project.id,
    key: projectKey(server, project),
    directory: project.worktree,
    workspaces: sidebarProjectWorkspaces(project).map((workspace) => workspace.directory),
  }))
  const explicit = entries
    .flatMap((project) =>
      project.workspaces.map((directory) => ({
        key: project.key,
        directory: pathKey(directory),
      })),
    )
    .toSorted(
      (a, b) =>
        b.directory.length - a.directory.length || a.key.localeCompare(b.key) || a.directory.localeCompare(b.directory),
    )
  const direct = new Map(
    entries
      .filter((project) => project.id && project.id !== "global")
      .reverse()
      .map((project) => [project.id, project.key]),
  )
  const unresolved = entries.filter((project) => !project.id || project.id === "global")
  return (session: SessionInfo) => {
    const directory = session.location.directory
    const workspace = explicit.find((workspace) => containsDirectory(workspace.directory, directory))
    if (workspace) return workspace.key
    const project = direct.get(session.projectID)
    if (project) return project
    return (
      unresolved.find((project) =>
        [project.directory, ...project.workspaces].some((root) => containsDirectory(root, directory)),
      )?.key ?? projectKey(server, { id: session.projectID, worktree: directory })
    )
  }
}

export function sidebarProjects(
  server: ServerConnection.Key,
  known: Omit<LocalProject, "expanded">[],
  sessions: SidebarSession[],
) {
  const eligible = new Set(
    sessions
      .filter((row) => !row.chat && !row.session.parentID && !row.session.time.archived)
      .map((row) => row.project),
  )
  const entries = known.map((project) => ({
    project,
    metadata: project.id && project.id !== "global" ? { ...project, expanded: true } : undefined,
  }))
  // The first selected entry is canonical when multiple opened directories resolve to the same project.
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
  const running = new Set<string>()
  const permissions = new Map<string, number>()
  const questions = new Map<string, number>()
  byKey.forEach((row) => {
    if (row.session.time.archived) return
    const parent = root(row)
    if (!parent || parent.session.time.archived) return
    if (row.running) running.add(parent.key)
    if (row.permissionCount) permissions.set(parent.key, (permissions.get(parent.key) ?? 0) + row.permissionCount)
    if (row.questionCount) questions.set(parent.key, (questions.get(parent.key) ?? 0) + row.questionCount)
    const time = row.session.parentID ? latestAttention(row.permissionAt, row.questionAt) : row.attention
    if (time === undefined) return
    attention.set(parent.key, Math.max(attention.get(parent.key) ?? time, time))
  })
  return {
    current: currentRoot,
    rows: [...byKey.values()]
      .filter((row) => !row.session.time.archived && !row.session.parentID)
      .map((row) => ({
        ...row,
        running: running.has(row.key) || undefined,
        attention: attention.get(row.key),
        permissionCount: permissions.get(row.key),
        questionCount: questions.get(row.key),
      }))
      .sort((a, b) => (b.messageAt ?? 0) - (a.messageAt ?? 0) || a.key.localeCompare(b.key)),
  }
}

export type SidebarActivity = "permission" | "question" | "running" | "unread"

// Pending requests block the session, so they outrank its running state.
export function sidebarActivity(rows: readonly SidebarSession[]): SidebarActivity | undefined {
  if (rows.some((row) => row.permissionCount)) return "permission"
  if (rows.some((row) => row.questionCount)) return "question"
  if (rows.some((row) => row.running)) return "running"
  if (rows.some((row) => row.attention !== undefined)) return "unread"
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
  return rows.filter((row) => !row.chat).toSorted(
    (a, b) =>
      (b.recentRank ?? (b.session.time.updated || b.session.time.created)) -
        (a.recentRank ?? (a.session.time.updated || a.session.time.created)) || a.key.localeCompare(b.key),
  )
}

export function sidebarSelectableSessions(
  view:
    | {
        mode: "attention"
        priority: readonly SidebarSession[]
        pinned: readonly SidebarSession[]
        days: readonly { rows: readonly SidebarSession[] }[]
        current: readonly SidebarSession[]
      }
    | {
        mode: "projects"
        chats?: readonly SidebarSession[]
        pinned: readonly SidebarSession[]
        recent: readonly SidebarSession[]
        projects: readonly (readonly SidebarSession[])[]
      },
) {
  const rows =
    view.mode === "attention"
      ? [...view.priority, ...view.pinned, ...view.days.flatMap((day) => day.rows), ...view.current]
      : [...(view.chats ?? []), ...view.pinned, ...view.recent, ...view.projects.flatMap((rows) => rows)]
  const seen = new Set<string>()
  return rows.filter((row) => {
    if (seen.has(row.key)) return false
    seen.add(row.key)
    return true
  })
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
