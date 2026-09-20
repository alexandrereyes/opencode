import { Key } from "@solid-primitives/keyed"
import { Icon } from "@opencode/ui-custom/icon"
import { TextInput } from "@opencode/ui-custom/text-input"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { For, Show, createEffect, createMemo, type Component } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection, serverName } from "@/runtime/server/registry"
import { displayName } from "@/shell/layout/helpers"
import type { LocalProject } from "@/shell/state/layout"
import { InlineServerSelect } from "@/settings/server-select"
import { DialogEditProject } from "./project-dialog"
import { SettingsProjectRow } from "./project-row"
import "@/settings/settings.css"

export const SettingsProjects: Component = () => {
  const dialog = useDialog()
  const language = useLanguage()
  const global = useGlobal()
  const [store, setStore] = createStore({ allServers: true, filter: "" })
  let search: HTMLInputElement | undefined
  const selected = global.settings.server.selected
  const multiple = createMemo(() => global.servers.list().length > 1)
  const projects = createMemo(() => {
    const server = selected()
    if (!server) return []
    return global.ensureServerCtx(server).projects.list()
  })

  const groups = createMemo(() =>
    global.servers
      .list()
      .map((server) => ({ server, projects: global.ensureServerCtx(server).projects.list() }))
      .filter((group) => group.projects.length > 0),
  )
  const searchable = createMemo(() =>
    store.allServers ? groups().reduce((total, group) => total + group.projects.length, 0) > 7 : projects().length > 7,
  )
  const query = createMemo(() => (searchable() ? store.filter.trim().toLowerCase() : ""))
  const filteredProjects = createMemo(() => {
    const value = query()
    if (!value) return projects()
    return projects().filter((project) => displayName(project).toLowerCase().includes(value))
  })
  const filteredGroups = createMemo(() => {
    const value = query()
    if (!value) return groups()
    return groups()
      .map((group) => ({
        ...group,
        projects: group.projects.filter((project) => displayName(project).toLowerCase().includes(value)),
      }))
      .filter((group) => group.projects.length > 0)
  })
  const emptyMessage = createMemo(() =>
    store.filter.trim() ? language.t("palette.empty") : language.t("settings.projects.empty"),
  )
  createEffect(() => {
    if (!searchable()) setStore("filter", "")
  })

  const openProjectSettings = (project: LocalProject, server = selected()) => {
    if (!server) return
    dialog.push(() => <DialogEditProject project={project} server={server} />)
  }

  return (
    <>
      <div class="settings-tab-header" classList={{ "settings-tab-header--stacked": searchable() }}>
        <div class="settings-tab-header-row">
          <div class="flex flex-col gap-1">
            <h2 class="settings-tab-title">{language.t("settings.projects.title")}</h2>
            <span class="text-11-regular text-v2-text-text-muted">{language.t("settings.projects.description")}</span>
          </div>
          <Show when={multiple()}>
            <InlineServerSelect
              all={{
                label: language.t("settings.projects.server.all"),
                selected: () => store.allServers,
                onSelect: () => setStore("allServers", true),
              }}
              onServerSelect={() => setStore("allServers", false)}
            />
          </Show>
        </div>
        <Show when={searchable()}>
          <div class="settings-tab-search">
            <TextInput
              ref={search}
              type="search"
              appearance="base"
              leadingIcon={<Icon name="magnifying-glass" size="small" />}
              value={store.filter}
              onInput={(event) => setStore("filter", event.currentTarget.value)}
              placeholder={language.t("settings.projects.search.placeholder")}
              aria-label={language.t("settings.projects.search.placeholder")}
              showClearButton={!!store.filter}
              onClearClick={() => {
                setStore("filter", "")
                search?.focus({ preventScroll: true })
              }}
              spellcheck={false}
              autocorrect="off"
              autocomplete="off"
              autocapitalize="off"
            />
          </div>
        </Show>
      </div>

      <div class="settings-tab-body">
        <Show
          when={store.allServers}
          fallback={
            <div class="flex flex-col gap-2 w-full">
              <Show
                when={filteredProjects().length > 0}
                fallback={<div class="py-12 text-center text-v2-text-text-muted text-13-regular">{emptyMessage()}</div>}
              >
                <Show when={selected()} keyed>
                  {(server) => (
                    <div class="settings-section">
                      <Show when={multiple()}>
                        <h3 class="settings-section-title">{serverName(server) || ServerConnection.key(server)}</h3>
                      </Show>
                      <div class="flex flex-col gap-2 w-full">
                        <Key each={filteredProjects()} by="worktree">
                          {(project) => (
                            <SettingsProjectRow
                              project={project()}
                              server={server}
                              onOpen={(item) => openProjectSettings(item, server)}
                            />
                          )}
                        </Key>
                      </div>
                    </div>
                  )}
                </Show>
              </Show>
            </div>
          }
        >
          <div class="flex flex-col gap-8 w-full">
            <Show
              when={filteredGroups().length > 0}
              fallback={<div class="py-12 text-center text-v2-text-text-muted text-13-regular">{emptyMessage()}</div>}
            >
              <For each={filteredGroups()}>
                {(group) => (
                  <div class="settings-section">
                    <Show when={multiple()}>
                      <h3 class="settings-section-title">
                        {serverName(group.server) || ServerConnection.key(group.server)}
                      </h3>
                    </Show>
                    <div class="flex flex-col gap-2 w-full">
                      <Key each={group.projects} by="worktree">
                        {(project) => (
                          <SettingsProjectRow
                            project={project()}
                            server={group.server}
                            onOpen={(item) => openProjectSettings(item, group.server)}
                          />
                        )}
                      </Key>
                    </div>
                  </div>
                )}
              </For>
            </Show>
          </div>
        </Show>
      </div>
    </>
  )
}
