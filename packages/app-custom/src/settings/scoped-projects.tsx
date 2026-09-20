import { Key } from "@solid-primitives/keyed"
import { Icon } from "@opencode/ui-custom/icon"
import { TextInput } from "@opencode/ui-custom/text-input"
import { Show, createEffect, createMemo } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection } from "@/runtime/server/registry"
import { displayName } from "@/shell/layout/helpers"
import { useSettingsSurface } from "./surface"
import { SettingsProjectRow } from "./workspaces/project-row"

export function SettingsScopedProjects(props: { server: ServerConnection.Any }) {
  const language = useLanguage()
  const global = useGlobal()
  const surface = useSettingsSurface()
  const [store, setStore] = createStore({ filter: "" })
  let search: HTMLInputElement | undefined
  const projects = createMemo(() => {
    const context = global.ensureServerCtx(props.server)
    return context.projects.list().map((project) => ({
      ...project,
      expanded: false,
      ...context.sync.data.project.find((item) => item.worktree === project.worktree),
    }))
  })
  const searchable = createMemo(() => projects().length > 7)
  const filtered = createMemo(() => {
    const query = searchable() ? store.filter.trim().toLowerCase() : ""
    if (!query) return projects()
    return projects().filter((project) => displayName(project).toLowerCase().includes(query))
  })
  const emptyMessage = createMemo(() =>
    store.filter.trim() ? language.t("palette.empty") : language.t("settings.projects.empty"),
  )
  createEffect(() => {
    if (!searchable()) setStore("filter", "")
  })

  return (
    <>
      <div class="settings-tab-header" classList={{ "settings-tab-header--stacked": searchable() }}>
        <div class="settings-tab-header-row">
          <div class="flex flex-col gap-1">
            <h2 class="settings-tab-title">{language.t("settings.projects.title")}</h2>
            <span class="text-11-regular text-v2-text-text-muted">{language.t("settings.projects.description")}</span>
          </div>
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
          when={filtered().length > 0}
          fallback={<div class="py-12 text-center text-v2-text-text-muted text-13-regular">{emptyMessage()}</div>}
        >
          <div class="flex flex-col gap-2 w-full">
            <Key each={filtered()} by="worktree">
              {(project) => (
                <SettingsProjectRow
                  project={project()}
                  server={props.server}
                  onOpen={(item) =>
                    surface.openProject({
                      server: ServerConnection.key(props.server),
                      project: item.worktree,
                    })
                  }
                />
              )}
            </Key>
          </div>
        </Show>
      </div>
    </>
  )
}
