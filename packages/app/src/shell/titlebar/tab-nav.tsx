import { createEffect, createMemo, createSignal, onCleanup, Show, type Ref } from "solid-js"
import { createStore } from "solid-js/store"
import { makeEventListener } from "@solid-primitives/event-listener"
import { createResizeObserver } from "@solid-primitives/resize-observer"
import { createMutation } from "@tanstack/solid-query"
import { IconButton } from "@opencode/ui/icon-button"
import { Icon } from "@opencode/ui/icon"
import { Checkbox } from "@opencode/ui/checkbox"
import { Menu } from "@opencode/ui/menu"
import { useServerCtx } from "@/runtime/server/runtime"
import { useLanguage } from "@/runtime/i18n/language"
import { ServerConnection, serverName, useServers } from "@/runtime/server/registry"
import { displayName, projectForSession } from "@/shell/layout/helpers"
import { SessionTabAvatar } from "@/shell/layout/session-tab-avatar"
import { SessionProgressIndicatorV2 } from "@opencode/session-ui/v2/session-progress-indicator-v2"
import type { SessionInfo } from "@opencode/client/promise"
import { sessionTabTitle } from "./tab-title"
import { useSettings } from "@/settings/model"
import { canOpenTabRename, forwardTabRef } from "./tab-gesture"
import { TabPreviewPopover } from "./tab-popover"
import { useSessionLifecycleActions } from "@/session/lifecycle-actions"
import { MobileTabActions, useMobileTabs } from "./mobile-tab-actions"
import { tabKey } from "@/shell/tabs/tabs"
import { getRelativeTime } from "@/shell/time"
import "./tab-nav.css"

// MouseEvent.button uses 1 for the middle/wheel button.
const MIDDLE_MOUSE_BUTTON = 1

