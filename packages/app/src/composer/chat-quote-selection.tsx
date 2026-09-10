import { createEffect, onCleanup, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Portal } from "solid-js/web"
import { Button } from "@opencode/ui/button"
import { useLanguage } from "@/runtime/i18n/language"
import "./chat-quotes.css"

export function selectedChatText(root: HTMLElement, selection: Selection | null) {
  if (!selection || selection.isCollapsed || selection.rangeCount !== 1) return
  const range = selection.getRangeAt(0)
  const element = range.startContainer instanceof Element ? range.startContainer : range.startContainer.parentElement
  const body = element?.closest('[data-slot="text-part-body"]')
  if (
    !body ||
    !body.closest('[data-timeline-row="AssistantPart"]') ||
    !root.contains(body) ||
    !body.contains(range.endContainer)
  )
    return
  const partID = body.closest('[data-component="text-part"]')?.getAttribute("data-timeline-part-id")
  const text = selection.toString().trim()
  if (!partID || !text) return
  return { partID, text, range }
}

export function ChatQuoteSelection(props: {
  root?: HTMLDivElement
  active: boolean
  onQuote: (partID: string, text: string) => void
}) {
  const language = useLanguage()
  const [state, setState] = createStore<{ selection?: { partID: string; text: string; x: number; y: number } }>({})
  createEffect(() => {
    const root = props.root
    setState("selection", undefined)
    if (!root || !props.active) return
    const clear = () => setState("selection", undefined)
    const update = () => {
      const selected = selectedChatText(root, window.getSelection())
      if (!selected) return clear()
      const rect = selected.range.getBoundingClientRect()
      if (!rect.width && !rect.height) return clear()
      setState("selection", {
        partID: selected.partID,
        text: selected.text,
        x: Math.max(8, Math.min(rect.left + rect.width / 2 - 52, window.innerWidth - 112)),
        y: rect.top >= 48 ? rect.top - 44 : Math.min(rect.bottom + 8, window.innerHeight - 48),
      })
    }
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") clear()
      if (event.key === "Shift" || event.key.startsWith("Arrow")) update()
    }
    const changed = () => update()
    document.addEventListener("pointerup", update)
    document.addEventListener("keyup", key)
    document.addEventListener("selectionchange", changed)
    root.addEventListener("scroll", clear, true)
    window.addEventListener("resize", clear)
    onCleanup(() => {
      document.removeEventListener("pointerup", update)
      document.removeEventListener("keyup", key)
      document.removeEventListener("selectionchange", changed)
      root.removeEventListener("scroll", clear, true)
      window.removeEventListener("resize", clear)
    })
  })
  return (
    <Show when={state.selection}>
      {(selection) => (
        <Portal>
          <div
            data-component="chat-quote-selection"
            data-prevent-autofocus
            dir={language.direction()}
            style={{ left: `${selection().x}px`, top: `${selection().y}px` }}
          >
            <Button
              type="button"
              variant="ghost"
              size="small"
              onPointerDown={(event: PointerEvent) => event.preventDefault()}
              onClick={() => {
                props.onQuote(selection().partID, selection().text)
                setState("selection", undefined)
                window.getSelection()?.removeAllRanges()
              }}
            >
              {language.t("chatQuotes.comment")}
            </Button>
          </div>
        </Portal>
      )}
    </Show>
  )
}
