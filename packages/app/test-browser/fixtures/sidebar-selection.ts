import { expect, jest, mock, test } from "bun:test"
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
      time: { created: 1, updated: now - position },
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
  const active = new Set<string>()
  const calls = { active: 0, navigation: 0 }
  type Listener = (event: { type: string; data: { sessionID: string } }) => void
  const listeners = new Set<Listener>()
  const emit = (type: string, sessionID: string) => {
    if (type === "session.execution.started") active.add(sessionID)
    if (["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].includes(type))
      active.delete(sessionID)
    listeners.forEach((listener) => listener({ type, data: { sessionID } }))
  }
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
        permission: { list: () => undefined },
        form: { list: () => undefined },
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
          active: async () => {
            calls.active++
            return Object.fromEntries([...active].map((id) => [id, { type: "running" }]))
          },
          archive: ({ sessionID }: { sessionID: string }) => mutate("archive", sessionID),
          navigation: async (input: { sessionID?: string }) => {
            calls.navigation++
            await navigation.wait
            return { data: backend.filter((row) => !input.sessionID || row.session.id === input.sessionID) }
          },
        },
      },
    },
  }
  return { connection, ctx, backend, setCache, setState, failures, waiters, navigation, emit, active, calls, listeners }
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
const { Persist, removePersisted } = await import("@/runtime/persistence/storage")
const storage = "opencode.global.dat:sidebar-navigation"
const wait = () => new Promise((resolve) => setTimeout(resolve, 160))
function mount(sidebar = true, direction = "ltr", currentTab?: Tab) {
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
                  return sidebar ? createComponent(SessionSidebar, { header: null, children: null, currentTab }) : null
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

test("sidebar render/churn benchmark", async () => {
  const start = performance.now()
  const ui = mount()
  try {
    await wait()
    const mounted = performance.now()
    const observer = new MutationObserver(() => {})
    observer.observe(ui.host, { childList: true, subtree: true })
    const session = hosts[0].backend[1].session
    for (let i = 0; i < 100; i++) hosts[0].setCache(session.id, { ...session, title: `Churn ${i}` })
    console.info(
      JSON.stringify({
        benchmark: "sidebar-happydom",
        mountMs: mounted - start,
        churnMs: performance.now() - mounted,
        mutations: observer.takeRecords().length,
      }),
    )
    observer.disconnect()
    hosts[0].setCache(session.id, session)
  } finally {
    ui.dispose()
  }
})

const recentSection = (root: ParentNode) =>
  [...root.querySelectorAll("section")].find((section) => section.querySelector("h2")?.textContent === "Recent")!
const recentLinks = (root: ParentNode) => [...recentSection(root).querySelectorAll<HTMLAnchorElement>("a")]
const recentOrder = (root: ParentNode) => recentLinks(root).map((link) => link.getAttribute("href"))

test("Recent expands by five, collapses in place, prunes only hidden selection and keeps search complete", async () => {
  const original = hosts.map((host) => host.backend.map((row) => structuredClone(row)))
  try {
    for (const direction of ["ltr", "rtl"]) {
      const sessions = Array.from({ length: 13 }, (_, i) => row(`recent-${i}`, i + 1))
      const archived = row("recent-archived")
      archived.session.time.archived = now
      hosts[0].backend.splice(
        0,
        hosts[0].backend.length,
        row("same"),
        ...sessions,
        row("recent-child", 0, "same"),
        archived,
      )
      hosts[1].backend.splice(0)
      const ui = mount(true, direction)
      try {
        await wait()
        flushPersisted()
        const preferences = localStorage.getItem(storage)
        const calls = hosts.map((host) => ({ ...host.calls }))
        const recent = recentSection(ui.host)
        const control = button(recent, "Show more sessions")
        expect(control.type).toBe("button")
        expect(control.tabIndex).toBe(0)
        expect(control.classList.contains("text-start")).toBe(true)
        expect(ui.host.dir).toBe(direction)
        expect(recentLinks(ui.host)).toHaveLength(5)
        expect(findRows(recent, "same")).toHaveLength(0)
        expect(findRows(ui.host, "recent-child")).toHaveLength(0)
        expect(findRows(ui.host, "recent-archived")).toHaveLength(0)
        const first = recentLinks(ui.host)[0]
        control.focus()
        control.click()
        expect(recentLinks(ui.host)).toHaveLength(10)
        expect(control.textContent).toBe("Show more sessions")
        expect(recentLinks(ui.host)[0] === first).toBe(true)
        expect(document.activeElement === control).toBe(true)

        search(ui.host, "recent-")
        expect(rows(ui.host)).toHaveLength(13)
        expect(button(ui.host, "Show more sessions")).toBeUndefined()
        const input = ui.host.querySelector<HTMLInputElement>('input[type="search"]')!
        input.focus()
        input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }))
        expect(input.value).toBe("")
        expect(document.activeElement === input).toBe(true)
        expect(recentLinks(ui.host)).toHaveLength(10)

        const toggle = ui.host.querySelector<HTMLButtonElement>('[aria-label="Attention view"]')!
        toggle.click()
        expect(button(ui.host, "Show more sessions")).toBeUndefined()
        toggle.click()
        expect(recentLinks(ui.host)).toHaveLength(10)
        const more = button(recentSection(ui.host), "Show more sessions")
        more.focus()
        more.click()
        expect(recentLinks(ui.host)).toHaveLength(13)
        expect(more.textContent).toBe("Show fewer sessions")
        expect(document.activeElement === more).toBe(true)
        const before = recentLinks(ui.host)
        const order = recentOrder(ui.host)
        for (let i = 0; i < 100; i++) hosts[0].emit("session.text.delta", "recent-7")
        hosts[0].setCache("recent-7", {
          ...sessions[7].session,
          title: "Streaming metadata",
          time: { ...sessions[7].session.time, updated: Date.now() + 1000 },
        })
        await wait()
        expect(recentOrder(ui.host)).toEqual(order)
        expect(recentLinks(ui.host).every((item, i) => item === before[i])).toBe(true)
        expect(document.activeElement === more).toBe(true)
        button(ui.host, "Select sessions").click()
        link(recentSection(ui.host), "recent-0").click()
        link(recentSection(ui.host), "recent-7").click()
        expect(count(ui.host)).toBe("2 sessions selected")
        more.focus()
        more.click()
        expect(recentLinks(ui.host)).toHaveLength(5)
        expect(more.textContent).toBe("Show more sessions")
        expect(document.activeElement === more).toBe(true)
        expect(count(ui.host)).toBe("1 session selected")
        expect(findRows(recentSection(ui.host), "recent-0")[0].dataset.selected).toBe("true")
        more.click()
        more.click()
        expect(count(ui.host)).toBe("1 session selected")
        // A row still rendered in its project stays selected when Recent folds.
        const project = ui.host.querySelector<HTMLElement>("[data-project-key]")!
        button(project, "Show more").click()
        link(recentSection(ui.host), "recent-7").click()
        link(recentSection(ui.host), "recent-9").click()
        expect(count(ui.host)).toBe("3 sessions selected")
        more.click()
        expect(count(ui.host)).toBe("2 sessions selected")
        expect(findRows(project, "recent-7")[0].dataset.selected).toBe("true")
        expect(findRows(ui.host, "recent-9")).toHaveLength(0)
        search(ui.host, "recent-")
        expect(rows(ui.host)).toHaveLength(13)
        search(ui.host, "")
        expect(recentLinks(ui.host)).toHaveLength(5)
        button(recentSection(ui.host), "Show more sessions").click()
        expect(recentLinks(ui.host)).toHaveLength(10) // A fresh mount below must reset this local state.
        flushPersisted()
        expect(localStorage.getItem(storage)).toBe(preferences)
        expect(hosts.map((host) => ({ ...host.calls }))).toEqual(calls)
      } finally {
        ui.dispose()
        hosts[0].setCache("recent-7", undefined)
      }
      const reload = mount(true, direction)
      try {
        await wait()
        expect(recentLinks(reload.host)).toHaveLength(5)
      } finally {
        reload.dispose()
      }
    }
  } finally {
    hosts.forEach((host, i) => host.backend.splice(0, host.backend.length, ...original[i]))
  }
})

