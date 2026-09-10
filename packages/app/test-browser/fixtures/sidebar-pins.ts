import { expect, mock, test } from "bun:test"
import { createRequire } from "node:module"
import { createComponent, type JSX } from "solid-js"
import { render } from "solid-js/web"
import { createStore } from "solid-js/store"
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query"
import { I18nProvider } from "@kobalte/core/i18n"
import type { SessionInfo, SessionNavigationInfo } from "@opencode/client/promise"
import type { Tab } from "@/shell/tabs/tabs"

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
mock.module("@/runtime/platform/platform", () => ({ usePlatform: () => ({ platform: "web" }) }))
mock.module("@/settings/model", () => ({
  useSettings: () => ({ permissions: { autoApprove: () => false }, appearance: { showProjectName: () => false } }),
}))
mock.module("@/runtime/i18n/language", () => ({
  useLanguage: () => ({ t: (key: string) => key, plural: (key: string) => key, intl: () => "en" }),
}))
mock.module("@/shell/commands/command", () => ({ useCommand: () => ({ register: () => {} }) }))
mock.module("@/shell/layout/session-tab-avatar", () => ({ SessionTabAvatar: () => null }))
mock.module("@/shell/titlebar/tab-popover", () => ({
  TabPreviewPopover: (props: { trigger: JSX.Element }) => props.trigger,
}))
mock.module("@opencode/session-ui/v2/session-progress-indicator-v2", () => ({ SessionProgressIndicatorV2: () => null }))
mock.module("@/composer/persistence", () => ({ createTabComposerState: () => {} }))
mock.module("@/shell/notifications/toast", () => ({ showToast: () => {} }))
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
  { type: "http" as const, http: { url: "http://localhost:5678" } },
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
  type Listener = (event: { type: string; data: { sessionID: string } }) => void
  const listeners = new Set<Listener>()
  const ctx = {
    sync: { data: { project: [{ id: "repo", worktree: "/repo" }], path: {} } },
    projects: { list: () => [] },
    notification: { session: { unseen: () => [] } },
    data: {
      session: { get: (id: string) => cache[id], remember: (session: SessionInfo) => setCache(session.id, session) },
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
          navigation: async (input: { sessionID?: string }) => ({
            data: backend.filter(
              (row) => !row.session.time.archived && (!input.sessionID || row.session.id === input.sessionID),
            ),
          }),
        },
      },
    },
  }
  return { connection, backend, ctx, setState, setCache, listeners }
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
mock.module("@/shell/tabs/tabs", () => ({
  ...tabsModule,
  useTabs: () => ({
    store: [],
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
