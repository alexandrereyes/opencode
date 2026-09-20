import { Button } from "@opencode/ui-custom/button"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { Tabs } from "@opencode/ui-custom/tabs"
import { createEffect, createMemo, Match, onMount, Show, Switch } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useGlobal, useServerCtx } from "@/runtime/server/runtime"
import { ServerConnection, serverName, useServers } from "@/runtime/server/registry"
import { useLayout, type LocalProject } from "@/shell/state/layout"
import { displayName } from "@/shell/layout/helpers"
import { useTabs } from "@/shell/tabs/tabs"
import { LocationProvider } from "@/workspaces/location"
import { SettingsGeneral } from "./general/general"
import { SettingsAppearance } from "./appearance/appearance"
import { SettingsExperimental } from "./experimental/experimental"
import { SettingsKeybinds } from "./keybinds/keybinds"
import { SettingsNotifications } from "./notifications/notifications"
import { SettingsProviders } from "./providers/providers"
import { SettingsModels } from "./models/models"
import { SettingsServers } from "./servers/servers"
import { SettingsWorkspaces } from "./workspaces/workspaces"
import { SettingsProjects } from "./workspaces/projects"
import { useWorkspacesPrefetch } from "./workspaces/queries"
import { SettingsExtensions } from "./providers/extensions"
import { SettingsAbout } from "./about/about"
import { SettingsSnippets } from "./snippets/snippets"
import { DialogEditProject } from "./workspaces/project-dialog"
import { ProjectSettingsExtensions } from "./workspaces/project-extensions"
import { SettingsServerDataScope, SettingsServerScope } from "./server-scope"
import { SettingsNavigation, type SettingsNavGroup } from "./navigation"
import { SettingsScopedProjects } from "./scoped-projects"
import { pageIcons, pageLabels } from "./pages"
import { useSettingsSurface } from "./surface"
import "@/settings/settings.css"

const rootSections = [
  ["general", "appearance", "notifications", "shortcuts", "snippets"],
  ["servers", "projects", "workspaces"],
  ["providers", "models", "extensions"],
  ["experimental"],
  ["about"],
] as const

const serverTabs = ["general", "projects", "workspaces", "providers", "models", "extensions"] as const
const projectTabs = ["general", "workspaces", "extensions"] as const

export function SettingsScreen() {
  const surface = useSettingsSurface()
  const dialog = useDialog()
  const servers = useServers()
  const global = useGlobal()
  let root: HTMLDivElement | undefined
  let viewType = surface.view().type

  onMount(() => root?.focus({ preventScroll: true }))
  createEffect(() => {
    const next = surface.view().type
    if (next === viewType) return
    viewType = next
    queueMicrotask(() => root?.focus({ preventScroll: true }))
  })

  const targetServer = createMemo(() => {
    const view = surface.view()
    if (view.type === "root") return
    return servers.list.find((item) => ServerConnection.key(item) === view.server)
  })
  const targetProject = createMemo(() => {
    const view = surface.view()
    const server = targetServer()
    if (view.type !== "project" || !server) return
    const context = global.ensureServerCtx(server)
    const project = context.projects.list().find((item) => item.worktree === view.project)
    const synced = context.sync.data.project.find((item) => item.worktree === view.project)
    if (!project && !synced) return
    return { expanded: false, ...project, ...synced, worktree: view.project }
  })

  createEffect(() => {
    const view = surface.view()
    if (view.type === "root") return
    const server = targetServer()
    if (!server) {
      surface.back()
      return
    }
    global.settings.server.set(ServerConnection.key(server))
  })

  return (
    <div
      ref={root}
      data-testid="settings-screen"
      class="settings-screen"
      tabIndex={-1}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented || dialog.active) return
        event.preventDefault()
        surface.back()
      }}
    >
      <Switch>
        <Match when={surface.view().type === "root"}>
          <RootSettings />
        </Match>
        <Match when={surface.view().type === "server"}>
          <Show when={targetServer()}>{(server) => <ServerSettings server={server()} />}</Show>
        </Match>
        <Match when={surface.view().type === "project"}>
          <Show when={targetServer()} keyed>
            {(server) => (
              <Show when={targetProject()} keyed>
                {(project) => <ProjectSettings server={server} project={project} />}
              </Show>
            )}
          </Show>
        </Match>
      </Switch>
    </div>
  )
}

