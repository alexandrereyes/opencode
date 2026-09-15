import { useGlobal, useServerCtx } from "@/runtime/server/runtime"
import { type HomeProjectSelection, useLayout } from "@/shell/state/layout"
import { ServerConnection, useServers } from "@/runtime/server/registry"
import { useProjectNavigation } from "@/workspaces/project-actions"
import { toggleHomeProjectSelection } from "@/shell/layout/helpers"
import { createEffect, createMemo, createResource } from "solid-js"
import { chatRoot } from "@/runtime/chats"

export function createHomeController() {
  const layout = useLayout()
  const global = useGlobal()
  const servers = useServers()
  const navigation = useProjectNavigation()
  const selection = layout.home.selection
  const focusedServer = createMemo<ServerConnection.Any | undefined>(
    () => servers.visible.find((conn) => ServerConnection.key(conn) === selection().server) ?? servers.visible[0],
  )
  const focusedServerCtx = useServerCtx(focusedServer)
  const [chat] = createResource(
    () => {
      const ctx = focusedServerCtx()
      return ctx?.sdk.connection.status() === "connected" ? ctx.sdk : undefined
    },
    async (sdk) => ({ sdk, root: await chatRoot(sdk) }),
  )
  const chatInfo = createMemo(() => {
    if (focusedServerCtx()?.sdk.connection.status() !== "connected") return
    const result = chat()
    return result?.sdk === focusedServerCtx()?.sdk ? result : undefined
  })
  const focusedSync = () => focusedServerCtx()?.sync
  const projects = createMemo(() => focusedServerCtx()?.projects.list() ?? [])
  const recentlyClosed = createMemo(() => focusedServerCtx()?.projects.recentlyClosed() ?? [])
  const homedir = createMemo(() => focusedSync()?.data.path.home ?? "")
  const selectedProject = createMemo(() => projects().find((project) => project.worktree === selection().directory))
  const newSessionProject = createMemo(
    () =>
      selection().chat
        ? undefined
        : (selectedProject() ??
          projects().find((project) => project.worktree === focusedServerCtx()?.projects.last()) ??
          projects()[0]),
  )

  createEffect(() => {
    const list = servers.visible
    if (list.some((conn) => ServerConnection.key(conn) === selection().server)) return
    const conn = list[0]
    if (conn) setSelection({ server: ServerConnection.key(conn) })
  })
  createEffect(() => {
    const ctx = focusedServerCtx()
    const id = selectedProject()?.id
    if (!ctx || !id || ctx.sdk.connection.status() !== "connected") return
    // Selecting a project is the demand for its worktree inventory: the session filter spans its worktrees.
    const root = ctx.sync.data.project.find((project) => project.id === id)?.worktree
    if (root) void ctx.sync.worktrees.load(id, root)
  })
  createEffect(() => {
    const current = selection()
    const info = chatInfo()
    if (!current.chat || !info || info.root !== undefined) return
    setSelection({ server: current.server })
  })

  function setSelection(next: HomeProjectSelection) {
    layout.home.setSelection(next)
  }

  return {
    selection: {
      value: selection,
      set: setSelection,
      focusServer: (conn: ServerConnection.Any) => setSelection({ server: ServerConnection.key(conn) }),
      selectChat: (conn: ServerConnection.Any) => {
        const server = ServerConnection.key(conn)
        setSelection(selection().server === server && selection().chat ? { server } : { server, chat: true })
      },
    },
    server: {
      list: () => servers.visible,
      health: (conn: ServerConnection.Any) => global.servers.health[ServerConnection.key(conn)],
      context: (conn: ServerConnection.Any) => global.ensureServerCtx(conn),
      focused: focusedServer,
      focusedContext: focusedServerCtx,
      focusedSync,
    },
    chat: {
      root: () => chatInfo()?.root,
      available: () => !!chatInfo()?.root,
    },
    project: {
      list: projects,
      recentlyClosed,
      homedir,
      selected: selectedProject,
      newSession: newSessionProject,
      forServer: (conn: ServerConnection.Any) => global.ensureServerCtx(conn).projects.list(),
      select: (conn: ServerConnection.Any, directory: string) => {
        const key = ServerConnection.key(conn)
        if (global.servers.health[key]?.healthy === false) return
        if (
          !global
            .ensureServerCtx(conn)
            .projects.list()
            .some((project) => project.worktree === directory)
        )
          return
        setSelection(toggleHomeProjectSelection(selection(), key, directory))
      },
      add: (conn: ServerConnection.Any, directories: string[]) => {
        const directory = directories[0]
        if (!directory) return
        const ctx = global.ensureServerCtx(conn)
        directories.forEach((item) => {
          if (ctx.projects.list().some((project) => project.worktree === item)) return
          const location = { directory: item }
          void ctx.sdk.api.file
            .list({ path: ".", location })
            .then(async (files) => {
              // TODO: Initialize empty directories when V2 exposes a native Git init API.
              return ctx.sdk.api.project.current({ location })
            })
            .then((project) => ctx.sync.child(item, { bootstrap: false })[1]("project", project.id))
            .catch(() => undefined)
          ctx.projects.open(item)
        })
        ctx.projects.touch(directory)
        setSelection({ server: ServerConnection.key(conn), directory })
      },
      openNewSession: () => {
        const conn = focusedServer()
        const project = newSessionProject()
        if (!conn || !project) return
        void navigation.openProjectNewSession(conn, project.worktree)
      },
      ...navigation,
    },
  }
}

export type HomeController = ReturnType<typeof createHomeController>
