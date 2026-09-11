import { expect, mock, test } from "bun:test"
import { createRequire } from "node:module"
import { createComponent, type JSX } from "solid-js"
import { render } from "solid-js/web"
import { createStore } from "solid-js/store"
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query"
import { I18nProvider } from "@kobalte/core/i18n"
import type { FormInfo, PermissionRequest, SessionInfo, SessionNavigationInfo } from "@opencode/client/promise"
import type { Tab } from "@/shell/tabs/tabs"
import type { Platform } from "@/runtime/platform/platform"

// Real Solid DOM components, including both menu variants, the index and persistence.
// Only host services and unrelated avatar/preview/drag presentation are substituted.
const require = createRequire(import.meta.url)
const solid = createRequire(require.resolve("vite-plugin-solid"))
const { transformSync } = solid("@babel/core")
Bun.plugin({
  name: "sidebar-pins-solid",
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
mock.module("@dnd-kit/solid", () => ({
  DragDropProvider: (props: { children: JSX.Element }) => props.children,
  PointerSensor: { configure: () => ({}) },
}))
mock.module("@dnd-kit/solid/sortable", () => ({
  isSortable: () => false,
  useSortable: () => ({ ref: () => {}, handleRef: () => {}, isDragSource: () => false }),
}))
const platform: Pick<Platform, "platform" | "os" | "openPath" | "openAttachmentPickerDialog"> = { platform: "web" }
mock.module("@/runtime/platform/platform", () => ({ usePlatform: () => platform }))
mock.module("@/servers/ssh/authenticate", () => ({ useSshAuthenticate: () => () => false }))
const edited: unknown[] = []
mock.module("@opencode/ui/context/dialog", () => ({ useDialog: () => ({ show: (render: () => unknown) => render() }) }))
mock.module("@/settings/workspaces/project-dialog", () => ({
  DialogEditProject: (props: unknown) => {
    edited.push(props)
    return null
  },
}))
mock.module("@/settings/model", () => ({
  useSettings: () => ({ permissions: { autoApprove: () => false }, appearance: { showProjectName: () => false } }),
}))
mock.module("@/runtime/i18n/language", () => ({
  useLanguage: () => ({
    t: (key: string, params?: Record<string, string>) =>
      key === "sidebar.project.server" ? `${params?.project} (${params?.server})` : key,
    plural: (key: string) => key,
    intl: () => "en",
  }),
}))
mock.module("@/shell/commands/command", () => ({ useCommand: () => ({ register: () => {} }) }))
mock.module("@/shell/layout/session-tab-avatar", () => ({ SessionTabAvatar: () => null }))
mock.module("@/shell/titlebar/tab-popover", () => ({
  TabPreviewPopover: (props: { trigger: JSX.Element }) => props.trigger,
}))
mock.module("@opencode/session-ui/v2/session-progress-indicator-v2", () => ({ SessionProgressIndicatorV2: () => null }))
mock.module("@/composer/persistence", () => ({ createTabComposerState: () => {} }))
const toasts: { title: string; description?: string }[] = []
mock.module("@/shell/notifications/toast", () => ({
  showToast: (toast: { title: string; description?: string }) => toasts.push(toast),
}))
const lifecycle: string[] = []
mock.module("@/session/lifecycle-actions", () => ({
  useSessionLifecycleActions: () => ({
    pending: () => false,
    archive: () => lifecycle.push("archive"),
    showDelete: () => lifecycle.push("delete"),
  }),
}))

const registry = await import("@/runtime/server/registry")
const { ServerConnection } = registry
const { sessionKey, projectKey } = await import("@/shell/titlebar/sidebar-model")
const connections = [
  { type: "http" as const, http: { url: "http://localhost:1234" } },
  { type: "http" as const, http: { url: "https://remote.example.test" } },
]
const now = Date.now()
function row(id: string, messageAt: number, permissionAt?: number): SessionNavigationInfo {
  return {
    messageAt,
    permissionAt,
    session: {
      id,
      projectID: "repo",
      title: id,
      location: { directory: "/repo" },
      time: { created: 1, updated: 1 },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}
const hosts = connections.map((connection, i) => {
  const backend = i
    ? [row("same", now)]
    : [
        row("same", now),
        row("priority", now - 1, 1),
        row("old", 1),
        ...Array.from({ length: 7 }, (_, i) => row(`recent-${i}`, now - i - 2)),
      ]
  const [cache, setCache] = createStore<Record<string, SessionInfo | undefined>>({})
  const [state, setState] = createStore({ connected: true })
  const [attention, setAttention] = createStore({
    notifications: {} as Record<string, { time: number; viewed: boolean }[]>,
    permissions: {} as Record<string, PermissionRequest[] | undefined>,
    forms: {} as Record<string, FormInfo[] | undefined>,
  })
  type Listener = (event: { type: string; data: { sessionID: string } }) => void
  const listeners = new Set<Listener>()
  const opened: string[] = []
  const touched: string[] = []
  const imported: unknown[] = []
  const ctx = {
    sync: { data: { project: [{ id: "repo", worktree: "/repo", name: "Shared project" }], path: {} } },
    projects: {
      list: () => [],
      open: (directory: string) => opened.push(directory),
      touch: (directory: string) => touched.push(directory),
    },
    notification: { session: { unseen: (id: string) => attention.notifications[id] ?? [] } },
    data: {
      session: {
        get: (id: string) => cache[id],
        remember: (session: SessionInfo) => setCache(session.id, session),
        permission: { list: (id: string) => attention.permissions[id] },
        form: { list: (id: string) => attention.forms[id] },
        message: { sync: async () => {} },
      },
    },
    sdk: {
      connection: { status: () => (state.connected ? "connected" : "disconnected") },
      event: {
        listen: (listener: Listener) => {
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
      },
      api: {
        session: {
          import: async (input: unknown) => {
            imported.push(input)
            return row("ses_imported", now).session
          },
          navigation: async (input: { sessionID?: string }) => ({
            data: backend.filter(
              (row) => !row.session.time.archived && (!input.sessionID || row.session.id === input.sessionID),
            ),
          }),
        },
      },
    },
  }
  return { connection, backend, ctx, setState, setCache, setAttention, listeners, opened, touched, imported }
})
mock.module("@/runtime/server/registry", () => ({ ...registry, useServers: () => ({ list: connections }) }))
mock.module("@/runtime/server/runtime", () => ({
  useGlobal: () => ({
    servers: { list: () => connections },
    ensureServerCtx: (connection: ServerConnection.Any) => hosts.find((host) => host.connection === connection)!.ctx,
  }),
  useServerCtx: (connection: () => ServerConnection.Any) => () =>
    hosts.find((host) => host.connection === connection())?.ctx,
}))
const [route, setRoute] = createStore<{ sessionId?: string }>({})
mock.module("@/shell/state/layout", () => ({
  useLayout: () => ({
    route: () =>
      route.sessionId
        ? { type: "session", server: ServerConnection.key(connections[0]), sessionId: route.sessionId }
        : { type: "home" },
  }),
  useCurrentRoute: () => () => ({ type: "home" }),
}))
const tabsModule = await import("@/shell/tabs/tabs")
const selected: Tab[] = []
const drafts: { server: ServerConnection.Key; directory?: string }[] = []
mock.module("@/shell/tabs/tabs", () => ({
  ...tabsModule,
  useTabs: () => ({
    store: [],
    newDraft: async (input: { server: ServerConnection.Key; directory?: string }) => {
      drafts.push(input)
    },
    select: (tab: Tab) => selected.push(tab),
    addSessionTab: (input: { server: ServerConnection.Key; sessionId: string }) => ({ type: "session", ...input }),
  }),
}))
const { SessionSidebar } = await import("@/shell/titlebar/sidebar")
const { TabNavItem } = await import("@/shell/titlebar/tab-nav")
const { flushPersisted } = await import("@/runtime/persistence/persist")
const storage = "opencode.global.dat:sidebar-navigation"
const key = (id: string, server = 0) => sessionKey(ServerConnection.key(connections[server]), id)
const wait = () => new Promise((resolve) => setTimeout(resolve, 150))
const titles = (root: ParentNode) =>
  [...root.querySelectorAll("[data-titlebar-tab-title]")].map((item) => item.textContent)
function section(host: HTMLElement, title: string) {
  return [...host.querySelectorAll("section")].find(
    (section) => section.querySelector("h2")?.textContent === `sidebar.sessions.${title}`,
  )
}
function findRow(host: ParentNode, id: string, server = 0) {
  const href = tabsModule.tabHref({ type: "session", server: ServerConnection.key(connections[server]), sessionId: id })
  return [...host.querySelectorAll<HTMLElement>("[data-titlebar-tab]")].find(
    (row) => row.querySelector("a")?.getAttribute("href") === href,
  )!
}
async function pin(host: HTMLElement, id: string, action: "pin" | "unpin", server = 0, context = false) {
  const row = findRow(host, id, server)
  if (context)
    row.querySelector("a")!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, button: 2 }))
  if (!context)
    row
      .querySelector<HTMLButtonElement>('[aria-label="common.moreOptions"]')!
      .dispatchEvent(
        new PointerEvent("pointerdown", { bubbles: true, cancelable: true, button: 0, pointerType: "mouse" }),
      )
  await wait()
  const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
    (item) => item.textContent === `sidebar.session.${action}`,
  )!
  expect(item).toBeDefined()
  item.dispatchEvent(
    context
      ? new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
      : new PointerEvent("pointerup", { button: 0, pointerType: "mouse", bubbles: true, cancelable: true }),
  )
  await wait()
}
function mount(direction: "ltr" | "rtl" = "ltr") {
  const host = document.createElement("div")
  host.dir = direction
  document.body.append(host)
  const dispose = render(
    () =>
      createComponent(I18nProvider, {
        locale: "en",
        direction,
        get children() {
          return createComponent(QueryClientProvider, {
            client: new QueryClient(),
            get children() {
              return createComponent(SessionSidebar, { header: null, children: null })
            },
          })
        },
      }),
    host,
  )
  return {
    host,
    dispose: () => {
      dispose()
      host.remove()
    },
  }
}

test("legacy prefs, real menus, search, priorities, reload, disconnect, archive and delete", async () => {
  const project = projectKey(ServerConnection.key(connections[0]), { id: "repo", worktree: "/repo" })
  localStorage.setItem(storage, JSON.stringify({ attention: false, order: [project], collapsed: { [project]: true } }))
  const first = mount()
  try {
    await wait()
    expect(JSON.parse(localStorage.getItem(storage)!)).toMatchObject({
      attention: false,
      collapsed: { [project]: true },
      pins: [],
    })
    expect(section(first.host, "pinned")).toBeUndefined()
    setRoute("sessionId", "old")
    await wait()
    expect(titles(section(first.host, "recent")!)).toContain("old")
    const input = first.host.querySelector<HTMLInputElement>('input[type="search"]')!
    input.value = "same"
    input.dispatchEvent(new Event("input", { bubbles: true }))
    await pin(first.host, "same", "pin", 1)
    await pin(first.host, "same", "pin", 0, true)
    expect(input.value).toBe("same")
    expect(titles(first.host)).toEqual(["same", "same"])
    expect(first.host.querySelectorAll('[data-slot="tab-pin"]')).toHaveLength(2)
    expect(first.host.querySelector('[data-slot="tab-pin"] use')?.getAttribute("href")).toContain("pin")
    expect(first.host.querySelector('[data-slot="tab-pin"] use')?.getAttribute("href")).not.toContain("plus")
    first.host.querySelector<HTMLButtonElement>('[aria-label="sidebar.search.clear"]')!.click()
    await pin(first.host, "old", "pin")
    await pin(first.host, "priority", "pin")
    expect(titles(section(first.host, "pinned")!)).toEqual(["same", "same", "old", "priority"])
    expect(titles(section(first.host, "recent")!)).toHaveLength(5)
    expect(titles(section(first.host, "recent")!)).not.toContain("same")
    expect(titles(first.host.querySelector(`[data-project-key='${project}']`)!)).toEqual(["old"])
    first.host.querySelector<HTMLButtonElement>('[aria-label="sidebar.attention.toggle"]')!.click()
    expect(titles(section(first.host, "priority")!)).toEqual(["priority"])
    expect(titles(section(first.host, "pinned")!)).toEqual(["same", "same", "old"])
    expect(titles(first.host).filter((title) => title === "priority")).toHaveLength(1)
    expect(titles(first.host).filter((title) => title === "old")).toHaveLength(1)
    expect(selected).toEqual([])
    expect(lifecycle).toEqual([])
    flushPersisted()
    expect(JSON.parse(localStorage.getItem(storage)!).pins).toEqual([
      key("same", 1),
      key("same"),
      key("old"),
      key("priority"),
    ])
  } finally {
    first.dispose()
  }

  const second = mount("rtl")
  try {
    await wait()
    expect(titles(section(second.host, "pinned")!)).toEqual(["same", "same", "old"])
    await pin(second.host, "same", "unpin", 1, true)
    await pin(second.host, "same", "pin", 1)
    expect(titles(section(second.host, "pinned")!)).toEqual(["same", "old", "same"])
    hosts[1].setState("connected", false)
    const remote = hosts[1].backend.splice(0)
    flushPersisted()
    expect(JSON.parse(localStorage.getItem(storage)!).pins).toContain(key("same", 1))
    hosts[1].setState("connected", true)
    await wait()
    expect(titles(section(second.host, "pinned")!)).toEqual(["same", "old"])
    flushPersisted()
    expect(JSON.parse(localStorage.getItem(storage)!).pins).toContain(key("same", 1))
    hosts[1].setState("connected", false)
    hosts[1].backend.push(...remote)
    hosts[1].setState("connected", true)
    await wait()
    expect(titles(section(second.host, "pinned")!)).toEqual(["same", "old", "same"])
    const archived = hosts[0].backend.find((row) => row.session.id === "old")!
    archived.session = { ...archived.session, time: { ...archived.session.time, archived: now } }
    hosts[0].setCache("old", archived.session)
    hosts[0].listeners.forEach((listener) => listener({ type: "session.archived", data: { sessionID: "old" } }))
    hosts[1].backend.splice(0)
    hosts[1].setCache("same", undefined)
    hosts[1].listeners.forEach((listener) => listener({ type: "session.deleted", data: { sessionID: "same" } }))
    await wait()
    expect(titles(section(second.host, "pinned")!)).toEqual(["same"])
    expect(titles(second.host)).not.toContain("old")
    expect(findRow(second.host, "same", 1)).toBeUndefined()
    expect(selected).toEqual([])
    expect(lifecycle).toEqual([])
    findRow(second.host, "same").querySelector<HTMLAnchorElement>("a")!.click()
    expect(selected).toHaveLength(1)
    expect(selected[0]).toMatchObject({ sessionId: "same", server: ServerConnection.key(connections[0]) })
  } finally {
    second.dispose()
  }

  const third = mount()
  try {
    await wait()
    expect(titles(section(third.host, "pinned")!)).toEqual(["same"])
    expect(titles(third.host)).not.toContain("old")
    expect(findRow(third.host, "same", 1)).toBeUndefined()
    await pin(third.host, "same", "unpin")
    expect(section(third.host, "pinned")).toBeUndefined()
    expect(titles(section(third.host, "priority")!)).toEqual(["priority"])
  } finally {
    third.dispose()
  }
})

test("horizontal and Home row consumers have no pin action without opting in", async () => {
  const host = document.createElement("div")
  document.body.append(host)
  const dispose = render(
    () =>
      createComponent(QueryClientProvider, {
        client: new QueryClient(),
        get children() {
          return createComponent(TabNavItem, {
            href: "/test",
            server: ServerConnection.key(connections[0]),
            session: row("ordinary", now).session,
            preparing: false,
            onClose: () => {},
            onNavigate: () => {},
            onRename: async () => {},
          })
        },
      }),
    host,
  )
  try {
    host
      .querySelector<HTMLButtonElement>('[aria-label="common.moreOptions"]')!
      .dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, pointerType: "mouse" }))
    await wait()
    expect(document.querySelectorAll('[role="menuitem"]').length).toBeGreaterThan(0)
    expect(
      [...document.querySelectorAll('[role="menuitem"]')].some((item) =>
        item.textContent?.includes("sidebar.session."),
      ),
    ).toBe(false)
    expect(host.querySelector('[data-slot="tab-pin"]')).toBeNull()
  } finally {
    dispose()
    host.remove()
  }
})

