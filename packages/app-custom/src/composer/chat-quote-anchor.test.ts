import { describe, expect, test } from "bun:test"
import { captureChatQuoteAnchor, resolveChatQuoteAnchor } from "./chat-quote-anchor"

describe("draft quote anchors", () => {
  test("keeps the selected occurrence across inline markup and DOM replacement", () => {
    const body = document.createElement("div")
    body.innerHTML = "<p>repeat phrase</p><p><strong>repeat</strong> <code>phrase</code></p>"
    const range = document.createRange()
    range.setStart(body.querySelector("strong")!.firstChild!, 0)
    range.setEnd(body.querySelector("code")!.firstChild!, 6)
    const anchor = captureChatQuoteAnchor(body, range)
    expect(anchor).toEqual({ start: 13, end: 26, exact: "repeat phrase" })
    body.innerHTML = "<p>repeat phrase</p><p><span>repeat </span><span>phrase</span></p>"
    const restored = resolveChatQuoteAnchor(body, { anchor, text: "repeat phrase" })
    expect(restored?.toString()).toBe("repeat phrase")
    expect(restored?.startContainer).toBe(body.querySelector("span")!.firstChild!)
  })

  test("does not guess repeated legacy quotes or relocate invalid anchors", () => {
    const body = document.createElement("div")
    body.textContent = "same same unique"
    expect(resolveChatQuoteAnchor(body, { text: "same" })).toBeUndefined()
    expect(resolveChatQuoteAnchor(body, { text: "unique" })?.toString()).toBe("unique")
    expect(resolveChatQuoteAnchor(body, { text: "same", anchor: { start: 1, end: 5, exact: "same" } })).toBeUndefined()
    expect(resolveChatQuoteAnchor(body, { text: "absent" })).toBeUndefined()
  })

  test("preserves code whitespace and UTF-16 offsets across syntax spans", () => {
    const body = document.createElement("div")
    body.innerHTML = "<p>مرحبا 👋</p><pre><code>const value = 1\n  return value</code></pre>"
    const range = document.createRange()
    range.selectNodeContents(body.querySelector("code")!)
    const anchor = captureChatQuoteAnchor(body, range)
    body.querySelector("code")!.innerHTML = "<span>const value = 1</span>\n  <span>return value</span>"
    expect(resolveChatQuoteAnchor(body, { text: anchor.exact, anchor })?.toString()).toBe(
      "const value = 1\n  return value",
    )
  })
})
