import { expect, mock, test } from "bun:test"
import { createRequire } from "node:module"
import { createComponent } from "solid-js"
import { render } from "solid-js/web"
import { createStore } from "solid-js/store"
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query"
import type { SessionInfo, SessionNavigationInfo } from "@opencode/client/promise"
import type { SessionLifecycleResult } from "@/session/lifecycle-actions"
import type { Tab } from "@/shell/tabs/tabs"

// Compile production JSX; use the real sidebar, rows, menus, dialogs, i18n and lifecycle.
const require = createRequire(import.meta.url)
const solid = createRequire(require.resolve("vite-plugin-solid"))
const { transformSync } = solid("@babel/core")
Bun.plugin({
  name: "sidebar-selection-solid",
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
const toasts: { title: string; description?: string }[] = []
mock.module("@/shell/notifications/toast", () => ({
  showToast: (toast: { title: string; description?: string }) => toasts.push(toast),
}))
const registry = await import("@/runtime/server/registry")
const { ServerConnection } = registry
const connections = [
  { type: "http" as const, http: { url: "http://localhost:1234" } },
  { type: "http" as const, http: { url: "https://remote.example.test" } },
]
const [registryState, setRegistry] = createStore({ connections })
const now = Date.now()
function row(id: string, position = 0, parentID?: string): SessionNavigationInfo {
  return {
    messageAt: now - position,
    session: {
      id,
      parentID,
      projectID: "repo",
      title: id,
      location: { directory: "/repo" },
      time: { created: 1, updated: 1 },
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    },
  }
}
const requests: { server: number; action: string; id: string }[] = []
const invalidated: string[] = []
const hosts = connections.map((connection, server) => {
  const [cache, setCache] = createStore<Record<string, SessionInfo | undefined>>({})
  const [state, setState] = createStore({ connected: true })
  const backend = server ? [row("same")] : [row("same"), ...Array.from({ length: 8 }, (_, i) => row(`row-${i}`, i + 1))]
  const failures = new Set<string>()
  const waiters = new Map<string, Promise<void>>()
  const navigation = { wait: undefined as Promise<void> | undefined }
  type Listener = (event: { type: string; data: { sessionID: string } }) => void
  const listeners = new Set<Listener>()
  const emit = (type: string, sessionID: string) =>
    listeners.forEach((listener) => listener({ type, data: { sessionID } }))
  const mutate = async (action: string, id: string) => {
    requests.push({ server, action, id })
    await waiters.get(id)
    if (failures.has(id)) throw new Error(`Rejected ${id}`)
    const index = backend.findIndex((row) => row.session.id === id)
    if (index >= 0) backend.splice(index, 1)
    if (action === "remove") setCache(id, undefined)
    emit(action === "remove" ? "session.deleted" : "session.archived", id)
  }
  const ctx = {
    sync: { data: { project: [{ id: "repo", worktree: "/repo", name: "Repo" }], path: {} } },
    projects: { list: () => [] },
    notification: { session: { unseen: () => [] } },
    data: {
      session: {
        list: () => Object.values(cache).filter((session): session is SessionInfo => !!session),
        get: (id: string) => cache[id],
        remember: (session: SessionInfo) => setCache(session.id, session),
        invalidate: (id: string) => invalidated.push(`${server}:${id}`),
        remove: (id: string) => mutate("remove", id),
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
          archive: ({ sessionID }: { sessionID: string }) => mutate("archive", sessionID),
          navigation: async (input: { sessionID?: string }) => {
            await navigation.wait
            return { data: backend.filter((row) => !input.sessionID || row.session.id === input.sessionID) }
          },
        },
      },
    },
  }
  return { connection, ctx, backend, setCache, setState, failures, waiters, navigation, emit }
})
mock.module("@/runtime/server/registry", () => ({
  ...registry,
  useServers: () => ({
    get list() {
      return registryState.connections
    },
  }),
}))
mock.module("@/runtime/server/runtime", () => ({
  useGlobal: () => ({
    servers: { list: () => registryState.connections },
    ensureServerCtx: (connection: ServerConnection.Any) =>
      hosts.find((host) => ServerConnection.key(host.connection) === ServerConnection.key(connection))!.ctx,
  }),
  useServerCtx: (connection: () => ServerConnection.Any | undefined) => () => {
    const conn = connection()
    return conn
      ? hosts.find((host) => ServerConnection.key(host.connection) === ServerConnection.key(conn))?.ctx
      : undefined
  },
}))
mock.module("@/shell/state/layout", () => ({
  useLayout: () => ({ route: () => ({ type: "home" }) }),
  useCurrentRoute: () => () => ({ type: "home" }),
}))
const tabsModule = await import("@/shell/tabs/tabs")
const selected: Tab[] = []
const closed: number[] = []
mock.module("@/shell/tabs/tabs", () => ({
  ...tabsModule,
  useTabs: () => ({
    store: [{ type: "session", server: ServerConnection.key(connections[0]), sessionId: "same" }],
    pendingSession: () => false,
    select: (tab: Tab) => selected.push(tab),
    closeTab: (index: number) => closed.push(index),
    addSessionTab: (input: { server: ServerConnection.Key; sessionId: string }) => ({ type: "session", ...input }),
  }),
}))
const { SessionSidebar } = await import("@/shell/titlebar/sidebar")
const { useSessionLifecycleActions } = await import("@/session/lifecycle-actions")
const { LanguageProvider } = await import("@/runtime/i18n/language")
const { DialogProvider } = await import("@opencode/ui/context/dialog")
const { sessionKey } = await import("@/shell/titlebar/sidebar-model")
const { SESSION_TABS_REMOVED_EVENT, readSessionTabsRemovedDetail } = await import("@/shell/titlebar/session-events")
const { flushPersisted } = await import("@/runtime/persistence/persist")
const storage = "opencode.global.dat:sidebar-navigation"
const wait = () => new Promise((resolve) => setTimeout(resolve, 160))
function mount(sidebar = true, direction = "ltr") {
  localStorage.setItem(
    storage,
    JSON.stringify({
      attention: false,
      order: [],
      collapsed: {},
      pins: [sessionKey(ServerConnection.key(connections[0]), "same")],
    }),
  )
  const host = document.createElement("div")
  host.dir = direction
  document.body.append(host)
  const query = new QueryClient()
  let lifecycle!: ReturnType<typeof useSessionLifecycleActions>
  const dispose = render(
    () =>
      createComponent(LanguageProvider, {
        get children() {
          return createComponent(QueryClientProvider, {
            client: query,
            get children() {
              return createComponent(DialogProvider, {
                get children() {
                  lifecycle = useSessionLifecycleActions()
                  return sidebar ? createComponent(SessionSidebar, { header: null, children: null }) : null
                },
              })
            },
          })
        },
      }),
    host,
  )
  return {
    host,
    query,
    lifecycle,
    dispose: () => {
      dispose()
      host.remove()
    },
  }
}
const button = (root: ParentNode, text: string) =>
  [...root.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text)!
const rows = (root: ParentNode) => [...root.querySelectorAll<HTMLElement>("[data-titlebar-tab]")]
const findRows = (root: ParentNode, id: string, server = 0) =>
  rows(root).filter(
    (item) =>
      item.querySelector("a")?.getAttribute("href") ===
      tabsModule.tabHref({ type: "session", server: ServerConnection.key(connections[server]), sessionId: id }),
  )
const link = (root: ParentNode, id: string, server = 0) =>
  findRows(root, id, server)[0].querySelector<HTMLAnchorElement>("a")!
function press(link: HTMLElement, init: MouseEventInit = {}) {
  const pointer = new PointerEvent("pointerdown", {
    button: 0,
    pointerType: "mouse",
    bubbles: true,
    cancelable: true,
    ...init,
  })
  link.dispatchEvent(pointer)
  if (!pointer.defaultPrevented)
    link.dispatchEvent(new MouseEvent("mousedown", { button: 0, bubbles: true, cancelable: true, ...init }))
  link.dispatchEvent(new PointerEvent("pointerup", { button: 0, pointerType: "mouse", bubbles: true, ...init }))
  link.dispatchEvent(new MouseEvent("click", { detail: 1, bubbles: true, cancelable: true, ...init }))
}
const count = (root: ParentNode) => root.querySelector('[data-slot="sidebar-selection"] [role="status"]')?.textContent
function search(root: ParentNode, value: string) {
  const input = root.querySelector<HTMLInputElement>('input[type="search"]')!
  input.value = value
  input.dispatchEvent(new Event("input", { bubbles: true }))
}

test("checkbox gestures preserve Shift ranges without double toggles", async () => {
  const ui = mount()
  try {
    await wait()
    const navigations = selected.length
    button(ui.host, "Select sessions").click()
    const checkbox = (id: string) => findRows(ui.host, id)[0].querySelector<HTMLInputElement>('input[type="checkbox"]')!
    const control = (id: string) =>
      findRows(ui.host, id)[0].querySelector<HTMLElement>('[data-slot="checkbox-checkbox-control"]')!
    press(control("same"))
    expect(count(ui.host)).toBe("1 session selected")
    expect(checkbox("same").checked).toBe(true)
    press(control("row-2"), { shiftKey: true })
    expect(count(ui.host)).toBe("5 sessions selected")
    expect(["same", "row-0", "row-1", "row-2"].every((id) => checkbox(id).checked)).toBe(true)
    press(control("row-2"))
    expect(count(ui.host)).toBe("4 sessions selected")
    expect(checkbox("row-2").checked).toBe(false)
    button(ui.host, "Clear").click()
    button(ui.host, "Select sessions").click()
    checkbox("same").click()
    checkbox("row-2").dispatchEvent(new MouseEvent("click", { shiftKey: true, bubbles: true, cancelable: true }))
    expect(count(ui.host)).toBe("5 sessions selected")
    expect(checkbox("row-2").checked).toBe(true)
    expect(selected).toHaveLength(navigations)
  } finally {
    ui.dispose()
  }
})

test("pointer modifiers intercept navigation, ranges dedupe repeated rows, checkbox and keyboard selection", async () => {
  const ui = mount(true, "rtl")
  try {
    await wait()
    expect(ui.host.querySelectorAll('input[type="checkbox"]')).toHaveLength(0)
    press(link(ui.host, "row-0"))
    expect(selected.at(-1)).toMatchObject({ sessionId: "row-0" })
    const navigations = selected.length
    press(link(ui.host, "same"), { metaKey: true })
    expect(document.activeElement).toBe(link(ui.host, "same"))
    expect(count(ui.host)).toBe("1 session selected")
    expect(findRows(ui.host, "same")).toHaveLength(2)
    expect(findRows(ui.host, "same").every((row) => row.dataset.selected === "true")).toBe(true)
    press(link(ui.host, "row-2"), { shiftKey: true })
    expect(count(ui.host)).toBe("5 sessions selected")
    press(link(ui.host, "same"), { ctrlKey: true })
    expect(count(ui.host)).toBe("4 sessions selected")
    press(link(ui.host, "same", 1))
    expect(count(ui.host)).toBe("3 sessions selected")
    link(ui.host, "row-0").click() // native keyboard activation generates detail=0
    expect(count(ui.host)).toBe("2 sessions selected")
    link(ui.host, "row-1").dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }))
    expect(count(ui.host)).toBe("1 session selected")
    const checkbox = findRows(ui.host, "row-2")[0].querySelector<HTMLInputElement>('input[type="checkbox"]')!
    expect(checkbox.checked).toBe(true)
    expect(checkbox.labels?.[0]?.textContent).toBe("Select session row-2")
    checkbox.click()
    expect(count(ui.host)).toBe("0 sessions selected")
    expect(selected).toHaveLength(navigations)
    button(ui.host, "Select visible").click()
    const unique = new Set(rows(ui.host).map((row) => row.querySelector("a")!.getAttribute("href")))
    expect(count(ui.host)).toBe(`${unique.size} sessions selected`)
    expect(unique.size).toBeLessThan(10) // undisplayed project overflow was not selected
    const before = count(ui.host)
    const close = findRows(ui.host, "same")[0].querySelector<HTMLButtonElement>('[aria-label="Close tab"]')!
    press(close)
    expect(closed).toHaveLength(1)
    expect(count(ui.host)).toBe(before)
    const menu = findRows(ui.host, "same")[0].querySelector<HTMLButtonElement>('[aria-label="More options"]')!
    menu.dispatchEvent(
      new PointerEvent("pointerdown", { button: 0, pointerType: "mouse", bubbles: true, cancelable: true }),
    )
    await wait()
    const pin = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
      (item) => item.textContent === "Unpin session",
    )!
    pin.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
    await wait()
    expect(findRows(ui.host, "same")[0].querySelector('[data-slot="tab-pin"]')).toBeNull()
    expect(count(ui.host)).toBe(before)
    expect(selected).toHaveLength(navigations)
  } finally {
    ui.dispose()
  }
})