export function TabNavItem(props: {
  ref?: Ref<HTMLDivElement>
  href: string
  server: ServerConnection.Key
  session: SessionInfo | undefined
  preparing: boolean
  fallbackTitle?: string
  onRename: (title: string) => Promise<void>
  onClose: () => void
  onNavigate: () => void
  active?: boolean
  unread?: boolean
  suppressNavigation?: boolean
  dragging?: boolean
  pressed?: boolean
  hidden?: boolean
  orientation?: "horizontal" | "vertical"
  projectLabel?: string
  compact?: boolean
  timestamp?: { dateTime: string; title: string; label: string }
  closable?: boolean
  pinned?: boolean
  onTogglePin?: () => void
  selectionMode?: boolean
  selected?: boolean
  selectionPending?: boolean
  onActivate?: (event: MouseEvent | KeyboardEvent) => boolean
}) {
  const language = useLanguage()
  const settings = useSettings()
  const lifecycle = useSessionLifecycleActions()
  const mobileTabs = useMobileTabs()
  const [menu, setMenu] = createStore({ open: false, actions: false, rename: false, delete: false })
  const [editing, setEditing] = createSignal(false)
  const [titleOverflowing, setTitleOverflowing] = createSignal(false)
  let tabRoot!: HTMLDivElement
  let titleEl!: HTMLSpanElement
  let measureFrame: number | undefined
  const rename = createMutation(() => ({ mutationFn: props.onRename }))
  const gesture = { selected: false, checkbox: undefined as MouseEvent | KeyboardEvent | undefined }
  const lifecyclePending = () => lifecycle.pending() || props.selectionPending

  const closeTab = (event: MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    if (props.closable !== false) props.onClose()
  }
  const servers = useServers()
  const serverCtx = useServerCtx(() => servers.list.find((item) => ServerConnection.key(item) === props.server))
  const project = createMemo(() => {
    const session = props.session
    if (!session) return
    return projectForSession(session, serverCtx()?.projects.list() ?? [])
  })
  const title = createMemo(() => {
    const session = props.session
    return sessionTabTitle(session ? session.title : props.fallbackTitle, language.t("session.tab.session"))
  })

  const projectName = createMemo(() => {
    const session = props.session
    if (!session) return
    return displayName(project() ?? { worktree: session.location.directory })
  })
  const previewPath = createMemo(() => {
    const session = props.session
    if (!session) return
    const home = serverCtx()?.sync.data.path.home
    return home ? session.location.directory.replace(home, "~") : session.location.directory
  })
  // Only label the server when multiple servers are connected.
  const serverLabel = createMemo(() => {
    if (servers.list.length <= 1) return
    const conn = servers.list.find((item) => ServerConnection.key(item) === props.server)
    return conn ? serverName(conn) : undefined
  })

  const [popoverOpen, setPopoverOpen] = createSignal(false)
  const previewBlocked = () =>
    !!props.dragging ||
    editing() ||
    menu.open ||
    menu.actions ||
    !!props.pressed ||
    !!props.selectionMode ||
    !props.session

  const measureTitleOverflow = () => {
    if (!titleEl || editing()) {
      setTitleOverflowing(false)
      return
    }
    setTitleOverflowing(titleEl.scrollWidth > titleEl.clientWidth)
  }

  const scheduleTitleOverflow = () => {
    if (measureFrame !== undefined) return
    measureFrame = requestAnimationFrame(() => {
      measureFrame = undefined
      measureTitleOverflow()
    })
  }

  createEffect(() => {
    title()
    props.active
    props.orientation
    editing()
    scheduleTitleOverflow()
  })

  // The overflow fade changes title padding; observe the stable tab box, not that feedback.
  createResizeObserver(() => tabRoot, scheduleTitleOverflow)
  onCleanup(() => {
    if (measureFrame !== undefined) cancelAnimationFrame(measureFrame)
  })

  const selectTitle = () => {
    const range = document.createRange()
    range.selectNodeContents(titleEl)
    const selection = window.getSelection()
    selection?.removeAllRanges()
    selection?.addRange(range)
  }

  const closeRename = async (save: boolean) => {
    if (rename.isPending || !editing()) return

    const original = props.session?.title ?? ""
    const next = (titleEl.textContent ?? "").trim()

    titleEl.scrollLeft = 0
    setEditing(false)

    if (!save || !next || next === original) {
      return
    }

    await rename.mutateAsync(next)
  }

  createEffect(() => {
    if (editing()) return
    if (!titleEl) return
    const value = title()
    if (value === undefined) return
    titleEl.textContent = value
  })

  const openRename = (event?: MouseEvent) => {
    event?.preventDefault()
    event?.stopPropagation()
    if (!canOpenTabRename(props.dragging, editing(), rename.isPending)) return
    const session = props.session
    if (!session) return
    titleEl.textContent = session.title ?? ""
    setEditing(true)

    requestAnimationFrame(() => {
      titleEl.focus()
      selectTitle()
    })
  }

  createEffect(() => {
    if (!editing()) return

    const cleanup = makeEventListener(
      document,
      "pointerdown",
      (event) => {
        const target = event.target
        if (!(target instanceof Node)) return
        if (tabRoot.contains(target)) return
        void closeRename(true)
      },
      { capture: true },
    )

    onCleanup(cleanup)
  })

  const preventMenuTouchMouse = (event: PointerEvent) => {
    // Kobalte selects on pointerup. Suppress the compatibility mousedown that
    // can hit a different session after the portaled menu has already closed.
    if (mobileTabs && event.pointerType === "touch") event.preventDefault()
  }
  const closeMenu = (event: Event) => {
    if (menu.rename) {
      event.preventDefault()
      setMenu("rename", false)
      openRename()
    }
    if (menu.delete && props.session) {
      event.preventDefault()
      setMenu("delete", false)
      if (!lifecyclePending()) void lifecycle.showDelete(props.server, props.session)
    }
  }
  const menuItems = () => (
    <>
      <Show when={props.onTogglePin}>
        <Menu.Item disabled={!props.session} onSelect={() => props.onTogglePin?.()}>
          {language.t(props.pinned ? "sidebar.session.unpin" : "sidebar.session.pin")}
        </Menu.Item>
      </Show>
      <Menu.Item disabled={!props.session || rename.isPending} onSelect={() => setMenu("rename", true)}>
        {language.t("common.rename")}
      </Menu.Item>
      <Show when={props.closable !== false}>
        <Menu.Item onSelect={props.onClose}>{language.t("common.closeTab")}</Menu.Item>
      </Show>
      <Menu.Separator />
      <Menu.Item
        disabled={!props.session || lifecyclePending()}
        onSelect={() => {
          if (props.session && !lifecyclePending()) void lifecycle.archive(props.server, props.session)
        }}
      >
        {language.t("common.archive")}
      </Menu.Item>
      <Menu.Item
        disabled={!props.session || lifecyclePending()}
        onSelect={() => {
          if (!lifecyclePending()) setMenu("delete", true)
        }}
      >
        {language.t("common.delete")}…
      </Menu.Item>
    </>
  )

  const tab = () => (
    <div
      ref={(el) => {
        tabRoot = el
        forwardTabRef(props.ref, el)
      }}
      data-titlebar-tab
      data-slot="titlebar-tab-item"
      data-orientation={props.orientation ?? "horizontal"}
      data-sidebar-time={props.orientation === "vertical" && props.timestamp ? "" : undefined}
      data-title-overflow={titleOverflowing()}
      data-editing={editing()}
      data-session-actions
      class="group relative flex h-7 w-full min-w-0 select-none flex-row items-center gap-1.5 overflow-hidden whitespace-nowrap rounded-[6px] px-1.5 [container-type:inline-size]"
      classList={{ invisible: props.hidden }}
      data-active={props.active}
      data-selected={props.selected}
      data-dragging={props.dragging}
      data-state={props.active || props.pressed || props.selected ? "pressed" : undefined}
      onMouseDown={(event) => {
        if (event.button !== MIDDLE_MOUSE_BUTTON) return
        event.preventDefault()
        event.stopPropagation()
      }}
      onAuxClick={(event) => {
        if (event.button !== MIDDLE_MOUSE_BUTTON) return
        closeTab(event)
      }}
    >
      <Show when={props.selectionMode}>
        <Checkbox
          ref={(element: HTMLDivElement) => {
            // Kobalte's onChange exposes only checked; capture the originating gesture before it toggles.
            makeEventListener(
              element,
              "click",
              (event) => {
                gesture.checkbox = event
              },
              { capture: true },
            )
            makeEventListener(
              element,
              "keydown",
              (event) => {
                gesture.checkbox = event
              },
              { capture: true },
            )
          }}
          checked={props.selected}
          disabled={props.selectionPending}
          hideLabel
          onChange={() => {
            const event = gesture.checkbox
            gesture.checkbox = undefined
            if (event) props.onActivate?.(event)
          }}
        >
          {language.t("sidebar.selection.session", { name: title() ?? "" })}
        </Checkbox>
      </Show>
      <Show when={props.pinned}>
        <span
          data-slot="tab-pin"
          role="img"
          aria-label={language.t("sidebar.session.pinned")}
          title={language.t("sidebar.session.pinned")}
          class="flex shrink-0 items-center text-v2-icon-icon-muted"
        >
          <Icon name="pin" size="small" />
        </span>
      </Show>
      <Menu.Context.Trigger
        as="a"
        disabled={editing() || props.dragging}
        aria-haspopup="menu"
        aria-expanded={menu.open}
        data-slot="tab-link"
        data-titlebar-tab-link
        href={props.href}
        draggable={false}
        onPointerDown={(event) => {
          gesture.selected = false
          if (event.button !== 0 || editing()) return
          gesture.selected = props.onActivate?.(event) ?? false
          if (gesture.selected) event.currentTarget.focus()
        }}
        onKeyDown={(event) => {
          if (event.key !== " " || !props.selectionMode || editing()) return
          props.onActivate?.(event)
        }}
        onDragStart={(event) => {
          event.preventDefault()
          event.stopPropagation()
        }}
        onMouseDown={(event) => {
          // Navigate on mousedown to shave the press-release delay off tab switches.
          if (event.button !== 0) return
          if (editing()) return
          if (gesture.selected || props.onActivate?.(event)) return
          if (props.suppressNavigation) return
          props.onNavigate()
        }}
        onClick={(event) => {
          event.preventDefault()
          // Mouse navigation already happened on mousedown; detail 0 means keyboard activation.
          if (event.detail > 0) return
          if (editing()) return
          if (props.onActivate?.(event)) return
          if (props.suppressNavigation) return
          props.onNavigate()
        }}
        class="flex h-full min-w-0 flex-1 flex-row items-center gap-1.5 text-[13px] font-medium text-v2-text-text-faint group-data-[active='true']:text-v2-text-text-base group-data-[editing='true']:text-v2-text-text-base [-webkit-user-drag:none]"
      >
        <span data-slot="project-avatar-slot" class="flex size-4 shrink-0 items-center justify-center">
          <Show
            when={props.session}
            keyed
            fallback={
              <Show
                when={props.preparing}
                fallback={
                  <span class="block size-4 rounded-[3px] border border-v2-border-border-muted" aria-hidden="true" />
                }
              >
                <SessionProgressIndicatorV2 />
              </Show>
            }
          >
            {(session) => (
              <SessionTabAvatar
                project={project()}
                directory={session.location.directory}
                sessionId={session.id}
                server={props.server}
                unread={props.unread}
              />
            )}
          </Show>
        </span>
        <span
          ref={(el) => {
            titleEl = el
            titleEl.textContent = title() ?? ""
          }}
          data-slot="tab-title"
          data-titlebar-tab-title
          dir="auto"
          class="min-w-0 flex-1 outline-none leading-4"
          classList={{
            "overflow-hidden text-clip whitespace-nowrap": !editing(),
            "select-text": editing(),
          }}
          contenteditable={editing() ? true : undefined}
          onDblClick={(event) => {
            if (!props.selectionMode) openRename(event)
          }}
          onKeyDown={(event) => {
            event.stopPropagation()
            if (event.key === "Enter") {
              event.preventDefault()
              void closeRename(true)
              return
            }
            if (event.key !== "Escape") return
            event.preventDefault()
            titleEl.textContent = props.session?.title ?? ""
            void closeRename(false)
          }}
          onBlur={() => void closeRename(true)}
          onPointerDown={(event) => {
            if (!editing()) return
            event.stopPropagation()
          }}
          onClick={(event) => {
            if (!editing()) return
            event.preventDefault()
          }}
        />
        <Show
          when={
            !props.compact &&
            props.orientation === "vertical" &&
            (props.projectLabel ?? (settings.appearance.showProjectName() && projectName()))
          }
        >
          {(name) => (
            <span data-slot="tab-project" dir="auto">
              {name()}
            </span>
          )}
        </Show>
        <Show when={props.orientation === "vertical" && props.timestamp}>
          {(timestamp) => (
            <time
              data-slot="tab-time"
              dir="auto"
              dateTime={timestamp().dateTime}
              title={timestamp().title}
              aria-label={timestamp().title}
            >
              {timestamp().label}
            </time>
          )}
        </Show>
        <Show when={mobileTabs && props.session}>
          {(session) => (
            <time
              data-slot="mobile-tab-time"
              dir="auto"
              dateTime={new Date(session().time.updated ?? session().time.created).toISOString()}
            >
              {getRelativeTime(session().time.updated ?? session().time.created, language.t, mobileTabs?.now())}
            </time>
          )}
        </Show>
      </Menu.Context.Trigger>

      <div data-slot="tab-close">
        <Menu open={menu.actions} onOpenChange={(open) => setMenu("actions", open)} placement="bottom-end">
          <Menu.Trigger
            as={IconButton}
            size="small"
            variant="ghost-muted"
            class="hover-reveal group-hover:opacity-100 group-focus-within:opacity-100 group-data-[active=true]:opacity-100"
            icon={<Icon name="outline-dots" />}
            aria-label={language.t("common.moreOptions")}
            disabled={props.dragging}
            onPointerDown={(event: PointerEvent) => event.stopPropagation()}
            onClick={(event: MouseEvent) => event.stopPropagation()}
          />
          <Menu.Portal>
            <Menu.Content onPointerDown={preventMenuTouchMouse} onCloseAutoFocus={closeMenu}>
              {menuItems()}
            </Menu.Content>
          </Menu.Portal>
        </Menu>
        <Show when={props.closable !== false}>
          <IconButton
            size="small"
            variant="ghost-muted"
            class="hover-reveal relative z-10 group-hover:opacity-100 group-data-[active=true]:opacity-100 group-data-[editing=true]:opacity-100"
            onPointerDown={(event) => {
              event.preventDefault()
              event.stopPropagation()
            }}
            onClick={closeTab}
            icon={<Icon name="xmark-small" />}
            aria-label={language.t("common.closeTab")}
          />
        </Show>
      </div>
    </div>
  )

  return (
    <Menu.Context
      onOpenChange={(open) => {
        setMenu("open", open)
        if (open) setPopoverOpen(false)
      }}
    >
      <TabPreviewPopover
        trigger={
          mobileTabs ? (
            <MobileTabActions
              tabs={mobileTabs}
              tabKey={
                props.session
                  ? tabKey({ type: "session", server: props.server, sessionId: props.session.id })
                  : props.href
              }
              enabled={!!props.session && !props.preparing}
              pending={lifecycle.pending()}
              onArchive={() => {
                if (props.session) void lifecycle.archive(props.server, props.session)
              }}
              onDelete={() => {
                if (props.session) void lifecycle.showDelete(props.server, props.session)
              }}
            >
              {tab()}
            </MobileTabActions>
          ) : (
            tab()
          )
        }
        orientation={props.orientation}
        open={popoverOpen() && !previewBlocked()}
        onOpenChange={(value) => {
          if (value && previewBlocked()) return
          setPopoverOpen(value)
        }}
        data={{
          projectName: projectName(),
          title: props.session?.title,
          path: previewPath(),
          serverName: serverLabel(),
        }}
      />
      <Menu.Context.Portal>
        <Menu.Context.Content onPointerDown={preventMenuTouchMouse} onCloseAutoFocus={closeMenu}>
          {menuItems()}
        </Menu.Context.Content>
      </Menu.Context.Portal>
    </Menu.Context>
  )
}

