import { createSimpleContext } from "@opencode/ui-custom/context"
import { Accessor, createEffect, createMemo, createResource, createRoot, getOwner, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import { createServerProjects, RECENTLY_CLOSED_DISPLAY_LIMIT, ServerConnection, useServers } from "./registry"
import { pathKey } from "@/workspaces/path-key"
import { useServerHealth } from "@/runtime/server/health"
import { createServerSdkContext } from "./client"
import { createServerSyncContext } from "./sync"
import { createData } from "@opencode/client/solid"
import type { ServerScope } from "@/runtime/server/scope"
import { createPermissionAutoApprover } from "@/session/requests/auto-approve"
import { createServerNotificationState } from "@/shell/notifications/notification"
import { createNotificationCoordinator } from "@/shell/notifications/coordinator"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { createDesktopData } from "./data"
import { ModelState } from "./persistence"
import { useLanguage } from "@/runtime/i18n/language"
import { showToast } from "@/shell/notifications/toast"
import { formatServerError } from "./errors"
import { useSettings } from "@/settings/model"
import { createServerSnippets } from "@/settings/snippets/server"
import { timelinePreset } from "@opencode/session-ui-custom/timeline/detail"
import { notifySessionTabsRemoved } from "@/shell/titlebar/session-events"
import { usePreferences } from "@/preferences/context"
import { Schema } from "effect"
import { Persistence } from "@/runtime/persistence/schema"

export const { use: useGlobal, provider: GlobalProvider } = createSimpleContext({
  name: "Global",
  init: () => {
    const server = useServers()
    const serverHealth = useServerHealth(
      () => server.list,
      () => true,
    )
    const [store, setStore] = createStore({
      settings: {
        serverKey: undefined as ServerConnection.Key | undefined,
      },
    })
    const models = createGlobalModels()
    const sidebar = createGlobalSidebar()
    const notificationCoordinator = createNotificationCoordinator()

    const settingsServer = createMemo(() => {
      const list = server.list
      return list.find((conn) => ServerConnection.key(conn) === store.settings.serverKey) ?? list[0]
    })

    createEffect(() => {
      const conn = settingsServer()
      const key = conn ? ServerConnection.key(conn) : undefined
      if (store.settings.serverKey !== key) setStore("settings", "serverKey", key)
    })

    const serverCtxs = new Map<ServerConnection.Key, ReturnType<typeof createServerController>>()
    const serverCtxDisposers = new Map<ServerConnection.Key, () => void>()

    const owner = getOwner()
    if (!owner) throw new Error("Global provider requires a Solid owner")

    const ensureServerCtx = (conn: ServerConnection.Any) => {
      const key = ServerConnection.key(conn)
      const existing = serverCtxs.get(key)
      if (existing) return existing
      const serverCtx = createRoot((dispose) => {
        serverCtxDisposers.set(key, dispose)
        return createServerController(conn, server.scope(key), server.projects.forServer(key), notificationCoordinator)
      }, owner)
      serverCtxs.set(key, serverCtx)
      return serverCtx
    }

    createMemo(() => {
      for (const conn of server.list) {
        ensureServerCtx(conn)
      }
    })

    createEffect(() => {
      for (const [key] of serverCtxs) {
        if (!server.list.find((conn) => ServerConnection.key(conn) === key)) {
          serverCtxDisposers.get(key)?.()
          serverCtxDisposers.delete(key)
          serverCtxs.delete(key)
        }
      }
    })

    return {
      servers: {
        list: () => server.list,
        health: serverHealth,
      },
      settings: {
        server: {
          get key() {
            return store.settings.serverKey
          },
          selected: settingsServer,
          set(key: ServerConnection.Key) {
            if (store.settings.serverKey !== key) setStore("settings", "serverKey", key)
          },
        },
      },
      models,
      sidebar,
      ensureServerCtx(conn: ServerConnection.Any) {
        return ensureServerCtx(conn)
      },
    }
  },
})

const SidebarState = Persistence.struct({
  attention: Schema.Boolean,
  order: Persistence.array(Schema.String),
  collapsed: Persistence.record(Schema.Boolean),
  pins: Persistence.array(Schema.String),
})

function createGlobalSidebar() {
  const preferences = usePreferences()
  const [store, set, raw, ready] = persisted(Persist.global("sidebar-navigation"), SidebarState, {
    attention: true,
    order: [],
    collapsed: {},
    pins: [],
  })
  preferences.legacy("sidebar", {
    raw,
    read: () => ({ sidebarOrder: [...store.order], pinnedSessions: [...store.pins] }),
  })
  createEffect(() => {
    if (!preferences.canonical()) return
    set("order", [...preferences.profile().data.sidebarOrder])
    set("pins", [...preferences.profile().data.pinnedSessions])
  })
  return { store, set, ready }
}

function createGlobalModels() {
  const preferences = usePreferences()
  const [local, setLocal, raw, ready] = persisted(Persist.global("model"), ModelState, {
    user: [],
    recent: [],
    variant: {},
  })
  preferences.legacy("models", {
    raw,
    read: () => ({
      models: {
        user: [...local.user],
        variant: Object.fromEntries(
          Object.entries(local.variant).filter((entry): entry is [string, string] => entry[1] !== undefined),
        ),
      },
    }),
  })
  createEffect(() => {
    if (!preferences.canonical()) return
    const remote = preferences.profile().data.models
    setLocal(
      "user",
      remote.user.map((model) => ({ ...model })),
    )
    setLocal("variant", { ...remote.variant })
  })
  const store = new Proxy(local, {
    get(target, property) {
      if (property === "user" && preferences.canonical()) return preferences.profile().data.models.user
      if (property === "variant" && preferences.canonical()) return preferences.profile().data.models.variant
      return target[property as keyof typeof target]
    },
  }) as typeof local
  const [recent] = createResource(
    async () => {
      const value = local.recent
      await ready.promise
      return value
    },
    (value) => value,
    { initialValue: [] },
  )

  return {
    store,
    set: setLocal,
    preferences,
    ready,
    recent: () => recent()!,
  }
}

function createServerController(
  conn: ServerConnection.Any,
  scope: ServerScope,
  projects: ReturnType<typeof createServerProjects>,
  notificationCoordinator: ReturnType<typeof createNotificationCoordinator>,
) {
  const language = useLanguage()
  const settings = useSettings()
  const connKey = ServerConnection.key(conn)
  const sdk = createServerSdkContext(conn, scope)
  const snippets = createServerSnippets(sdk)
  const source = createData({
    api: () => sdk.api,
    initialMessageLimit: () => (timelinePreset(settings.general.timelineDetail())?.id === "compact" ? 40 : 20),
    event: {
      on: sdk.event.on,
      listen: (handler) => sdk.event.listen((event) => handler({ name: event.type, details: event })),
    },
    connection: sdk.connection,
    directory: "",
    onError(error) {
      showToast({
        variant: "error",
        title: language.t("common.requestFailed"),
        description: formatServerError(error, language.t),
      })
    },
  })
  const data = createDesktopData({
    data: source,
    remove: (sessionID) => sdk.api.session.remove({ sessionID }),
  })
  // Each descendant has its own event, including sessions whose ancestry is not cached locally.
  const hideSession = (sessionID: string) =>
    notifySessionTabsRemoved({
      server: connKey,
      directory: data.session.get(sessionID)?.location.directory ?? "",
      sessionIDs: [sessionID],
    })
  onCleanup(data.on("session.archived", (event) => hideSession(event.data.sessionID)))
  onCleanup(data.on("session.deleted", (event) => hideSession(event.data.sessionID)))
  const sync = createServerSyncContext(sdk, data)
  createPermissionAutoApprover({ sdk, data })
  const notification = createServerNotificationState({ sdk, data, key: connKey, coordinator: notificationCoordinator })

  function enrich(project: { worktree: string; expanded: boolean }) {
    const [childStore] = sync.child(project.worktree, { bootstrap: false })
    const projectID = childStore.project
    const metadata = projectID
      ? sync.data.project.find((x) => x.id === projectID)
      : sync.data.project.find((x) => x.worktree === project.worktree)

    // Preserve local icon override from per-workspace localStorage cache (childStore.icon).
    // Without this, different subdirectories of the same git repo would share the same
    // icon from the database instead of using their individual overrides.
    const base = { ...metadata, ...project }
    if (childStore.icon) {
      return { ...base, icon: { ...base.icon, override: childStore.icon } }
    }
    return base
  }

  const projectsList = createMemo(() => projects.list().map(enrich))
  const recentlyClosedList = createMemo(() => {
    const known = new Set(sync.data.project.map((project) => pathKey(project.worktree)))
    return projects
      .recentlyClosed()
      .filter((worktree) => known.has(pathKey(worktree)))
      .slice(0, RECENTLY_CLOSED_DISPLAY_LIMIT)
      .map((worktree) => enrich({ worktree, expanded: false }))
  })

  const isLocal =
    (conn?.type === "sidecar" && conn.variant === "base") || (conn?.type === "http" && isLocalHost(conn.http.url))

  return {
    data,
    sdk,
    snippets,
    sync,
    isLocal,
    projects: {
      ...projects,
      list: projectsList,
      recentlyClosed: recentlyClosedList,
    },
    notification,
  }
}

export function useServerCtx(server: Accessor<ServerConnection.Any>): Accessor<ServerCtx>
export function useServerCtx(server: Accessor<ServerConnection.Any | undefined>): Accessor<ServerCtx | undefined>
export function useServerCtx(server: Accessor<ServerConnection.Any | undefined>) {
  const global = useGlobal()
  return () => {
    const s = server()
    if (s) return global.ensureServerCtx(s)
  }
}

export type ServerCtx = ReturnType<typeof createServerController>

function isLocalHost(url: string) {
  const host = url.replace(/^https?:\/\//, "").split(":")[0]
  if (host === "localhost" || host === "127.0.0.1") return "local"
}
