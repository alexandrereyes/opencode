import { Icon } from "@opencode/ui-custom/icon"
import { Menu } from "@opencode/ui-custom/menu"
import { createStore } from "solid-js/store"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection } from "@/runtime/server/registry"
import { displayName } from "@/shell/layout/helpers"
import { ProjectIcon } from "@/shell/layout/project-icon"
import type { LocalProject } from "@/shell/state/layout"
import { useProjectActions } from "@/workspaces/project-actions"

export function SettingsProjectRow(props: {
  project: LocalProject
  server: ServerConnection.Any
  onOpen: (project: LocalProject) => void
}) {
  const language = useLanguage()
  const actions = useProjectActions()
  const [store, setStore] = createStore({ menu: undefined as { x: number; y: number } | undefined })
  let row: HTMLDivElement | undefined
  let button: HTMLButtonElement | undefined
  let outside = false
  let actionSelected = false
  const openMenu = (x: number, y: number) => {
    if (!row) return
    actionSelected = false
    const bounds = row.getBoundingClientRect()
    setStore("menu", { x: x - bounds.left, y: y - bounds.top })
  }

  return (
    <div
      ref={row}
      data-component="settings-project-row"
      data-project-path={props.project.worktree}
      data-server={ServerConnection.key(props.server)}
      class="settings-project-row group"
      onContextMenu={(event) => {
        event.preventDefault()
        openMenu(event.clientX, event.clientY)
      }}
    >
      <button
        ref={button}
        type="button"
        aria-label={displayName(props.project)}
        aria-haspopup="menu"
        aria-expanded={!!store.menu}
        class="settings-project-row-content"
        onClick={() => props.onOpen(props.project)}
        onKeyDown={(event) => {
          if (event.key !== "ContextMenu" && (event.key !== "F10" || !event.shiftKey)) return
          event.preventDefault()
          const bounds = event.currentTarget.getBoundingClientRect()
          openMenu(bounds.left + 12, bounds.bottom)
        }}
      >
        <span class="flex items-start gap-2.5 min-w-0 flex-1">
          <ProjectIcon project={props.project} class="shrink-0" />
          <span class="flex min-w-0 flex-1 flex-col gap-1.5">
            <bdi class="settings-project-row-name truncate">{displayName(props.project)}</bdi>
            <bdi
              dir="ltr"
              class="text-11-regular leading-[var(--line-height-compact)] text-v2-text-text-muted truncate"
              title={props.project.worktree}
            >
              {props.project.worktree}
            </bdi>
          </span>
        </span>
        <Icon
          name="chevron-right"
          size="small"
          class="shrink-0 text-v2-icon-icon-muted opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100"
        />
      </button>
      <Menu
        modal={false}
        placement="bottom-start"
        gutter={2}
        open={!!store.menu}
        onOpenChange={(open) => {
          if (!open) setStore("menu", undefined)
        }}
      >
        <Menu.Trigger
          as="span"
          aria-hidden="true"
          tabIndex={-1}
          class="pointer-events-none absolute size-px"
          style={{ left: `${store.menu?.x ?? 0}px`, top: `${store.menu?.y ?? 0}px` }}
        />
        <Menu.Portal>
          <Menu.Content
            onInteractOutside={() => {
              outside = true
            }}
            onCloseAutoFocus={(event) => {
              event.preventDefault()
              const restore = !outside && !actionSelected
              outside = false
              if (restore) requestAnimationFrame(() => button?.focus())
            }}
          >
            <Menu.Item
              onSelect={() => {
                actionSelected = true
                actions.edit(props.server, props.project)
              }}
            >
              {language.t("common.rename")}
            </Menu.Item>
            <Menu.Separator />
            <Menu.Item
              onSelect={() => {
                actionSelected = true
                const next = row?.nextElementSibling
                const previous = row?.previousElementSibling
                const adjacentRow = next?.matches('[data-component="settings-project-row"]')
                  ? next
                  : previous?.matches('[data-component="settings-project-row"]')
                    ? previous
                    : undefined
                const adjacentPath = adjacentRow?.getAttribute("data-project-path")
                const adjacentServer = adjacentRow?.getAttribute("data-server")
                actions.close(props.server, props.project, displayName(props.project), (outcome) => {
                  const currentAdjacent =
                    adjacentPath && adjacentServer
                      ? [...document.querySelectorAll<HTMLElement>('[data-component="settings-project-row"]')]
                          .find(
                            (item) =>
                              item.dataset.projectPath === adjacentPath && item.dataset.server === adjacentServer,
                          )
                          ?.querySelector<HTMLButtonElement>(":scope > button")
                      : undefined
                  const target = outcome === "confirm" ? currentAdjacent : button
                  if (target?.isConnected) target.focus({ preventScroll: true })
                })
              }}
            >
              {language.t("common.close")}
            </Menu.Item>
          </Menu.Content>
        </Menu.Portal>
      </Menu>
    </div>
  )
}
