import { createEffect, createUniqueId, For, on, onCleanup, onMount, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Portal } from "solid-js/web"
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
  onEditingChange: (editing: boolean) => void
  onDone: () => void
}) {
  const language = useLanguage()
  const id = createUniqueId()
  const [state, setState] = createStore({
    open: false,
    viewportHeight: typeof window === "undefined" ? 720 : (window.visualViewport?.height ?? window.innerHeight),
    viewportTop: 0,
    viewportWidth: typeof window === "undefined" ? 1024 : window.innerWidth,
    editorHeight: 240,
  })
  let popover: HTMLElement | undefined
  let previous = new Set(props.quotes.all().map((quote) => quote.id))
  createEffect(() => {
    const quotes = props.quotes.all()
    const added = quotes.find((quote) => !previous.has(quote.id))
    previous = new Set(quotes.map((quote) => quote.id))
    if (added) props.quotes.editor.open(added.id)
    if (props.quotes.editor.current() && !quotes.some((quote) => quote.id === props.quotes.editor.current()))
      props.quotes.editor.close()
  })
  createEffect(() => props.onEditingChange(!!props.quotes.editor.current()))
  onMount(() => {
    const viewport = window.visualViewport
    const target = viewport ?? window
    const update = () =>
      setState({
        viewportHeight: viewport?.height ?? window.innerHeight,
        viewportTop: viewport?.offsetTop ?? 0,
        viewportWidth: window.innerWidth,
      })
    update()
    target.addEventListener("resize", update)
    target.addEventListener("scroll", update)
    onCleanup(() => {
      target.removeEventListener("resize", update)
      target.removeEventListener("scroll", update)
    })
  })
  onCleanup(() => props.onEditingChange(false))
  const done = () => {
    const quote = editing()
    if (quote && !quote.comment.trim()) props.quotes.remove(quote.id)
    flushPersisted()
    props.quotes.editor.close()
    setState("open", false)
    props.onDone()
  }
  const editing = () => props.quotes.all().find((quote) => quote.id === props.quotes.editor.current())
  const position = () => props.quotes.editor.position()
  createEffect(() => {
    if (!editing() || !popover) return
    const observer = new ResizeObserver(([entry]) => {
      if (entry) setState("editorHeight", entry.target.getBoundingClientRect().height)
    })
    observer.observe(popover)
    onCleanup(() => observer.disconnect())
  })
  const top = () => {
    const below = (position()?.bottom ?? 72) + 8
    const available = state.viewportTop + state.viewportHeight - state.editorHeight - 8
    if (below <= available) return below
    return Math.max(state.viewportTop + 8, Math.min((position()?.top ?? 80) - state.editorHeight - 8, available))
  }
  return (
    <Show when={props.quotes.all().length}>
      <Show when={editing()} keyed>
        {(quote) => (
          <Portal>
            <section
              ref={popover}
              data-component="chat-quotes"
              data-slot="chat-quote-popover"
              data-editing="true"
              data-prevent-autofocus
              dir={language.direction()}
              role="region"
              aria-label={language.t("chatQuotes.editNumber", {
                number: props.quotes.all().findIndex((item) => item.id === quote.id) + 1,
              })}
              style={{
                left: `${Math.max(8, Math.min(position()?.left ?? state.viewportWidth / 2 - 180, state.viewportWidth - 376))}px`,
                top: `${top()}px`,
                "max-height": `${Math.max(120, state.viewportHeight - 16)}px`,
                "--quote-viewport-bottom": `${Math.max(0, window.innerHeight - state.viewportTop - state.viewportHeight)}px`,
                "--quote-editor-max-height": `${Math.max(64, Math.min(180, state.viewportHeight * 0.25))}px`,
              }}
            >
              <article data-slot="chat-quote" data-editing="true">
                <header>
                  <span>
                    {language.t("chatQuotes.editNumber", {
                      number: props.quotes.all().findIndex((item) => item.id === quote.id) + 1,
                    })}
                  </span>
                  <div data-slot="chat-quote-actions">
                    <IconButton
                      icon={<Icon name="trash" />}
                      aria-label={language.t("chatQuotes.remove")}
                      onClick={() => {
                        props.quotes.remove(quote.id)
                        flushPersisted()
                        props.onDone()
                      }}
                    />
                    <Button size="small" variant="ghost" onClick={done}>
                      {language.t("chatQuotes.done")}
                    </Button>
                  </div>
                </header>
                <Show when={!position()}>
                  <blockquote dir="auto" aria-label={language.t("chatQuotes.selectedText")}>
                    {quote.text}
                  </blockquote>
                </Show>
                <QuoteCommentEditor
                  quote={quote}
                  id={`${id}-${quote.id}`}
                  label={language.t("chatQuotes.userComment")}
                  placeholder={language.t("chatQuotes.placeholder")}
                  completion={props.completion}
                  onInput={(value, prompt) => props.quotes.update(quote.id, value, prompt)}
                  onDone={done}
                />
              </article>
            </section>
          </Portal>
        )}
      </Show>
      <section data-component="chat-quotes" data-slot="chat-quotes-summary" data-editing="false" data-prevent-autofocus>
        <Show when={state.open}>
          <div id={id} data-slot="chat-quotes-list">
            <For each={props.quotes.all()}>
              {(quote, index) => (
                <article data-slot="chat-quote" data-editing="false">
                  <header>
                    <span>{language.t("chatQuotes.editNumber", { number: index() + 1 })}</span>
                    <div data-slot="chat-quote-actions">
                      <IconButton
                        icon={<Icon name="edit" />}
                        aria-label={language.t("chatQuotes.edit")}
                        onClick={() => props.quotes.editor.open(quote.id)}
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
                  <Show when={quote.comment}>
                    <p dir="auto">{quote.comment}</p>
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
