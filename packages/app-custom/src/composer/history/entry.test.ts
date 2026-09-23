import { describe, expect, test } from "bun:test"
import type { Prompt } from "@/composer/state"
import { prependHistoryEntry, removeHistoryEntry, type PromptHistoryComment } from "./entry"
import { Schema } from "effect"
import { PromptHistoryState } from "../schema"
import { Persistence } from "@/runtime/persistence/schema"

const DEFAULT_PROMPT: Prompt = [{ type: "text", content: "", start: 0, end: 0 }]

test("failed history removal matches comments and leaves other attachment entries intact", () => {
  const prompt: Prompt = [
    { type: "path", id: "file", filename: "large.zip", mime: "application/zip", path: "/tmp/large.zip" },
  ]
  const earlier = prependHistoryEntry([], text("earlier"))
  const entries = prependHistoryEntry(earlier, prompt, [comment("note")])
  expect(removeHistoryEntry(entries, prompt)).toBe(entries)
  expect(removeHistoryEntry(entries, prompt, [comment("note")])).toEqual(earlier)
})

const text = (value: string): Prompt => [{ type: "text", content: value, start: 0, end: value.length }]
const comment = (id: string, value = "note"): PromptHistoryComment => ({
  id,
  path: "src/a.ts",
  selection: { start: 2, end: 4 },
  comment: value,
  time: 1,
  origin: "review",
  preview: "const a = 1",
})

describe("Composer history", () => {
  test("prependHistoryEntry skips empty prompt and deduplicates consecutive entries", () => {
    const first = prependHistoryEntry([], DEFAULT_PROMPT)
    expect(first).toEqual([])

    const commentsOnly = prependHistoryEntry([], DEFAULT_PROMPT, [comment("c1")])
    expect(commentsOnly).toHaveLength(1)

    const withOne = prependHistoryEntry([], text("hello"))
    expect(withOne).toHaveLength(1)

    const deduped = prependHistoryEntry(withOne, text("hello"))
    expect(deduped).toBe(withOne)

    const dedupedComments = prependHistoryEntry(commentsOnly, DEFAULT_PROMPT, [comment("c1")])
    expect(dedupedComments).toBe(commentsOnly)
  })

  test("insertion isolates canonical entries from source mutations", () => {
    const prompt: Prompt = [
      {
        type: "file",
        path: "src/a.ts",
        content: "@src/a.ts",
        start: 0,
        end: 9,
        selection: { startLine: 1, startChar: 0, endLine: 2, endChar: 0 },
      },
    ]
    const comments = [comment("c1")]
    const entries = prependHistoryEntry([], prompt, comments)
    const stored = entries[0]

    if (prompt[0]?.type !== "file" || stored?.prompt[0]?.type !== "file") throw new Error("expected file")
    prompt[0].selection!.startLine = 9
    comments[0].selection.start = 9

    expect(stored.prompt[0].selection?.startLine).toBe(1)
    expect(stored.comments[0]?.selection.start).toBe(2)
  })

  test("upgrades stored prompt arrays once at the persistence boundary", () => {
    expect(
      Schema.decodeUnknownSync(Persistence.withInitial(PromptHistoryState, { entries: [] }))({
        entries: [text("stored")],
      }),
    ).toEqual({
      entries: [{ prompt: text("stored"), comments: [] }],
    })
  })
})
