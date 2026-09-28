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

export type SettingsTransientView = Pick<SettingsView, "target" | "searchActivation">

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
const subtabs: Record<NonNullable<SettingsView["subtab"]>, true> = {
  mcps: true,
  plugins: true,
  skills: true,
  lsps: true,
}

// The URL carries the destination so a refresh or a reopened PWA returns to it; search state stays transient.
export function parseSettingsView(search: string, state?: SettingsTransientView): SettingsView {
  // History entries written before the URL carried the destination hold a whole view; keep only transient fields.
  const transient = { target: state?.target, searchActivation: state?.searchActivation }
  const params = new URLSearchParams(search)
  const tab = params.get("tab") ?? "general"
  const server = params.get("server")
  const project = params.get("project")
  const subtab = params.get("subtab")
  const nested = subtab && isSubtab(subtab) && tab === "extensions" ? subtab : undefined

  if (project && server && isProjectTab(tab)) {
    // Custom projects can be opened from the root all-servers list, so the origin is part of the URL.
    const parent = params.get("parent") === "server" ? "server" : "root"
    return { type: "project", server, project, parent, tab, subtab: nested, ...transient }
  }
  if (!project && server && isServerTab(tab))
    return { type: "server", server, tab, subtab: nested === "lsps" ? undefined : nested, ...transient }
  if (!project && !server && isRootTab(tab))
    return { type: "root", tab, subtab: nested === "lsps" ? undefined : nested, ...transient }
  return { type: "root", tab: "general", ...transient }
}

export function settingsViewUrl(view: SettingsView) {
  const params = new URLSearchParams()
  if (view.type !== "root") params.set("server", view.server)
  if (view.type === "project") params.set("project", view.project)
  if (view.type === "project" && view.parent === "server") params.set("parent", "server")
  if (view.tab !== "general") params.set("tab", view.tab)
  if (view.tab === "extensions" && view.subtab) params.set("subtab", view.subtab)
  const search = params.toString()
  return search ? `/settings?${search}` : "/settings"
}

export function isRootTab(value: string): value is SettingsRootTab {
  return Object.hasOwn(rootTabs, value)
}

export function isServerTab(value: string): value is SettingsServerTab {
  return Object.hasOwn(serverTabs, value)
}

export function isProjectTab(value: string): value is SettingsProjectTab {
  return Object.hasOwn(projectTabs, value)
}

function isSubtab(value: string): value is NonNullable<SettingsView["subtab"]> {
  return Object.hasOwn(subtabs, value)
}
