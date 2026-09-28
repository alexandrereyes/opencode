import { useLocation, useNavigate } from "@solidjs/router"
import { batch, createEffect, on } from "solid-js"
import { createStore } from "solid-js/store"
import { createSimpleContext } from "@opencode/ui-custom/context"
import { useLayout, type LayoutRoute } from "@/shell/state/layout"
import { useCommand } from "@/shell/commands/command"
import {
  isProjectTab,
  isRootTab,
  isServerTab,
  parseSettingsView,
  settingsViewUrl,
  type SettingsProjectTab,
  type SettingsRootTab,
  type SettingsServerTab,
  type SettingsTransientView,
  type SettingsView,
} from "./route"

export type { SettingsProjectTab, SettingsRootTab, SettingsServerTab, SettingsView } from "./route"

export function selectSettingsView(view: SettingsView, tab: string): SettingsView {
  if (view.type === "root" && isRootTab(tab)) return { ...view, tab }
  if (view.type === "server" && isServerTab(tab)) return { ...view, tab }
  if (view.type === "project" && isProjectTab(tab)) return { ...view, tab }
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
      settings?: { route: Exclude<LayoutRoute, { type: "settings" }>; view?: SettingsTransientView }
    }>()
    const active = () => layout.route().type === "settings"
    const source = () => location.state?.settings?.route ?? { type: "home" as const }
    const view = () => parseSettingsView(location.search, location.state?.settings?.view)
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
      navigate(settingsViewUrl(destination), {
        replace,
        state: {
          settings: {
            route: route.type === "settings" ? source() : route,
            view: { target: destination.target, searchActivation: destination.searchActivation },
          },
        },
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
