import { createMemo, createResource, mapArray } from "solid-js"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection, serverName } from "@/runtime/server/registry"
import { useSettings } from "@/settings/model"
import { useLayout } from "@/shell/state/layout"
import type { Tab } from "@/shell/tabs/tabs"
import { createSidebarIndex } from "./sidebar-index"
import { createRecentClock } from "./sidebar-order"
import { rootSessions, isChatDirectory, sessionKey, sidebarProjects, sidebarProjectInventory } from "./sidebar-model"
import { createSidebarWorktrees } from "./sidebar-worktrees"
import { chatRoot } from "@/runtime/chats"
import { createSidebarChatTabs, createSidebarRows } from "./sidebar-rows"

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
  const chatTab = createSidebarChatTabs(() => options.tabs?.() ?? [])
  const indexes = mapArray(
    () => (options.enabled?.() === false ? [] : global.servers.list()),
    (connection) => {
      const server = ServerConnection.key(connection)
      const ctx = global.ensureServerCtx(connection)
      const projects = createMemo(() => ctx.projects.list())
      const inventory = createMemo(() => sidebarProjectInventory(server, projects()))
      const [chat] = createResource(
        () => (ctx.sdk.connection.status() === "connected" ? ctx.sdk.connection.epoch() + 1 : undefined),
        () => chatRoot(ctx.sdk),
      )
      const index = createSidebarIndex(ctx, clock)
      const rows = createSidebarRows({
        server,
        rows: () => index.state.rows,
        fallback: () => {
          const route = layout.route()
          const tab = options.currentTab()
          return [
            ...(route.type === "session" && route.server === server ? [route.sessionId] : []),
            ...(tab?.type === "session" && tab.server === server ? [tab.sessionId] : []),
            // A submitted draft can finish while another tab is selected, before the navigation index catches up.
            ...(options.tabs?.() ?? []).flatMap((tab) =>
              tab.type === "session" && tab.server === server ? [tab.sessionId] : [],
            ),
          ]
        },
        cached: (id) => ctx.data.session.get(id),
        running: (id) => ctx.data.session.status(id) === "running",
        rank: (id) => index.ranks[id],
        project: inventory,
        chatRoot: chat,
        chatTab,
        notifications: (id) => ctx.notification.session.unseen(id),
        autoApprove: () => settings.permissions.autoApprove(),
      })
      return {
        connection,
        ctx,
        projects,
        inventory,
        index,
        rows,
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
      indexes().flatMap((entry) => entry.rows()),
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
