import { expect, mock, test } from "bun:test"
import { createRequire } from "node:module"
import { createComponent } from "solid-js"
import { render } from "solid-js/web"
import { QueryClient, QueryClientProvider } from "@tanstack/solid-query"
import { OpenCode, type SessionInfo } from "@opencode/client/promise"

const require = createRequire(import.meta.url)
const solid = createRequire(require.resolve("vite-plugin-solid"))
const { transformSync } = solid("@babel/core")
Bun.plugin({
  name: "sidebar-worktree-delete-solid",
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

const registry = await import("@/runtime/server/registry")
const { ServerConnection } = registry
const connection = { type: "http" as const, http: { url: "http://worktree-delete.test" } }
const server = ServerConnection.key(connection)
const session = (id: string, directory: string): SessionInfo => ({
  id,
  projectID: "project",
  title: id,
  location: { directory },
  time: { created: 1, updated: 1 },
  cost: 0,
  tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
})

type Fixture = ReturnType<typeof fixture>
let active: Fixture
let controls: {
  lifecycle: ReturnType<typeof useSessionLifecycleActions>
  dialog: ReturnType<typeof useDialog>
}
const toasts: Array<{ title?: string; description?: string }> = []

mock.module("@/runtime/platform/platform", () => ({ usePlatform: () => ({ platform: "web" }) }))
mock.module("@/runtime/server/registry", () => ({
  ...registry,
  useServers: () => ({ list: [connection] }),
}))
mock.module("@/runtime/server/runtime", () => ({
  useGlobal: () => ({ ensureServerCtx: () => active.ctx }),
}))
mock.module("@/shell/tabs/tabs", () => ({
  useTabs: () => ({ store: [], updateDraft: () => {} }),
}))
mock.module("@/shell/notifications/toast", () => ({
  showToast: (toast: { title?: string; description?: string }) => toasts.push(toast),
}))
mock.module("@/shell/titlebar/session-events", () => ({ notifySessionTabsRemoved: () => {} }))

const { useSessionLifecycleActions } = await import("@/session/lifecycle-actions")
const { useSidebarWorktreeDelete } = await import("@/shell/titlebar/sidebar-worktree-delete")
const { LanguageProvider } = await import("@/runtime/i18n/language")
const { DialogProvider, useDialog } = await import("@opencode/ui/context/dialog")

function fixture() {
  const state = {
    deleteGate: undefined as PromiseWithResolvers<void> | undefined,
    archiveGate: undefined as PromiseWithResolvers<void> | undefined,
    archiveError: undefined as Error | undefined,
    deletes: 0,
    archives: [] as string[],
    removed: [] as string[],
  }
  const sessions = [session("worktree-session", "/repo/feature/src")]
  const api = OpenCode.make({
    baseUrl: "http://worktree-delete.test",
    fetch: async (input, init) => {
      const request = input instanceof Request ? input : new Request(input, init)
      const url = new URL(request.url)
      if (url.pathname === "/api/rpc/custom.worktrees/inspect")
        return Response.json({
          output: {
            directory: "/repo/feature",
            identity: "identity",
            branch: "feature",
            dirty: false,
            localBranch: { name: "feature" },
          },
        })
      if (url.pathname === "/api/session") return Response.json({ data: sessions, cursor: {} })
      if (url.pathname === "/api/rpc/custom.worktrees/delete") {
        state.deletes++
        await state.deleteGate?.promise
        return Response.json({ output: { directory: "/repo/feature" } })
      }
      if (url.pathname.endsWith("/archive")) {
        const sessionID = url.pathname.split("/").at(-2)
        if (sessionID) state.archives.push(decodeURIComponent(sessionID))
        await state.archiveGate?.promise
        if (state.archiveError)
          return Response.json(
            { _tag: "SessionNotFoundError", sessionID: sessionID ?? "missing", message: state.archiveError.message },
            { status: 404 },
          )
        return new Response(null, { status: 204 })
      }
      return Response.json({ message: `Unexpected ${request.method} ${url.pathname}` }, { status: 500 })
    },
  })
  const ctx = {
    sdk: {
      connection: { status: () => "connected" },
      api,
    },
    sync: {
      worktrees: {
        remove: (_project: string, directory: string) => state.removed.push(directory),
        refresh: async () => {},
      },
    },
    data: {
      session: {
        list: () => sessions,
        get: (id: string) => sessions.find((item) => item.id === id),
        remember: () => {},
        invalidate: () => {},
        remove: async () => {},
      },
    },
  }
  return { state, ctx }
}

function Harness() {
  const lifecycle = useSessionLifecycleActions()
  const deletion = useSidebarWorktreeDelete(lifecycle.archiveMany, lifecycle.pending)
  const dialog = useDialog()
  const target = {
    server,
    ctx: active.ctx,
    projectID: "project",
    projectDirectory: "/repo",
    directory: "/repo/feature",
    name: "feature",
  }
  controls = { lifecycle, dialog }
  const root = document.createElement("div")
  const button = (text: string, onClick: () => void) => {
    const element = document.createElement("button")
    element.textContent = text
    element.addEventListener("click", onClick)
    root.append(element)
  }
  button("Open delete", () => deletion.show(target))
  button("Start bulk archive", () => {
    void lifecycle.archiveMany([{ server, session: session("bulk", "/repo") }], () => {})
  })
  button("Open other dialog", () => {
    void dialog.show(() => {
      const element = document.createElement("div")
      element.textContent = "Other dialog"
      return element
    })
  })
  return root
}

async function mount() {
  active = fixture()
  toasts.length = 0
  const host = document.createElement("div")
  document.body.append(host)
  const query = new QueryClient()
  const dispose = render(
    () =>
      createComponent(LanguageProvider, {
        get children() {
          return createComponent(QueryClientProvider, {
            client: query,
            get children() {
              return createComponent(DialogProvider, {
                get children() {
                  return createComponent(Harness, {})
                },
              })
            },
          })
        },
      }),
    host,
  )
  const button = (text: string) =>
    [...document.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === text)!
  const wait = () => new Promise((resolve) => setTimeout(resolve, 30))
  return {
    button,
    wait,
    dispose: () => {
      dispose()
      host.remove()
      query.clear()
    },
  }
}

test("worktree deletion uses real lifecycle results for cancel, success, failure, and a closed-dialog race", async () => {
  const view = await mount()
  try {
    view.button("Open delete").click()
    await view.wait()
    const body = document.querySelector<HTMLElement>('[data-slot="dialog-body"]')!
    const container = document.querySelector<HTMLElement>('[data-slot="dialog-container"]')!
    const details = document.querySelector<HTMLElement>('[data-slot="worktree-delete-details"]')!
    const path = document.querySelector<HTMLElement>('[data-slot="worktree-delete-path"]')!
    const options = document.querySelector<HTMLElement>('[data-slot="worktree-delete-options"]')!
    expect(body.className).toContain("px-4")
    expect(body.className).toContain("min-w-0")
    expect(container.className).toContain("max-w-[calc(100vw-32px)]")
    expect(details.className).toContain("gap-3")
    expect(path.dir).toBe("ltr")
    expect(path.className).toContain("break-words")
    expect(path.className).toContain("[overflow-wrap:anywhere]")
    expect(options.className).toContain("[--checkbox-align:flex-start]")
    expect(options.className).toContain("[overflow-wrap:anywhere]")
    view.button("Cancel").click()
    await view.wait()
    expect(active.state.deletes).toBe(0)
    expect(active.state.archives).toEqual([])

    view.button("Open delete").click()
    await view.wait()
    view.button("Delete worktree").click()
    await view.wait()
    expect(active.state.deletes).toBe(1)
    expect(active.state.archives).toEqual(["worktree-session"])
    expect(active.state.removed).toEqual(["/repo/feature"])
    expect(toasts.some((toast) => toast.title === "Deleted feature worktree")).toBe(true)

    active.state.archiveError = new Error("archive failed")
    view.button("Open delete").click()
    await view.wait()
    view.button("Delete worktree").click()
    await view.wait()
    expect(toasts.some((toast) => toast.description === "archive failed")).toBe(true)
    expect(toasts.filter((toast) => toast.title === "Deleted feature worktree")).toHaveLength(1)
    active.state.archiveError = undefined
    active.state.archives.length = 0
    toasts.length = 0
    active.state.deleteGate = Promise.withResolvers<void>()
    active.state.archiveGate = Promise.withResolvers<void>()
    view.button("Open delete").click()
    await view.wait()
    view.button("Delete worktree").click()
    await view.wait()
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }))
    await view.wait()
    expect([...document.querySelectorAll("button")].some((item) => item.textContent === "Delete worktree")).toBe(false)
    void controls.lifecycle.archiveMany([{ server, session: session("bulk", "/repo") }], () => {})
    await view.wait()
    expect(controls.lifecycle.pending()).toBe(true)
    expect(active.state.archives).toEqual(["bulk"])
    void controls.dialog.show(() => {
      const element = document.createElement("div")
      element.textContent = "Other dialog"
      return element
    })
    await view.wait()
    active.state.deleteGate.resolve()
    await view.wait()

    expect(document.body.textContent).toContain("Other dialog")
    expect(active.state.archives).toEqual(["bulk"])
    expect(toasts.some((toast) => toast.title === "Worktree deleted with cleanup errors")).toBe(true)
    expect(toasts.some((toast) => toast.title === "Deleted feature worktree")).toBe(false)
    active.state.archiveGate.resolve()
    await view.wait()
  } finally {
    active.state.deleteGate?.resolve()
    active.state.archiveGate?.resolve()
    view.dispose()
  }
})