test("query/view resets, Escape stays local, collapsed/live rows prune and reload clears selection", async () => {
  const ui = mount()
  const composer = document.createElement("textarea")
  document.body.append(composer)
  try {
    await wait()
    button(ui.host, "Select sessions").click()
    button(ui.host, "Select visible").click()
    composer.focus()
    const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })
    composer.dispatchEvent(escape)
    expect(escape.defaultPrevented).toBe(false)
    expect(count(ui.host)).toBeDefined()
    link(ui.host, "same").dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    )
    expect(count(ui.host)).toBeUndefined()
    button(ui.host, "Select sessions").click()
    search(ui.host, "same")
    expect(count(ui.host)).toBeUndefined()
    button(ui.host, "Select sessions").click()
    button(ui.host, "Select visible").click()
    expect(count(ui.host)).toBe("2 sessions selected")
    ui.host.querySelector<HTMLButtonElement>('[aria-label="Attention view"]')!.click()
    expect(count(ui.host)).toBeUndefined()
    search(ui.host, "row-7")
    button(ui.host, "Select sessions").click()
    link(ui.host, "row-7").click()
    const removed = hosts[0].backend.splice(
      hosts[0].backend.findIndex((row) => row.session.id === "row-7"),
      1,
    )[0]
    hosts[0].setCache("row-7", undefined)
    hosts[0].emit("session.deleted", "row-7")
    await wait()
    expect(count(ui.host)).toBe("0 sessions selected")
    expect(button(ui.host, "Archive").disabled).toBe(true)
    hosts[0].backend.push(removed)
    hosts[0].emit("session.created", "row-7")
    await wait()
    link(ui.host, "row-7").click()
    flushPersisted()
    expect(JSON.parse(localStorage.getItem(storage)!)).not.toHaveProperty("keys")
  } finally {
    ui.dispose()
    composer.remove()
  }
  const reload = mount()
  try {
    await wait()
    expect(count(reload.host)).toBeUndefined()
  } finally {
    reload.dispose()
  }
})

