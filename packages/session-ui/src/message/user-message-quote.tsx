import { createEffect, createUniqueId, onCleanup, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Button } from "@opencode/ui/button"
import { Icon } from "@opencode/ui/icon"
import { useI18n } from "@opencode/ui/context/i18n"
import type { SessionUserQuote } from "../actions"
import "./user-message-quote.css"

export function UserMessageQuote(props: {
  quote: SessionUserQuote
  open?: boolean
  onOpenChange?: (open: boolean) => void
}) {
  const i18n = useI18n()
  const id = createUniqueId()
  const [state, setState] = createStore({ open: false, truncated: false })
  const open = () => props.open ?? state.open
  let text!: HTMLQuoteElement

  createEffect(() => {
    props.quote.text
    const measure = () => {
      if (!text.clientWidth) return
      setState("truncated", text.scrollHeight > parseFloat(getComputedStyle(text).lineHeight) * 4 + 1)
    }
    const observer = new ResizeObserver(measure)
    observer.observe(text)
    measure()
    onCleanup(() => observer.disconnect())
  })

  return (
    <div data-component="user-message-quote">
      <div data-slot="user-message-quote-caption">
        <Icon name="speech-bubble" size="small" />
        <span>{i18n.t("ui.message.quote.caption")}</span>
      </div>
      <blockquote ref={text} id={id} dir="auto" data-expanded={open() ? "true" : "false"}>
        {props.quote.text}
      </blockquote>
      <Show when={state.truncated || open()}>
        <Button
          size="small"
          variant="ghost-muted"
          data-slot="user-message-quote-toggle"
          aria-expanded={open()}
          aria-controls={id}
          onClick={(event: MouseEvent) => {
            event.stopPropagation()
            const next = !open()
            setState("open", next)
            props.onOpenChange?.(next)
          }}
        >
          {i18n.t(open() ? "ui.message.quote.collapse" : "ui.message.quote.expand")}
        </Button>
      </Show>
      <Show when={props.quote.comment.trim()}>
        <div data-slot="user-message-quote-comment" dir="auto">
          {props.quote.comment}
        </div>
      </Show>
    </div>
  )
}
