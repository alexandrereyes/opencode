import { describe, expect, test } from "bun:test"
import type { SessionInboxInfo } from "@opencode/client/promise"
import { Session } from "@opencode/schema/session"
import { EditorState } from "@codemirror/state"
import { editedPromptInput, queuedPrompt, queuedPromptRows } from "./queue"
import type { SessionPart } from "@/composer/state"
import { formatSessionContext } from "@/composer/session-reference"
import {
  composerPromptFromDocument,
  composerReferences,
  composerReferencesFromPrompt,
} from "@/composer/editor/codemirror"

const queued = [
  {
    id: "msg_original",
    sessionID: "ses_1",
    timeCreated: 1,
    type: "user",
    delivery: "queue",
    payload: { text: "original" },
  },
  {
    id: "msg_replacement",
    sessionID: "ses_1",
    timeCreated: 2,
    type: "user",
    delivery: "queue",
    payload: { text: "edited" },
  },
] satisfies SessionInboxInfo[]

describe("queuedPromptRows", () => {
  test("keeps the edited prompt to one row while its replacement is admitted", () => {
    expect(queuedPromptRows(queued, { original: "msg_original", replacement: "msg_replacement" })).toEqual([
      { id: "msg_replacement", text: "edited", attachments: 0 },
    ])
  })

  test("keeps the original visible until its replacement appears", () => {
    expect(queuedPromptRows([queued[0]], { original: "msg_original", replacement: "msg_replacement" })).toEqual([
      { id: "msg_original", text: "original", attachments: 0 },
    ])
  })

  test("retains unrelated queue entries", () => {
    expect(queuedPromptRows(queued)).toEqual([
      { id: "msg_original", text: "original", attachments: 0 },
      { id: "msg_replacement", text: "edited", attachments: 0 },
    ])
  })

  test("keeps other prompts visible while a mutation replaces the edited prompt", () => {
    const other = { ...queued[0], id: "msg_other", payload: { text: "other" } }

    expect(
      queuedPromptRows([queued[0], other, queued[1]], { original: "msg_original", replacement: "msg_replacement" }),
    ).toEqual([
      { id: "msg_other", text: "other", attachments: 0 },
      { id: "msg_replacement", text: "edited", attachments: 0 },
    ])
  })
})

test("queue edits replace session metadata and model context", async () => {
  const original: SessionPart = {
    type: "session",
    content: "@Same",
    start: 0,
    end: 5,
    session: { id: Session.ID.make("ses_old"), server: "sidecar", title: "Same", directory: "/old" },
  }
  const replacement: SessionPart = {
    ...original,
    session: { id: Session.ID.make("ses_new"), server: "sidecar", title: "Same", directory: "/new" },
  }
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    timeCreated: 1,
    type: "user",
    delivery: "queue",
    payload: {
      text: `@Same\n${formatSessionContext(original)}`,
      metadata: { displayText: "@Same", sessions: [original] },
    },
  } as Extract<SessionInboxInfo, { type: "user" }>

  const result = await editedPromptInput("ses_current", "/current", item, [replacement], "@Same", [])

  expect(result.metadata.sessions).toEqual([replacement])
  expect(result.text).toContain('"sessionID":"ses_new"')
  expect(result.text).not.toContain('"sessionID":"ses_old"')
})

test("queue edits round-trip same-named cited images and preserve unrelated files", async () => {
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    timeCreated: 1,
    type: "user",
    delivery: "queue",
    payload: {
      text: "See [photo.png] and [photo-2.png]",
      files: [
        {
          data: "YQ==",
          mime: "image/png",
          name: "photo.png",
          source: { type: "inline" },
          mention: { text: "[photo.png]", start: 4, end: 15 },
        },
        {
          data: "Yg==",
          mime: "image/png",
          name: "photo.png",
          source: { type: "inline" },
          mention: { text: "[photo-2.png]", start: 20, end: 33 },
        },
        {
          data: "Yw==",
          mime: "image/png",
          name: "unrelated.png",
          source: { type: "inline" },
          mention: { text: "[not-at-this-range.png]", start: 0, end: 23 },
        },
      ],
      metadata: { displayText: "See [photo.png] and [photo-2.png]" },
    },
  } as Extract<SessionInboxInfo, { type: "user" }>
  const loaded = queuedPrompt(item)
  const images = loaded.filter((part) => part.type === "image")
  expect(images.map((image) => image.filename)).toEqual(["photo.png", "photo-2.png"])
  expect(new Set(images.map((image) => image.id)).size).toBe(2)

  const state = EditorState.create({
    doc: "See [photo.png] and [photo-2.png]",
    extensions: [composerReferences.init(() => composerReferencesFromPrompt(loaded))],
  }).update({ changes: { from: 4, to: 15, insert: "photo.png" } }).state
  const prompt = composerPromptFromDocument(state.doc.toString(), state.field(composerReferences), images)

  const result = await editedPromptInput("ses_current", "/current", item, prompt, state.doc.toString(), [])
  expect(result.files).toHaveLength(2)
  expect(result.files?.map((file) => ({ name: file.name, mention: file.mention }))).toEqual([
    { name: "unrelated.png", mention: undefined },
    { name: "photo.png", mention: { text: "[photo-2.png]", start: 18, end: 31 } },
  ])
  const cited = result.files?.[1]
  if (!cited?.mention) throw new Error("Missing queued image mention")
  expect(state.doc.sliceString(cited.mention.start, cited.mention.end)).toBe(cited.mention.text)
})