test("Recent control counts the forced current root and never offers a no-op expansion", async () => {
  const original = hosts.map((host) => host.backend.map((row) => structuredClone(row)))
  try {
    for (const size of [0, 1, 5, 6, 11, 12]) {
      const sessions = Array.from({ length: size }, (_, i) => row(`current-${i}`, i + 1))
      const current = sessions.at(-1)?.session.id ?? "same"
      hosts[0].backend.splice(0, hosts[0].backend.length, row("same"), ...sessions)
      hosts[1].backend.splice(0)
      const ui = mount(true, "ltr", {
        type: "session",
        server: ServerConnection.key(connections[0]),
        sessionId: current,
      })
      try {
        await wait()
        expect(findRows(ui.host, current).length).toBeGreaterThan(0)
        if (!size) {
          expect(recentSection(ui.host)).toBeUndefined()
          continue
        }
        const recent = recentSection(ui.host)
        expect(recentLinks(ui.host)).toHaveLength(Math.min(size, 6))
        expect(findRows(recent, current)).toHaveLength(1)
        const control = button(recent, "Show more sessions")
        if (size <= 6) {
          expect(control).toBeUndefined()
          expect(button(recent, "Show fewer sessions")).toBeUndefined()
          continue
        }
        control.focus()
        control.click()
        expect(recentLinks(ui.host)).toHaveLength(11)
        expect(control.textContent).toBe(size === 11 ? "Show fewer sessions" : "Show more sessions")
        if (size === 12) control.click()
        expect(recentLinks(ui.host)).toHaveLength(size)
        expect(control.textContent).toBe("Show fewer sessions")
        expect(document.activeElement === control).toBe(true)
        button(ui.host, "Select sessions").click()
        link(recent, current).click()
        control.click()
        expect(recentLinks(ui.host)).toHaveLength(6)
        expect(findRows(recent, current)).toHaveLength(1)
        expect(count(ui.host)).toBe("1 session selected")
        expect(control.textContent).toBe("Show more sessions")
      } finally {
        ui.dispose()
      }
    }
  } finally {
    hosts.forEach((host, i) => host.backend.splice(0, host.backend.length, ...original[i]))
  }
})

