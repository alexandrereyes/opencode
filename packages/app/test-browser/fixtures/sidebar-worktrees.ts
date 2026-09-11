import { expect, mock, test } from "bun:test"
import { createRequire } from "node:module"
import { createServer } from "node:http"
import { createComponent, createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import { render } from "solid-js/web"
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query"
import { OpenCode, type OpenCodeEvent, type SessionNavigationInfo } from "@opencode/client/promise"
import { createData } from "@opencode/client/solid"
import { createWorktreeInventory, withWorktreeInventory } from "@/workspaces/inventory"
import { ServerScope } from "@/runtime/server/scope"
import type { Project } from "@/runtime/server/types"

const require = createRequire(import.meta.url)
const solid = createRequire(require.resolve("vite-plugin-solid"))
const { transformSync } = solid("@babel/core")
Bun.plugin({
  name: "sidebar-worktrees-solid",
  setup(build) {
    build.onLoad({ filter: /\.tsx$/ }, async (args) => ({
      contents: transformSync(await Bun.file(args.path).text(), {
        filename: args.path,
        presets: [solid.resolve("babel-preset-solid"), solid.resolve("@babel/preset-typescript")],
      }).code,
      loader: "js",
    }))
  },
})
mock.module("@/runtime/platform/platform", () => ({ usePlatform: () => ({ platform: "web" }) }))
mock.module("@/servers/ssh/authenticate", () => ({ useSshAuthenticate: () => () => false }))
mock.module("@/settings/model", () => ({
  useSettings: () => ({ permissions: { autoApprove: () => false }, appearance: { showProjectName: () => false } }),
}))
mock.module("@/shell/commands/command", () => ({ useCommand: () => ({ register: () => {} }) }))
mock.module("@/shell/layout/session-tab-avatar", () => ({ SessionTabAvatar: () => null }))
mock.module("@/composer/persistence", () => ({ createTabComposerState: () => {} }))
mock.module("@/shell/notifications/toast", () => ({ showToast: () => {} }))
const archived: string[][] = []
mock.module("@/session/lifecycle-actions", () => ({
  useSessionLifecycleActions: () => ({
    pending: () => false,
    archiveMany: async (
      rows: { key?: string; session?: { id: string } }[],
      onComplete: (result: { succeeded: typeof rows; failed: [] }) => void,
    ) => {
      archived.push(rows.map((row) => row.key ?? row.session?.id ?? ""))
      const result = { succeeded: rows, failed: [] as [] }
      onComplete(result)
      return result
    },
  }),
}))
mock.module("@/shell/state/layout", () => ({
  useLayout: () => ({ route: () => ({ type: "home" }) }),
  useCurrentRoute: () => () => ({ type: "home" }),
}))

const registry = await import("@/runtime/server/registry")
const { ServerConnection } = registry
const { projectKey, sessionKey } = await import("@/shell/titlebar/sidebar-model")
const { worktreeKey } = await import("@/shell/titlebar/sidebar-worktrees")
const tabsModule = await import("@/shell/tabs/tabs")
const drafts: { server: string; directory?: string }[] = []
const tabStore: Array<{
  type: "draft"
  draftID: string
  server: string
  directory: string
  worktree?: string
  branch?: string
}> = []
mock.module("@/shell/tabs/tabs", () => ({
  ...tabsModule,
  useTabs: () => ({
    store: tabStore,
    pendingSession: () => false,
    newDraft: async (input: { server: string; directory?: string }) => {
      drafts.push(input)
    },
    addSessionTab: () => {},
    select: () => {},
    updateDraft: (draftID: string, update: Partial<(typeof tabStore)[number]>) => {
      const draft = tabStore.find((item) => item.draftID === draftID)
      if (draft) Object.assign(draft, update)
    },
  }),
}))
const connections = [
  { type: "http" as const, http: { url: "http://sidebar-local.test" } },
  { type: "http" as const, http: { url: "http://sidebar-remote.test" } },
]
mock.module("@/runtime/server/registry", () => ({ ...registry, useServers: () => ({ list: connections }) }))
const calls: { server: number; path: string; directory: string }[] = []
const removals: Record<string, unknown>[] = []
const removedDirectories = new Set<string>()
const gates = {
  inventory: Promise.withResolvers<void>(),
  remoteInventory: Promise.withResolvers<void>(),
  branch: Promise.withResolvers<void>(),
}
const now = Date.now()
function row(id: string, directory: string, position = 0, projectID = "repo"): SessionNavigationInfo {
  return {
    messageAt: now - position,
    session: {
      id,
      projectID,
      title: id,
      location: { directory },
      time: { created: 1, updated: now - position },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}
const backend = [
  [
    ...Array.from({ length: 7 }, (_, i) => row(`root-${i}`, i ? "/repo/src" : "/repo", i)),
    ...Array.from({ length: 7 }, (_, i) => row(`feat-${i}`, i ? "/trees/feat/src" : "/trees/feat", 20 + i)),
    row("other-feat", "/other/feat", 30),
    row("loose", "/loose/feat/src", 40),
    row("missing", "/missing/feat", 50),
    row("prefix", "/trees/feature", 60),
    row("second", "/second", 70, "second"),
  ],
  [row("remote-root", "/repo", 80), row("remote-feat", "/trees/feat", 90)],
]

test("grouping, lazy metadata, identity, drafts, keyboard selection/reorder, collapse persistence and empty groups", async () => {
  const apiServer = createServer(async (request, response) => {
    response.setHeader("access-control-allow-origin", "*")
    response.setHeader("access-control-allow-headers", "x-fixture-server")
    response.setHeader("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
    if (request.method === "OPTIONS") {
      response.writeHead(204)
      response.end()
      return
    }
    const json = (value: unknown, status = 200) => {
      response.writeHead(status, { "content-type": "application/json" })
      response.end(JSON.stringify(value))
    }
    const url = new URL(request.url!, "http://localhost")
    const server = Number(request.headers["x-fixture-server"])
    const directory = url.searchParams.get("location[directory]") ?? ""
    const targetDirectory = url.searchParams.get("directory") ?? directory
    calls.push({ server, path: url.pathname, directory })
    if (url.pathname === "/api/worktree/inspect")
      return json({
        directory: targetDirectory,
        identity: "idle-token",
        branch: "idle",
        dirty: true,
        localBranch: { name: "idle" },
        remoteBranch: { name: "upstream", branch: "idle" },
      })
    if (url.pathname === "/api/session")
      return json({ data: [row("idle-history", "/empty/idle/src", 0, "empty").session], cursor: {} })
    if (url.pathname === "/api/worktree/delete" && request.method === "DELETE") {
      const payload = JSON.parse(
        Buffer.concat((await Array.fromAsync(request)).map((chunk) => Buffer.from(chunk))).toString("utf8"),
      ) as Record<string, unknown>
      removals.push(payload)
      removedDirectories.add(String(payload.directory))
      return json({
        directory: payload.directory,
        localBranch: payload.deleteLocalBranch ? { name: "idle", deleted: true } : undefined,
        remoteBranch: payload.deleteRemoteBranch
          ? { name: "idle", remote: "upstream", deleted: true }
          : undefined,
      })
    }
    if (url.pathname === "/api/session/navigation")
      return json({
        data: backend[server].filter(
          (row) => !url.searchParams.get("sessionID") || row.session.id === url.searchParams.get("sessionID"),
        ),
      })
    if (url.pathname === "/api/session/active") return json({ data: {} })
    if (url.pathname === "/api/worktree") {
      if (!server && directory === "/repo") await gates.inventory.promise
      if (server && directory === "/repo") await gates.remoteInventory.promise
      if (directory === "/empty" && removedDirectories.has("/empty/idle"))
        return json({ message: "Inventory unavailable" }, 503)
      return json(
        directory === "/repo"
          ? [
              { directory: "/repo" },
              { directory: "/trees/feat", strategy: "git" },
              { directory: "/other/feat", strategy: "git" },
            ]
          : directory === "/empty"
            ? [{ directory: "/empty" }, { directory: "/empty/idle", strategy: "git" }].filter(
                (item) => !removedDirectories.has(item.directory),
              )
            : [{ directory }],
      )
    }
    const worktree = directory === "/loose/feat/src" ? "/loose/feat" : directory
    const location = { directory, project: { id: "repo", canonical: "/repo", directory: worktree } }
    if (url.pathname === "/api/location") {
      if (directory === "/missing/feat" || directory === "/trees/feature") return json({ message: "Unavailable" }, 400)
      return json(location)
    }
    if (url.pathname === "/api/vcs") {
      if (!server && directory === "/trees/feat") await gates.branch.promise
      return json({
        location,
        data: {
          branch: {
            current:
              directory === "/loose/feat"
                ? undefined
                : directory === "/empty/idle"
                  ? "idle"
                  : server
                    ? "remote/branch"
                    : "feat/payments",
          },
        },
      })
    }
    return json({ message: `Unexpected ${url.pathname}` }, 500)
  })
  await new Promise<void>((resolve) => apiServer.listen(0, "127.0.0.1", resolve))
  const address = apiServer.address()
  if (!address || typeof address === "string") throw new Error("Expected ephemeral TCP server")
  const roots = connections.map((connection, server) =>
    createRoot((dispose) => {
      const api = OpenCode.make({
        baseUrl: `http://127.0.0.1:${address.port}`,
        headers: { "x-fixture-server": String(server) },
      })
      const listeners = new Set<(event: OpenCodeEvent) => void>()
      const dataListeners = new Set<(event: { name: OpenCodeEvent["type"]; details: OpenCodeEvent }) => void>()
      const data = createData({
        api: () => api,
        directory: "/repo",
        event: {
          on: () => () => {},
          listen: (handler) => {
            dataListeners.add(handler)
            return () => dataListeners.delete(handler)
          },
        },
      })
      const [state, setState] = createStore({
        path: { home: "/home/test" },
        project: [
          {
            id: "repo",
            worktree: "/repo",
            name: "Repo",
            vcs: "git",
            worktrees: [{ directory: "/repo" }],
            sandboxes: [],
            time: { created: 1, updated: 1 },
          },
          {
            id: "second",
            worktree: "/second",
            name: "Second",
            vcs: "git",
            worktrees: [{ directory: "/second" }],
            sandboxes: [],
            time: { created: 1, updated: 1 },
          },
          {
            id: "empty",
            worktree: "/empty",
            name: "Empty",
            vcs: "git",
            worktrees: [],
            sandboxes: [],
            time: { created: 1, updated: 1 },
          },
        ] as Project[],
      })
      const query = new QueryClient()
      const inventory = createWorktreeInventory({
        scope: ServerScope.fromServerKey(ServerConnection.key(connection)),
        queryClient: query,
        api: () => api.worktree,
        updated: (directory, items) =>
          setState("project", (projects) =>
            projects.map((project) =>
              project.worktree === directory ? withWorktreeInventory(project, items) : project,
            ),
          ),
      })
      const opened: string[] = []
      const ctx = {
        data,
        sync: { data: state, worktrees: inventory },
        projects: { list: () => [], open: (directory: string) => opened.push(directory), touch: () => {} },
        notification: { session: { unseen: () => [] } },
        sdk: {
          api,
          connection: { status: () => "connected" },
          event: {
            listen: (listener: (event: OpenCodeEvent) => void) => {
              listeners.add(listener)
              return () => listeners.delete(listener)
            },
          },
        },
      }
      return {
        ctx,
        opened,
        setState,
        listeners,
        dataListeners,
        dispose: () => {
          dispose()
          query.clear()
        },
      }
    }),
  )
  mock.module("@/runtime/server/runtime", () => ({
    useGlobal: () => ({
      servers: { list: () => connections },
      ensureServerCtx: (connection: ServerConnection.Any) =>
        roots[connections.indexOf(connection as (typeof connections)[number])].ctx,
    }),
    useServerCtx: (connection: () => ServerConnection.Any) => () =>
      roots[connections.indexOf(connection() as (typeof connections)[number])]?.ctx,
  }))
  const { SessionSidebar } = await import("@/shell/titlebar/sidebar")
  const { LanguageProvider } = await import("@/runtime/i18n/language")
  const { DialogProvider } = await import("@opencode/ui/context/dialog")
  const { flushPersisted } = await import("@/runtime/persistence/persist")
  const { Persist, removePersisted } = await import("@/runtime/persistence/storage")
  const storage = "opencode.global.dat:sidebar-navigation"
  const project = projectKey(ServerConnection.key(connections[0]), { id: "repo", worktree: "/repo" })
  const second = projectKey(ServerConnection.key(connections[0]), { id: "second", worktree: "/second" })
  localStorage.setItem(storage, JSON.stringify({ attention: true, order: [], collapsed: { [second]: true }, pins: [] }))
  const host = document.createElement("div")
  document.body.append(host)
  const query = new QueryClient()
  const mount = () =>
    render(
      () =>
        createComponent(LanguageProvider, {
          get children() {
            return createComponent(QueryClientProvider, {
              client: query,
              get children() {
                return createComponent(DialogProvider, {
                  get children() {
                    return createComponent(SessionSidebar, { header: null, children: null })
                  },
                })
              },
            })
          },
        }),
      host,
    )
  let dispose = mount()
  const wait = () => new Promise((resolve) => setTimeout(resolve, 180))
  const projectElement = (key = project) =>
    [...host.querySelectorAll<HTMLElement>("[data-project-key]")].find((item) => item.dataset.projectKey === key)!
  const group = (directory: string, key = project) =>
    [...projectElement(key).querySelectorAll<HTMLElement>("[data-worktree-key]")].find(
      (item) => item.dataset.worktreeKey === worktreeKey(key, directory),
    )!
  const header = (element: HTMLElement) => element.querySelector<HTMLButtonElement>("button[aria-expanded]")!
  const titles = (element: ParentNode) =>
    [...element.querySelectorAll("[data-titlebar-tab-title]")].map((item) => item.textContent)
  const button = (text: string) =>
    [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text)!
  const toggle = () => host.querySelector<HTMLButtonElement>('[aria-label="Attention view"]')!.click()
  try {
    await wait()
    expect(
      calls.filter(
        (call) => call.path.includes("worktree") || call.path.includes("vcs") || call.path === "/api/location",
      ),
    ).toEqual([])
    toggle()
    await wait()
    const emptyProject = projectKey(ServerConnection.key(connections[0]), { id: "empty", worktree: "/empty" })
    expect(calls.filter((call) => call.path === "/api/worktree").map((call) => [call.server, call.directory])).toEqual([
      [0, "/repo"],
      [1, "/repo"],
      [0, "/empty"],
      [1, "/empty"],
      [1, "/second"],
    ])
    expect(group("/empty/idle", emptyProject)).toBeDefined()
    expect(titles(group("/empty/idle", emptyProject))).toEqual([])
    const idle = group("/empty/idle", emptyProject)
    const idleHeader = header(idle)
    expect(idleHeader.textContent).toContain("idle (0)")
    expect(idle.querySelector('[data-action="sidebar-worktree-new-session"]')).toBeDefined()
    const idleExpanded = idleHeader.getAttribute("aria-expanded")
    const trash = idle.querySelector<HTMLButtonElement>('[data-action="sidebar-worktree-delete"]')!
    expect(trash).toBeDefined()
    trash.focus()
    trash.click()
    expect(idleHeader.getAttribute("aria-expanded")).toBe(idleExpanded)
    await wait()
    const dialogButton = (text: string) =>
      [...document.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text)!
    expect(document.querySelector('[role="alert"]')?.textContent).toContain("uncommitted changes")
    dialogButton("Cancel").click()
    expect(removals).toHaveLength(0)
    await wait()
    trash.click()
    await wait()
    tabStore.push({
      type: "draft",
      draftID: "idle-draft",
      server: ServerConnection.key(connections[0]),
      directory: "/empty/idle/src",
      worktree: "/empty/idle",
      branch: "idle",
    })
    const choices = [...document.querySelectorAll<HTMLInputElement>('[data-slot="checkbox-checkbox-input"]')]
    expect(choices).toHaveLength(2)
    choices.forEach((choice) => choice.click())
    dialogButton("Delete worktree").click()
    await wait()
    expect(removals).toContainEqual({
      directory: "/empty/idle",
      force: true,
      identity: "idle-token",
      branch: "idle",
      remote: { name: "upstream", branch: "idle" },
      deleteLocalBranch: true,
      deleteRemoteBranch: true,
    })
    expect(archived.at(-1)).toEqual(["idle-history"])
    expect(tabStore[0]).toMatchObject({ directory: "/empty", worktree: undefined, branch: undefined })
    tabStore.splice(0)
    expect(group("/empty/idle", emptyProject)).toBeUndefined()
    expect(group("/trees/feat/src")).toBeDefined()
    expect(group("/repo/src")).toBeUndefined()
    expect(group("/repo")).toBeUndefined()
    const projectOrder = () =>
      [...host.querySelectorAll<HTMLElement>("[data-project-key]")].map((element) => element.dataset.projectKey)
    expect(projectElement(emptyProject)).toBeDefined()
    expect(projectOrder().indexOf(emptyProject)).toBeGreaterThan(projectOrder().indexOf(project))
    expect(titles(group("/trees/feat/src"))).toContain("feat-1")
    // In-flight inventory may finish, but a collapsed project in Priority must not
    // start Location or branch work from the old Projects snapshot.
    header(projectElement()).click()
    toggle()
    gates.inventory.resolve()
    await wait()
    expect(
      calls.filter(
        (call) =>
          !call.server &&
          ["/api/location", "/api/vcs"].includes(call.path) &&
          !call.directory.startsWith("/empty"),
      ),
    ).toEqual([])
    toggle()
    await wait()
    expect(
      calls.filter(
        (call) =>
          !call.server &&
          ["/api/location", "/api/vcs"].includes(call.path) &&
          !call.directory.startsWith("/empty"),
      ),
    ).toEqual([])
    header(projectElement()).click()

    // Independently remove all eligible rows while the other server's inventory
    // is pending. The old request must not resurrect demand for those paths.
    const remoteProject = projectKey(ServerConnection.key(connections[1]), { id: "repo", worktree: "/repo" })
    const remoteHeader = header(projectElement(remoteProject))
    const occupiedIndex = projectOrder().indexOf(remoteProject)
    remoteHeader.focus()
    const remoteRows = backend[1].splice(0)
    remoteRows.forEach((row) => {
      const event: OpenCodeEvent = {
        id: `evt_remove_${row.session.id}`,
        created: now,
        type: "session.deleted",
        data: { sessionID: row.session.id },
        durable: { aggregateID: row.session.id, seq: 1, version: 2 },
      }
      roots[1].listeners.forEach((listener) => listener(event))
    })
    await wait()
    gates.remoteInventory.resolve()
    await wait()
    expect(
      calls
        .filter((call) => call.server && ["/api/location", "/api/vcs"].includes(call.path))
        .map((call) => call.directory)
        .sort(),
    ).toEqual(["/empty/idle", "/other/feat", "/trees/feat"])
    expect(projectElement(remoteProject)).toBeDefined()
    expect(header(projectElement(remoteProject)) === remoteHeader).toBe(true)
    expect(document.activeElement === remoteHeader).toBe(true)
    expect(projectOrder().indexOf(remoteProject)).toBeGreaterThan(occupiedIndex)
    expect(titles(projectElement(remoteProject))).toEqual([])
    expect(projectOrder().indexOf(remoteProject)).toBeGreaterThan(projectOrder().indexOf(second))
    const emptyIndex = projectOrder().indexOf(remoteProject)
    remoteHeader.focus()
    backend[1].push(...remoteRows)
    remoteRows.forEach((row) => {
      const event: OpenCodeEvent = {
        id: `evt_available_${row.session.id}`,
        created: now,
        type: "session.renamed",
        data: { sessionID: row.session.id, title: row.session.title },
        durable: { aggregateID: row.session.id, seq: 2, version: 1 },
      }
      roots[1].listeners.forEach((listener) => listener(event))
    })
    await wait()
    expect(document.activeElement === remoteHeader).toBe(true)
    const feature = group("/trees/feat")
    const featureHeader = header(feature)
    const rootHeader = header(projectElement())
    expect(featureHeader.textContent).toContain("feat")
    expect(titles(feature)).toEqual(["feat-0", "feat-1", "feat-2", "feat-3", "feat-4"])
    expect(group("/trees/feat/src")).toBeUndefined()
    expect(group("/repo/src")).toBeUndefined()
    expect(group("/loose/feat")).toBeDefined()
    expect(group("/missing/feat")).toBeDefined()
    expect(group("/trees/feature")).toBeDefined()
    expect(
      calls
        .filter((call) => call.path === "/api/location")
        .map((call) => call.directory)
        .sort(),
    ).toEqual(["/loose/feat/src", "/missing/feat", "/trees/feature"])
    featureHeader.focus()
    gates.branch.resolve()
    await wait()
    expect(header(group("/trees/feat")) === featureHeader).toBe(true)
    expect(document.activeElement === featureHeader).toBe(true)
    expect(featureHeader.textContent).toContain("feat/payments")
    expect(header(group("/other/feat")).textContent).toContain("feat/payments")
    const remote = projectKey(ServerConnection.key(connections[1]), { id: "repo", worktree: "/repo" })
    expect(header(group("/trees/feat", remote)).textContent).toContain("remote/branch")
    expect(header(projectElement(remoteProject)) === remoteHeader).toBe(true)
    expect(projectOrder().indexOf(remoteProject)).toBeLessThan(emptyIndex)
    expect(projectOrder().indexOf(remote)).toBeLessThan(projectOrder().indexOf(emptyProject))
    expect(header(group("/loose/feat")).textContent).toBe("feat (1)")
    expect(
      calls
        .filter((call) => call.path === "/api/vcs" && !call.server)
        .map((call) => call.directory)
        .sort(),
    ).toEqual(["/empty/idle", "/loose/feat", "/other/feat", "/trees/feat"])
    for (const direction of ["ltr", "rtl"]) {
      host.dir = direction
      const create = feature.querySelector<HTMLButtonElement>('[data-action="sidebar-worktree-new-session"]')!
      expect(create.getAttribute("aria-label")).toBe("New session in feat/payments")
      expect(create.closest("button[aria-expanded]")).toBeNull()
      create.focus()
      // HappyDOM has no native keyboard activation: click represents the browser's Enter/Space default action.
      create.click()
      expect(featureHeader.getAttribute("aria-expanded")).toBe("true")
      expect(drafts.at(-1)).toEqual({ server: ServerConnection.key(connections[0]), directory: "/trees/feat" })
      expect(roots[0].opened.at(-1)).toBe("/trees/feat")
    }
    group("/missing/feat").querySelector<HTMLButtonElement>('[data-action="sidebar-worktree-new-session"]')!.click()
    expect(drafts.at(-1)?.directory).toBe("/missing/feat")
    group("/trees/feat", remote)
      .querySelector<HTMLButtonElement>('[data-action="sidebar-worktree-new-session"]')!
      .click()
    expect(drafts.at(-1)).toEqual({ server: ServerConnection.key(connections[1]), directory: "/trees/feat" })
    projectElement().querySelector<HTMLButtonElement>('[data-action="sidebar-project-new-session"]')!.click()
    expect(drafts.at(-1)?.directory).toBe("/repo")
    const before = calls.length
    roots[0].setState("project", 0, "name", "Renamed")
    roots[0].ctx.data.session.remember({ ...backend[0][0].session, title: "Live title" })
    await wait()
    expect(header(projectElement()) === rootHeader).toBe(true)
    expect(header(group("/trees/feat")) === featureHeader).toBe(true)
    expect(calls.length).toBe(before)
    featureHeader.focus()
    const branch: OpenCodeEvent = {
      id: "evt_branch",
      created: now,
      type: "vcs.branch.updated",
      location: { directory: "/trees/feat" },
      data: { branch: "fix/live-branch" },
    }
    roots[0].dataListeners.forEach((listener) => listener({ name: branch.type, details: branch }))
    expect(header(group("/trees/feat")) === featureHeader).toBe(true)
    expect(document.activeElement === featureHeader).toBe(true)
    expect(featureHeader.textContent).toContain("fix/live-branch")
    expect(header(group("/trees/feat", remote)).textContent).toContain("remote/branch")
    rootHeader.focus()
    rootHeader.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", altKey: true, bubbles: true, cancelable: true }),
    )
    await Promise.resolve()
    expect(document.activeElement === rootHeader).toBe(true)
    expect(header(projectElement()) === rootHeader).toBe(true)
    const rendered = () => [
      ...new Set([...host.querySelectorAll<HTMLAnchorElement>("[data-titlebar-tab-link]")].map((link) => link.href)),
    ]
    button("Select sessions").click()
    expect(button("Delete…").style.color).toBe("var(--v2-state-fg-danger)")
    expect(feature.querySelector<HTMLButtonElement>('button[aria-label="Delete"]')?.style.color).toBe(
      "var(--v2-state-fg-danger)",
    )
    button("Select visible").click()
    expect(host.querySelector('[data-slot="sidebar-selection"] [role="status"]')?.textContent).toContain(
      String(rendered().length),
    )
    button("Archive").click()
    expect(archived.at(-1)).toHaveLength(rendered().length)
    const selected = archived.at(-1)!
    expect(selected).toContain(sessionKey(ServerConnection.key(connections[0]), "feat-4"))
    expect(selected).not.toContain(sessionKey(ServerConnection.key(connections[0]), "feat-5"))
    button("Clear")?.click()
    button("Select sessions").click()
    group("/loose/feat")
      .querySelector("a")!
      .dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }))
    feature
      .querySelectorAll("a")[2]
      .dispatchEvent(new KeyboardEvent("keydown", { key: " ", shiftKey: true, bubbles: true, cancelable: true }))
    button("Archive").click()
    expect(archived.at(-1)).toEqual(
      ["loose", "missing", "other-feat", "feat-0", "feat-1", "feat-2"].map((id) =>
        sessionKey(ServerConnection.key(connections[0]), id),
      ),
    )
    button("Select sessions")?.click()
    button("Select visible").click()
    featureHeader.click()
    expect(group("/trees/feat") === feature).toBe(true)
    expect(titles(feature)).toEqual([])
    button("Archive").click()
    expect(archived.at(-1)).not.toContain(sessionKey(ServerConnection.key(connections[0]), "feat-4"))
    expect(featureHeader.getAttribute("aria-expanded")).toBe("false")
    flushPersisted()
    expect(JSON.parse(localStorage.getItem(storage)!).collapsed[worktreeKey(project, "/trees/feat")]).toBe(true)
    dispose()
    dispose = mount()
    await wait()
    expect(header(group("/trees/feat")).getAttribute("aria-expanded")).toBe("false")
    expect(calls.filter((call) => call.path === "/api/worktree")).toHaveLength(7)
    header(group("/trees/feat")).click()
    const more = [...group("/trees/feat").querySelectorAll<HTMLButtonElement>("button")].find(
      (button) => button.textContent === "Show more",
    )!
    more.click()
    expect(titles(group("/trees/feat"))).toHaveLength(7)
    const search = host.querySelector<HTMLInputElement>('input[type="search"]')!
    search.value = "feat-"
    search.dispatchEvent(new Event("input", { bubbles: true }))
    expect(titles(host)).toHaveLength(7)
    search.value = ""
    search.dispatchEvent(new Event("input", { bubbles: true }))
    expect(titles(group("/trees/feat"))).toHaveLength(7)
    const dead = backend[0].findIndex((row) => row.session.id === "other-feat")
    backend[0].splice(dead, 1)
    const event: OpenCodeEvent = {
      id: "evt_deleted",
      created: now,
      type: "session.deleted",
      data: { sessionID: "other-feat" },
      durable: { aggregateID: "other-feat", seq: 1, version: 2 },
    }
    roots[0].listeners.forEach((listener) => listener(event))
    await wait()
    expect(group("/other/feat")).toBeDefined()
    expect(titles(group("/other/feat"))).toEqual([])
    expect(header(projectElement())).toBeDefined()
    expect(calls.some((call) => !call.server && call.directory === "/second")).toBe(false)
    expect(calls.some((call) => call.directory === "/empty")).toBe(true)
  } finally {
    gates.inventory.resolve()
    gates.remoteInventory.resolve()
    gates.branch.resolve()
    dispose()
    host.remove()
    query.clear()
    roots.forEach((root) => root.dispose())
    apiServer.closeAllConnections()
    apiServer.close()
    await removePersisted(Persist.global("sidebar-navigation"))
  }
}, 20_000)
