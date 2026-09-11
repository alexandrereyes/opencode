import { describe, expect, test } from "bun:test"
import { history, redo, undo } from "@codemirror/commands"
import { EditorState, type Transaction, type TransactionSpec } from "@codemirror/state"
import { Skill } from "@opencode/schema/skill"
import { Session } from "@opencode/schema/session"
import {
  composerPromptFromDocument,
  composerReferenceHistory,
  composerReferences,
  composerReferencesFromPrompt,
  copyComposerText,
  setComposerReferences,
} from "./codemirror"
import type { ComposerPrompt } from "../types"
import { normalizeComposerCursor, normalizeComposerPrompt } from "../prompt-parts"

const skill = {
  type: "skill" as const,
  id: Skill.ID.make("effect"),
  name: Skill.Name.make("Effect"),
  content: "$effect",
  start: 2,
  end: 9,
}

function createView(prompt: ComposerPrompt) {
  const normalized = normalizeComposerPrompt(prompt)
  const text = normalized.map((part) => ("content" in part ? part.content : "")).join("")
  let state = EditorState.create({
    doc: text,
    extensions: [
      history(),
      composerReferences.init(() => composerReferencesFromPrompt(normalized)),
      composerReferenceHistory,
    ],
  })
  const target = {
    get state() {
      return state
    },
    dispatch(transaction: Transaction) {
      state = transaction.state
    },
  }
  return {
    get state() {
      return state
    },
    dispatch(spec: TransactionSpec) {
      state = state.update(spec).state
    },
    command(command: typeof undo) {
      return command(target)
    },
  }
}

describe("CodeMirror composer references", () => {
  test("maps edits outside a reference and invalidates edits inside or across its limits", () => {
    const view = createView([
      { type: "text", content: "A ", start: 0, end: 2 },
      skill,
      { type: "text", content: " B", start: 9, end: 11 },
    ])

    view.dispatch({ changes: { from: 0, insert: "X" } })
    expect(view.state.field(composerReferences)).toMatchObject([
      { from: 3, to: 10, part: { type: "skill", start: 3, end: 10 } },
    ])

    view.dispatch({ changes: { from: 10, insert: "!" } })
    expect(view.state.field(composerReferences)).toMatchObject([{ from: 3, to: 10, part: { type: "skill" } }])

    view.dispatch({ changes: { from: 9, to: 10 } })
    expect(view.state.field(composerReferences)).toEqual([])
    expect(composerPromptFromDocument(view.state.doc.toString(), view.state.field(composerReferences), [])).toEqual([
      { type: "text", content: "XA $effec! B", start: 0, end: 12 },
    ])

    expect(view.command(undo)).toBe(true)
    expect(view.state.field(composerReferences)).toMatchObject([{ from: 3, to: 10, part: { type: "skill" } }])
    expect(view.command(redo)).toBe(true)
    expect(view.state.field(composerReferences)).toEqual([])
  })

  test("round-trips mapped references without producing a controlled rewrite", () => {
    const view = createView([{ type: "text", content: "A ", start: 0, end: 2 }, skill])

    view.dispatch({ changes: { from: 0, insert: "prefix " } })
    const projected = composerPromptFromDocument(view.state.doc.toString(), view.state.field(composerReferences), [])
    expect(composerReferencesFromPrompt(projected)).toEqual([...view.state.field(composerReferences)])

    expect(view.command(undo)).toBe(true)
    expect(view.state.doc.toString()).toBe("A $effect")
    expect(view.state.field(composerReferences)).toMatchObject([{ from: 2, to: 9, part: { start: 2, end: 9 } }])
    expect(view.command(redo)).toBe(true)
    expect(view.state.doc.toString()).toBe("prefix A $effect")
    expect(view.state.field(composerReferences)).toMatchObject([{ from: 9, to: 16, part: { start: 9, end: 16 } }])
  })

  test("invalidates a reference when its first character or middle is edited", () => {
    for (const changes of [
      { from: 2, to: 3 },
      { from: 5, insert: "x" },
    ]) {
      const view = createView([
        { type: "text", content: "A ", start: 0, end: 2 },
        skill,
        { type: "text", content: " B", start: 9, end: 11 },
      ])
      view.dispatch({ changes })
      expect(view.state.field(composerReferences)).toEqual([])
      expect(composerPromptFromDocument(view.state.doc.toString(), view.state.field(composerReferences), [])).toEqual([
        { type: "text", content: view.state.doc.toString(), start: 0, end: view.state.doc.length },
      ])
    }
  })

  test("restores inserted reference text and identity through undo and redo", () => {
    const view = createView([{ type: "text", content: "$eff", start: 0, end: 4 }])
    const prompt: ComposerPrompt = [
      { ...skill, start: 0, end: 7 },
      { type: "text", content: " ", start: 7, end: 8 },
    ]

    view.dispatch({
      changes: { from: 0, to: 4, insert: "$effect " },
      selection: { anchor: 8 },
      effects: setComposerReferences.of(composerReferencesFromPrompt(prompt)),
    })
    expect(view.state.doc.toString()).toBe("$effect ")
    expect(view.state.field(composerReferences)[0]?.part).toMatchObject({ type: "skill", id: "effect" })

    expect(view.command(undo)).toBe(true)
    expect(view.state.doc.toString()).toBe("$eff")
    expect(view.state.field(composerReferences)).toEqual([])
    expect(view.command(redo)).toBe(true)
    expect(view.state.field(composerReferences)[0]?.part).toMatchObject({ type: "skill", id: "effect" })
  })

  test("round-trips duplicate visible references by range and serializes sessions for the clipboard", () => {
    const session = {
      type: "session" as const,
      session: {
        id: Session.ID.make("ses_reference_12345678901234567890"),
        server: "http://localhost:4096",
        title: "Shared",
      },
      content: "@Shared",
      start: 0,
      end: 7,
    }
    const prompt: ComposerPrompt = [
      session,
      { type: "text", content: " ", start: 7, end: 8 },
      { ...session, start: 8, end: 15 },
    ]
    const references = composerReferencesFromPrompt(prompt)

    expect(composerPromptFromDocument("@Shared @Shared", references, [])).toEqual(prompt)
    expect(copyComposerText("@Shared @Shared", references, 0, 15)).toContain("ses_reference_12345678901234567890")
    expect(copyComposerText("@Shared @Shared", references, 1, 4)).toBeUndefined()
  })

  test("normalizes CRLF before deriving reference ranges and caret positions", () => {
    const prompt: ComposerPrompt = [
      { type: "text", content: "before\r\n", start: 0, end: 8 },
      { ...skill, start: 8, end: 15 },
      { type: "text", content: "\r\nafter", start: 15, end: 22 },
    ]

    expect(normalizeComposerPrompt(prompt)).toEqual([
      { type: "text", content: "before\n", start: 0, end: 7 },
      { ...skill, start: 7, end: 14 },
      { type: "text", content: "\nafter", start: 14, end: 20 },
    ])
    expect(composerReferencesFromPrompt(prompt)).toMatchObject([
      { from: 7, to: 14, part: { start: 7, end: 14, type: "skill" } },
    ])
    expect(normalizeComposerCursor(prompt, 22)).toBe(20)
    expect(normalizeComposerCursor(prompt, 8)).toBe(7)
  })
})