test("shared sidebar clock updates every view without reordering, remounting, losing focus or selection", async () => {
  const original = hosts.map((host) => host.backend.map((row) => structuredClone(row)))
  const sheet = document.createElement("style")
  sheet.textContent = await Bun.file(new URL("../../src/shell/titlebar/tab-nav.css", import.meta.url)).text()
  document.head.append(sheet)
  try {
    for (const direction of ["ltr", "rtl"]) {
      jest.useFakeTimers()
      const at = new Date(2026, 8, 11, 12).getTime()
      jest.setSystemTime(at)
      const pinned = row("same")
      pinned.messageAt = at - 42_000
      pinned.session.title = "جلسة mixed project title with a long descriptive name"
      pinned.session.time.updated = at // A metadata update must not mask the message clock.
      const minute = row("row-0")
      minute.messageAt = at - 60_000
      const hours = row("row-1")
      hours.messageAt = at - 36_000_000
      hours.session.location.directory = "/repo-worktree"
      const empty = row("row-2")
      delete empty.messageAt
      empty.session.time = { created: at - 86_400_000, updated: at }
      const priority = row("row-3")
      priority.messageAt = at - 3_600_000
      priority.permissionAt = at - 1000
      hosts[0].backend.splice(0, hosts[0].backend.length, pinned, minute, hours, empty, priority)
      hosts[1].backend.splice(0)
      const ui = mount(true, direction)
      ui.host.style.setProperty("--line-height-compact", "16px")
      try {
        // Drain navigation/persistence promises while the shared wall clock stays fixed.
        for (let i = 0; i < 20; i++) {
          await Promise.resolve()
          jest.advanceTimersByTime(0)
        }
        const labels = new Map([
          ["same", "42s"],
          ["row-0", "1m"],
          ["row-1", "10h"],
          ["row-2", "1d"],
          ["row-3", "1h"],
        ])
        for (const [id, label] of labels) {
          const matches = findRows(ui.host, id)
          expect(matches.length).toBeGreaterThan(0)
          for (const match of matches) expect(match.querySelector("time")?.textContent).toBe(label)
        }
        const recent = recentSection(ui.host)
        const project = ui.host.querySelector<HTMLElement>("[data-project-key]")!
        expect(project.querySelector('[data-action="sidebar-project-menu"]')).not.toBeNull()
        const compact = findRows(project, "same")[0]
        const pinnedRow = findRows(ui.host, "same")[0]
        const time = pinnedRow.querySelector<HTMLTimeElement>("time")!
        expect(time.dateTime).toBe(new Date(pinned.messageAt).toISOString())
        expect(time.title).toBe(
          new Intl.DateTimeFormat("en", { dateStyle: "full", timeStyle: "long" }).format(pinned.messageAt),
        )
        expect(time.getAttribute("aria-label")).toBe(time.title)
        expect(time.dir).toBe("auto")
        expect(pinnedRow.querySelector('[data-slot="tab-pin"]')).not.toBeNull()
        expect(pinnedRow.querySelector('[aria-label="Close tab"]')).toBeNull()
        expect(pinnedRow.querySelector('[aria-label="More options"]')).toBeNull()
        expect(pinnedRow.querySelector('[aria-label="Archive"]')).not.toBeNull()
        expect(pinnedRow.querySelector('[aria-label="Delete"]')).not.toBeNull()
        expect(getComputedStyle(time).lineHeight).toBe("16px")
        expect(getComputedStyle(compact.querySelector("a")!).paddingInlineEnd).toBe("48px")
        pinnedRow.dataset.titleOverflow = "true"
        pinnedRow.dataset.active = "true"
        expect(getComputedStyle(pinnedRow.querySelector("a")!).paddingInlineEnd).toBe("48px")
        expect(getComputedStyle(pinnedRow.querySelector("a")!).gridTemplateColumns).toBe("16px minmax(0, 1fr) auto")
        expect(getComputedStyle(pinnedRow.querySelector('[data-slot="tab-title"]')!).textOverflow).toBe("ellipsis")
        const focused = link(recent, "row-0")
        button(ui.host, "Select sessions").click()
        focused.click()
        focused.focus()
        const checkbox = findRows(recent, "row-0")[0].querySelector<HTMLInputElement>('input[type="checkbox"]')!
        const before = rows(ui.host)
        const calls = hosts.map((host) => ({ ...host.calls }))
        const observer = new MutationObserver(() => {})
        observer.observe(ui.host, { childList: true, subtree: true })
        jest.advanceTimersByTime(60_000)
        expect(time.textContent).toBe("1m")
        expect(findRows(recent, "row-0")[0].querySelector("time")?.textContent).toBe("2m")
        expect(rows(ui.host).every((row, i) => row === before[i])).toBe(true)
        expect(document.activeElement === focused).toBe(true)
        expect(checkbox.checked).toBe(true)
        expect(count(ui.host)).toBe("1 session selected")
        expect(hosts.map((host) => ({ ...host.calls }))).toEqual(calls)
        // Clock ticks change text in place, never row elements.
        expect(
          observer
            .takeRecords()
            .flatMap((record) => [...record.removedNodes])
            .some((node) => node instanceof HTMLElement),
        ).toBe(false)
        observer.disconnect()

        // Execution ordering can advance independently of the last real interaction.
        hosts[0].emit("session.execution.started", "same")
        expect(time.textContent).toBe("1m")
        hosts[0].setCache("same", {
          ...pinned.session,
          title: "Renamed",
          time: { ...pinned.session.time, updated: at + 60_000 },
        })
        expect(time.dateTime).toBe(new Date(pinned.messageAt).toISOString())
        expect(time.textContent).toBe("1m")

        search(ui.host, "row-1")
        expect(rows(ui.host)).toHaveLength(1)
        const result = rows(ui.host)[0]
        const resultTime = result.querySelector("time")!
        result.querySelector("a")!.focus()
        jest.advanceTimersByTime(60_000)
        expect(rows(ui.host)[0] === result).toBe(true)
        expect(resultTime.textContent).toBe("10h")
        expect(document.activeElement === result.querySelector("a")).toBe(true)
        search(ui.host, "")
        ui.host.querySelector<HTMLButtonElement>('[aria-label="Attention view"]')!.click()
        const prioritySection = [...ui.host.querySelectorAll("section")].find(
          (section) => section.querySelector("h2")?.textContent === "Priority",
        )!
        const priorityRow = findRows(prioritySection, "row-3")[0]
        const attentionRows = rows(ui.host)
        expect(priorityRow.querySelector("time")?.textContent).toBe("1h")
        expect(findRows(ui.host, "same")[0].querySelector("time")?.textContent).toBe("2m")
        priorityRow.querySelector("a")!.focus()
        jest.advanceTimersByTime(60_000)
        expect(rows(ui.host).every((row, i) => row === attentionRows[i])).toBe(true)
        expect(document.activeElement === priorityRow.querySelector("a")).toBe(true)
        expect(findRows(ui.host, "same")[0].querySelector("time")?.textContent).toBe("3m")
      } finally {
        ui.dispose()
        hosts[0].active.clear()
        jest.useRealTimers()
      }
    }
  } finally {
    sheet.remove()
    hosts.forEach((host, i) => host.backend.splice(0, host.backend.length, ...original[i]))
  }
})

