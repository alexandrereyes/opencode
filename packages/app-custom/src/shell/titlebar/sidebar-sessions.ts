import { createMemo, createResource, mapArray } from "solid-js"
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
  isChatDirectory,
  sessionKey,
  sidebarProjects,
  sidebarProjectInventory,
  type SidebarSession,
} from "./sidebar-model"
import { createSidebarWorktrees } from "./sidebar-worktrees"
import { chatRoot } from "@/runtime/chats"
import { resolvedChatIdentity } from "@/runtime/chats"

export function createSidebarSessions(options: {
  currentTab: () => Tab | undefined
  enabled?: () => boolean
  clock?: ReturnType<typeof createRecentClock>
  tabs?: () => Tab[]
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
      const inventory = createMemo(() => sidebarProjectInventory(ServerConnection.key(connection), projects()))
      const [chat] = createResource(
        () => (ctx.sdk.connection.status() === "connected" ? ctx.sdk.connection.epoch() + 1 : undefined),
        () => chatRoot(ctx.sdk),
      )
      return {
        connection,
        ctx,
        projects,
        inventory,
        index: createSidebarIndex(ctx, clock),
        worktrees: createSidebarWorktrees(ctx),
        chat,
      }
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
        const project = entry.inventory()
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
            project: project(session),
            running: entry.ctx.data.session.status(session.id) === "running",
            recentRank: entry.index.ranks[session.id],
            chat:
              resolvedChatIdentity(
                session.location.directory,
                entry.chat(),
                options
                  .tabs?.()
                  .some(
                    (tab) =>
                      tab.type === "session" && tab.server === server && tab.sessionId === session.id && !!tab.chat,
                  ),
              ) || undefined,
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
        entry.projects().filter((project) => !isChatDirectory(project.worktree, entry.chat())),
        sessions().rows.filter((row) => row.server === server),
      ).map((project) => ({ ...project, connection: entry.connection, serverName: serverName(entry.connection) }))
    }),
  )

  const chatRoots = createMemo(
    () => new Map(indexes().map((entry) => [ServerConnection.key(entry.connection), entry.chat()])),
  )
  return { indexes, sessions, projectGroups, chatRoots }
}
