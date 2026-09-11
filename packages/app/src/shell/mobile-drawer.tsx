import Drawer from "@corvu/drawer"
import { createEffect, onCleanup, type ParentProps } from "solid-js"
import { useLanguage } from "@/runtime/i18n/language"
import "./mobile-drawer.css"

export function MobileDrawer(
  props: ParentProps<{
    open: boolean
    onOpenChange: (open: boolean) => void
    onContentPresentChange?: (present: boolean) => void
    returnFocus?: () => HTMLElement | undefined
    closeOnOutsideFocus?: boolean
    suspended?: boolean
  }>,
) {
  let focus: HTMLElement | undefined
  createEffect(() => {
    if (!props.open) {
      focus = undefined
      return
    }
    // Remember focus before a portaled dialog takes it, not when suspension renders.
    const rememberFocus = (event: FocusEvent) => {
      if (props.suspended) return
      const active = event.target
      if (active instanceof HTMLElement && active.closest('[data-slot="mobile-drawer-content"]')) focus = active
    }
    document.addEventListener("focusin", rememberFocus)
    onCleanup(() => document.removeEventListener("focusin", rememberFocus))
  })
  return (
    <Drawer
      open={props.open}
      onOpenChange={props.onOpenChange}
      onContentPresentChange={props.onContentPresentChange}
      side="bottom"
      finalFocusEl={props.returnFocus?.()}
      closeOnOutsideFocus={props.suspended ? false : props.closeOnOutsideFocus}
      closeOnOutsidePointer={!props.suspended}
      closeOnEscapeKeyDown={!props.suspended}
      trapFocus={!props.suspended}
      noOutsidePointerEvents={!props.suspended}
      onInitialFocus={(event) => {
        if (!focus?.isConnected) return
        event.preventDefault()
        focus.focus({ preventScroll: true })
      }}
    >
      {props.children}
    </Drawer>
  )
}

export const MobileDrawerTrigger = Drawer.Trigger

export function MobileDrawerContent(props: ParentProps<{ suspended?: boolean }>) {
  const language = useLanguage()
  return (
    <Drawer.Portal forceMount>
      <Drawer.Overlay data-slot="mobile-drawer-overlay" data-suspended={props.suspended || undefined} />
      <Drawer.Content
        forceMount
        data-slot="mobile-drawer-content"
        data-suspended={props.suspended || undefined}
        dir={language.direction()}
      >
        <div data-slot="mobile-drawer-handle" aria-hidden="true">
          <span />
        </div>
        {props.children}
      </Drawer.Content>
    </Drawer.Portal>
  )
}

export const MobileDrawerLabel = Drawer.Label
export const MobileDrawerClose = Drawer.Close