test("Arabic sidebar uses English compact fallback and a localized absolute date", async () => {
  const stored = localStorage.getItem("opencode.global.dat:language")
  localStorage.setItem("opencode.global.dat:language", JSON.stringify({ locale: "ar" }))
  const ui = mount(true, "rtl")
  try {
    await wait()
    const time = ui.host.querySelector<HTMLTimeElement>("time")!
    expect(time.textContent).toMatch(/^\d+[smhd]$/)
    expect(time.title).toBe(
      new Intl.DateTimeFormat("ar", { dateStyle: "full", timeStyle: "long" }).format(new Date(time.dateTime)),
    )
    expect(time.getAttribute("aria-label")).toBe(time.title)
    expect(time.dir).toBe("auto")
    expect(ui.host.dir).toBe("rtl")
    const control = button(ui.host, "Show more sessions")
    control.focus()
    control.click()
    expect(control.textContent).toBe("Show fewer sessions")
    expect(document.activeElement === control).toBe(true)
  } finally {
    ui.dispose()
    removePersisted(Persist.global("language"))
    if (stored !== null) localStorage.setItem("opencode.global.dat:language", stored)
  }
})

test("Recent keeps DOM, focus and selection through assistant steps, reads, rename and duplicate lifecycle events", async () => {
  const ui = mount()
  const original = hosts[0].backend.map((row) => structuredClone(row))
  try {
    await wait()
    const activeCalls = hosts[0].calls.active
    const focused = link(recentSection(ui.host), "row-2")
    button(ui.host, "Select sessions").click()
    focused.click()
    focused.focus()
    const checkbox = findRows(recentSection(ui.host), "row-2")[0].querySelector<HTMLInputElement>(
      'input[type="checkbox"]',
    )!
    const before = recentOrder(ui.host)
    const requests = hosts[0].calls.navigation
    for (let i = 0; i < 100; i++) hosts[0].emit("session.text.delta", "row-2")
    await wait()
    expect(hosts[0].calls.navigation).toBe(requests)
    for (const type of [
      "session.step.started",
      "session.step.ended",
      "session.retry.scheduled",
      "session.step.started",
      "session.step.ended",
      "session.renamed",
      "session.viewed",
      "session.inbox.delivered",
    ]) {
      const index = hosts[0].backend.findIndex((row) => row.session.id === "row-2")
      const previous = hosts[0].backend[index]
      hosts[0].backend[index] = {
        ...previous,
        messageAt: Date.now(),
        session: { ...previous.session, title: type, time: { ...previous.session.time, updated: Date.now() } },
      }
      hosts[0].emit(type, "row-2")
      await wait()
      expect(recentOrder(ui.host)).toEqual(before)
      expect(link(recentSection(ui.host), "row-2") === focused).toBe(true)
      expect(document.activeElement === focused).toBe(true)
      expect(checkbox.checked).toBe(true)
      expect(count(ui.host)).toBe("1 session selected")
    }
    hosts[0].emit("session.execution.started", "row-3")
    hosts[0].emit("session.execution.started", "row-2")
    expect(recentLinks(ui.host)[0] === focused).toBe(true)
    const active = recentOrder(ui.host)
    hosts[0].emit("session.execution.started", "row-3")
    for (const type of [
      "session.step.started",
      "session.step.ended",
      "session.retry.scheduled",
      "session.step.started",
      "session.step.ended",
    ])
      hosts[0].emit(type, "row-3")
    hosts[0].emit("session.inbox.delivered", "row-3") // steering during the same execution
    await wait()
    expect(recentOrder(ui.host)).toEqual(active)
    hosts[0].emit("session.execution.succeeded", "row-3")
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "row-3")).toBe(true)
    hosts[0].emit("session.execution.succeeded", "row-2")
    expect(recentLinks(ui.host)[0] === focused).toBe(true)
    hosts[0].emit("session.execution.succeeded", "row-3")
    expect(recentLinks(ui.host)[0] === focused).toBe(true)
    expect(document.activeElement === focused).toBe(true)
    expect(checkbox.checked).toBe(true)
    expect(hosts[0].calls.active).toBe(activeCalls)
    await wait()
  } finally {
    ui.dispose()
    hosts[0].backend.splice(0, hosts[0].backend.length, ...original)
    hosts[0].active.clear()
  }
})