test("bulk delete uses one real confirmation, cancel sends nothing, partial failure retains failed selection", async () => {
  const ui = mount()
  try {
    await wait()
    search(ui.host, "same")
    button(ui.host, "Select sessions").click()
    button(ui.host, "Select visible").click()
    const before = requests.length
    button(ui.host, "Delete…").click()
    await wait()
    expect(document.querySelectorAll('[role="dialog"]')).toHaveLength(1)
    expect(document.querySelector('[data-slot="dialog-title"]')?.textContent).toBe("Delete 2 sessions")
    expect(document.querySelector('[data-slot="dialog-description"]')?.textContent).toContain(
      "all their child sessions",
    )
    expect(document.querySelectorAll('[role="dialog"] li')).toHaveLength(2)
    button(document, "Cancel").click()
    await wait()
    expect(requests).toHaveLength(before)
    expect(count(ui.host)).toBe("2 sessions selected")
    hosts[1].failures.add("same")
    const gate = Promise.withResolvers<void>()
    hosts[0].waiters.set("same", gate.promise)
    button(ui.host, "Delete…").click()
    await wait()
    button(document, "Delete 2 sessions").click()
    await Promise.resolve()
    expect(button(ui.host, "Archive").disabled).toBe(true)
    expect(button(ui.host, "Clear").disabled).toBe(true)
    expect(button(document, "Cancel").disabled).toBe(true)
    expect(requests.slice(before)).toEqual([{ server: 0, action: "remove", id: "same" }])
    gate.resolve()
    await wait()
    expect(requests.slice(before)).toEqual([
      { server: 0, action: "remove", id: "same" },
      { server: 1, action: "remove", id: "same" },
    ])
    expect(count(ui.host)).toBe("1 session selected")
    expect(findRows(ui.host, "same", 1)[0].dataset.selected).toBe("true")
    expect(toasts.at(-1)).toEqual(
      expect.objectContaining({ title: "1 completed; 1 session failed", description: "Rejected same" }),
    )
    expect(document.querySelector('[role="dialog"]')).toBeNull()
  } finally {
    hosts[1].failures.clear()
    hosts[0].waiters.clear()
    ui.dispose()
  }
})

