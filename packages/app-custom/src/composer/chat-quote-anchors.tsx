import { createEffect, For, onCleanup, Show } from "solid-js"
import { createStore, reconcile } from "solid-js/store"
import { Portal } from "solid-js/web"
import { useLanguage } from "@/runtime/i18n/language"
import type { ComposerState } from "./state"
import { resolveChatQuoteAnchor } from "./chat-quote-anchor"

type Rect = { left: number; top: number; width: number; height: number }

export function ChatQuoteAnchors(props: { root?: HTMLElement; active: boolean; quotes?: ComposerState["quotes"] }) {
  const language = useLanguage()
  const [state, setState] = createStore<{
    hover: string
    focused: string
    anchors: { id: string; number: number; rects: Rect[]; badge: Rect }[]
    rail?: Rect & { contentHeight: number }
  }>({ hover: "", focused: "", anchors: [] })
  let rail: HTMLDivElement | undefined
  const placeEditor = () => {
    const id = props.quotes?.editor.current()
    const button =
      id && rail?.isConnected ? rail.querySelector<HTMLElement>(`[data-anchor-id="${CSS.escape(id)}"]`) : undefined
    const box = button?.getBoundingClientRect()
    const bounds = rail?.getBoundingClientRect()
    props.quotes?.editor.place(
      box && bounds && box.top >= bounds.top && box.bottom <= bounds.bottom
        ? { left: box.left, top: box.top, bottom: box.bottom }
        : undefined,
    )
  }
  createEffect(() => {
    // Direction can change without resizing the text block.
    language.direction()
    const root = props.root
    const quotes = props.quotes
    const items = quotes
      ?.all()
      .map((quote) => ({ id: quote.id, partID: quote.partID, text: quote.text, anchor: quote.anchor }))
    quotes?.editor.current()
    if (!root || !props.active || !quotes || !items?.length) {
      setState("anchors", [])
      return
    }
    let frame = 0
    const observed = new Set<Element>()
    const resize = new ResizeObserver(() => schedule())
    const update = () => {
      frame = 0
      const viewport = root.getBoundingClientRect()
      const top = Array.from(root.querySelectorAll("[data-sticky-user], [data-session-title]")).reduce(
        (top, header) => {
          const box = header.getBoundingClientRect()
          const inset = Number.parseFloat(getComputedStyle(header).top) || 0
          return box.top <= viewport.top + inset + 1 && box.bottom > viewport.top ? Math.max(top, box.bottom) : top
        },
        Math.max(viewport.top, 0),
      )
      const bounds = new DOMRect(
        Math.max(viewport.left, 0),
        top,
        Math.min(viewport.right, window.innerWidth) - Math.max(viewport.left, 0),
        Math.max(0, Math.min(viewport.bottom, window.innerHeight) - top),
      )
      const bodies = new Map(
        Array.from(root.querySelectorAll('[data-timeline-row="AssistantPart"] [data-slot="text-part-body"]')).map(
          (body) => [body.closest('[data-component="text-part"]')?.getAttribute("data-timeline-part-id"), body],
        ),
      )
      const mounted = new Set<Element>([root, ...bodies.values()])
      observed.forEach((body) => {
        if (mounted.has(body)) return
        resize.unobserve(body)
        observed.delete(body)
      })
      mounted.forEach((body) => {
        if (observed.has(body)) return
        observed.add(body)
        resize.observe(body)
      })
      const anchors = items.flatMap((quote, index) => {
        const body = bodies.get(quote.partID)
        if (!body) return []
        const range = resolveChatQuoteAnchor(body, quote)
        if (!range) return []
        const rects = quoteRects(range, root, bounds)
        if (!rects.length) return []
        const last = rects[rects.length - 1]!
        // Use the paragraph gutter rather than covering the next character when
        // the selection ends in the middle of a line.
        const badge = {
          left: 2,
          top: last.top,
          width: 24,
          height: 24,
        }
        // Keep multiple comments ending on the same line individually reachable.
        return [{ id: quote.id, number: index + 1, rects, badge }]
      })
      // Pack in visual order, then pull the stack back from the bottom edge.
      // A native scroll rail handles more markers than the visible height can fit.
      // Numbers and DOM/tab order continue to follow the draft, not the packing order.
      const ordered = [...anchors].sort((a, b) => a.badge.top - b.badge.top || a.number - b.number)
      const contentHeight = Math.max(bounds.height, ordered.length * 28)
      ordered.forEach((anchor, index) => {
        anchor.badge.top = Math.max(anchor.badge.top - bounds.top, index ? ordered[index - 1]!.badge.top + 28 : 2)
      })
      ordered.toReversed().forEach((anchor, index, reversed) => {
        anchor.badge.top = Math.min(anchor.badge.top, index ? reversed[index - 1]!.badge.top - 28 : contentHeight - 26)
      })
      setState("rail", {
        left: getComputedStyle(root).direction === "rtl" ? bounds.left : bounds.right - 28,
        top: bounds.top,
        width: 28,
        height: bounds.height,
        contentHeight,
      })
      setState("anchors", reconcile(anchors))
      placeEditor()
    }
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(update)
    }
    const hit = (event: MouseEvent) =>
      state.anchors.find((anchor) =>
        anchor.rects.some(
          (rect) =>
            event.clientX >= rect.left &&
            event.clientX <= rect.left + rect.width &&
            event.clientY >= rect.top &&
            event.clientY <= rect.top + rect.height,
        ),
      )
    const hover = (event: PointerEvent) => setState("hover", hit(event)?.id ?? "")
    const leave = () => setState("hover", "")
    const click = (event: MouseEvent) => {
      if (!window.getSelection()?.isCollapsed) return
      if (event.target instanceof Element && event.target.closest("a, button, input, textarea")) return
      const anchor = hit(event)
      if (anchor) quotes.editor.open(anchor.id)
    }
    const mutation = new MutationObserver(schedule)
    mutation.observe(root, { childList: true, subtree: true, characterData: true })
    root.addEventListener("pointermove", hover)
    root.addEventListener("pointerleave", leave)
    root.addEventListener("click", click)
    root.addEventListener("scroll", schedule, true)
    window.addEventListener("resize", schedule)
    window.visualViewport?.addEventListener("resize", schedule)
    window.visualViewport?.addEventListener("scroll", schedule)
    schedule()
    onCleanup(() => {
      cancelAnimationFrame(frame)
      resize.disconnect()
      mutation.disconnect()
      root.removeEventListener("pointermove", hover)
      root.removeEventListener("pointerleave", leave)
      root.removeEventListener("click", click)
      root.removeEventListener("scroll", schedule, true)
      window.removeEventListener("resize", schedule)
      window.visualViewport?.removeEventListener("resize", schedule)
      window.visualViewport?.removeEventListener("scroll", schedule)
      quotes.editor.place(undefined)
    })
  })
  return (
    <Portal>
      <div data-component="chat-quote-anchors" dir={language.direction()}>
        <For each={state.anchors}>
          {(anchor) => (
            <div
              data-quote-id={anchor.id}
              data-active={
                state.hover === anchor.id || state.focused === anchor.id || props.quotes?.editor.current() === anchor.id
              }
            >
              <For each={anchor.rects}>
                {(rect) => (
                  <span
                    data-slot="quote-highlight"
                    style={{
                      left: `${rect.left}px`,
                      top: `${rect.top}px`,
                      width: `${rect.width}px`,
                      height: `${rect.height}px`,
                    }}
                  />
                )}
              </For>
            </div>
          )}
        </For>
        <Show when={state.anchors.length > 0 && state.rail}>
          {(bounds) => (
            <div
              ref={rail}
              data-slot="quote-anchor-rail"
              onScroll={placeEditor}
              style={{
                left: `${bounds().left}px`,
                top: `${bounds().top}px`,
                width: `${bounds().width}px`,
                height: `${bounds().height}px`,
              }}
            >
              <div style={{ height: `${bounds().contentHeight}px`, position: "relative" }}>
                <For each={state.anchors}>
                  {(anchor) => (
                    <button
                      type="button"
                      data-slot="quote-anchor"
                      data-anchor-id={anchor.id}
                      data-prevent-autofocus
                      aria-label={language.t("chatQuotes.editNumber", { number: anchor.number })}
                      aria-expanded={props.quotes?.editor.current() === anchor.id}
                      style={{ left: `${anchor.badge.left}px`, top: `${anchor.badge.top}px` }}
                      onPointerEnter={() => setState("hover", anchor.id)}
                      onPointerLeave={() => setState("hover", "")}
                      onFocus={() => setState("focused", anchor.id)}
                      onBlur={() => setState("focused", "")}
                      onClick={() => {
                        props.quotes?.editor.open(anchor.id)
                        placeEditor()
                      }}
                    >
                      {anchor.number}
                    </button>
                  )}
                </For>
              </div>
            </div>
          )}
        </Show>
      </div>
    </Portal>
  )
}