test("Recent reconciles reconnect snapshots and isolates identical IDs across server removal", async () => {
  const ui = mount()
  const original = hosts[0].backend.map((row) => structuredClone(row))
  try {
    await wait()
    hosts[0].emit("session.execution.started", "row-2")
    const before = recentOrder(ui.host)
    hosts[0].setState("connected", false)
    hosts[0].setState("connected", true)
    await wait()
    expect(recentOrder(ui.host)).toEqual(before)
    hosts[0].setState("connected", false)
    const index = hosts[0].backend.findIndex((row) => row.session.id === "row-3")
    const previous = hosts[0].backend[index]
    hosts[0].backend[index] = {
      ...previous,
      session: { ...previous.session, time: { ...previous.session.time, updated: Date.now() + 1000 } },
    }
    hosts[0].active.delete("row-2") // a missed terminal
    hosts[0].active.add("row-3") // a missed start
    hosts[0].setState("connected", true)
    await wait()
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "row-2")).toBe(true)
    expect(recentLinks(ui.host)[1] === link(recentSection(ui.host), "row-3")).toBe(true)
    hosts[1].emit("session.execution.started", "same")
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "same", 1)).toBe(true)
    const calls = hosts[0].calls.active
    setRegistry("connections", [connections[0]])
    await wait()
    expect(hosts[1].listeners.size).toBe(0)
    expect(hosts[0].calls.active).toBe(calls)
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "row-2")).toBe(true)
    hosts[1].active.clear()
    setRegistry("connections", connections)
    await wait()
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "row-2")).toBe(true)
    expect(hosts[0].calls.active).toBe(calls)
  } finally {
    ui.dispose()
    setRegistry("connections", connections)
    hosts[0].backend.splice(0, hosts[0].backend.length, ...original)
    hosts.forEach((host) => host.active.clear())
  }
})