async function projectMenu(group: HTMLElement, action?: string, keyboard = false) {
  const trigger = group.querySelector<HTMLButtonElement>('[data-action="sidebar-project-menu"]')!
  trigger.focus()
  trigger.dispatchEvent(
    keyboard
      ? new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true })
      : new PointerEvent("pointerdown", { button: 0, pointerType: "mouse", bubbles: true, cancelable: true }),
  )
  await wait()
  expect(trigger.getAttribute("aria-expanded")).toBe("true")
  const menu = document.getElementById(trigger.getAttribute("aria-controls")!)!
  const items = [...menu.querySelectorAll<HTMLElement>('[role="menuitem"]')]
  const labels = items.map((item) => item.textContent)
  if (action) {
    const item = items.find((item) => item.textContent === action)
    expect(item).toBeDefined()
    item!.focus()
    item!.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
  }
  if (!action) {
    trigger.dispatchEvent(
      new PointerEvent("pointerdown", { button: 0, pointerType: "mouse", bubbles: true, cancelable: true }),
    )
  }
  await wait()
  expect(trigger.getAttribute("aria-expanded")).toBe("false")
  return labels
}

test("project header actions preserve collapse/order and target canonical projects across servers", async () => {
  hosts[1].backend.push(row("remote-project-session", now))
  platform.platform = "desktop"
  platform.os = "macos"
  const revealed: string[] = []
  platform.openPath = async (directory) => {
    revealed.push(directory)
  }
  platform.openAttachmentPickerDialog = async (_options, onFile) => {
    await onFile(new File([JSON.stringify({ info: row("ses_exported", now).session, messages: [] })], "session.json"))
  }
  hosts[0].backend.push({
    ...row("worktree", now),
    session: { ...row("worktree", now).session, location: { directory: "/repo-worktree" } },
  })
  hosts[0].ctx.sync.data.project.push({ id: "global", worktree: "/plain", name: "Plain" })
  // Global metadata isn't indexed, but a non-Git session supplies its own directory.
  hosts[0].backend.push({
    ...row("non-git", now),
    session: { ...row("non-git", now).session, projectID: "global", location: { directory: "/plain" } },
  })
  hosts[0].backend.push({
    ...row("unknown", now),
    session: { ...row("unknown", now).session, projectID: "unknown", location: { directory: "/unknown" } },
  })
  const key = projectKey(ServerConnection.key(connections[0]), { id: "repo", worktree: "/repo" })
  localStorage.setItem(
    storage,
    JSON.stringify({ attention: false, order: [key], collapsed: { [key]: true }, pins: [] }),
  )
  setRoute("sessionId", "old")
  const ui = mount("rtl")
  try {
    await wait()
    const groups = [...ui.host.querySelectorAll<HTMLElement>("[data-project-key]")]
    const local = groups.find((group) => group.dataset.projectKey === key)!
    const remote = groups.find(
      (group) =>
        group.dataset.projectKey ===
        projectKey(ServerConnection.key(connections[1]), { id: "repo", worktree: "/repo" }),
    )!
    const plain = groups.find(
      (group) =>
        group.dataset.projectKey ===
        projectKey(ServerConnection.key(connections[0]), { id: "global", worktree: "/plain" }),
    )!
    const unknown = groups.find(
      (group) =>
        group.dataset.projectKey ===
        projectKey(ServerConnection.key(connections[0]), { id: "unknown", worktree: "/unknown" }),
    )!
    expect(groups).toHaveLength(4)
    const header = local.querySelector<HTMLButtonElement>("button[aria-expanded]")!
    const order = groups.map((group) => group.dataset.projectKey)
    expect(header.getAttribute("aria-expanded")).toBe("false")
    const shortcut = local.querySelector<HTMLButtonElement>('[data-action="sidebar-project-new-session"]')!
    expect(header.contains(shortcut)).toBe(false)
    expect(shortcut.querySelector("use")?.getAttribute("href")).toContain("edit")
    shortcut.focus()
    expect(document.activeElement).toBe(shortcut)
    shortcut.click()
    await projectMenu(remote, "command.session.new", true)
    await projectMenu(plain, "command.session.new")
    expect(drafts.slice(-3)).toEqual([
      { server: ServerConnection.key(connections[0]), directory: "/repo" },
      { server: ServerConnection.key(connections[1]), directory: "/repo" },
      { server: ServerConnection.key(connections[0]), directory: "/plain" },
    ])
    expect(header.getAttribute("aria-expanded")).toBe("false")
    expect(
      [...ui.host.querySelectorAll<HTMLElement>("[data-project-key]")].map((group) => group.dataset.projectKey),
    ).toEqual(order)
    expect(await projectMenu(local)).toEqual([
      "command.session.new",
      "command.session.import",
      "dialog.project.edit.title",
      "session.header.reveal.finder",
    ])
    expect(await projectMenu(remote)).not.toContain("session.header.reveal.finder")
    expect(await projectMenu(plain)).not.toContain("dialog.project.edit.title")
    expect(await projectMenu(unknown)).not.toContain("dialog.project.edit.title")
    await projectMenu(remote, "dialog.project.edit.title")
    expect(edited.at(-1)).toMatchObject({
      server: connections[1],
      project: { id: "repo", worktree: "/repo", name: "Shared project" },
    })
    await projectMenu(local, "session.header.reveal.finder")
    expect(revealed).toEqual(["/repo"])
    await projectMenu(remote, "command.session.import")
    expect(hosts[1].imported).toHaveLength(1)
    expect(hosts[0].imported).toHaveLength(0)
    expect(hosts[1].imported[0]).toMatchObject({ location: { directory: "/repo" } })
    expect(selected.at(-1)).toMatchObject({ server: ServerConnection.key(connections[1]), sessionId: "ses_imported" })
    expect(hosts[1].opened).toEqual(["/repo", "/repo"])
    expect(hosts[1].touched).toEqual(["/repo", "/repo"])
    platform.openPath = async () => {
      throw new Error("reveal failed")
    }
    await projectMenu(local, "session.header.reveal.finder")
    expect(toasts.at(-1)).toMatchObject({ title: "common.requestFailed", description: "reveal failed" })
    platform.openAttachmentPickerDialog = async () => {
      throw new Error("picker failed")
    }
    await projectMenu(local, "command.session.import")
    expect(toasts.at(-1)).toMatchObject({ title: "common.requestFailed", description: "picker failed" })
    const count = toasts.length
    platform.openAttachmentPickerDialog = async (_options, onFile) => {
      await onFile(new File(["{}"], "invalid.json"))
    }
    await projectMenu(local, "command.session.import")
    expect(toasts).toHaveLength(count + 1)
    expect(hosts[0].imported).toHaveLength(0)
    platform.openAttachmentPickerDialog = async (_options, onFile) => {
      await onFile(new File([JSON.stringify({ info: row("ses_exported", now).session, messages: [] })], "session.json"))
    }
    hosts[0].ctx.sdk.api.session.import = async () => {
      throw new Error("import failed")
    }
    await projectMenu(local, "command.session.import")
    expect(toasts.at(-1)).toMatchObject({ title: "common.requestFailed", description: "import failed" })
  } finally {
    ui.dispose()
    platform.platform = "web"
    platform.openPath = async () => {}
    delete platform.openAttachmentPickerDialog
  }
  const web = mount()
  try {
    await wait()
    const local = [...web.host.querySelectorAll<HTMLElement>("[data-project-key]")].find(
      (group) => group.dataset.projectKey === key,
    )!
    expect(await projectMenu(local)).toEqual(["command.session.new", "dialog.project.edit.title"])
  } finally {
    web.dispose()
  }
}, 15_000)

