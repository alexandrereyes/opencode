import { createEffect, createUniqueId, onCleanup, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Icon } from "@opencode/ui-custom/icon"
import { useI18n } from "@opencode/ui-custom/context/i18n"
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
  const toggleable = () => state.truncated || open()
  const toggle = () => {
    const next = !open()
    setState("open", next)
    props.onOpenChange?.(next)
  }
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
      <div
        data-slot="user-message-quote-source"
        role={toggleable() ? "button" : undefined}
        tabIndex={toggleable() ? 0 : undefined}
        aria-expanded={toggleable() ? open() : undefined}
        aria-controls={toggleable() ? id : undefined}
        aria-describedby={toggleable() ? id : undefined}
        aria-label={toggleable() ? i18n.t(open() ? "ui.message.quote.collapse" : "ui.message.quote.expand") : undefined}
        onClick={(event) => {
          if (!toggleable() || window.getSelection()?.toString()) return
          event.stopPropagation()
          toggle()
        }}
        onKeyDown={(event) => {
          if (event.target !== event.currentTarget || !toggleable()) return
          if (event.key !== "Enter" && event.key !== " ") return
          event.preventDefault()
          event.stopPropagation()
          toggle()
        }}
      >
        <div data-slot="user-message-quote-caption">
          <Icon name="speech-bubble" size="small" />
          <span>{i18n.t("ui.message.quote.caption")}</span>
        </div>
        <blockquote ref={text} id={id} dir="auto" data-expanded={open() ? "true" : "false"}>
          {props.quote.text}
        </blockquote>
      </div>
      <Show when={props.quote.comment.trim()}>
        <div data-slot="user-message-quote-comment" dir="auto">
          {props.quote.comment}
        </div>
      </Show>
    </div>
  )
}

/** One-line quote row shown while the whole message is collapsed. */
export function UserMessageQuotePreview(props: { quote: SessionUserQuote }) {
  const i18n = useI18n()
  return (
    <div data-slot="user-message-quote-preview">
      <Icon name="speech-bubble" size="small" />
      <span data-slot="user-message-quote-preview-line">
        <span data-slot="user-message-quote-preview-label">{i18n.t("ui.message.quote.previewLabel")}</span>{" "}
        <bdi dir="auto">{props.quote.comment.trim() || props.quote.text}</bdi>
      </span>
    </div>
  )
}