test("Recent retains a moved identity and forgets archived/deleted ranks", async () => {
  const ui = mount()
  const added = row("transient", 100)
  try {
    await wait()
    hosts[0].backend.push(added)
    hosts[0].emit("session.created", "transient")
    hosts[0].emit("session.execution.started", "transient")
    await wait()
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "transient")).toBe(true)
    const moved = { ...added, session: { ...added.session, projectID: "other", location: { directory: "/other" } } }
    hosts[0].backend[hosts[0].backend.indexOf(added)] = moved
    const focused = link(recentSection(ui.host), "transient")
    focused.focus()
    hosts[0].emit("session.moved", "transient")
    await wait()
    expect(recentLinks(ui.host)[0] === focused).toBe(true)
    expect(document.activeElement === focused).toBe(true)
    expect(ui.host.textContent).toContain("other")
    for (const type of ["session.archived", "session.deleted"]) {
      hosts[0].backend.splice(
        hosts[0].backend.findIndex((row) => row.session.id === "transient"),
        1,
      )
      hosts[0].emit(type, "transient")
      await wait()
      expect(findRows(ui.host, "transient")).toHaveLength(0)
      hosts[0].backend.push(added)
      hosts[0].emit("session.created", "transient")
      await wait()
      expect(findRows(recentSection(ui.host), "transient")).toHaveLength(0)
      hosts[0].emit("session.execution.started", "transient")
      expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "transient")).toBe(true)
    }
  } finally {
    ui.dispose()
    hosts[0].backend.splice(
      hosts[0].backend.findIndex((row) => row.session.id === "transient"),
      1,
    )
    hosts[0].active.clear()
  }
})

test("a lifecycle event during initial snapshot wins over its older active snapshot", async () => {
  const hold = Promise.withResolvers<void>()
  hosts[0].navigation.wait = hold.promise
  const ui = mount()
  try {
    await Promise.resolve()
    hosts[0].emit("session.execution.started", "row-3")
    hold.resolve()
    await wait()
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "row-3")).toBe(true)
    hosts[0].emit("session.execution.started", "row-2")
    hosts[0].emit("session.execution.started", "row-3")
    expect(recentLinks(ui.host)[0] === link(recentSection(ui.host), "row-2")).toBe(true)
    await wait()
  } finally {
    hold.resolve()
    hosts[0].navigation.wait = undefined
    ui.dispose()
    hosts[0].active.clear()
  }
})

test("sidebar quick actions reserve space and reveal on focus with real icons in LTR and RTL", async () => {
  const sheet = document.createElement("style")
  sheet.textContent = await Bun.file(new URL("../../src/shell/titlebar/tab-nav.css", import.meta.url)).text()
  document.head.append(sheet)
  try {
    for (const direction of ["ltr", "rtl"]) {
      const ui = mount(true, direction)
      try {
        await wait()
        const row = findRows(ui.host, "same")[0]
        const cluster = row.querySelector<HTMLElement>('[data-slot="tab-quick-actions"]')!
        const actions = [...cluster.querySelectorAll<HTMLButtonElement>("button")]
        const link = row.querySelector("a")!
        const time = row.querySelector("time")!
        expect(actions.map((item) => item.getAttribute("aria-label"))).toEqual(["Archive", "Delete"])
        expect(actions.map((item) => item.querySelector("use")?.getAttribute("href"))).toEqual([
          expect.stringContaining("archive"),
          expect.stringContaining("trash"),
        ])
        expect(actions.every((item) => item.tabIndex === 0 && item.title === item.getAttribute("aria-label"))).toBe(
          true,
        )
        expect(row.querySelector('[aria-label="More options"]')).toBeNull()
        expect(row.querySelector('[aria-label="Close tab"]')).toBeNull()
        expect(getComputedStyle(cluster).opacity).toBe("0")
        expect(getComputedStyle(cluster).pointerEvents).toBe("none")
        const padding = getComputedStyle(link).paddingInlineEnd
        expect(padding).toBe("48px")
        expect(getComputedStyle(cluster.parentElement!).width).toBe("44px")
        row.removeAttribute("data-sidebar-time")
        row.dataset.titleOverflow = "true"
        expect(getComputedStyle(link).paddingInlineEnd).toBe(padding)
        row.setAttribute("data-sidebar-time", "")
        for (const focused of [link, ...actions]) {
          focused.focus()
          expect(document.activeElement === focused).toBe(true)
          expect(row.contains(document.activeElement)).toBe(true)
          expect(getComputedStyle(link).paddingInlineEnd).toBe(padding)
          expect(time.isConnected).toBe(true)
          expect(time.getAttribute("aria-hidden")).toBeNull()
          expect(getComputedStyle(time).display).not.toBe("none")
        }
        // HappyDOM has no hover/focus-within CSS evaluation; inspect the parsed reveal and touch rules.
        const rules = [...sheet.sheet!.cssRules]
        expect(
          rules.some(
            (rule) =>
              rule.cssText.includes(":hover, :focus-within") &&
              rule.cssText.includes("opacity: 1") &&
              rule.cssText.includes("pointer-events: auto"),
          ),
        ).toBe(true)
        expect(
          rules.some((rule) => rule.cssText.includes("(hover: none)") && rule.cssText.includes("tab-quick-actions")),
        ).toBe(true)
      } finally {
        ui.dispose()
      }
    }
  } finally {
    sheet.remove()
  }
})

