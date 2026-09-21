import type { ChatQuote } from "./schema"

// Offsets count DOM text, not Markdown source or Selection.toString() (which
// inserts visual newlines). This survives syntax highlighting and inline markup.
export function captureChatQuoteAnchor(body: Element, range: Range): NonNullable<ChatQuote["anchor"]> {
  const before = range.cloneRange()
  before.selectNodeContents(body)
  before.setEnd(range.startContainer, range.startOffset)
  const start = before.toString().length
  const exact = range.toString()
  return { start, end: start + exact.length, exact }
}

export function resolveChatQuoteAnchor(body: Element, quote: Pick<ChatQuote, "anchor" | "text">) {
  const text = body.textContent ?? ""
  const anchor = quote.anchor
  const exact = anchor?.exact ?? quote.text
  if (!exact) return
  const start = anchor?.start ?? text.indexOf(exact)
  const end = anchor?.end ?? start + exact.length
  // Old drafts can recover only unambiguous text. Never attach a repeated phrase
  // to an arbitrary occurrence, or silently move an invalid persisted anchor.
  if (!anchor && text.indexOf(exact, start + 1) !== -1) return
  if (!Number.isInteger(start) || !Number.isInteger(end) || start < 0 || end <= start) return
  if (text.slice(start, end) !== exact) return
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT)
  const range = document.createRange()
  let offset = 0
  let found = false
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = node.textContent?.length ?? 0
    if (!found && start < offset + length) {
      range.setStart(node, start - offset)
      found = true
    }
    if (found && end <= offset + length) {
      range.setEnd(node, end - offset)
      return range
    }
    offset += length
  }
}
