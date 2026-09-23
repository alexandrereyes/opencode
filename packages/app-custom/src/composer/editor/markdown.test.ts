import { describe, expect, test } from "bun:test"
import { history, undo } from "@codemirror/commands"
import { Compartment, EditorState } from "@codemirror/state"
import { EditorView } from "@codemirror/view"
import { composerReferenceHistory, composerReferences, setComposerReferences } from "./codemirror"
import { composerMarkdown, markdownKeyEdit, markdownLinkEdit, tokenizeMarkdown } from "./markdown"

const spans = (text: string) => tokenizeMarkdown(text).map((range) => [text.slice(range.from, range.to), range.style])

describe("markdown source", () => {
  test("block markers and absolute offsets", () => {
    expect(spans("intro\n## Title\n>> quote\n!!! attention\n  12) item")).toEqual([
      ["##", "marker"],
      ["Title", "heading"],
      [">>", "marker"],
      ["quote", "quote"],
      ["!!!", "marker"],
      ["attention", "attention"],
      ["12)", "list"],
    ])
  })
  test.each(["-", "*", "+", "1.", "2)", "123456789."])("list %s only colors the marker", (marker) => {
    expect(spans(`  ${marker} item`)).toEqual([[marker, "list"]])
  })
  test.each([
    "",
    "##Title",
    "####### title",
    "-nodash",
    "1234567890. item",
    "!!!important",
    "wild!!!",
    "!! close",
    "~/repo/file",
    "2 * 3 * 4",
    "foo_bar_baz",
    "SCREAMING_SNAKE_CASE",
    "trailing * ",
    "ends *",
    "*never closed",
    "*open\nclose*",
  ])("plain text: %s", (text) => {
    expect(spans(text)).toEqual([])
  })
  test.each(["```", "~~~"])("uniform fenced code %s", (fence) => {
    expect(spans(`${fence}ts\n# **code**\n${fence}\n- item`)).toEqual([
      [fence + "ts", "fence"],
      ["# **code**", "fence"],
      [fence, "fence"],
      ["-", "list"],
    ])
  })
  test("fences need matching character and length, no info on close", () => {
    expect(spans("````\n```\n~~~~\n````js\n`````\n# title").map((span) => span[1])).toEqual([
      "fence",
      "fence",
      "fence",
      "fence",
      "fence",
      "marker",
      "heading",
    ])
    expect(spans("```\n\n# unclosed")).toEqual([
      ["```", "fence"],
      ["# unclosed", "fence"],
    ])
  })
  test("inline code suppresses scanning", () => {
    expect(spans("run ``a ` **b**`` now")).toEqual([["``a ` **b**``", "code"]])
    expect(spans("a ` b")).toEqual([])
  })
  test("links preserve punctuation and empty labels", () => {
    expect(spans("[docs](https://x.dev) [](url)")).toEqual([
      ["[", "marker"],
      ["docs", "link"],
      ["](", "marker"],
      ["https://x.dev", "url"],
      [")", "marker"],
      ["[", "marker"],
      ["](", "marker"],
      ["url", "url"],
      [")", "marker"],
    ])
  })
  test.each(["*", "_", "**", "__", "***", "___"])("emphasis %s", (run) => {
    expect(spans(`${run}word${run}`)).toEqual([
      [run, "marker"],
      ...(run.length >= 2 ? [["word", "strong"]] : []),
      ...(run.length !== 2 ? [["word", "emphasis"]] : []),
      [run, "marker"],
    ])
  })
  test("nested inline styles compose with blocks", () => {
    expect(spans("# **see `code`**").map((span) => span[1])).toEqual([
      "marker",
      "heading",
      "marker",
      "strong",
      "marker",
      "code",
    ])
  })
  test("references exclude all markdown marks and reference-only updates restore styling", () => {
    const compartment = new Compartment()
    const state = EditorState.create({
      doc: "# **@agent**",
      extensions: [composerReferences, compartment.of(composerMarkdown)],
    })
    const referenced = state.update({
      effects: setComposerReferences.of([
        { from: 4, to: 10, part: { type: "agent", name: "agent", content: "@agent", start: 4, end: 10 } },
      ]),
    }).state
    const decorations = referenced.facet(EditorView.decorations)
    decorations.forEach((set) => {
      if (typeof set === "function") return
      set.between(4, 10, (from, to, value) => {
        if (value.spec.class === "composer-reference") return
        expect(from >= 10 || to <= 4).toBe(true)
      })
    })
    expect(referenced.field(composerMarkdown)).toBe(state.field(composerMarkdown))
    const cleared = referenced.update({ effects: setComposerReferences.of([]) }).state
    const restored: string[] = []
    cleared.facet(EditorView.decorations).forEach((set) => {
      if (typeof set === "function") return
      set.between(5, 9, (_from, _to, value) => {
        restored.push(value.spec.class)
      })
    })
    expect(restored).toContain("composer-md-heading composer-md-strong")
    expect(cleared.update({ selection: { anchor: 2 } }).state.field(composerMarkdown)).toBe(
      state.field(composerMarkdown),
    )
    expect(
      referenced.update({ effects: compartment.reconfigure([]) }).state.field(composerMarkdown, false),
    ).toBeUndefined()
  })
})

