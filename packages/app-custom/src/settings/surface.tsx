import { useLocation, useNavigate } from "@solidjs/router"
import { batch, createEffect, on } from "solid-js"
import { createStore } from "solid-js/store"
import { createSimpleContext } from "@opencode/ui-custom/context"
import { useLayout, type LayoutRoute } from "@/shell/state/layout"
import { useCommand } from "@/shell/commands/command"

export type SettingsRootTab =
  | "general"
  | "appearance"
  | "notifications"
  | "shortcuts"
  | "snippets"
  | "servers"
  | "projects"
  | "workspaces"
  | "providers"
  | "models"
  | "extensions"
  | "experimental"
  | "about"

export type SettingsServerTab = "general" | "projects" | "workspaces" | "providers" | "models" | "extensions"
export type SettingsProjectTab = "general" | "workspaces" | "extensions"

export type SettingsView = (
  | { type: "root"; tab: SettingsRootTab }
  | { type: "server"; server: string; tab: SettingsServerTab }
  | { type: "project"; server: string; project: string; tab: SettingsProjectTab; parent: "root" | "server" }
) & {
  target?: string
  subtab?: "mcps" | "plugins" | "skills" | "lsps"
  searchActivation?: number
}

const rootTabs: Record<SettingsRootTab, true> = {
  general: true,
  appearance: true,
  notifications: true,
  shortcuts: true,
  snippets: true,
  servers: true,
  projects: true,
  workspaces: true,
  providers: true,
  models: true,
  extensions: true,
  experimental: true,
  about: true,
}
const serverTabs: Record<SettingsServerTab, true> = {
  general: true,
  projects: true,
  workspaces: true,
  providers: true,
  models: true,
  extensions: true,
}
const projectTabs: Record<SettingsProjectTab, true> = {
  general: true,
  workspaces: true,
  extensions: true,
}

export function selectSettingsView(view: SettingsView, tab: string): SettingsView {
  if (view.type === "root" && tab in rootTabs) return { ...view, tab: tab as SettingsRootTab }
  if (view.type === "server" && tab in serverTabs) return { ...view, tab: tab as SettingsServerTab }
  if (view.type === "project" && tab in projectTabs) return { ...view, tab: tab as SettingsProjectTab }
  return view
}

export function parentSettingsView(view: Exclude<SettingsView, { type: "root" }>): SettingsView {
  if (view.type === "server") return { type: "root", tab: "general" }
  if (view.parent === "root") return { type: "root", tab: "projects" }
  return { type: "server", server: view.server, tab: "projects" }
}

export function projectSettingsView(
  current: SettingsView,
  input: { server: string; project: string; tab?: SettingsProjectTab },
): SettingsView {
  return {
    type: "project",
    ...input,
    parent: current.type === "server" ? "server" : "root",
    tab: input.tab ?? "general",
  }
}

export const { use: useSettingsSurface, provider: SettingsSurfaceProvider } = createSimpleContext({
  name: "SettingsSurface",
  gate: false,
  init: () => {
    const navigate = useNavigate()
    const layout = useLayout()
    const command = useCommand()
    const location = useLocation<{
      settings?: { route: Exclude<LayoutRoute, { type: "settings" }>; view: SettingsView }
    }>()
    const active = () => layout.route().type === "settings"
    const source = () => location.state?.settings?.route ?? { type: "home" as const }
    const view = (): SettingsView => location.state?.settings?.view ?? { type: "root", tab: "general" }
    const [search, setSearch] = createStore({
      query: "",
      origin: undefined as SettingsView | undefined,
      selected: "",
      highlighted: "",
      scrollTop: 0,
      activation: 0,
      expanded: true,
    })
    let focus: HTMLElement | undefined

    const show = (destination: SettingsView, replace: boolean) => {
      const route = layout.route()
      if (route.type !== "settings" && document.activeElement instanceof HTMLElement) focus = document.activeElement
      navigate("/settings", {
        replace,
        state: { settings: { route: route.type === "settings" ? source() : route, view: destination } },
      })
    }

    createEffect(
      on(
        active,
        (value) => {
          if (value) return
          setSearch({ query: "", origin: undefined, selected: "", highlighted: "", scrollTop: 0, expanded: true })
          if (focus?.isConnected) focus.focus({ preventScroll: true })
          focus = undefined
        },
        { defer: true },
      ),
    )

    return {
      active,
      route: source,
      view,
      search: {
        state: search,
        input(query: string) {
          if (!search.query.trim() && query.trim()) setSearch("origin", { ...view(), target: undefined })
          setSearch({ query, highlighted: "", scrollTop: 0, expanded: true })
          if (!query.trim()) setSearch({ selected: "", origin: undefined })
        },
        expand() {
          setSearch("expanded", true)
        },
        highlight(id: string) {
          setSearch("highlighted", id)
        },
        scroll(scrollTop: number) {
          setSearch("scrollTop", scrollTop)
        },
        open(destination: SettingsView, id: string) {
          batch(() => {
            show({ ...destination, searchActivation: search.activation + 1 }, true)
            setSearch({ selected: id, highlighted: id, expanded: false, activation: search.activation + 1 })
          })
        },
        clear() {
          setSearch({ query: "", selected: "", highlighted: "", scrollTop: 0, origin: undefined, expanded: true })
        },
        back() {
          if (!search.query.trim() || !search.selected || !search.origin) return false
          show(search.origin, true)
          setSearch({ selected: "", expanded: true })
          return true
        },
      },
      open(tab: SettingsRootTab = "general") {
        show({ type: "root", tab }, active())
      },
      openServer(server: string, tab: SettingsServerTab = "general") {
        show({ type: "server", server, tab }, active())
      },
      replaceServer(server: string, tab: SettingsServerTab = "general") {
        show({ type: "server", server, tab }, true)
      },
      openProject(input: { server: string; project: string; tab?: SettingsProjectTab }) {
        show(projectSettingsView(view(), input), active())
      },
      select(tab: string) {
        show({ ...selectSettingsView(view(), tab), target: undefined, subtab: undefined }, true)
      },
      subtab(subtab: SettingsView["subtab"]) {
        show({ ...view(), subtab, target: undefined }, true)
      },
      back() {
        const current = view()
        if (current.type === "root") {
          command.trigger("common.goBack")
          return
        }
        show(parentSettingsView(current), true)
      },
      close() {
        if (active()) command.trigger("common.goBack")
      },
    }
  },
})
