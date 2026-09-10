import { describe, expect, test } from "bun:test"
import { createStore } from "solid-js/store"
import { Session } from "@opencode/schema/session"
import { Schema } from "effect"
import type { ComposerPersistedState, ComposerSessionPart } from "./types"
import { createComposerEditorActions } from "./editor/actions"
import { extractPromptFromMessage } from "./prompt"
import { buildPromptRequest } from "./request"
import { formatSessionReference, formatSessionReferences, parseSessionReferences } from "./session-reference"
import { ComposerStore } from "./schema"
import { prependHistoryEntry } from "./history/entry"

const server = "http://localhost:4096"
const part = (id: string, title: string, start: number): ComposerSessionPart => ({
  type: "session",
  content: `@${title}`,
  start,
  end: start + title.length + 1,
  session: { id: Session.ID.make(id), server, title, directory: `/work/${id}` },
})

describe("session references", () => {
  test("preserves distinct identities for duplicate titles through portable copy and paste", () => {
    const sessions = [part("ses_one", "Same", 0), part("ses_two", "Same", 10)]
    const copied = formatSessionReferences("@Same and @Same", sessions)
    const pasted = parseSessionReferences(copied, server)

    expect(copied).toContain("opencode://session/ses_one")
    expect(copied).toContain("opencode://session/ses_two")
    expect(pasted?.filter((item) => item.type === "session").map((item) => String(item.session.id))).toEqual([
      "ses_one",
      "ses_two",
    ])
    expect(pasted?.flatMap((item) => ("content" in item ? [item.content] : [])).join("")).toBe("@Same and @Same")
  })

  test("does not bind a reference copied from another server", () => {
    expect(parseSessionReferences(formatSessionReference(part("ses_one", "One", 0)), "sidecar")).toBeUndefined()
  })

  test("persists session identity and keeps equal titles distinct in history", () => {
    const first = part("ses_one", "Same", 0)
    const second = part("ses_two", "Same", 0)
    const persisted = Schema.decodeUnknownSync(ComposerStore)(
      JSON.parse(JSON.stringify({ prompt: [first], cursor: 5, context: { items: [] } })),
    )
    const history = prependHistoryEntry(prependHistoryEntry([], [first]), [second])

    expect(persisted.prompt).toEqual([first])
    expect(history).toHaveLength(2)
  })

  test("deduplicates model context without removing repeated metadata occurrences", () => {
    const first = part("ses_one", "Same", 0)
    const second = part("ses_one", "Same", 10)
    const request = buildPromptRequest({
      prompt: [first, { type: "text", content: " and ", start: 5, end: 10 }, second],
      context: [],
      images: [],
      text: "@Same and @Same",
      sessionDirectory: "/work/current",
    })

    expect(request.sessions).toHaveLength(2)
    expect(request.text.match(/"sessionID":"ses_one"/g)).toHaveLength(1)
  })

  test("ignores stale offsets instead of rebinding identity to an equal title", () => {
    const valid = part("ses_valid", "Same", 11)
    const stale = part("ses_stale", "Same", 99)
    const prompt = extractPromptFromMessage({
      id: "msg_session",
      type: "user",
      text: "@Same then @Same",
      metadata: { displayText: "@Same then @Same", comments: [], sessions: [stale, valid] },
      time: { created: 1 },
    })

    expect(prompt.filter((item) => item.type === "session").map((item) => String(item.session.id))).toEqual([
      "ses_valid",
    ])
    expect(prompt.flatMap((item) => ("content" in item ? [item.content] : [])).join("")).toBe("@Same then @Same")
  })

  test("replaces a selected range containing an existing chip", () => {
    const old = part("ses_old", "Old", 2)
    const next = part("ses_new", "New", 0)
    const [state, setState] = createStore<ComposerPersistedState>({
      prompt: [
        { type: "text", content: "A ", start: 0, end: 2 },
        old,
        { type: "text", content: " Z", start: 6, end: 8 },
      ],
      cursor: 6,
      context: { items: [] },
    })
    const actions = createComposerEditorActions([state, setState])

    actions.replaceRange([next], { start: 2, end: 6 })

    expect(state.prompt.flatMap((item) => ("content" in item ? [item.content] : [])).join("")).toBe("A @New Z")
    expect(state.prompt.filter((item) => item.type === "session").map((item) => String(item.session.id))).toEqual([
      "ses_new",
    ])
    expect(state.cursor).toBe(6)
  })
})