function RootSettings() {
  const language = useLanguage()
  const surface = useSettingsSurface()
  const layout = useLayout()
  const servers = useServers()
  const tabs = useTabs()
  const global = useGlobal()
  const [state, setState] = createStore({ worktreeFilterReset: 0 })

  const sourceServer = createMemo(() => {
    const route = surface.route()
    if (route.type === "session") return servers.list.find((item) => ServerConnection.key(item) === route.server)
    if (route.type === "draft") {
      const draft = tabs.store.find((item) => item.type === "draft" && item.draftID === route.draftID)
      return servers.list.find((item) => ServerConnection.key(item) === draft?.server)
    }
    return servers.list.find((item) => ServerConnection.key(item) === layout.home.selection().server)
  })
  const selectedServer = createMemo(() => global.settings.server.selected() ?? sourceServer() ?? servers.list[0])
  const serverCtx = useServerCtx(selectedServer)
  const prefetchWorkspaces = useWorkspacesPrefetch(selectedServer)
  const directory = createMemo(() => {
    const selected = selectedServer()
    if (!selected) return
    const route = surface.route()
    if (route.type === "session" && route.server === ServerConnection.key(selected))
      return serverCtx()?.data.session.get(route.sessionId)?.location.directory
    if (route.type !== "draft") return
    const draft = tabs.store.find((item) => item.type === "draft" && item.draftID === route.draftID)
    return draft?.type === "draft" && draft.server === ServerConnection.key(selected) ? draft.directory : undefined
  })
  const groups = createMemo<SettingsNavGroup[]>(() => [
    ...rootSections.map((items) => ({
      items: items.map((value) => ({
        value,
        icon: pageIcons[value],
        label: language.t(pageLabels[value]),
        onPrefetch: value === "workspaces" ? prefetchWorkspaces : undefined,
      })),
    })),
    ...(servers.list.length > 1
      ? [
          {
            label: language.t("status.popover.tab.servers"),
            items: servers.list.map((server) => ({
              value: `server:${ServerConnection.key(server)}`,
              icon: pageIcons.servers,
              label: serverName(server) || ServerConnection.key(server),
            })),
          },
        ]
      : []),
  ])

  createEffect(() => {
    const server = sourceServer()
    if (server) global.settings.server.set(ServerConnection.key(server))
  })

  const change = (value: string) => {
    if (value.startsWith("server:")) {
      surface.openServer(value.slice("server:".length))
      return
    }
    if (value === "workspaces") setState("worktreeFilterReset", (current) => current + 1)
    surface.select(value)
  }

  return (
    <SettingsNavigation
      value={surface.view().tab}
      groups={groups()}
      backLabel={language.t("settings.backToApp")}
      onBack={() => surface.close()}
      onChange={change}
    >
      <Tabs.Content value="general" class="settings-panel">
        <SettingsGeneral server={selectedServer()} />
      </Tabs.Content>
      <Tabs.Content value="appearance" class="settings-panel">
        <SettingsAppearance />
      </Tabs.Content>
      <Tabs.Content value="notifications" class="settings-panel">
        <SettingsNotifications />
      </Tabs.Content>
      <Tabs.Content value="shortcuts" class="settings-panel">
        <SettingsKeybinds active={surface.view().tab === "shortcuts"} />
      </Tabs.Content>
      <Tabs.Content value="snippets" class="settings-panel">
        <SettingsSnippets />
      </Tabs.Content>
      <Tabs.Content value="servers" class="settings-panel">
        <SettingsServers />
      </Tabs.Content>
      <Tabs.Content value="projects" class="settings-panel">
        <SettingsProjects />
      </Tabs.Content>
      <SettingsServerScope directory={directory()}>
        <Tabs.Content value="workspaces" class="settings-panel">
          <SettingsWorkspaces activeDirectory={directory()} resetProjectFilter={() => state.worktreeFilterReset} />
        </Tabs.Content>
        <Tabs.Content value="providers" class="settings-panel">
          <SettingsProviders directory={directory()} onBack={() => surface.select("providers")} />
        </Tabs.Content>
        <Tabs.Content value="models" class="settings-panel">
          <SettingsModels active={surface.view().tab === "models"} />
        </Tabs.Content>
        <Tabs.Content value="extensions" class="settings-panel">
          <SettingsExtensions />
        </Tabs.Content>
      </SettingsServerScope>
      <Tabs.Content value="experimental" class="settings-panel">
        <SettingsExperimental />
      </Tabs.Content>
      <Tabs.Content value="about" class="settings-panel settings-about">
        <SettingsAbout active={surface.view().tab === "about"} />
      </Tabs.Content>
    </SettingsNavigation>
  )
}

