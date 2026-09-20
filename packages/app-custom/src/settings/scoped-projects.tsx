import { For, Show } from "solid-js"
import { Icon } from "@opencode/ui-custom/icon"
import { useLanguage } from "@/runtime/i18n/language"
import { useGlobal } from "@/runtime/server/runtime"
import { ServerConnection } from "@/runtime/server/registry"
import { displayName } from "@/shell/layout/helpers"
import { ProjectIcon } from "@/shell/layout/project-icon"
import { useSettingsSurface } from "./surface"

export function SettingsScopedProjects(props: { server: ServerConnection.Any }) {
  const language = useLanguage()
  const global = useGlobal()
  const surface = useSettingsSurface()
  const projects = () => {
    const context = global.ensureServerCtx(props.server)
    return [...context.projects.list(), ...context.sync.data.project]
      .filter((project, index, items) => items.findIndex((item) => item.worktree === project.worktree) === index)
      .map((project) => ({
        expanded: false,
        ...project,
        ...context.sync.data.project.find((item) => item.worktree === project.worktree),
      }))
  }

  return (
    <>
      <div class="settings-tab-header">
        <div class="settings-tab-header-row">
          <div class="flex flex-col gap-1">
            <h2 class="settings-tab-title">{language.t("settings.projects.title")}</h2>
            <span class="text-11-regular text-v2-text-text-muted">{language.t("settings.projects.description")}</span>
          </div>
        </div>
      </div>
      <div class="settings-tab-body">
        <Show
          when={projects().length > 0}
          fallback={
            <div class="py-12 text-center text-v2-text-text-muted text-13-regular">
              {language.t("settings.projects.empty")}
            </div>
          }
        >
          <div class="flex flex-col gap-2 w-full">
            <For each={projects()}>
              {(project) => (
                <button
                  type="button"
                  class="group mx-px flex items-center justify-between gap-5 px-4 py-2.5 rounded-lg bg-v2-background-bg-base shadow-[var(--v2-elevation-raised)] transition-all hover:bg-v2-background-bg-layer-01 text-left"
                  onClick={() =>
                    surface.openProject({
                      server: ServerConnection.key(props.server),
                      project: project.worktree,
                    })
                  }
                >
                  <span class="flex items-center gap-2.5 min-w-0 flex-1">
                    <ProjectIcon project={project} class="shrink-0" />
                    <span class="text-13-medium text-v2-text-text-base truncate">{displayName(project)}</span>
                  </span>
                  <Icon name="chevron-right" size="small" class="text-v2-icon-icon-muted" />
                </button>
              )}
            </For>
          </div>
        </Show>
      </div>
    </>
  )
}