test("collapsing and live archive prune selection; confirmation follows only remaining visible rows", async () => {
  const ui = mount()
  try {
    await wait()
    button(ui.host, "Show more").click()
    press(link(ui.host, "row-7"), { ctrlKey: true })
    expect(count(ui.host)).toBe("1 session selected")
    const project = findRows(ui.host, "row-7")[0].closest("[data-project-key]")!
    project.querySelector<HTMLButtonElement>("button[aria-expanded]")!.click()
    expect(count(ui.host)).toBe("0 sessions selected")
    search(ui.host, "row-6")
    press(link(ui.host, "row-6"), { ctrlKey: true })
    button(ui.host, "Delete…").click()
    await wait()
    expect(document.querySelector('[data-slot="dialog-title"]')?.textContent).toBe("Delete 1 session")
    const session = hosts[0].ctx.data.session.get("row-6")!
    hosts[0].ctx.data.session.remember({ ...session, time: { ...session.time, archived: now } })
    hosts[0].emit("session.archived", "row-6")
    const before = requests.length
    await Promise.resolve()
    expect(count(ui.host)).toBe("0 sessions selected")
    expect(button(document, "Delete 0 sessions").disabled).toBe(true)
    button(document, "Delete 0 sessions").click()
    expect(requests).toHaveLength(before)
    button(document, "Cancel").click()
    await wait()
    hosts[0].ctx.data.session.remember(session)
    search(ui.host, "same")
    press(link(ui.host, "same", 1), { metaKey: true })
    expect(count(ui.host)).toBe("1 session selected")
    setRegistry("connections", [connections[0]])
    expect(count(ui.host)).toBe("0 sessions selected")
    expect(button(ui.host, "Archive").disabled).toBe(true)
  } finally {
    setRegistry("connections", connections)
    ui.dispose()
  }
})