describe("markdown edits", () => {
  test.each(["`", "*", "_", "~", "(", "[", "{", '"', "'"])("wraps with %s keeping inner selection", (key) => {
    const state = EditorState.create({ doc: "word", selection: { anchor: 4, head: 0 } })
    const next = state.update(markdownKeyEdit(state, key)!).state
    expect(next.sliceDoc(next.selection.main.from, next.selection.main.to)).toBe("word")
    expect(next.selection.main.anchor).toBe(5)
    expect(next.doc.length).toBe(6)
  })
  test("fence skeleton at line start including indentation", () => {
    const state = EditorState.create({ doc: "intro\n  ``", selection: { anchor: 10 } })
    const next = state.update(markdownKeyEdit(state, "`")!).state
    expect(next.doc.toString()).toBe("intro\n  ```\n\n```")
    expect(next.selection.main.head).toBe(12)
    const filled = next.update({ changes: { from: next.selection.main.head, insert: "# **code**" } }).state
    expect(spans(filled.doc.toString())).toEqual([
      ["  ```", "fence"],
      ["# **code**", "fence"],
      ["```", "fence"],
    ])
    expect(markdownKeyEdit(EditorState.create({ doc: "a``", selection: { anchor: 3 } }), "`")).toBeUndefined()
  })
  test.each(["https://example.com", "http://example.com", "mailto:user@example.com"])("URL paste %s", (url) => {
    const state = EditorState.create({ doc: "label", selection: { anchor: 0, head: 5 } })
    expect(state.update(markdownLinkEdit(state, url)!).state.doc.toString()).toBe(`[label](${url})`)
  })
  test.each(["opencode://session/abc", "https://a\nhttps://b", "https://a b", " https://a"])(
    "ordinary paste %s",
    (url) => {
      expect(
        markdownLinkEdit(EditorState.create({ doc: "label", selection: { anchor: 0, head: 5 } }), url),
      ).toBeUndefined()
    },
  )
  test.each(["", " ", "https://a", "mailto:a@b", "[label](url)"])("does not link selection %s", (doc) => {
    expect(
      markdownLinkEdit(EditorState.create({ doc, selection: { anchor: 0, head: doc.length } }), "https://b"),
    ).toBeUndefined()
  })
  test.each(["wrap", "link"])("%s preserves reference boundaries and one undo restores the original", (edit) => {
    const original = EditorState.create({
      doc: "@agent",
      selection: { anchor: 0, head: 6 },
      extensions: [
        history(),
        composerReferences.init(() => [
          { from: 0, to: 6, part: { type: "agent", name: "agent", content: "@agent", start: 0, end: 6 } },
        ]),
        composerReferenceHistory,
      ],
    })
    const wrapped = original.update(
      (edit === "wrap" ? markdownKeyEdit(original, "`") : markdownLinkEdit(original, "https://example.com"))!,
    ).state
    expect(wrapped.doc.toString()).toBe(edit === "wrap" ? "`@agent`" : "[@agent](https://example.com)")
    expect(wrapped.field(composerReferences)).toEqual([
      { from: 1, to: 7, part: { type: "agent", name: "agent", content: "@agent", start: 1, end: 7 } },
    ])
    expect(wrapped.sliceDoc(1, 7)).toBe("@agent")
    expect(wrapped.selection.main.anchor).toBe(edit === "wrap" ? 1 : wrapped.doc.length)
    expect(wrapped.selection.main.head).toBe(edit === "wrap" ? 7 : wrapped.doc.length)
    expect(
      undo({
        state: wrapped,
        dispatch: (transaction) => {
          expect(transaction.state.doc.toString()).toBe("@agent")
          expect(transaction.state.field(composerReferences)).toEqual(original.field(composerReferences))
          expect(transaction.state.selection).toEqual(original.selection)
        },
      }),
    ).toBe(true)
  })
})