test("project menu and focus survive session refreshes while project data stays current", async () => {
  const previous = hosts[0].ctx.sync.data
  const [sync, setSync] = createStore(structuredClone(previous))
  hosts[0].ctx.sync.data = sync
  const background = row("ses_background", now)
  background.session = { ...background.session, projectID: "global", location: { directory: "/background" } }
  hosts[0].backend.push(background)
  const key = projectKey(ServerConnection.key(connections[0]), { id: "repo", worktree: "/repo" })
  localStorage.setItem(storage, JSON.stringify({ attention: false, order: [key], collapsed: {}, pins: [] }))
  const ui = mount()
  try {
    await wait()
    const group = [...ui.host.querySelectorAll<HTMLElement>("[data-project-key]")].find(
      (group) => group.dataset.projectKey === key,
    )!
    const trigger = group.querySelector<HTMLButtonElement>('[data-action="sidebar-project-menu"]')!
    trigger.focus()
    trigger.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
    await wait()
    const menu = document.getElementById(trigger.getAttribute("aria-controls")!)!
    const item = menu.querySelector<HTMLElement>('[role="menuitem"]')!
    item.focus()
    expect(document.activeElement).toBe(item)

    hosts[0].backend[hosts[0].backend.indexOf(background)] = {
      ...background,
      session: { ...background.session, time: { ...background.session.time, updated: now + 1 } },
    }
    hosts[0].listeners.forEach((listener) =>
      listener({ type: "session.step.ended", data: { sessionID: background.session.id } }),
    )
    await wait()
    expect(hosts[0].ctx.data.session.get(background.session.id)?.time.updated).toBe(now + 1)
    expect(trigger.isConnected).toBe(true)
    expect(trigger.getAttribute("aria-expanded")).toBe("true")
    expect(document.getElementById(menu.id)).toBe(menu)
    expect(document.activeElement).toBe(item)

    setSync("project", (project) => project.id === "repo", { name: "Renamed project", worktree: "/renamed" })
    await wait()
    expect(trigger.isConnected).toBe(true)
    expect(trigger.getAttribute("aria-expanded")).toBe("true")
    expect(document.activeElement).toBe(item)
    expect(group.querySelector("button[aria-expanded] span[dir=auto]")?.textContent).toContain("Renamed project")
    item.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
    await wait()
    expect(drafts.at(-1)).toEqual({ server: ServerConnection.key(connections[0]), directory: "/renamed" })
    await projectMenu(group, "dialog.project.edit.title", true)
    expect(edited.at(-1)).toMatchObject({
      server: connections[0],
      project: { id: "repo", name: "Renamed project", worktree: "/renamed" },
    })

    const header = group.querySelector<HTMLButtonElement>("button[aria-expanded]")!
    header.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", altKey: true, bubbles: true, cancelable: true }),
    )
    expect([...ui.host.querySelectorAll<HTMLElement>("[data-project-key]")][1]).toBe(group)
    expect(group.querySelector('[data-action="sidebar-project-menu"]')).toBe(trigger)
  } finally {
    ui.dispose()
    hosts[0].ctx.sync.data = previous
    hosts[0].backend.splice(
      hosts[0].backend.findIndex((row) => row.session.id === background.session.id),
      1,
    )
  }
})

