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
    expect(anchor).toEqual({
      start: 13,
      end: 26,
      exact: "repeat phrase",
      coordinate: "rendered",
      prefix: "repeat phrase",
      suffix: "",
    })
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

  test("finds iOS source anchors by their copyable text and context", () => {
    const body = document.createElement("div")
    body.innerHTML =
      "<p>Status:</p><ul><li><strong>Rodando:</strong> nada.</li><li><strong>Rodando:</strong> tudo.</li></ul>"
    const source = (text: string, prefix: string, suffix: string) => ({
      text,
      anchor: { start: 12, end: 29, exact: "**Rodando:** nada", coordinate: "source" as const, prefix, suffix },
    })
    expect(resolveChatQuoteAnchor(body, source("Rodando: nada", "Status:\n", ".\nRodando"))?.toString()).toBe(
      "Rodando: nada",
    )
    const repeated = resolveChatQuoteAnchor(body, source("Rodando:", "nada.\n", " tudo."))
    expect(repeated?.startContainer).toBe(body.querySelectorAll("strong")[1]!.firstChild!)
    expect(resolveChatQuoteAnchor(body, source("Rodando:", "", ""))).toBeUndefined()
    expect(resolveChatQuoteAnchor(body, source("ausente", "", ""))).toBeUndefined()
  })

  test("matches across different whitespace and relocates rendered anchors only with context", () => {
    const body = document.createElement("div")
    body.innerHTML = "<p>first   line</p>\n\n<p>second line</p>"
    const moved = { start: 0, end: 4, exact: "line", prefix: "second ", suffix: "" }
    expect(resolveChatQuoteAnchor(body, { text: "line", anchor: moved })?.toString()).toBe("line")
    expect(resolveChatQuoteAnchor(body, { text: "line", anchor: moved })?.startContainer).toBe(
      body.querySelectorAll("p")[1]!.firstChild!,
    )
    expect(
      resolveChatQuoteAnchor(body, {
        text: "first line second",
        anchor: { start: 0, end: 1, exact: "x", coordinate: "source", prefix: "", suffix: "" },
      })?.toString(),
    ).toBe("first   line\n\nsecond")
  })
})
