import type { useLanguage } from "@/runtime/i18n/language"
import type { LocalProject } from "@/shell/state/layout"
import { displayName } from "@/shell/layout/helpers"
import { pathKey } from "@/workspaces/path-key"
import { clientSettings, projectSettings, serverSettings, type SettingsSearchEntry } from "./search-catalog"
import { pageLabels } from "./pages"
import type { SettingsSearchResult } from "./search-results"
import type { SettingsServerTab, SettingsView } from "./surface"

export type SettingsSearchServer = {
  key: string
  name: string
  connected: boolean
  projects: readonly LocalProject[]
}

export function settingsSearchProjects(
  tracked: readonly LocalProject[],
  synced: readonly (Partial<Omit<LocalProject, "worktree" | "expanded">> & { worktree: string })[],
) {
  const metadata = new Map(synced.map((project) => [pathKey(project.worktree), project]))
  return tracked.map((project) => ({
    ...project,
    ...metadata.get(pathKey(project.worktree)),
    worktree: project.worktree,
    expanded: project.expanded,
  }))
}

export function settingsSearchIndex(input: {
  servers: readonly SettingsSearchServer[]
  desktop: boolean
  browser: boolean
  dev: boolean
  mobile: boolean
  translate: ReturnType<typeof useLanguage>["t"]
}) {
  const items: SettingsSearchResult[] = []
  const add = (
    entry: SettingsSearchEntry<SettingsView["tab"]>,
    view: SettingsView,
    owner: string,
    server?: string,
    project?: string,
    projectName?: string,
  ) => {
    const page =
      !server && view.tab === "general" && view.target
        ? `${input.translate(pageLabels.general)} / ${input.translate(entry.section ?? "settings.general.section.general")}`
        : input.translate(
            entry.section ??
              (view.type !== "root" && view.tab === "general"
                ? "settings.general.section.general"
                : pageLabels[view.tab]),
          )
    items.push({
      id: JSON.stringify([server, project, view.tab, view.target, view.subtab, entry.label]),
      title: input.translate(entry.label),
      description: entry.description ? input.translate(entry.description) : "",
      keywords: entry.keywords ?? "",
      owner,
      page,
      server,
      project,
      projectName,
      topLevel: !view.target && !view.subtab && !project,
      view,
    })
  }

  clientSettings.forEach((entry) => {
    if (entry.available === "desktop" && !input.desktop) return
    if (entry.available === "browser" && !input.browser) return
    if ((entry.available === "dev" || entry.available === "mobile-dev") && !input.dev) return
    if (entry.available === "mobile-dev" && !input.mobile) return
    add(entry, { type: "root", tab: entry.tab, target: entry.target }, "")
  })
  input.servers.forEach((server) => {
    const view = (tab: SettingsServerTab, subtab?: SettingsView["subtab"]): SettingsView => {
      if (input.servers.length === 1) return { type: "root", tab: tab === "general" ? "servers" : tab, subtab }
      return { type: "server", server: server.key, tab, subtab }
    }
    items.push({
      id: `server:${server.key}`,
      entity: true,
      title: server.name,
      description: "",
      keywords: "",
      owner: input.translate("status.popover.tab.servers"),
      page: input.translate("settings.server.section.connection"),
      server: server.key,
      view: view("general"),
    })
    if (!server.connected) return
    serverSettings.forEach((entry) => add(entry, view(entry.tab, entry.subtab), server.name, server.key))
    server.projects.forEach((project) => {
      const destination: SettingsView = {
        type: "project",
        server: server.key,
        project: project.worktree,
        tab: "general",
        parent: input.servers.length > 1 ? "server" : "root",
      }
      const name = displayName(project)
      items.push({
        id: `project:${server.key}:${project.worktree}`,
        entity: true,
        title: name,
        description: "",
        keywords: "",
        owner: server.name,
        page: input.translate("settings.tab.projects"),
        server: server.key,
        project: project.worktree,
        projectInfo: project,
        view: destination,
      })
      projectSettings.forEach((entry) =>
        add(
          entry,
          { ...destination, tab: entry.tab, subtab: entry.subtab },
          `${server.name} · ${name}`,
          server.key,
          project.worktree,
          name,
        ),
      )
    })
  })
  return items
}
