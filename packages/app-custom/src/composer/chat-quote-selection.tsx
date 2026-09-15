import { createEffect, onCleanup, Show } from "solid-js"
import { createStore } from "solid-js/store"
import { Portal } from "solid-js/web"
import { Button } from "@opencode/ui-custom/button"
import { Icon } from "@opencode/ui-custom/icon"
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
  onQuote?: (partID: string, text: string) => void
  onAddToInput?: (text: string) => void
}) {
  const language = useLanguage()
  const [state, setState] = createStore<{
    selection?: {
      partID: string
      text: string
      anchorX: number
      top: number
      bottom: number
      x: number
      y: number
      positioned: boolean
    }
  }>({})
  let toolbar: HTMLDivElement | undefined
  const clear = () => setState("selection", undefined)
  const dismiss = () => {
    clear()
    window.getSelection()?.removeAllRanges()
  }
  createEffect(() => {
    const root = props.root
    clear()
    if (!root || !props.active || (!props.onQuote && !props.onAddToInput)) return
    const update = () => {
      const selected = selectedChatText(root, window.getSelection())
      if (!selected) return clear()
      const rect = selected.range.getBoundingClientRect()
      if (!rect.width && !rect.height) return clear()
      setState("selection", {
        partID: selected.partID,
        text: selected.text,
        anchorX: rect.left + rect.width / 2,
        top: rect.top,
        bottom: rect.bottom,
        x: rect.left + rect.width / 2,
        y: rect.top,
        positioned: window.matchMedia("(max-width: 767px)").matches,
      })
    }
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") return dismiss()
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
  createEffect(() => {
    const selection = state.selection
    if (!selection || selection.positioned || !toolbar) return
    const rect = toolbar.getBoundingClientRect()
    const margin = 8
    const x = Math.max(margin + rect.width / 2, Math.min(selection.anchorX, window.innerWidth - margin - rect.width / 2))
    const above = selection.top - rect.height - margin
    const y = above >= margin ? above : Math.min(selection.bottom + margin, window.innerHeight - margin - rect.height)
    setState("selection", { ...selection, x, y: Math.max(margin, y), positioned: true })
  })
  return (
    <Show when={state.selection}>
      {(selection) => (
        <Portal>
          <div
            ref={toolbar}
            data-component="chat-quote-selection"
            data-prevent-autofocus
            dir={language.direction()}
            style={{ left: `${selection().x}px`, top: `${selection().y}px` }}
            classList={{ invisible: !selection().positioned }}
            role="toolbar"
            aria-label={language.t("chatQuotes.selectionActions")}
          >
            <Show when={props.onQuote}>
              {(onQuote) => (
                <Button
                  type="button"
                  variant="ghost"
                  size="small"
                  onPointerDown={(event: PointerEvent) => event.preventDefault()}
                  onClick={() => {
                    const selected = selection()
                    dismiss()
                    onQuote()(selected.partID, selected.text)
                  }}
                >
                  <Icon name="comment" />
                  {language.t("chatQuotes.comment")}
                </Button>
              )}
            </Show>
            <Show when={props.onAddToInput}>
              {(onAddToInput) => (
                <Button
                  type="button"
                  variant="ghost"
                  size="small"
                  onPointerDown={(event: PointerEvent) => event.preventDefault()}
                  onClick={() => {
                    const text = selection().text
                    dismiss()
                    onAddToInput()(text)
                  }}
                >
                  <Icon name="plus" />
                  {language.t("chatQuotes.addToInput")}
                </Button>
              )}
            </Show>
          </div>
        </Portal>
      )}
    </Show>
  )
}
