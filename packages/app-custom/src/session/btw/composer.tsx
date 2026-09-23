import { createEffect, on, onCleanup, onMount, Show } from "solid-js"
import { ProviderIcon } from "@opencode/ui-custom/provider-icon"
import { Tooltip } from "@opencode/ui-custom/tooltip"
import { ComposerEditor } from "@/composer/editor/editor"
import { createComposerEditor, type ComposerEditorModel } from "@/composer/editor/interaction"
import { clonePrompt } from "@/composer/prompt-parts"
import { createMemoryComposerState } from "@/composer/state"
import type { ModelSelection } from "@/providers/models/selection"
import { useLanguage } from "@/runtime/i18n/language"
import type { ComposerBtw } from "./model"
import { btwQuestionText } from "./question"

// Replaces the main composer while a side question is active. The main draft
// stays in its own (hidden) editor; this one edits only the side question.
export function BtwComposer(props: {
  btw: ComposerBtw
  completion: ComposerEditorModel["completion"]
  models: ModelSelection
  borderUnderlay?: boolean
}) {
  const language = useLanguage()
  const state = createMemoryComposerState()
  state.set(
    props.btw.state.draftPrompt ?? [
      { type: "text", content: props.btw.state.draft, start: 0, end: props.btw.state.draft.length },
    ],
    props.btw.state.draft.length,
  )
  const question = () => btwQuestionText(editor.parts())
  const editor = createComposerEditor({
    store: state.store,
    commands: () => [],
    context: props.completion.context,
    snippets: props.completion.snippets,
    searchContextFiles: props.completion.searchContextFiles,
    onContextQuery: props.completion.onContextQuery,
    onEditor: (element) => props.btw.setEditor(element as HTMLDivElement),
    view: {
      allowShell: false,
      placeholder: () => language.t("session.btw.question"),
      submit: {
        available: () => !props.btw.state.pending,
        stopping: () => props.btw.state.pending && !question().trim(),
        working: () => props.btw.state.pending,
        onStop: props.btw.cancel,
        onSubmit: () => {
          if (!question().trim()) return
          void props.btw.ask(question(), { draft: editor.value(), draftPrompt: clonePrompt(editor.parts()) })
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
  onMount(() => editor.restoreFocus())
  onCleanup(() => props.btw.setEditor(undefined))
  return (
    <ComposerEditor
      controller={editor}
      borderUnderlay={props.borderUnderlay}
      addMenu={false}
      modelControl={<BtwModelLabel btw={props.btw} models={props.models} />}
    />
  )
}

function BtwModelLabel(props: { btw: ComposerBtw; models: ModelSelection }) {
  const language = useLanguage()
  const model = () => {
    const current = props.btw.sessionModel()
    if (!current) return
    const info = props.models.list().find((item) => item.id === current.id && item.provider.id === current.providerID)
    return {
      providerID: current.providerID,
      name: [info?.name ?? current.id, current.variant].filter(Boolean).join(" · "),
    }
  }
  return (
    <Show when={model()}>
      {(model) => (
        <Tooltip placement="top" value={language.t("session.btw.model")}>
          <span
            data-slot="btw-model"
            class="flex h-8 min-w-0 max-w-[260px] shrink-0 items-center gap-1.5 px-1 text-[13px] font-[500] leading-[var(--line-height-compact)] tracking-[-0.04px] text-v2-text-text-muted"
          >
            <ProviderIcon id={model().providerID} class="size-4 shrink-0" />
            <span class="truncate">{model().name}</span>
          </span>
        </Tooltip>
      )}
    </Show>
  )
}
