import { createEffect, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import { makeEventListener } from "@solid-primitives/event-listener"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { useLanguage } from "@/runtime/i18n/language"

export function SessionDeleteButton(props: {
  size?: "small"
  disabled?: boolean
  tabIndex?: number
  "data-action"?: string
  onConfirm: () => void
}) {
  const language = useLanguage()
  const [state, setState] = createStore({ confirming: false })
  let button!: HTMLButtonElement
  const label = () => language.t(state.confirming ? "session.delete.confirmAction" : "common.delete")
  createEffect(() => {
    if (props.disabled || props.tabIndex === -1) setState("confirming", false)
    if (!state.confirming) return
    onCleanup(
      makeEventListener(
        document,
        "pointerdown",
        (event) => {
          if (event.target instanceof Node && !button.contains(event.target)) setState("confirming", false)
        },
        { capture: true },
      ),
    )
  })
  return (
    <IconButton
      ref={button}
      size={props.size}
      variant="ghost-muted"
      data-action={props["data-action"]}
      disabled={props.disabled}
      aria-disabled={props.disabled}
      tabIndex={props.tabIndex}
      icon={<Icon name="trash" />}
      style={{
        color: "var(--v2-state-fg-danger)",
        "background-color": state.confirming ? "var(--v2-state-bg-danger)" : undefined,
      }}
      aria-label={label()}
      title={label()}
      onBlur={() => setState("confirming", false)}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || !state.confirming) return
        event.preventDefault()
        event.stopPropagation()
        setState("confirming", false)
      }}
      on:click={(event) => {
        event.preventDefault()
        event.stopPropagation()
        if (props.disabled) return
        event.currentTarget.focus({ preventScroll: true })
        if (!state.confirming) {
          setState("confirming", true)
          return
        }
        setState("confirming", false)
        props.onConfirm()
      }}
    />
  )
}
