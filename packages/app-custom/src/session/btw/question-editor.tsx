import { createEffect, createUniqueId, on } from "solid-js"
import { Button } from "@opencode/ui-custom/button"
import { ComposerEditor } from "@/composer/editor/editor"
import { createComposerEditor, type ComposerEditorModel } from "@/composer/editor/interaction"
import { createMemoryComposerState } from "@/composer/state"
import { useLanguage } from "@/runtime/i18n/language"
import type { BtwModel } from "./state"
import { btwQuestionText } from "./question"

export function BtwQuestionEditor(props: {
  btw: BtwModel
  completion: ComposerEditorModel["completion"]
  onDone: () => void
}) {
  const language = useLanguage()
  const id = createUniqueId()
  const state = createMemoryComposerState()
  state.set(
    props.btw.state.draftPrompt ?? [
      { type: "text", content: props.btw.state.draft, start: 0, end: props.btw.state.draft.length },
    ],
    props.btw.state.draft.length,
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
      placeholder: () => language.t("session.btw.question"),
      submit: {
        available: () => !props.btw.state.pending,
        stopping: () => false,
        onStop: props.btw.cancel,
        onSubmit: () => {
          if (!props.btw.state.pending) void props.btw.ask(btwQuestionText(editor.parts()), true)
        },
      },
    },
  })
  createEffect(on(editor.parts, (prompt) => props.btw.draft(editor.value(), prompt), { defer: true }))
  createEffect(
    on(
      () => props.btw.state.draft,
      (draft) => {
        if (draft === editor.value()) return
        state.set(
          props.btw.state.draftPrompt ?? [{ type: "text", content: draft, start: 0, end: draft.length }],
          draft.length,
        )
      },
    ),
  )
  createEffect(
    on(
      () => props.btw.state.focus,
      () => editor.restoreFocus(),
      { defer: true },
    ),
  )
  return (
    <div class="btw-form">
      <ComposerEditor
        controller={editor}
        compact={{
          id,
          ariaLabel: language.t("session.btw.question"),
          autofocus: true,
          submit: true,
          onDone: props.onDone,
        }}
      />
      <Button
        type="button"
        disabled={props.btw.state.pending || !btwQuestionText(editor.parts()).trim()}
        onClick={() => editor.submit()}
      >
        {language.t("session.btw.ask")}
      </Button>
    </div>
  )
}
