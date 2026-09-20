import { Show } from "solid-js"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { useLanguage } from "@/runtime/i18n/language"
import type { ServerConnection } from "@/runtime/server/registry"
import type { LocalProject } from "@/shell/state/layout"
import { useProjectActions } from "@/workspaces/project-actions"

export function SidebarProjectActions(props: {
  connection: ServerConnection.Any
  directory: string
  name: string
  metadata?: LocalProject
}) {
  const language = useLanguage()
  const actions = useProjectActions()
  const newSession = () => actions.openNewSession(props.connection, props.directory)
  return (
    <div
      data-slot="sidebar-project-actions"
      class="hover-reveal me-1 flex shrink-0 items-center gap-1 group-hover/project:opacity-100 group-focus-within/project:opacity-100"
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
      <Show when={props.metadata?.id && props.metadata.id !== "global" ? props.metadata : undefined}>
        {(project) => (
          <Tooltip value={language.t("dialog.project.edit.title")}>
            <IconButton
              data-action="sidebar-project-edit"
              variant="ghost-muted"
              size="small"
              icon={<Icon name="settings-gear" />}
              aria-label={language.t("dialog.project.edit.title")}
              onClick={() => actions.edit(props.connection, project())}
            />
          </Tooltip>
        )}
      </Show>
      <Tooltip value={language.t("sidebar.project.remove")}>
        <IconButton
          data-action="sidebar-project-remove"
          variant="ghost-muted"
          size="small"
          icon={<Icon name="trash" />}
          style={{ color: "var(--v2-state-fg-danger)" }}
          aria-label={language.t("sidebar.project.remove")}
          onClick={() => actions.close(props.connection, { worktree: props.directory }, props.name)}
        />
      </Tooltip>
    </div>
  )
}

export function SidebarWorktreeNewSession(props: {
  connection: ServerConnection.Any
  directory: string
  projectDirectory: string
  name: string
}) {
  const language = useLanguage()
  const actions = useProjectActions()
  return (
    <Tooltip value={language.t("sidebar.worktree.newSession", { worktree: props.name })}>
      <IconButton
        data-action="sidebar-worktree-new-session"
        variant="ghost-muted"
        size="small"
        class="hover-reveal me-1 shrink-0 group-hover/worktree:opacity-100 group-focus-within/worktree:opacity-100"
        icon={<Icon name="plus" />}
        aria-label={language.t("sidebar.worktree.newSession", { worktree: props.name })}
        onClick={() => actions.openNewSession(props.connection, props.directory, props.projectDirectory)}
      />
    </Tooltip>
  )
}