function ServerSettings(props: { server: ServerConnection.Any }) {
  const language = useLanguage()
  const surface = useSettingsSurface()
  const tabs = useTabs()
  const serverCtx = useServerCtx(() => props.server)
  const prefetchWorkspaces = useWorkspacesPrefetch(() => props.server)
  const [state, setState] = createStore({ worktreeFilterReset: 0 })
  const directory = createMemo(() => {
    const route = surface.route()
    const key = ServerConnection.key(props.server)
    if (route.type === "session" && route.server === key)
      return serverCtx()?.data.session.get(route.sessionId)?.location.directory
    if (route.type !== "draft") return
    const draft = tabs.store.find((item) => item.type === "draft" && item.draftID === route.draftID)
    return draft?.type === "draft" && draft.server === key ? draft.directory : undefined
  })
  const groups = createMemo<SettingsNavGroup[]>(() => [
    {
      items: serverTabs.map((value) => ({
        value,
        icon: value === "general" ? pageIcons.servers : pageIcons[value],
        label:
          value === "general"
            ? serverName(props.server) || ServerConnection.key(props.server)
            : language.t(pageLabels[value]),
        onPrefetch: value === "workspaces" ? prefetchWorkspaces : undefined,
      })),
    },
  ])
  const change = (value: string) => {
    if (value === "workspaces") setState("worktreeFilterReset", (current) => current + 1)
    surface.select(value)
  }

  return (
    <SettingsServerDataScope server={props.server} directory={directory()}>
      <SettingsNavigation
        value={surface.view().tab}
        groups={groups()}
        backLabel={language.t("settings.backToSettings")}
        onBack={() => surface.back()}
        onChange={change}
      >
        <Tabs.Content value="general" class="settings-panel">
          <SettingsServers server={props.server} />
        </Tabs.Content>
        <Tabs.Content value="projects" class="settings-panel">
          <SettingsScopedProjects server={props.server} />
        </Tabs.Content>
        <Tabs.Content value="workspaces" class="settings-panel">
          <SettingsWorkspaces activeDirectory={directory()} resetProjectFilter={() => state.worktreeFilterReset} />
        </Tabs.Content>
        <Tabs.Content value="providers" class="settings-panel">
          <SettingsProviders directory={directory()} onBack={() => surface.select("providers")} />
        </Tabs.Content>
        <Tabs.Content value="models" class="settings-panel">
          <SettingsModels active={surface.view().tab === "models"} />
        </Tabs.Content>
        <Tabs.Content value="extensions" class="settings-panel">
          <SettingsExtensions />
        </Tabs.Content>
      </SettingsNavigation>
    </SettingsServerDataScope>
  )
}

function ProjectSettings(props: { server: ServerConnection.Any; project: LocalProject }) {
  const language = useLanguage()
  const surface = useSettingsSurface()
  const dialog = useDialog()
  const prefetchWorkspaces = useWorkspacesPrefetch(
    () => props.server,
    () => props.project.id,
  )
  const [state] = createStore({ worktreeFilterReset: 0 })
  const groups = createMemo<SettingsNavGroup[]>(() => [
    {
      items: projectTabs.map((value) => ({
        value,
        icon: value === "general" ? pageIcons.projects : pageIcons[value],
        label: value === "general" ? displayName(props.project) : language.t(pageLabels[value]),
        onPrefetch: value === "workspaces" ? prefetchWorkspaces : undefined,
      })),
    },
  ])

  return (
    <SettingsServerDataScope server={props.server} directory={props.project.worktree}>
      <LocationProvider directory={props.project.worktree}>
        <SettingsNavigation
          value={surface.view().tab}
          groups={groups()}
          backLabel={language.t("settings.backToProjects")}
          onBack={() => surface.back()}
          onChange={(value) => surface.select(value)}
        >
          <Tabs.Content value="general" class="settings-panel">
            <div class="settings-tab-header">
              <div class="settings-tab-header-row">
                <div class="flex min-w-0 flex-col gap-1">
                  <h2 class="settings-tab-title truncate">{displayName(props.project)}</h2>
                  <span class="text-11-regular text-v2-text-text-muted">
                    {language.t("project.settings.general.description")}
                  </span>
                </div>
                <Button
                  type="button"
                  variant="outline"
                  onClick={() =>
                    void dialog.push(() => <DialogEditProject project={props.project} server={props.server} />)
                  }
                >
                  {language.t("dialog.project.edit.title")}
                </Button>
              </div>
            </div>
          </Tabs.Content>
          <Tabs.Content value="workspaces" class="settings-panel">
            <SettingsWorkspaces
              projectID={props.project.id}
              activeDirectory={props.project.worktree}
              resetProjectFilter={() => state.worktreeFilterReset}
            />
          </Tabs.Content>
          <Tabs.Content value="extensions" class="settings-panel">
            <ProjectSettingsExtensions />
          </Tabs.Content>
        </SettingsNavigation>
      </LocationProvider>
    </SettingsServerDataScope>
  )
}
