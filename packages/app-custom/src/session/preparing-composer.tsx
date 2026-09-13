import { createEffect, on, onCleanup, onMount } from "solid-js"
import { useLocation } from "@solidjs/router"
import { ComposerEditor } from "@/composer/editor/editor"
import { setCursorPosition } from "@/composer/editor/dom"
import { createComposerEditor } from "@/composer/editor/interaction"
import type { PendingSession } from "@/shell/tabs/tabs"

export function PreparingComposer(props: { pending: PendingSession }) {
  const location = useLocation()
  let element: HTMLElement | undefined
  let focused = false
  const onFocusIn = (event: FocusEvent) => {
    if (event.target === element) focused = true
    if (event.target !== element && event.target !== document.body) focused = false
  }
  onMount(() => {
    document.addEventListener("focusin", onFocusIn, true)
    onCleanup(() => document.removeEventListener("focusin", onFocusIn, true))
  })
  const editor = createComposerEditor({
    store: () => props.pending.composer.store,
    commands: () => [],
    context: () => [],
    searchContextFiles: () => [],
    onEditor: (value) => {
      element = value
    },
    view: {
      draftOnly: true,
      submit: { stopping: () => false, onSubmit() {}, onStop() {} },
    },
  })
  createEffect(
    on(
      () => props.pending,
      (pending) => {
        const pathname = location.pathname
        editor.restoreFocus(pending.composer.cursor())
        onCleanup(() => {
          if (!focused) return
          const cursor = pending.composer.cursor()
          requestAnimationFrame(() => {
            if (location.pathname !== pathname) return
            const next = document.querySelector<HTMLDivElement>('[data-component="composer-editor"]')
            if (!next || next === element) return
            next.focus()
            setCursorPosition(next, cursor ?? 0)
          })
        })
      },
    ),
  )

  return (
    <div data-component="session-composer-dock" class="w-full shrink-0 bg-v2-background-bg-base pb-3">
      <div class="mx-auto w-full max-w-[1000px] px-3">
        <ComposerEditor controller={editor} modelControlsVisible={false} />
      </div>
    </div>
  )
}
