import { createSimpleContext } from "@opencode/ui-custom/context"
import { batch, createEffect, createMemo } from "solid-js"
import { type SetStoreFunction, type Store } from "solid-js/store"
import { Persist, persisted } from "@/runtime/persistence/storage"
import { pathKey } from "@/workspaces/path-key"
import { ServerScope } from "@/runtime/server/scope"
import { ServerHttp, ServerHttpBase, ServerKey, serverState } from "./persistence"
import type { SshItem } from "@/servers/ssh/types"
import { usePreferences } from "@/preferences/context"

type ServerState = ReturnType<typeof serverState>["current"]["Type"]
// The store retains more history than is displayed. Consumers filter recently closed entries
// against the live project list (dropping deleted projects) and then cap the visible count via
// RECENTLY_CLOSED_DISPLAY_LIMIT. Retaining extra history ensures entries that are temporarily
// filtered out do not evict still-visible ones from the persisted store.
const RECENTLY_CLOSED_HISTORY_LIMIT = 16
export const RECENTLY_CLOSED_DISPLAY_LIMIT = 5

export function normalizeServerUrl(input: string) {
  const trimmed = input.trim()
  if (!trimmed) return
  const withProtocol = /^https?:\/\//.test(trimmed) ? trimmed : `http://${trimmed}`
  return withProtocol.replace(/\/+$/, "")
}

