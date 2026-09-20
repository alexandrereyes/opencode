import { useLocation, useNavigate } from "@solidjs/router"
import { createEffect, on } from "solid-js"
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

export type SettingsView =
  | { type: "root"; tab: SettingsRootTab }
  | { type: "server"; server: string; tab: SettingsServerTab }
  | { type: "project"; server: string; project: string; tab: SettingsProjectTab; parent: "root" | "server" }

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
        show(selectSettingsView(view(), tab), true)
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
