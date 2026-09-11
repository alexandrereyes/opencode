import { expect, mock, test } from "bun:test"
import { createRequire } from "node:module"
import { createComponent, type JSX } from "solid-js"
import { render } from "solid-js/web"
import { createStore } from "solid-js/store"
import type { Tab } from "@/shell/tabs/tabs"

// Compile production JSX as Vite does; no browser process or visual automation.
const require = createRequire(import.meta.url)
const solid = createRequire(require.resolve("vite-plugin-solid"))
const { transformSync } = solid("@babel/core")
Bun.plugin({
  name: "sidebar-search-solid",
  setup(build) {
    build.onLoad(
      { filter: /[/\\](sidebar|tab-strip|helper|text-input|button|icon-button|tooltip|icon)\.tsx$/ },
      async (args) => ({
        contents: transformSync(await Bun.file(args.path).text(), {
          filename: args.path,
          presets: [solid.resolve("babel-preset-solid"), solid.resolve("@babel/preset-typescript")],
        }).code,
        loader: "js",
      }),
    )
  },
})

// Substitute host services, dragging and unrelated row presentation. The sidebar, strip,
// shortcut registration/cleanup, command provider and search input remain real.
mock.module("@dnd-kit/solid", () => ({
  DragDropProvider: (props: { children: JSX.Element }) => props.children,
  PointerSensor: { configure: () => ({}) },
}))
mock.module("@dnd-kit/solid/sortable", () => ({
  isSortable: () => false,
  useSortable: () => ({ ref: () => {}, handleRef: () => {}, isDragSource: () => false }),
}))
mock.module("@/runtime/server/runtime", () => ({
  useGlobal: () => ({ servers: { list: () => [] } }),
  useServerCtx: () => () => undefined,
}))
mock.module("@/shell/state/layout", () => ({
  useLayout: () => ({ route: () => ({ type: "home" }) }),
  useCurrentRoute: () => () => ({ type: "home" }),
}))
mock.module("@/settings/model", () => ({
  useSettings: () => ({ keybinds: { get: () => undefined }, permissions: { autoApprove: () => false } }),
}))
mock.module("@/runtime/i18n/language", () => ({
  useLanguage: () => ({ t: (key: string) => key, plural: (key: string) => key, intl: () => "en" }),
}))
mock.module("@opencode/ui/context/dialog", () => ({ useDialog: () => ({ active: false }) }))
mock.module("@/servers/ssh/authenticate", () => ({ useSshAuthenticate: () => () => false }))
mock.module("@/runtime/persistence/storage", () => ({
  Persist: { global: (key: string) => key },
  persisted: (_key: string, _schema: unknown, initial: object) => [...createStore(initial), undefined, () => false],
  removePersisted: () => {},
  draftPersistedKeys: () => [],
}))
mock.module("@/composer/persistence", () => ({ createTabComposerState: () => {} }))
mock.module("@/shell/notifications/toast", () => ({ showToast: () => {} }))
mock.module("@/session/lifecycle-actions", () => ({ useSessionLifecycleActions: () => ({ pending: () => false }) }))
mock.module("@/shell/titlebar/tab-nav", () => {
  const item = (props: { href: string }) => {
    const link = document.createElement("a")
    link.href = props.href
    link.textContent = props.href
    return link
  }
  return { DraftTabItem: item, TabNavItem: item }
})

const tabsModule = await import("@/shell/tabs/tabs")
const { ServerConnection } = await import("@/runtime/server/registry")
const server = ServerConnection.Key.make("http://localhost:1234")
const draft: Tab = { type: "draft", draftID: "draft-search-test", server, directory: "/test" }
const pending: Tab = {
  type: "session",
  server,
  sessionId: "ses_pending",
}
const selected: Tab[] = []
mock.module("@/shell/tabs/tabs", () => ({
  ...tabsModule,
  useTabs: () => ({
    store: [draft, pending],
    info: {},
    pendingSession: (_server: string, id: string) => id === pending.sessionId,
    select: (tab: Tab) => selected.push(tab),
  }),
}))

const { SessionSidebar } = await import("@/shell/titlebar/sidebar")
const { CommandProvider, useCommand, parseKeybind } = await import("@/shell/commands/command")

test("Mod+1/2 survive search and clearing with focus in search or composer", async () => {
  const host = document.createElement("div")
  const composer = document.createElement("div")
  composer.contentEditable = "true"
  document.body.append(host, composer)
  let command!: ReturnType<typeof useCommand>
  const dispose = render(
    () =>
      createComponent(CommandProvider, {
        get children() {
          command = useCommand()
          return createComponent(SessionSidebar, { header: null, children: null })
        },
      }),
    host,
  )
  try {
    await Promise.resolve()
    const input = host.querySelector<HTMLInputElement>('input[type="search"]')!
    const strip = host.querySelector<HTMLElement>('[data-slot="vertical-tabs"]')!
    const registrations = command.options.filter((option) => /^tab\.[12]$/.test(option.id))
    expect(registrations).toHaveLength(2)
    expect(strip.querySelectorAll("a")).toHaveLength(2)

    for (const query of ["", "needle", ""]) {
      if (input.value) host.querySelector<HTMLButtonElement>('[aria-label="sidebar.search.clear"]')!.click()
      if (query) {
        input.value = query
        input.dispatchEvent(new Event("input", { bubbles: true }))
      }
      await Promise.resolve()

      expect(input.value).toBe(query)
      expect(host.querySelector('[data-slot="vertical-tabs"]') === strip).toBe(true)
      expect(!!strip.closest("[hidden]")).toBe(!!query)
      if (query) {
        const results = document.getElementById(input.getAttribute("aria-controls")!)!
        expect(results.contains(strip)).toBe(false)
        expect(results.querySelectorAll("a")).toHaveLength(0)
      }
      expect(command.options.filter((option) => /^tab\.[12]$/.test(option.id))).toEqual(registrations)
      expect(host.querySelector('[data-slot="session-sidebar"]')?.getAttribute("data-mode")).toBe(
        query ? "search" : "attention",
      )
      for (const target of [input, composer]) {
        target.focus()
        expect(document.activeElement === target).toBe(true)
        for (const [index, tab] of [draft, pending].entries()) {
          const keybind = parseKeybind(`mod+${index + 1}`)[0]
          const event = new KeyboardEvent("keydown", {
            key: keybind.key,
            ctrlKey: keybind.ctrl,
            metaKey: keybind.meta,
            bubbles: true,
            cancelable: true,
          })
          target.dispatchEvent(event)
          expect(event.defaultPrevented).toBe(true)
          expect(selected.at(-1)).toBe(tab)
        }
      }
    }
    expect(selected).toHaveLength(12)
  } finally {
    dispose()
    host.remove()
    composer.remove()
  }
})