test("initial partial loading selects only rendered results and never expands a submitted archive", async () => {
  const gate = Promise.withResolvers<void>()
  hosts[1].navigation.wait = gate.promise
  const ui = mount()
  try {
    await wait()
    search(ui.host, "row-5")
    button(ui.host, "Select sessions").click()
    button(ui.host, "Select visible").click()
    expect(count(ui.host)).toBe("1 session selected")
    const before = requests.length
    button(ui.host, "Archive").click()
    await wait()
    gate.resolve()
    await wait()
    expect(requests.slice(before)).toEqual([{ server: 0, action: "archive", id: "row-5" }])
    expect(count(ui.host)).toBeUndefined()
  } finally {
    gate.resolve()
    hosts[1].navigation.wait = undefined
    ui.dispose()
  }
})

test("archive selection reports disconnected server without sending a request", async () => {
  const ui = mount()
  try {
    await wait()
    search(ui.host, "same")
    button(ui.host, "Select sessions").click()
    button(ui.host, "Select visible").click()
    hosts[1].setState("connected", false)
    const before = requests.length
    button(ui.host, "Archive").click()
    await wait()
    expect(requests).toHaveLength(before)
    expect(count(ui.host)).toBe("1 session selected")
    expect(toasts.at(-1)?.description).toContain("server is unavailable")
  } finally {
    hosts[1].setState("connected", true)
    ui.dispose()
  }
})