export function DraftTabItem(props: {
  ref?: Ref<HTMLDivElement>
  href: string
  title: string
  active?: boolean
  onNavigate: () => void
  onClose: () => void
  suppressNavigation?: boolean
  dragging?: boolean
  pressed?: boolean
  hidden?: boolean
  orientation?: "horizontal" | "vertical"
}) {
  const language = useLanguage()
  const closeTab = (event: MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    props.onClose()
  }
  return (
    <div
      ref={(el) => forwardTabRef(props.ref, el)}
      data-titlebar-tab
      data-slot="titlebar-tab-item"
      data-orientation={props.orientation ?? "horizontal"}
      data-active={props.active}
      data-dragging={props.dragging}
      data-state={props.active || props.pressed ? "pressed" : undefined}
      class="group relative flex h-7 w-full min-w-0 flex-row items-center gap-1.5 overflow-hidden rounded-[6px] px-1.5 [container-type:inline-size] whitespace-nowrap"
      classList={{ invisible: props.hidden }}
      onMouseDown={(event) => {
        if (event.button !== MIDDLE_MOUSE_BUTTON) return
        event.preventDefault()
        event.stopPropagation()
      }}
      onAuxClick={(event) => {
        if (event.button !== MIDDLE_MOUSE_BUTTON) return
        closeTab(event)
      }}
    >
      <a
        data-slot="tab-link"
        data-titlebar-tab-link
        href={props.href}
        draggable={false}
        onDragStart={(event) => {
          event.preventDefault()
          event.stopPropagation()
        }}
        onMouseDown={(event) => {
          // Navigate on mousedown to shave the press-release delay off tab switches.
          if (event.button !== 0) return
          if (props.suppressNavigation) return
          props.onNavigate()
        }}
        onClick={(event) => {
          event.preventDefault()
          // Mouse navigation already happened on mousedown; detail 0 means keyboard activation.
          if (event.detail > 0) return
          if (props.suppressNavigation) return
          props.onNavigate()
        }}
        class="flex h-full min-w-0 flex-1 flex-row items-center gap-1.5 text-[13px] font-medium text-v2-text-text-faint group-data-[active='true']:text-v2-text-text-base [-webkit-user-drag:none]"
      >
        <span class="flex size-4 shrink-0 items-center justify-center">
          <svg
            class="text-v2-icon-icon-muted group-data-[active='true']:text-v2-icon-icon-base"
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
            aria-hidden="true"
          >
            <path
              d="M9.00002 13.5H14M2.60419 10.9167V13.3958H5.08335L13.3959 5.08333L10.9167 2.60416L2.60419 10.9167Z"
              stroke="currentColor"
            />
          </svg>
        </span>
        <span
          data-titlebar-tab-title
          class="min-w-0 flex-1 overflow-hidden text-clip whitespace-nowrap outline-none leading-4"
        >
          {props.title}
        </span>
      </a>
      <div data-slot="tab-close">
        <IconButton
          size="small"
          variant="ghost-muted"
          onPointerDown={(event) => {
            event.preventDefault()
            event.stopPropagation()
          }}
          onMouseDown={(event) => {
            event.preventDefault()
            event.stopPropagation()
          }}
          class="hover-reveal relative z-10 group-hover:opacity-100 group-data-[active=true]:opacity-100 group-data-[editing=true]:opacity-100"
          onClick={closeTab}
          icon={<Icon name="xmark-small" />}
          aria-label={language.t("common.closeTab")}
        />
      </div>
    </div>
  )
}
