import { createContext, createEffect, createMemo, onCleanup, useContext, type ParentProps } from "solid-js"
import { createStore } from "solid-js/store"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { useLanguage } from "@/runtime/i18n/language"

const actionsWidth = 88
const intentThreshold = 8
const MobileTabsContext = createContext<{
  open: () => boolean
  now: () => number
  revealed: () => string | undefined
  reveal: (key?: string) => void
}>()

export const useMobileTabs = () => useContext(MobileTabsContext)

export function MobileTabProvider(props: ParentProps<{ open: boolean }>) {
  const [state, setState] = createStore({ now: Date.now(), revealed: undefined as string | undefined })
  createEffect(() => {
    if (!props.open) {
      setState("revealed", undefined)
      return
    }
    setState("now", Date.now())
    const timer = window.setInterval(() => setState("now", Date.now()), 60_000)
    onCleanup(() => window.clearInterval(timer))
  })
  return (
    <MobileTabsContext.Provider
      value={{
        open: () => props.open,
        now: () => state.now,
        revealed: () => state.revealed,
        reveal: (key) => setState("revealed", key),
      }}
    >
      {props.children}
    </MobileTabsContext.Provider>
  )
}

export function MobileTabActions(
  props: ParentProps<{
    tabs: NonNullable<ReturnType<typeof useMobileTabs>>
    tabKey: string
    enabled: boolean
    pending: boolean
    onArchive: () => void
    onDelete: () => void
  }>,
) {
  const language = useLanguage()
  const revealed = createMemo(() => props.tabs.open() && props.tabs.revealed() === props.tabKey && props.enabled)
  let root!: HTMLDivElement
  let content!: HTMLDivElement
  let actions!: HTMLDivElement
  let offset = 0
  let suppress = false
  let gesture: { id: number; x: number; y: number; base: number; direction: number; axis?: "x" | "y" } | undefined

  const applyOffset = (value: number, dragging = false) => {
    offset = value
    content.style.setProperty("--mobile-tab-offset", `${value}px`)
    content.dataset.dragging = String(dragging)
  }
  const focusContent = () =>
    content.querySelector<HTMLElement>("[data-titlebar-tab-link]")?.focus({ preventScroll: true })
  const close = () => {
    if (actions.contains(document.activeElement)) focusContent()
    if (props.tabs.revealed() === props.tabKey) props.tabs.reveal()
  }
  createEffect(() => {
    const open = revealed()
    // CSS direction can be overridden independently of the selected language.
    const direction = getComputedStyle(root).direction === "rtl" ? 1 : -1
    if (!open && actions.contains(document.activeElement) && props.tabs.open()) focusContent()
    applyOffset(open ? direction * actionsWidth : 0)
    if (!props.tabs.open()) gesture = undefined
  })
  onCleanup(() => {
    if (props.tabs.revealed() === props.tabKey) props.tabs.reveal()
  })

  const finish = (cancelled: boolean) => {
    const current = gesture
    gesture = undefined
    if (!current) return
    if (cancelled || current.axis) suppress = true
    if (!cancelled && current.axis === "x") {
      if (Math.abs(offset) > actionsWidth / 2) props.tabs.reveal(props.tabKey)
      else close()
    }
    if (!cancelled && !current.axis && revealed()) {
      suppress = true
      focusContent()
      close()
    }
    applyOffset(revealed() ? current.direction * actionsWidth : 0)
  }
  const blockNavigation = (event: MouseEvent) => {
    // TabNavItem navigates on mousedown, including compatibility mouse events
    // after touch. Retain suppression until the next real pointer gesture.
    if (!suppress || (event.type === "click" && event.detail === 0)) return
    event.preventDefault()
    event.stopPropagation()
  }

  return (
    <div
      ref={root}
      data-slot="mobile-tab-swipe"
      data-revealed={revealed()}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || !revealed()) return
        event.preventDefault()
        event.stopPropagation()
        close()
      }}
    >
      <div ref={actions} data-slot="mobile-tab-actions" aria-hidden={!revealed()} inert={!revealed()}>
        <IconButton
          variant="ghost-muted"
          icon={<Icon name="archive" />}
          aria-label={language.t("common.archive")}
          aria-disabled={props.pending}
          tabIndex={revealed() ? 0 : -1}
          onClick={() => {
            if (!props.pending) props.onArchive()
          }}
        />
        <IconButton
          variant="ghost-muted"
          data-action="mobile-tab-delete"
          style={{ color: "var(--v2-state-fg-danger)" }}
          icon={<Icon name="trash" />}
          aria-label={language.t("common.delete")}
          aria-disabled={props.pending}
          tabIndex={revealed() ? 0 : -1}
          onClick={(event) => {
            if (props.pending) return
            event.currentTarget.focus({ preventScroll: true })
            props.onDelete()
          }}
        />
      </div>
      <div
        ref={content}
        data-slot="mobile-tab-content"
        on:mousedown={{ handleEvent: blockNavigation, capture: true }}
        on:click={{ handleEvent: blockNavigation, capture: true }}
        on:pointerdown={{
          capture: true,
          handleEvent: (event: PointerEvent) => {
            // Controls stop propagation, so reset before their handlers run.
            // Compatibility mousedown/click events do not start a new pointer gesture.
            suppress = false
            if (!props.enabled || event.pointerType === "mouse" || !event.isPrimary) return
            if (event.target instanceof Element && event.target.closest('button, [contenteditable="true"]')) return
            gesture = {
              id: event.pointerId,
              x: event.clientX,
              y: event.clientY,
              base: offset,
              direction: getComputedStyle(root).direction === "rtl" ? 1 : -1,
            }
          },
        }}
        onPointerMove={(event) => {
          if (!gesture || gesture.id !== event.pointerId) return
          const dx = event.clientX - gesture.x
          const dy = event.clientY - gesture.y
          if (!gesture.axis) {
            if (Math.max(Math.abs(dx), Math.abs(dy)) < intentThreshold) return
            gesture.axis = Math.abs(dx) > Math.abs(dy) ? "x" : "y"
            suppress = true
          }
          if (gesture.axis !== "x") return
          content.setPointerCapture(event.pointerId)
          const distance = Math.max(
            0,
            Math.min(actionsWidth, gesture.base * gesture.direction + dx * gesture.direction),
          )
          applyOffset(distance * gesture.direction, true)
        }}
        onPointerUp={() => finish(false)}
        onPointerCancel={() => finish(true)}
      >
        {props.children}
      </div>
    </div>
  )
}
