import { Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { Menu } from "@opencode/ui/menu"
import { Tooltip } from "@opencode/ui/tooltip"
import { useLanguage } from "@/runtime/i18n/language"
import { usePlatform } from "@/runtime/platform/platform"
import type { ServerConnection } from "@/runtime/server/registry"
import type { LocalProject } from "@/shell/state/layout"
import { useProjectActions } from "@/workspaces/project-actions"
import { fileManagerApp } from "@/home/projects/file-manager"

export function SidebarProjectActions(props: {
  connection: ServerConnection.Any
  directory: string
  metadata?: LocalProject
}) {
  const language = useLanguage()
  const platform = usePlatform()
  const actions = useProjectActions()
  const [state, setState] = createStore({ open: false })
  const newSession = () => actions.openNewSession(props.connection, props.directory)
  return (
    <div
      data-slot="sidebar-project-actions"
      data-menu={state.open}
      class="hover-reveal me-1 flex shrink-0 items-center gap-1 group-hover/project:opacity-100 group-focus-within/project:opacity-100 data-[menu=true]:opacity-100"
    >
      <Tooltip value={language.t("command.session.new")}>
        <IconButton
          data-action="sidebar-project-new-session"
          variant="ghost-muted"
          size="small"
          icon={<Icon name="edit" />}
          aria-label={language.t("command.session.new")}
          onClick={newSession}
        />
      </Tooltip>
      <Menu
        modal={false}
        placement="bottom-end"
        gutter={6}
        open={state.open}
        onOpenChange={(open) => setState("open", open)}
      >
        <Menu.Trigger
          as={IconButton}
          data-action="sidebar-project-menu"
          variant="ghost-muted"
          size="small"
          icon={<Icon name="outline-dots" />}
          aria-label={language.t("common.moreOptions")}
        />
        <Menu.Portal>
          <Menu.Content>
            <Menu.Item onSelect={newSession}>{language.t("command.session.new")}</Menu.Item>
            <Show when={actions.canImportSession}>
              <Menu.Item onSelect={() => actions.importSession(props.connection, { worktree: props.directory })}>
                {language.t("command.session.import")}
              </Menu.Item>
            </Show>
            <Show when={props.metadata?.id && props.metadata.id !== "global" ? props.metadata : undefined}>
              {(project) => (
                <Menu.Item onSelect={() => actions.edit(props.connection, project())}>
                  {language.t("dialog.project.edit.title")}
                </Menu.Item>
              )}
            </Show>
            <Show when={actions.canReveal(props.connection)}>
              <Menu.Item onSelect={() => actions.reveal(props.connection, { worktree: props.directory })}>
                {language.t(
                  fileManagerApp(platform.platform === "desktop" ? (platform.os ?? "unknown") : "unknown").actionLabel,
                )}
              </Menu.Item>
            </Show>
          </Menu.Content>
        </Menu.Portal>
      </Menu>
    </div>
  )
}
