import { createMemo, For, Show, type JSX } from "solid-js"
import { createStore } from "solid-js/store"
import { createResizeObserver } from "@solid-primitives/resize-observer"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Menu } from "@opencode/ui-custom/menu"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection } from "@/runtime/server/registry"
import { useGlobal, useServerCtx } from "@/runtime/server/runtime"
import { SessionTabAvatarView } from "@/shell/layout/session-tab-avatar"
import { listClosedTabs, type ClosedTab } from "@/shell/tabs/closed"
import { useTabs } from "@/shell/tabs/tabs"
import { sessionTabTitle } from "./tab-title"

// Sessions that never received a prompt are empty; reopening them is not useful.
function useRecentlyClosedTabs() {
  const tabs = useTabs()
  return createMemo(() => listClosedTabs(tabs.closed, tabs.store).filter((entry) => entry.info?.prompted === true))
}

/** Wraps the new-session control: a click opens a new session, a context menu lists recently closed tabs. */
export function RecentlyClosedTabsMenu(props: {
  onNewTab: () => void
  tooltip?: JSX.Element
  vertical?: boolean
  keybind?: string
}) {
  const language = useLanguage()
  const tabs = useTabs()
  const recent = useRecentlyClosedTabs()

  return (
    <Menu.Context modal={false}>
      <Show
        when={props.vertical}
        fallback={
          <Tooltip placement="bottom" value={props.tooltip}>
            <Menu.Context.Trigger
              as={IconButton}
              type="button"
              variant="ghost-muted"
              size="large"
              class="shrink-0"
              icon={<Icon name="plus" />}
              onClick={props.onNewTab}
              aria-label={language.t("command.session.new")}
            />
          </Tooltip>
        }
      >
        <Menu.Context.Trigger
          as="button"
          type="button"
          data-action="vertical-tabs-new-session"
          class="group flex h-7 w-full shrink-0 items-center gap-1.5 rounded-[6px] ps-1.5 pe-2 text-[13px] leading-4 text-v2-text-text-faint hover:bg-v2-background-bg-layer-02 hover:text-v2-text-text-base"
          onClick={props.onNewTab}
          aria-label={language.t("command.session.new")}
        >
          <Icon name="edit" class="shrink-0" />
          <span class="min-w-0 truncate">{language.t("command.session.new")}</span>
          <span
            class="ms-auto hidden min-w-0 truncate text-v2-text-text-faint group-hover:block group-focus-visible:block"
            aria-hidden="true"
          >
            <bdi dir="ltr">{props.keybind}</bdi>
          </span>
        </Menu.Context.Trigger>
      </Show>
      <Menu.Context.Portal>
        <Menu.Context.Content
          aria-label={language.t("home.recentlyClosed")}
          class="max-h-[66.667dvh] w-56 max-w-56 overflow-y-auto"
        >
          <Menu.Group>
            <Menu.GroupLabel>{language.t("home.recentlyClosed")}</Menu.GroupLabel>
            <For each={recent()}>
              {(entry) => (
                <RecentlyClosedTabItem
                  entry={entry}
                  onSelect={() => tabs.reopenClosedTab(entry.tab, { append: true })}
                />
              )}
            </For>
          </Menu.Group>
        </Menu.Context.Content>
      </Menu.Context.Portal>
    </Menu.Context>
  )
}