test("shared lifecycle dedupes cascade roots across servers and preserves cache/tab invalidation", async () => {
  const ui = mount(false)
  const events: unknown[] = []
  const listener = (event: Event) => events.push(readSessionTabsRemovedDetail(event))
  window.addEventListener(SESSION_TABS_REMOVED_EVENT, listener)
  try {
    const parent = row("parent").session
    const child = row("child", 1, "parent").session
    const grandchild = row("grandchild", 2, "child").session
    const other = row("other").session
    const target = (session: SessionInfo, server = 0) => ({
      session,
      server: ServerConnection.key(connections[server]),
    })
    ;[parent, child, grandchild, other].forEach(hosts[0].ctx.data.session.remember)
    hosts[1].ctx.data.session.remember(parent)
    ui.query.setQueryData(["home-sessions", connections[0]], [parent, child, grandchild, other])
    ui.query.setQueryData(["home-sessions", connections[1]], [parent, other])
    const changes: string[] = []
    const unsubscribe = ui.query.getQueryCache().subscribe((event) => {
      if (event.type === "updated" && event.action.type === "invalidate") changes.push(String(event.query.queryKey[0]))
    })
    const before = requests.length
    let result: SessionLifecycleResult | undefined
    await ui.lifecycle.archiveMany(
      [target(child), target(grandchild), target(parent), target(parent), target(parent, 1)],
      (value) => (result = value),
    )
    expect(requests.slice(before)).toEqual([
      { server: 0, action: "archive", id: "parent" },
      { server: 1, action: "archive", id: "parent" },
    ])
    expect(result?.succeeded).toHaveLength(4)
    expect(result?.failed).toEqual([])
    expect(ui.query.getQueryData(["home-sessions", connections[0]])).toEqual([other])
    expect(ui.query.getQueryData(["home-sessions", connections[1]])).toEqual([other])
    expect(changes).toEqual(["home-sessions", "home-sessions"])
    expect(invalidated).toEqual(expect.arrayContaining(["0:parent", "0:child", "0:grandchild", "1:parent"]))
    expect(hosts[0].ctx.data.session.get("grandchild")?.time.archived).toBeGreaterThan(0)
    expect(events).toEqual([
      { server: target(parent).server, directory: "/repo", sessionIDs: ["parent", "child", "grandchild"] },
      { server: target(parent, 1).server, directory: "/repo", sessionIDs: ["parent"] },
    ])
    unsubscribe()
    const missing = { session: other, server: ServerConnection.Key.make("http://missing.test") }
    await ui.lifecycle.archiveMany([missing], (value) => (result = value))
    expect(result?.failed).toHaveLength(1)
    expect(result?.succeeded).toEqual([])
    expect(toasts.at(-1)?.description).toContain("server is unavailable")
  } finally {
    window.removeEventListener(SESSION_TABS_REMOVED_EVENT, listener)
    ui.dispose()
  }
})

