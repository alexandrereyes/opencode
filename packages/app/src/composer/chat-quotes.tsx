import { createEffect, createUniqueId, For, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Button } from "@opencode/ui/button"
import { Icon } from "@opencode/ui/icon"
import { IconButton } from "@opencode/ui/icon-button"
import { useLanguage } from "@/runtime/i18n/language"
import type { ComposerState } from "./state"
import { flushPersisted } from "@/runtime/persistence/persist"
import "./chat-quotes.css"

export function ChatQuotes(props: { quotes: ComposerState["quotes"]; onDone: () => void }) {
  const language = useLanguage()
  const id = createUniqueId()
  const [state, setState] = createStore({ open: false, editing: "" })
  let previous = new Set(props.quotes.all().map((quote) => quote.id))
  createEffect(() => {
    const quotes = props.quotes.all()
    const added = quotes.find((quote) => !previous.has(quote.id))
    previous = new Set(quotes.map((quote) => quote.id))
    if (added) setState({ open: true, editing: added.id })
  })
  const done = () => {
    flushPersisted()
    setState({ editing: "", open: false })
    props.onDone()
  }
  return (
    <Show when={props.quotes.all().length}>
      <section data-component="chat-quotes" data-prevent-autofocus>
        <Show when={state.open}>
          <div id={id} data-slot="chat-quotes-list">
            <For each={props.quotes.all()}>
              {(quote) => (
                <article data-slot="chat-quote">
                  <header>
                    <span>{language.t("chatQuotes.source")}</span>
                    <div data-slot="chat-quote-actions">
                      <IconButton
                        icon={<Icon name={state.editing === quote.id ? "check" : "edit"} />}
                        aria-label={language.t(state.editing === quote.id ? "chatQuotes.done" : "chatQuotes.edit")}
                        onClick={() => (state.editing === quote.id ? done() : setState("editing", quote.id))}
                      />
                      <IconButton
                        icon={<Icon name="trash" />}
                        aria-label={language.t("chatQuotes.remove")}
                        onClick={() => props.quotes.remove(quote.id)}
                      />
                    </div>
                  </header>
                  <blockquote dir="auto" aria-label={language.t("chatQuotes.selectedText")}>
                    {quote.text}
                  </blockquote>
                  <Show
                    when={state.editing === quote.id}
                    fallback={
                      <Show when={quote.comment}>
                        <p dir="auto">{quote.comment}</p>
                      </Show>
                    }
                  >
                    <label for={`${id}-${quote.id}`}>{language.t("chatQuotes.userComment")}</label>
                    <textarea
                      id={`${id}-${quote.id}`}
                      dir="auto"
                      rows={2}
                      ref={(element) => queueMicrotask(() => element.isConnected && element.focus())}
                      value={quote.comment}
                      placeholder={language.t("chatQuotes.placeholder")}
                      onInput={(event) => props.quotes.update(quote.id, event.currentTarget.value)}
                      onKeyDown={(event) => {
                        if (
                          event.isComposing ||
                          (event.key !== "Escape" && !(event.key === "Enter" && (event.metaKey || event.ctrlKey)))
                        )
                          return
                        event.preventDefault()
                        event.stopPropagation()
                        done()
                      }}
                    />
                  </Show>
                </article>
              )}
            </For>
          </div>
        </Show>
        <Button
          type="button"
          size="small"
          variant="ghost-muted"
          aria-expanded={state.open}
          aria-controls={id}
          onClick={() => setState("open", !state.open)}
        >
          <Icon name="comment" />
          {language.plural("chatQuotes.title", props.quotes.all().length)}
          <Icon name="chevron-down" classList={{ "rotate-180": state.open }} />
        </Button>
      </section>
    </Show>
  )
}