export function serverName(conn?: ServerConnection.Any, ignoreDisplayName = false) {
  if (!conn) return ""
  if (conn.displayName && !ignoreDisplayName) return conn.displayName
  if (conn.type === "ssh") return conn.host
  return conn.http.url.replace(/^https?:\/\//, "").replace(/\/+$/, "")
}

function isLocalHost(url: string) {
  const host = url.replace(/^https?:\/\//, "").split(":")[0]
  if (host === "localhost" || host === "127.0.0.1") return "local"
}

export function createServerProjects(input: {
  scope: () => ServerScope
  store: Store<ServerState>
  setStore: SetStoreFunction<ServerState>
  preferences?: ReturnType<typeof usePreferences>
}) {
  const setStore = input.setStore
  const remote = () =>
    input.preferences?.canonical() ? input.preferences.profile().data.projects[input.scope()] : undefined
  const current = () => remote()?.projects ?? input.store.projects[input.scope()] ?? []
  const currentClosed = () => remote()?.recentlyClosed ?? input.store.recentlyClosed?.[input.scope()] ?? []
  const removeLocal = (directory: string) => {
    setStore(
      "projects",
      input.scope(),
      current().filter((project) => project.worktree !== directory),
    )
  }
  const remove = (directory: string) => {
    removeLocal(directory)
    void input.preferences?.mutate({ type: "project.remove", server: input.scope(), directory })
  }
  return {
    list: current,
    recentlyClosed: currentClosed,
    remove,
    open(directory: string) {
      const scope = input.scope()
      const key = pathKey(directory)
      const closed = currentClosed()
      if (closed.some((worktree) => pathKey(worktree) === key)) {
        setStore(
          "recentlyClosed",
          scope,
          closed.filter((worktree) => pathKey(worktree) !== key),
        )
      }
      if (current().some((project) => project.worktree === directory)) return
      setStore("projects", scope, [{ worktree: directory, expanded: true }, ...current()])
      void input.preferences?.mutate({ type: "project.open", server: scope, directory })
    },
    // User-initiated close: removes the project and records it in recently closed.
    // Internal, non-user removals (e.g. sandbox/worktree normalization) should use remove().
    close(directory: string) {
      removeLocal(directory)
      const key = pathKey(directory)
      const closed = [directory, ...currentClosed().filter((worktree) => pathKey(worktree) !== key)].slice(
        0,
        RECENTLY_CLOSED_HISTORY_LIMIT,
      )
      setStore("recentlyClosed", input.scope(), closed)
      void input.preferences?.mutate({ type: "project.close", server: input.scope(), directory })
    },
    expand(directory: string) {
      const index = current().findIndex((project) => project.worktree === directory)
      if (index === -1) return
      setStore("projects", input.scope(), index, "expanded", true)
      void input.preferences?.mutate({ type: "project.expand", server: input.scope(), directory })
    },
    collapse(directory: string) {
      const index = current().findIndex((project) => project.worktree === directory)
      if (index === -1) return
      setStore("projects", input.scope(), index, "expanded", false)
      void input.preferences?.mutate({ type: "project.collapse", server: input.scope(), directory })
    },
    move(directory: string, toIndex: number) {
      const fromIndex = current().findIndex((project) => project.worktree === directory)
      if (fromIndex === -1 || fromIndex === toIndex) return
      const next = [...current()]
      const [item] = next.splice(fromIndex, 1)
      next.splice(toIndex, 0, item)
      setStore("projects", input.scope(), next)
      void input.preferences?.mutate({ type: "project.move", server: input.scope(), directory, toIndex })
    },
    last() {
      return remote()?.lastProject ?? input.store.lastProject[input.scope()]
    },
    touch(directory: string) {
      setStore("lastProject", input.scope(), directory)
      void input.preferences?.mutate({ type: "project.touch", server: input.scope(), directory })
    },
  }
}

export function resolveServerList(input: {
  props?: Array<ServerConnection.Any>
  stored: ServerConnection.Http[]
}): Array<ServerConnection.Any> {
  const deduped = new Map<ServerConnection.Key, ServerConnection.Any>(
    input.props?.map((v) => [ServerConnection.key(v), v]) ?? [],
  )

  for (const conn of input.stored) {
    const key = ServerConnection.key(conn)

    const existing = deduped.get(key)
    if (existing)
      deduped.set(key, {
        ...existing,
        ...conn,
        http: { ...existing.http, ...conn.http },
      })
    else deduped.set(key, conn)
  }

  return [...deduped.values()]
}

export function canRemoveServer(input: {
  key: ServerConnection.Key
  provided?: Array<ServerConnection.Any>
  stored: ServerConnection.Http[]
}) {
  if (input.provided?.some((server) => ServerConnection.key(server) === input.key)) return false
  return input.stored.some((server) => server.http.url === input.key)
}

export namespace ServerConnection {
  type Base = { displayName?: string; label?: string }

  export type HttpBase = typeof ServerHttpBase.Type

  // Regular web connections
  export type Http = typeof ServerHttp.Type

  export type Sidecar = {
    type: "sidecar"
    http: HttpBase
  } & (
    | // Regular desktop server
    { variant: "base"; reconnect?: (signal: AbortSignal) => Promise<HttpBase> }
    // WSL server (windows only)
    | {
        variant: "wsl"
        distro: string
      }
  ) &
    Base

  // Remote server desktop can SSH into
  export type Ssh = {
    type: "ssh"
    stage?: SshItem["stage"]
    connecting?: boolean
    authenticationRequired?: boolean
    id?: string
    host: string
    // SSH client exposes an HTTP server for the app to use as a proxy
    http: HttpBase
    reconnect?: (signal: AbortSignal) => Promise<HttpBase>
  } & Base

  export type Any =
    | Http
    // All these are desktop-only
    | (Sidecar | Ssh)

  export const key = (conn: Any): Key => {
    switch (conn.type) {
      case "http":
        return Key.make(conn.http.url)
      case "sidecar": {
        if (conn.variant === "wsl") return Key.make(`wsl:${conn.distro}`)
        return Key.make("sidecar")
      }
      case "ssh":
        return Key.make(`ssh:${conn.id ?? conn.host}`)
    }
  }

  export const Key = ServerKey
  export type Key = typeof Key.Type

  export const builtin = (conn: Any) => conn.type === "sidecar" && conn.variant === "base"
  export const local = (conn?: Any) =>
    !!conn && (builtin(conn) || (conn.type === "http" && isLocalHost(conn.http.url) === "local"))
}

export const { use: useServers, provider: ServersProvider } = createSimpleContext({
  name: "Server",
  gate: true,
  init: (props: {
    defaultServer?: ServerConnection.Key
    canonicalLocalServer?: ServerConnection.Key
    servers?: Array<ServerConnection.Any>
  }) => {
    const preferences = usePreferences()
    const [store, setStore, raw] = persisted(
      {
        ...Persist.global("server"),
        sync: true,
        previousKey: "server.v3",
      },
      serverState(() => props.canonicalLocalServer),
      { list: [], hidden: {}, projects: {}, lastProject: {}, recentlyClosed: {} },
    )
    preferences.legacy("projects", {
      raw,
      read: () => {
        const servers = new Set([
          ...Object.keys(store.projects),
          ...Object.keys(store.recentlyClosed),
          ...Object.keys(store.lastProject),
        ])
        return {
          projects: Object.fromEntries(
            [...servers].map((server) => [
              server,
              {
                projects: [...(store.projects[server] ?? [])],
                recentlyClosed: [...(store.recentlyClosed[server] ?? [])],
                lastProject: store.lastProject[server],
              },
            ]),
          ),
        }
      },
    })
    createEffect(() => {
      if (!preferences.canonical()) return
      const projects = preferences.profile().data.projects
      setStore(
        "projects",
        Object.fromEntries(
          Object.entries(projects).map(([server, library]) => [
            server,
            library.projects.map((project) => ({ ...project })),
          ]),
        ),
      )
      setStore(
        "recentlyClosed",
        Object.fromEntries(Object.entries(projects).map(([server, library]) => [server, [...library.recentlyClosed]])),
      )
      setStore(
        "lastProject",
        Object.fromEntries(
          Object.entries(projects).flatMap(([server, library]) =>
            library.lastProject === undefined ? [] : [[server, library.lastProject]],
          ),
        ),
      )
    })

    const allServers = createMemo((): Array<ServerConnection.Any> => {
      return resolveServerList({ stored: store.list, props: props.servers })
    })
    const visibleServers = createMemo(() => allServers().filter((conn) => !store.hidden[ServerConnection.key(conn)]))

    function add(input: ServerConnection.Http) {
      const url_ = normalizeServerUrl(input.http.url)
      if (!url_) return
      const conn: ServerConnection.Http = { ...input, authToken: undefined, http: { ...input.http, url: url_ } }
      return batch(() => {
        const existing = store.list.findIndex((x) => x.http.url === url_)
        if (existing !== -1) {
          setStore("list", existing, conn)
        } else {
          setStore("list", store.list.length, conn)
        }
        return conn
      })
    }

    function remove(key: ServerConnection.Key) {
      const list = store.list.filter((x) => x.http.url !== key)
      batch(() => {
        setStore("list", list)
      })
    }

    function canRemove(key: ServerConnection.Key) {
      return canRemoveServer({ key, provided: props.servers, stored: store.list })
    }

    const scope = (key: ServerConnection.Key) => ServerScope.fromServerKey(key, props.canonicalLocalServer)
    const projectStores = new Map<ServerConnection.Key, ReturnType<typeof createServerProjects>>()
    const projectsForServer = (key: ServerConnection.Key) => {
      const existing = projectStores.get(key)
      if (existing) return existing
      const next = createServerProjects({ scope: () => scope(key), store, setStore, preferences })
      projectStores.set(key, next)
      return next
    }

    return {
      get list() {
        return allServers()
      },
      get visible() {
        return visibleServers()
      },
      isHidden(key: ServerConnection.Key) {
        return store.hidden[key] ?? false
      },
      setHidden(key: ServerConnection.Key, hidden: boolean) {
        setStore("hidden", key, hidden)
      },
      add,
      remove,
      canRemove,
      scope,
      projects: {
        forServer: projectsForServer,
      },
    }
  },
})
