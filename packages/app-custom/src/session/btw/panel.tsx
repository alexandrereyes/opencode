import { createEffect, onCleanup, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Button } from "@opencode/ui-custom/button"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { Markdown } from "@opencode/session-ui-custom/markdown"
import { useLanguage } from "@/runtime/i18n/language"
import type { BtwModel } from "./state"
import "./panel.css"

export function BtwPanel(props: { btw: BtwModel; restoreFocus: () => void }) {
  const language = useLanguage()
  const [layout, setLayout] = createStore({ height: 520 })
  let panel: HTMLDivElement | undefined
  let input: HTMLTextAreaElement | undefined
  const close = () => {
    props.btw.dismiss()
    props.restoreFocus()
  }
  createEffect(() => {
    if (!props.btw.state.open) return
    props.btw.state.focus
    if (!props.btw.state.collapsed) input?.focus({ preventScroll: true })
  })
  createEffect(() => {
    if (!props.btw.state.open) return
    const update = () => {
      const bottom = panel?.getBoundingClientRect().bottom ?? 0
      setLayout("height", Math.max(120, Math.min(520, bottom - (window.visualViewport?.offsetTop ?? 0) - 64)))
    }
    const escape = (event: KeyboardEvent) => {
      if (props.btw.state.collapsed || event.key !== "Escape" || event.defaultPrevented || event.isComposing) return
      event.preventDefault()
      props.btw.collapse()
      props.restoreFocus()
    }
    update()
    const observer = new ResizeObserver(update)
    if (panel?.parentElement) observer.observe(panel.parentElement)
    window.visualViewport?.addEventListener("resize", update)
    window.visualViewport?.addEventListener("scroll", update)
    window.addEventListener("resize", update)
    document.addEventListener("keydown", escape)
    onCleanup(() => {
      observer.disconnect()
      window.visualViewport?.removeEventListener("resize", update)
      window.visualViewport?.removeEventListener("scroll", update)
      window.removeEventListener("resize", update)
      document.removeEventListener("keydown", escape)
    })
  })
  return (
    <Show when={props.btw.state.open}>
      <div
        ref={panel}
        class="btw-panel"
        data-slot="session-btw-panel"
        data-prevent-autofocus
        role="region"
        aria-label={language.t("command.session.btw")}
        style={{ "max-height": `${layout.height}px` }}
      >
        <div class="btw-header">
          <Button
            variant="ghost"
            onClick={() => (props.btw.state.collapsed ? props.btw.open() : props.btw.collapse())}
            aria-expanded={!props.btw.state.collapsed}
          >
            <Icon name={props.btw.state.collapsed ? "chevron-up" : "chevron-down"} />
            {language.t("session.btw.title")}
          </Button>
          <Show when={props.btw.state.pending}>
            <span role="status">{language.t("session.btw.loading")}</span>
          </Show>
          <IconButton
            icon={<Icon name="close" />}
            variant="ghost"
            aria-label={language.t("session.btw.dismiss")}
            onClick={close}
          />
        </div>
        <Show when={!props.btw.state.collapsed}>
          <div class="btw-body">
            <p class="text-text-weak">{language.t("session.btw.hint")}</p>
            <Show when={props.btw.state.question}>
              <p class="btw-question">{props.btw.state.question}</p>
            </Show>
            <Show when={props.btw.state.answer}>
              <Markdown text={props.btw.state.answer} />
            </Show>
            <Show when={props.btw.state.error}>
              <div role="alert">
                <p>{language.t("session.btw.error")}</p>
                <Button variant="outline" onClick={() => void props.btw.ask(props.btw.state.question)}>
                  {language.t("session.btw.retry")}
                </Button>
              </div>
            </Show>
          </div>
          <form
            class="btw-form"
            onSubmit={(event) => {
              event.preventDefault()
              void props.btw.ask()
            }}
          >
            <textarea
              ref={input}
              rows={2}
              value={props.btw.state.draft}
              aria-label={language.t("session.btw.question")}
              placeholder={language.t("session.btw.question")}
              onInput={(event) => props.btw.draft(event.currentTarget.value)}
              onKeyDown={(event) => {
                if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
                event.preventDefault()
                if (!props.btw.state.pending) void props.btw.ask()
              }}
            />
            <Button type="submit" disabled={props.btw.state.pending || !props.btw.state.draft.trim()}>
              {language.t("session.btw.ask")}
            </Button>
          </form>
        </Show>
      </div>
    </Show>
  )
}