test("Escape clears selection while either quick action is focused without running actions", async () => {
  const ui = mount()
  try {
    await wait()
    const before = requests.length
    const navigations = selected.length
    const closes = closed.length
    for (const label of ["Archive", "Delete"]) {
      button(ui.host, "Select sessions").click()
      link(ui.host, "same").click()
      expect(count(ui.host)).toBe("1 session selected")
      const action = findRows(ui.host, "same")[0].querySelector<HTMLButtonElement>(`[aria-label="${label}"]`)!
      action.focus()
      expect(document.activeElement === action).toBe(true)
      const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true })
      action.dispatchEvent(escape)
      action.dispatchEvent(new KeyboardEvent("keyup", { key: "Escape", bubbles: true, cancelable: true }))
      expect(escape.defaultPrevented).toBe(true)
      expect(count(ui.host)).toBeUndefined()
      expect(ui.host.querySelectorAll('input[type="checkbox"]')).toHaveLength(0)
      expect(requests).toHaveLength(before)
      expect(selected).toHaveLength(navigations)
      expect(closed).toHaveLength(closes)
      expect(document.querySelector('[role="dialog"]')).toBeNull()
    }
  } finally {
    ui.dispose()
  }
})

test("quick Archive/Delete isolate pointer, keyboard and modifiers, preserve confirmation and remove live selection", async () => {
  const original = hosts.map((host) => host.backend.map((row) => structuredClone(row)))
  try {
    for (const selectionMode of [false, true]) {
      hosts[0].backend.splice(0, hosts[0].backend.length, row("same"), row("row-0"), row("row-1"))
      hosts[1].backend.splice(0)
      const ui = mount(true, selectionMode ? "rtl" : "ltr")
      const gate = Promise.withResolvers<void>()
      const events: unknown[] = []
      const listener = (event: Event) => events.push(readSessionTabsRemovedDetail(event))
      window.addEventListener(SESSION_TABS_REMOVED_EVENT, listener)
      try {
        await wait()
        const navigations = selected.length
        const closes = closed.length
        const before = requests.length
        if (selectionMode) {
          button(ui.host, "Select sessions").click()
          link(ui.host, "same").click()
          link(ui.host, "row-0").click()
        }
        const selection = count(ui.host)
        const project = ui.host.querySelector("[data-project-key]")!
        const expanded = project.querySelector("button[aria-expanded]")!.getAttribute("aria-expanded")
        const row = findRows(ui.host, "same")[0]
        const archive = row.querySelector<HTMLButtonElement>('[aria-label="Archive"]')!
        const remove = row.querySelector<HTMLButtonElement>('[aria-label="Delete"]')!
        const bubbled: string[] = []
        for (const type of [
          "pointerdown",
          "mousedown",
          "click",
          "dblclick",
          "auxclick",
          "keydown",
          "keyup",
          "dragstart",
        ])
          row.addEventListener(type, () => bubbled.push(type))
        for (const init of [{}, { shiftKey: true }, { ctrlKey: true }, { metaKey: true }]) {
          press(remove, init)
          await wait()
          expect(document.querySelectorAll('[role="dialog"]')).toHaveLength(1)
          expect(document.querySelector('[data-slot="dialog-title"]')?.textContent).toBe("Delete session")
          expect(requests).toHaveLength(before)
          button(document, "Cancel").click()
          await wait()
          expect(count(ui.host)).toBe(selection)
        }
        for (const key of ["Enter", " "]) {
          remove.focus()
          remove.dispatchEvent(new KeyboardEvent("keydown", { key, shiftKey: true, bubbles: true, cancelable: true }))
          remove.dispatchEvent(new KeyboardEvent("keyup", { key, shiftKey: true, bubbles: true, cancelable: true }))
          remove.click() // Browser-generated native button activation has detail=0.
          await wait()
          expect(requests).toHaveLength(before)
          button(document, "Cancel").click()
          await wait()
        }
        for (const type of ["dblclick", "auxclick", "dragstart"])
          remove.dispatchEvent(new MouseEvent(type, { button: 1, bubbles: true, cancelable: true }))
        // Touch gets the same direct archive action, regardless of Shift.
        hosts[0].waiters.set("same", gate.promise)
        archive.dispatchEvent(
          new PointerEvent("pointerdown", { pointerType: "touch", bubbles: true, cancelable: true }),
        )
        archive.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }))
        archive.dispatchEvent(new MouseEvent("click", { detail: 1, shiftKey: true, bubbles: true, cancelable: true }))
        await Promise.resolve()
        expect(archive.disabled).toBe(true)
        expect(remove.disabled).toBe(true)
        archive.click()
        remove.click()
        expect(requests.slice(before)).toEqual([{ server: 0, action: "archive", id: "same" }])
        expect(document.querySelector('[role="dialog"]')).toBeNull()
        expect(bubbled).toEqual([])
        expect(count(ui.host)).toBe(selection)
        expect(selected).toHaveLength(navigations)
        expect(closed).toHaveLength(closes)
        expect(project.querySelector("button[aria-expanded]")!.getAttribute("aria-expanded")).toBe(expanded)
        gate.resolve()
        await wait()
        expect(findRows(ui.host, "same")).toHaveLength(0)
        expect(count(ui.host)).toBe(selectionMode ? "1 session selected" : undefined)
        findRows(ui.host, "row-0")[0].querySelector<HTMLButtonElement>('[aria-label="Delete"]')!.click()
        await wait()
        expect(requests).toHaveLength(before + 1)
        button(document, "Delete session").click()
        await wait()
        expect(requests.slice(before)).toEqual([
          { server: 0, action: "archive", id: "same" },
          { server: 0, action: "remove", id: "row-0" },
        ])
        expect(findRows(ui.host, "row-0")).toHaveLength(0)
        expect(count(ui.host)).toBe(selectionMode ? "0 sessions selected" : undefined)
        expect(events).toEqual([
          {
            server: ServerConnection.key(connections[0]),
            directory: "/repo",
            sessionIDs: expect.arrayContaining(["same"]),
          },
          { server: ServerConnection.key(connections[0]), directory: "/repo", sessionIDs: ["row-0"] },
        ])
      } finally {
        gate.resolve()
        hosts[0].waiters.clear()
        window.removeEventListener(SESSION_TABS_REMOVED_EVENT, listener)
        ui.dispose()
        ;["same", "row-0", "row-1"].forEach((id) => hosts[0].setCache(id, undefined))
      }
    }
  } finally {
    hosts.forEach((host, i) => host.backend.splice(0, host.backend.length, ...original[i]))
  }
}, 15_000)

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
    link(ui.host, "same").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }))
    await wait()
    const close = [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find(
      (item) => item.textContent === "Close tab",
    )!
    close.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }))
    await wait()
    expect(closed).toHaveLength(1)
    expect(count(ui.host)).toBe(before)
    link(ui.host, "same").dispatchEvent(
      new KeyboardEvent("keydown", { key: "F10", shiftKey: true, bubbles: true, cancelable: true }),
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

test("row menus and direct actions block mutations while a bulk request is pending", async () => {
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
          .querySelector("a")!
          .dispatchEvent(new KeyboardEvent("keydown", { key: "F10", shiftKey: true, bubbles: true, cancelable: true }))
      await wait()
      for (const action of ["Pin session", "Rename", "Archive", "Delete…"]) {
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
    for (const label of ["Archive", "Delete"]) {
      const action = findRows(ui.host, "row-1")[0].querySelector<HTMLButtonElement>(`[aria-label="${label}"]`)!
      expect(action.disabled).toBe(true)
      press(action, { shiftKey: true })
      action.click()
    }
    expect(requests.slice(before)).toEqual([{ server: 0, action: "archive", id: "row-0" }])
    expect(document.querySelector('[role="dialog"]')).toBeNull()
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
