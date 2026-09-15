import { createMemo, mapArray } from "solid-js"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection, serverName } from "@/runtime/server/registry"
import { useSettings } from "@/settings/model"
import { useLayout } from "@/shell/state/layout"
import type { Tab } from "@/shell/tabs/tabs"
import { navigationSession, sessionAttention } from "@/shell/notifications/session-attention"
import { createSidebarIndex } from "./sidebar-index"
import { createRecentClock } from "./sidebar-order"
import {
  rootSessions,
  sessionKey,
  sidebarProjects,
  sidebarSessionProject,
  type SidebarSession,
} from "./sidebar-model"
import { createSidebarWorktrees } from "./sidebar-worktrees"

export function createSidebarSessions(options: {
  currentTab: () => Tab | undefined
  enabled?: () => boolean
  clock?: ReturnType<typeof createRecentClock>
}) {
  const global = useGlobal()
  const layout = useLayout()
  const settings = useSettings()
  const clock = options.clock ?? createRecentClock()
  const indexes = mapArray(
    () => (options.enabled?.() === false ? [] : global.servers.list()),
    (connection) => {
      const ctx = global.ensureServerCtx(connection)
      const projects = createMemo(() => ctx.projects.list())
      return { connection, ctx, projects, index: createSidebarIndex(ctx, clock), worktrees: createSidebarWorktrees(ctx) }
    },
  )
  const current = () => {
    const route = layout.route()
    return route.type === "session" ? sessionKey(route.server, route.sessionId) : undefined
  }
  const sessions = createMemo(() => {
    const currentTab = options.currentTab()
    return rootSessions(
      indexes().flatMap((entry) => {
        const server = ServerConnection.key(entry.connection)
        const selected = entry.projects()
        const known = new Map(
          Object.values(entry.index.state.rows)
            .filter(Boolean)
            .map((row) => [row.session.id, row]),
        )
        const route = layout.route()
        if (route.type === "session" && route.server === server && !known.has(route.sessionId)) {
          const session = entry.ctx.data.session.get(route.sessionId)
          if (session) known.set(session.id, { session })
        }
        if (currentTab?.type === "session" && currentTab.server === server && !known.has(currentTab.sessionId)) {
          const session = entry.ctx.data.session.get(currentTab.sessionId)
          if (session) known.set(session.id, { session })
        }
        return [...known.values()].map((row): SidebarSession => {
          const session = navigationSession(row, entry.ctx.data.session.get(row.session.id))
          return {
            ...row,
            session,
            server,
            key: sessionKey(server, session.id),
            project: sidebarSessionProject(server, session, selected),
            running: entry.ctx.data.session.status(session.id) === "running",
            recentRank: entry.index.ranks[session.id],
            ...sessionAttention({
              ...row,
              session,
              notifications: entry.ctx.notification.session.unseen(session.id),
              autoApprove: settings.permissions.autoApprove(),
            }),
          }
        })
      }),
      current(),
      currentTab?.type === "session" ? sessionKey(currentTab.server, currentTab.sessionId) : undefined,
    )
  })
  const projectGroups = createMemo(() =>
    indexes().flatMap((entry) => {
      const server = ServerConnection.key(entry.connection)
      return sidebarProjects(
        server,
        entry.projects(),
        sessions().rows.filter((row) => row.server === server),
      ).map((project) => ({ ...project, connection: entry.connection, serverName: serverName(entry.connection) }))
    }),
  )

  return { indexes, sessions, projectGroups }
}
