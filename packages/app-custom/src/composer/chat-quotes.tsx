import { createEffect, createUniqueId, For, on, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Button } from "@opencode/ui-custom/button"
import { Icon } from "@opencode/ui-custom/icon"
import { IconButton } from "@opencode/ui-custom/icon-button"
import { useLanguage } from "@/runtime/i18n/language"
import type { ComposerState, Prompt } from "./state"
import { createMemoryComposerState } from "./state"
import { flushPersisted } from "@/runtime/persistence/persist"
import type { ChatQuote } from "./schema"
import { ComposerEditor } from "./editor/editor"
import { createComposerEditor, type ComposerEditorModel } from "./editor/interaction"
import "./chat-quotes.css"

export function ChatQuotes(props: {
  quotes: ComposerState["quotes"]
  completion: ComposerEditorModel["completion"]
  onDone: () => void
}) {
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
                    <QuoteCommentEditor
                      quote={quote}
                      id={`${id}-${quote.id}`}
                      label={language.t("chatQuotes.userComment")}
                      placeholder={language.t("chatQuotes.placeholder")}
                      completion={props.completion}
                      onInput={(value, prompt) => props.quotes.update(quote.id, value, prompt)}
                      onDone={done}
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

function QuoteCommentEditor(props: {
  quote: ChatQuote
  id: string
  label: string
  placeholder: string
  completion: ComposerEditorModel["completion"]
  onInput: (value: string, prompt: Prompt) => void
  onDone: () => void
}) {
  const state = createMemoryComposerState()
  state.set(
    props.quote.commentPrompt ?? [
      { type: "text", content: props.quote.comment, start: 0, end: props.quote.comment.length },
    ],
    props.quote.comment.length,
  )
  const editor = createComposerEditor({
    store: state.store,
    commands: () => [],
    context: props.completion.context,
    snippets: props.completion.snippets,
    searchContextFiles: props.completion.searchContextFiles,
    onContextQuery: props.completion.onContextQuery,
    view: {
      allowShell: false,
      placeholder: () => props.placeholder,
      submit: { stopping: () => false, onSubmit() {}, onStop() {} },
    },
  })
  createEffect(on(editor.parts, (prompt) => props.onInput(editor.value(), prompt), { defer: true }))
  return (
    <>
      <label
        for={props.id}
        onClick={(event) => {
          event.preventDefault()
          editor.restoreFocus()
        }}
      >
        {props.label}
      </label>
      <ComposerEditor
        controller={editor}
        compact={{ id: props.id, ariaLabel: props.label, autofocus: true, onDone: props.onDone }}
      />
    </>
  )
}