test("row menus block Archive and Delete while a bulk request is pending", async () => {
  const ui = mount()
  const gate = Promise.withResolvers<void>()
  try {
    await wait()
    hosts[0].waiters.set("row-0", gate.promise)
    press(link(ui.host, "row-0"), { ctrlKey: true })
    press(link(ui.host, "row-1"))
    const before = requests.length
    button(ui.host, "Archive").click()
    await Promise.resolve()
    expect(requests.slice(before)).toEqual([{ server: 0, action: "archive", id: "row-0" }])
    for (const context of [false, true]) {
      const row = findRows(ui.host, "row-1")[0]
      if (context)
        row
          .querySelector("a")!
          .dispatchEvent(new MouseEvent("contextmenu", { button: 2, bubbles: true, cancelable: true }))
      if (!context)
        row
          .querySelector<HTMLButtonElement>('[aria-label="More options"]')!
          .dispatchEvent(
            new PointerEvent("pointerdown", { button: 0, pointerType: "mouse", bubbles: true, cancelable: true }),
          )
      await wait()
      for (const action of ["Archive", "Delete…"]) {
        const item = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
          (item) => item.textContent === action,
        )!
        expect(item).toBeDefined()
        expect(item.getAttribute("aria-disabled")).toBe("true")
        item.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
        item.dispatchEvent(
          new PointerEvent("pointerup", { button: 0, pointerType: "mouse", bubbles: true, cancelable: true }),
        )
      }
      expect(requests.slice(before)).toEqual([{ server: 0, action: "archive", id: "row-0" }])
      expect(document.querySelector('[role="dialog"]')).toBeNull()
      document
        .querySelector<HTMLElement>('[role="menu"]')!
        .dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }))
      await wait()
    }
    gate.resolve()
    await wait()
    expect(requests.slice(before)).toEqual([
      { server: 0, action: "archive", id: "row-0" },
      { server: 0, action: "archive", id: "row-1" },
    ])
  } finally {
    gate.resolve()
    hosts[0].waiters.delete("row-0")
    ui.dispose()
  }
})

test("shared delete suppresses selected descendants even when root fails, then cleans cascade caches once", async () => {
  const ui = mount(false)
  const events: unknown[] = []
  const listener = (event: Event) => events.push(readSessionTabsRemovedDetail(event))
  window.addEventListener(SESSION_TABS_REMOVED_EVENT, listener)
  try {
    const parent = row("delete-parent").session
    const child = row("delete-child", 1, parent.id).session
    const other = row("keep").session
    ;[parent, child, other].forEach(hosts[0].ctx.data.session.remember)
    const target = (session: SessionInfo) => ({ session, server: ServerConnection.key(connections[0]) })
    const targets = [target(child), target(parent), target(child)]
    ui.query.setQueryData(["home-sessions", connections[0]], [parent, child, other])
    hosts[0].failures.add(parent.id)
    let result: SessionLifecycleResult | undefined
    const before = requests.length
    ui.lifecycle.showDeleteMany(
      () => targets,
      (value) => (result = value),
    )
    await wait()
    button(document, "Delete 2 sessions").click()
    await wait()
    expect(requests.slice(before)).toEqual([{ server: 0, action: "remove", id: parent.id }])
    expect(result?.failed.map((item) => item.session.id)).toEqual([child.id, parent.id])
    expect(result?.succeeded).toEqual([])
    expect(events).toEqual([])
    expect(ui.query.getQueryData(["home-sessions", connections[0]])).toEqual([parent, child, other])
    hosts[0].failures.delete(parent.id)
    ui.lifecycle.showDeleteMany(
      () => targets,
      (value) => (result = value),
    )
    await wait()
    button(document, "Delete 2 sessions").click()
    await wait()
    expect(requests.slice(before)).toEqual([
      { server: 0, action: "remove", id: parent.id },
      { server: 0, action: "remove", id: parent.id },
    ])
    expect(result?.succeeded).toHaveLength(2)
    expect(ui.query.getQueryData(["home-sessions", connections[0]])).toEqual([other])
    expect(events).toEqual([{ server: target(parent).server, directory: "/repo", sessionIDs: [parent.id, child.id] }])
    // Singular callers share the same cache and tab-removal path.
    await ui.lifecycle.archive(target(other).server, other)
    expect(ui.query.getQueryData(["home-sessions", connections[0]])).toEqual([])
    expect(events).toHaveLength(2)
    expect(hosts[0].ctx.data.session.get(other.id)?.time.archived).toBeGreaterThan(0)
  } finally {
    hosts[0].failures.clear()
    window.removeEventListener(SESSION_TABS_REMOVED_EVENT, listener)
    ui.dispose()
  }
})
