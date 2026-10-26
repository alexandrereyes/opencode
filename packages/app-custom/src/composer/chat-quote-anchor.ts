import type { ChatQuote } from "./schema"

// Rendered text kept on each side so another client can find the passage in its own rendering.
const CONTEXT = 64

// Offsets count DOM text, not Markdown source or Selection.toString() (which
// inserts visual newlines). This survives syntax highlighting and inline markup.
export function captureChatQuoteAnchor(body: Element, range: Range): NonNullable<ChatQuote["anchor"]> {
  const before = range.cloneRange()
  before.selectNodeContents(body)
  before.setEnd(range.startContainer, range.startOffset)
  const start = before.toString().length
  const exact = range.toString()
  const text = body.textContent ?? ""
  return {
    start,
    end: start + exact.length,
    exact,
    coordinate: "rendered",
    prefix: text.slice(Math.max(0, start - CONTEXT), start),
    suffix: text.slice(start + exact.length, start + exact.length + CONTEXT),
  }
}

export function resolveChatQuoteAnchor(body: Element, quote: Pick<ChatQuote, "anchor" | "text">) {
  const text = body.textContent ?? ""
  const offsets = locate(text, quote)
  if (!offsets) return
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT)
  const range = document.createRange()
  let offset = 0
  let found = false
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = node.textContent?.length ?? 0
    if (!found && offsets.start < offset + length) {
      range.setStart(node, offsets.start - offset)
      found = true
    }
    if (found && offsets.end <= offset + length) {
      range.setEnd(node, offsets.end - offset)
      return range
    }
    offset += length
  }
}

function locate(text: string, quote: Pick<ChatQuote, "anchor" | "text">) {
  const anchor = quote.anchor
  if (!anchor) {
    // Old drafts can recover only unambiguous text. Never attach a repeated phrase
    // to an arbitrary occurrence.
    const start = text.indexOf(quote.text)
    if (!quote.text || start === -1 || text.indexOf(quote.text, start + 1) !== -1) return
    return { start, end: start + quote.text.length }
  }
  if (anchor.coordinate !== "source" && valid(text, anchor)) return { start: anchor.start, end: anchor.end }
  // Source offsets count raw Markdown, which never matches rendered text: search the copyable text instead.
  // A rendered anchor without context (older web drafts) is never silently moved.
  if (anchor.coordinate === "source") return search(text, quote.text, anchor)
  if (anchor.prefix === undefined && anchor.suffix === undefined) return
  return search(text, anchor.exact, anchor)
}

function valid(text: string, anchor: NonNullable<ChatQuote["anchor"]>) {
  if (
    !Number.isInteger(anchor.start) ||
    !Number.isInteger(anchor.end) ||
    anchor.start < 0 ||
    anchor.end <= anchor.start
  )
    return false
  return text.slice(anchor.start, anchor.end) === anchor.exact
}

/**
 * Whitespace-insensitive search for `needle`; several matches are told apart by how much of the
 * stored prefix and suffix surrounds each one, and a tie resolves nothing.
 */
export function search(text: string, needle: string, context: { prefix?: string; suffix?: string }) {
  const haystack = normalize(text)
  const target = normalize(needle).value.trim()
  if (!target) return
  const prefix = normalize(context.prefix ?? "").value.trimEnd()
  const suffix = normalize(context.suffix ?? "").value.trimStart()
  const matches = occurrences(haystack.value, target).map((index) => ({
    index,
    score:
      commonSuffix(haystack.value.slice(0, index).trimEnd(), prefix) +
      commonPrefix(haystack.value.slice(index + target.length).trimStart(), suffix),
  }))
  const best = Math.max(...matches.map((match) => match.score))
  const winners = matches.filter((match) => match.score === best)
  if (winners.length !== 1) return
  const index = winners[0]!.index
  return { start: haystack.map[index]!, end: haystack.map[index + target.length - 1]! + 1 }
}

// Collapses every whitespace run to one space; `map` gives each normalized index its original offset.
function normalize(text: string) {
  const map: number[] = []
  const chars: string[] = []
  for (let index = 0; index < text.length; index++) {
    const space = /\s/.test(text[index]!)
    if (space && chars.at(-1) === " ") continue
    chars.push(space ? " " : text[index]!)
    map.push(index)
  }
  return { value: chars.join(""), map }
}

function occurrences(text: string, target: string) {
  const found: number[] = []
  for (let index = text.indexOf(target); index !== -1; index = text.indexOf(target, index + 1)) found.push(index)
  return found
}

function commonSuffix(a: string, b: string) {
  let length = 0
  while (length < a.length && length < b.length && a[a.length - 1 - length] === b[b.length - 1 - length]) length++
  return length
}

function commonPrefix(a: string, b: string) {
  let length = 0
  while (length < a.length && length < b.length && a[length] === b[length]) length++
  return length
}