function quoteRects(range: Range, root: HTMLElement, bounds: DOMRect) {
  const walker = document.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT)
  const rects: Rect[] = []
  // Measure text leaves, avoiding duplicate element/text rectangles from a Range
  // crossing inline markup. Clip each leaf to its nested code/table scrollports.
  for (let node: Node | null = walker.currentNode; node; node = walker.nextNode()) {
    if (node.nodeType !== Node.TEXT_NODE || !range.intersectsNode(node)) continue
    const leaf = document.createRange()
    leaf.setStart(node, node === range.startContainer ? range.startOffset : 0)
    leaf.setEnd(node, node === range.endContainer ? range.endOffset : (node.textContent?.length ?? 0))
    if (leaf.collapsed) continue
    const clip = {
      left: Math.max(bounds.left, 0),
      top: Math.max(bounds.top, 0),
      right: Math.min(bounds.right, window.innerWidth),
      bottom: Math.min(bounds.bottom, window.innerHeight),
    }
    for (let parent = node.parentElement; parent && parent !== root; parent = parent.parentElement) {
      const style = getComputedStyle(parent)
      const x = /auto|scroll|hidden|clip/.test(style.overflowX)
      const y = /auto|scroll|hidden|clip/.test(style.overflowY)
      if (!x && !y) continue
      const box = parent.getBoundingClientRect()
      if (x) {
        clip.left = Math.max(clip.left, box.left)
        clip.right = Math.min(clip.right, box.right)
      }
      if (y) {
        clip.top = Math.max(clip.top, box.top)
        clip.bottom = Math.min(clip.bottom, box.bottom)
      }
    }
    Array.from(leaf.getClientRects()).forEach((rect) => {
      const left = Math.max(rect.left, clip.left)
      const top = Math.max(rect.top, clip.top)
      const right = Math.min(rect.right, clip.right)
      const bottom = Math.min(rect.bottom, clip.bottom)
      if (right > left && bottom > top) rects.push({ left, top, width: right - left, height: bottom - top })
    })
  }
  return rects
}