/** A touch-reachable button for the phone drawer, shown only while there is something to reopen. */
export function RecentlyClosedTabsButton(props: { onReopen?: () => void }) {
  const language = useLanguage()
  const tabs = useTabs()
  const recent = useRecentlyClosedTabs()
  const [menu, setMenu] = createStore({ open: false })
  // The drawer's dismissal skips a handled Escape, so the key closes only the menu above it.
  const closeOnEscape = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || !menu.open) return
    event.preventDefault()
    setMenu("open", false)
  }

  return (
    <Show when={recent().length > 0}>
      <Menu
        modal={false}
        placement="top-end"
        gutter={4}
        open={menu.open}
        onOpenChange={(open) => setMenu("open", open)}
      >
        <Menu.Trigger
          as={IconButton}
          type="button"
          data-action="mobile-tabs-recently-closed"
          variant="ghost-muted"
          size="normal"
          class="shrink-0"
          icon={<Icon name="history" />}
          aria-label={language.t("home.recentlyClosed")}
          // A touch-opened menu leaves focus on this button inside the drawer.
          onKeyDown={closeOnEscape}
        />
        <Menu.Portal>
          {/* The drawer stays open under the menu, and its rows navigate on press: this backdrop between the drawer
              (z-index 51) and the menu takes the tap that dismisses the menu, so nothing underneath runs. A modal
              menu is not an option, as the drawer would close on it. */}
          <Show when={menu.open}>
            <div
              data-slot="recently-closed-tabs-backdrop"
              aria-hidden="true"
              class="pointer-events-auto fixed inset-0 z-[55]"
              onPointerDown={(event) => event.preventDefault()}
              onClick={() => setMenu("open", false)}
            />
          </Show>
          <Menu.Content
            aria-label={language.t("home.recentlyClosed")}
            class="max-h-[50dvh] w-56 max-w-[calc(100vw-32px)] overflow-y-auto"
            // Kobalte selects on pointerup; keep the compatibility mousedown from reaching the drawer underneath.
            onPointerDown={(event: PointerEvent) => {
              if (event.pointerType === "touch") event.preventDefault()
            }}
            onKeyDown={closeOnEscape}
          >
            <Menu.Group>
              <Menu.GroupLabel>{language.t("home.recentlyClosed")}</Menu.GroupLabel>
              <For each={recent()}>
                {(entry) => (
                  <RecentlyClosedTabItem
                    entry={entry}
                    onSelect={() => {
                      tabs.reopenClosedTab(entry.tab, { append: true })
                      props.onReopen?.()
                    }}
                  />
                )}
              </For>
            </Menu.Group>
          </Menu.Content>
        </Menu.Portal>
      </Menu>
    </Show>
  )
}

function RecentlyClosedTabItem(props: { entry: ClosedTab; onSelect: () => void }) {
  const global = useGlobal()
  const language = useLanguage()
  const [state, setState] = createStore({ truncated: false })
  const placement = language.direction() === "rtl" ? "left-start" : "right-start"
  const serverCtx = useServerCtx(() =>
    global.servers.list().find((item) => ServerConnection.key(item) === props.entry.tab.server),
  )
  const session = createMemo(() => serverCtx()?.data.session.get(props.entry.tab.sessionId))
  const directory = () => props.entry.info?.directory ?? session()?.location.directory ?? ""
  // Chat sessions have no project; the tab strip marks them with the chat icon.
  const project = createMemo(() => {
    const value = session()
    if (!value || props.entry.tab.chat) return
    return serverCtx()?.projects.forSession(value)
  })
  const title = () => sessionTabTitle(session()?.title ?? props.entry.info?.title, language.t("session.tab.session"))

  return (
    <Menu.Item class="max-w-full" onSelect={props.onSelect}>
      <span class="flex size-4 shrink-0 items-center justify-center" aria-hidden="true">
        <SessionTabAvatarView
          project={project()}
          directory={directory()}
          unread={false}
          loading={false}
          icon={props.entry.tab.chat ? <Icon name="speech-bubble" class="text-v2-icon-icon-muted" /> : undefined}
        />
      </span>
      <Tooltip
        placement={placement}
        value={<bdi dir="auto">{title()}</bdi>}
        disabled={!state.truncated}
        class="min-w-0 flex-1"
        contentClass="max-w-[min(480px,calc(100vw-32px))] break-words"
      >
        <span
          ref={(element) =>
            createResizeObserver(element, () => setState("truncated", element.scrollWidth > element.clientWidth))
          }
          dir="auto"
          class="block min-w-0 truncate text-start"
        >
          {title()}
        </span>
      </Tooltip>
    </Menu.Item>
  )
}