test("Priority excludes partial-cache/current children and follows live unread and resolved index requests", async () => {
  const host = hosts[0]
  const root = row("slice1-root", now)
  const child = row("slice1-child", now)
  child.session.parentID = root.session.id
  child.unreadAt = 900
  const orphan = row("slice1-orphan", now, 1000)
  orphan.session.parentID = "missing-parent"
  orphan.session.projectID = "only-child"
  const cachedRequest = row("slice1-cached", now, 70)
  const indexedRequest = row("slice1-indexed", now, 80)
  host.backend.push(root, child, orphan, cachedRequest, indexedRequest)
  host.ctx.sync.data.project.push(
    { id: "empty", worktree: "/empty", name: "Empty" },
    { id: "only-child", worktree: "/child", name: "Only child" },
  )
  host.setAttention("notifications", root.session.id, [{ time: 50, viewed: false }])
  host.setAttention("permissions", cachedRequest.session.id, [
    { id: "per_cached", sessionID: cachedRequest.session.id, action: "shell", resources: [], created: 70 },
  ])
  localStorage.setItem(storage, JSON.stringify({ attention: true, order: [], collapsed: {}, pins: [] }))
  setRoute("sessionId", orphan.session.id)
  const ui = mount()
  const priority = () => titles(section(ui.host, "priority")!).filter((title) => title?.startsWith("slice1-"))
  try {
    await wait()
    expect(priority()).toEqual(["slice1-indexed", "slice1-cached", "slice1-root"])
    host.setCache(child.session.id, undefined)
    host.setCache(child.session.id, { ...child.session, parentID: undefined })
    expect(priority()).not.toContain("slice1-child")
    expect(titles(ui.host)).not.toContain("slice1-orphan")
    host.setAttention("notifications", root.session.id, [
      { time: 50, viewed: false },
      { time: 100, viewed: false },
    ])
    expect(priority()).toEqual(["slice1-root", "slice1-indexed", "slice1-cached"])
    host.setCache(root.session.id, { ...root.session, time: { ...root.session.time, viewed: 100 } })
    expect(priority()).toEqual(["slice1-indexed", "slice1-cached"])
    host.setAttention("permissions", cachedRequest.session.id, [])
    // The complete snapshot, revalidated by the SSE event, confirms resolution.
    host.backend[host.backend.indexOf(cachedRequest)] = { session: cachedRequest.session, messageAt: now }
    host.listeners.forEach((listener) =>
      listener({ type: "permission.replied", data: { sessionID: cachedRequest.session.id } }),
    )
    await wait()
    expect(priority()).toEqual(["slice1-indexed"])
    host.backend[host.backend.indexOf(indexedRequest)] = { session: indexedRequest.session, messageAt: now }
    host.listeners.forEach((listener) =>
      listener({ type: "permission.replied", data: { sessionID: indexedRequest.session.id } }),
    )
    await wait()
    expect(priority()).toEqual([])
    ui.host.querySelector<HTMLButtonElement>('[aria-label="sidebar.attention.toggle"]')!.click()
    const projects = () =>
      [...ui.host.querySelectorAll<HTMLElement>("[data-project-key]")].map((group) => group.dataset.projectKey)
    expect(projects()).not.toContain(
      projectKey(ServerConnection.key(connections[0]), { id: "empty", worktree: "/empty" }),
    )
    expect(projects()).not.toContain(
      projectKey(ServerConnection.key(connections[0]), { id: "only-child", worktree: "/child" }),
    )
    const before = projects()
    ui.host.querySelector<HTMLButtonElement>("[data-project-key] button[aria-expanded]")!.click()
    expect(projects()).toEqual(before)
  } finally {
    ui.dispose()
  }
})
