import { Button } from "@opencode/ui-custom/button"
import { useDialog } from "@opencode/ui-custom/context/dialog"
import { DockShell, DockTray } from "@opencode/ui-custom/dock-surface"
import { Icon } from "@opencode/ui-custom/icon"
import { createEffect, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { useServerSDK } from "@/runtime/server/client"
import { useServer } from "@/runtime/server/current"
import type { Project } from "@/runtime/server/types"
import { showToast } from "@/shell/notifications/toast"
import { SessionWorkspaceMenu } from "@/session/timeline/session-workspace-menu"
import { useDirectoryPicker } from "@/workspaces/selection/picker"

export function SessionLocationMissing(props: { sessionID: string; directory: string; project?: Project }) {
  const language = useLanguage()
  const server = useServer()
  const serverSDK = useServerSDK()
  const dialog = useDialog()
  const pickDirectory = useDirectoryPicker()
  const [state, setState] = createStore({ moving: false, restoreFocus: false })
  let button: HTMLButtonElement | undefined

  createEffect(() => {
    if (!state.restoreFocus || state.moving || dialog.active) return
    setState("restoreFocus", false)
    button?.focus()
  })

  const move = (directory: string) => {
    if (state.moving) return
    setState("moving", true)
    void serverSDK.api.session
      .move({ sessionID: props.sessionID, directory })
      .catch((error: unknown) => {
        setState("restoreFocus", true)
        showToast({
          variant: "error",
          title: language.t("workspace.move.failed"),
          description: error instanceof Error ? error.message : language.t("common.requestFailed"),
        })
      })
      .finally(() => setState("moving", false))
  }

  const choose = () => {
    if (state.moving) return
    pickDirectory({
      server: server.conn,
      title: language.t("session.location.choose"),
      onSelect: (result) => {
        const selected = Array.isArray(result) ? result[0] : result
        if (selected) move(selected)
        if (!selected) setState("restoreFocus", true)
      },
    })
  }

  return (
    <div data-component="session-location-missing">
      <DockShell class="flex flex-col gap-2 p-3">
        <div role="status" class="flex items-start gap-2 text-13-regular leading-[var(--line-height-base)]">
          <Icon name="warning" class="shrink-0 text-icon-warning-base" />
          <div class="min-w-0 flex flex-col gap-1">
            <div class="font-medium text-text-strong">{language.t("session.location.unavailable")}</div>
            <div class="break-all font-mono text-12-regular text-text-weak">{props.directory}</div>
            <div class="text-text-base">{language.t("session.location.description")}</div>
          </div>
        </div>
      </DockShell>
      <DockTray attach="top" class="flex flex-wrap justify-end gap-2 p-2 pt-[22px]">
        <Show when={props.project?.vcs === "git" && props.project} keyed>
          {(project) => (
            <SessionWorkspaceMenu
              eligible={!state.moving}
              missing
              variant="neutral"
              sessionID={props.sessionID}
              project={project}
              directory={props.directory}
              placement="top-end"
            >
              {language.t("session.location.worktree")}
            </SessionWorkspaceMenu>
          )}
        </Show>
        <Button
          ref={(element: HTMLButtonElement) => {
            button = element
          }}
          variant="contrast"
          onClick={choose}
          disabled={state.moving}
        >
          {language.t(state.moving ? "session.location.moving" : "session.location.choose")}
        </Button>
      </DockTray>
    </div>
  )
}
