import { describe, expect, test } from "bun:test"
import type { SessionInboxInfo } from "@opencode/client/promise"
import { Session } from "@opencode/schema/session"
import { EditorState } from "@codemirror/state"
import { editedPromptInput, queuedPrompt, queuedPromptAttachments, queuedPromptRows } from "./queue"
import type { ImageAttachmentPart, SessionPart } from "@/composer/state"
import type { AttachmentDestination } from "@/composer/attachments/deliver"
import { readPromptPresentation } from "@/composer/comment-note"
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
    time: { created: 1 },
    type: "user",
    delivery: "queue",
    payload: { text: "original" },
  },
  {
    id: "msg_replacement",
    sessionID: "ses_1",
    time: { created: 2 },
    type: "user",
    delivery: "queue",
    payload: { text: "edited" },
  },
] satisfies SessionInboxInfo[]

const nativeDestination: AttachmentDestination = {
  input: { image: true, pdf: true },
  local: false,
  upload: () => Promise.reject(new Error("Native attachments must not upload")),
}

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

  test("counts a path-only attachment when the row has no display text", () => {
    const item = {
      ...queued[0],
      payload: {
        text: "Attached file: `/remote/archive.zip`",
        files: [],
        metadata: {
          displayText: "",
          comments: [],
          attachments: [{ name: "archive.zip", mime: "application/zip", path: "/remote/archive.zip" }],
        },
      },
    } satisfies Extract<SessionInboxInfo, { type: "user" }>

    expect(queuedPromptRows([item])).toEqual([{ id: "msg_original", text: "", attachments: 1 }])
  })
})

describe("queuedPromptAttachments", () => {
  test("restores uncited inline files of any MIME with stable data URI references", () => {
    const item = {
      ...queued[0],
      payload: {
        text: "see [photo.png]",
        files: [
          { data: "aW1hZ2U=", mime: "image/png", source: { type: "inline" }, name: "loose.png" },
          { data: "cGRm", mime: "application/pdf", source: { type: "inline" }, name: "notes.pdf" },
          { data: "AAEC", mime: "application/octet-stream", source: { type: "inline" }, name: "data.bin" },
          {
            data: "Y2l0ZWQ=",
            mime: "image/png",
            source: { type: "inline" },
            name: "photo.png",
            mention: { text: "[photo.png]", start: 4, end: 15 },
          },
          { data: "ZXh0ZXJuYWw=", mime: "text/plain", source: { type: "uri", uri: "file:///tmp/external.txt" } },
        ],
      },
    } satisfies Extract<SessionInboxInfo, { type: "user" }>

    expect(queuedPromptAttachments(item)).toEqual([
      {
        type: "image",
        id: "msg_original:file:0",
        filename: "loose.png",
        mime: "image/png",
        blob: { id: "data:image/png;base64,aW1hZ2U=", url: "data:image/png;base64,aW1hZ2U=" },
      },
      {
        type: "image",
        id: "msg_original:file:1",
        filename: "notes.pdf",
        mime: "application/pdf",
        blob: { id: "data:application/pdf;base64,cGRm", url: "data:application/pdf;base64,cGRm" },
      },
      {
        type: "image",
        id: "msg_original:file:2",
        filename: "data.bin",
        mime: "application/octet-stream",
        blob: {
          id: "data:application/octet-stream;base64,AAEC",
          url: "data:application/octet-stream;base64,AAEC",
        },
      },
    ])
    expect(
      queuedPrompt(item)
        .filter((part) => part.type === "image")
        .map((part) => part.id),
    ).toEqual(["msg_original:file:3", "msg_original:file:0", "msg_original:file:1", "msg_original:file:2"])
  })
})

test("queue edits upload image and PDF attachments when the destination cannot read them inline", async () => {
  const item = {
    ...queued[0],
    payload: {
      text: "inspect",
      files: [
        { data: "aW1hZ2U=", mime: "image/png", source: { type: "inline" }, name: "image.png" },
        { data: "cGRm", mime: "application/pdf", source: { type: "inline" }, name: "document.pdf" },
      ],
      metadata: { displayText: "inspect" },
    },
  } satisfies Extract<SessionInboxInfo, { type: "user" }>
  const uploads: string[] = []
  const destination: AttachmentDestination = {
    input: { image: false, pdf: false },
    local: false,
    upload: (file) => {
      uploads.push(file.name)
      return Promise.resolve(`/remote/${file.name}`)
    },
  }

  const result = await editedPromptInput(
    "ses_current",
    "/current",
    item,
    queuedPrompt(item),
    "inspect",
    destination,
    [],
  )

  expect(uploads).toEqual(["image.png", "document.pdf"])
  expect(result.files).toEqual([])
  expect(result.metadata.attachments).toEqual([
    { name: "image.png", mime: "image/png", path: "/remote/image.png" },
    { name: "document.pdf", mime: "application/pdf", path: "/remote/document.pdf" },
  ])
  expect(result.metadata.comments).toEqual([])
  expect(result.text.match(/Attached file:/g)).toHaveLength(2)

  const next = {
    ...item,
    id: "msg_replacement",
    payload: { text: result.text, metadata: result.metadata },
  } satisfies Extract<SessionInboxInfo, { type: "user" }>
  const nextText = "inspect carefully"
  const roundTrip = await editedPromptInput(
    "ses_current",
    "/current",
    next,
    [{ type: "text", content: nextText, start: 0, end: nextText.length }, ...queuedPromptAttachments(next)],
    nextText,
    nativeDestination,
    [],
  )

  expect(readPromptPresentation(roundTrip.metadata)?.attachments).toEqual(result.metadata.attachments)
  expect(roundTrip.text.match(/Attached file: `\/remote\/(image\.png|document\.pdf)`/g)).toHaveLength(2)
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
    time: { created: 1 },
    type: "user",
    delivery: "queue",
    payload: {
      text: `@Same\n${formatSessionContext(original)}`,
      metadata: { displayText: "@Same", sessions: [original] },
    },
  } as Extract<SessionInboxInfo, { type: "user" }>

  const result = await editedPromptInput("ses_current", "/current", item, [replacement], "@Same", nativeDestination, [])

  expect(result.metadata.sessions).toEqual([replacement])
  expect(result.text).toContain('"sessionID":"ses_new"')
  expect(result.text).not.toContain('"sessionID":"ses_old"')
})

test("queue edits round-trip same-named cited images and preserve unrelated files", async () => {
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    time: { created: 1 },
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

  const result = await editedPromptInput(
    "ses_current",
    "/current",
    item,
    prompt,
    state.doc.toString(),
    nativeDestination,
    [],
  )
  expect(result.files).toHaveLength(2)
  expect(result.files?.map((file) => ({ name: file.name, mention: file.mention }))).toEqual([
    { name: "unrelated.png", mention: undefined },
    { name: "photo.png", mention: { text: "[photo-2.png]", start: 18, end: 31 } },
  ])
  const cited = result.files?.[1]
  if (!cited?.mention) throw new Error("Missing queued image mention")
  expect(state.doc.sliceString(cited.mention.start, cited.mention.end)).toBe(cited.mention.text)
})

test("queue edits remove and replace uncited inline files while preserving external references and metadata", async () => {
  const quote = { id: "quote_1", messageID: "msg_source", partID: "part_1", text: "quoted", comment: "keep" }
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    time: { created: 1 },
    type: "user",
    delivery: "queue",
    payload: {
      text: "Ask @agent with @skill",
      files: [
        { data: "b2xkIHBkZg==", mime: "application/pdf", source: { type: "inline" }, name: "remove.pdf" },
        { data: "b2xkIGJpbmFyeQ==", mime: "application/octet-stream", source: { type: "inline" }, name: "replace.bin" },
        { data: "a2VlcCBpbWFnZQ==", mime: "image/png", source: { type: "inline" }, name: "keep.png" },
        {
          data: "ZXh0ZXJuYWw=",
          mime: "text/plain",
          source: { type: "uri", uri: "file:///workspace/reference.txt" },
          name: "reference.txt",
        },
      ],
      agents: [{ name: "agent", mention: { text: "@agent", start: 4, end: 10 } }],
      skills: [{ id: "skill", name: "skill", mention: { text: "@skill", start: 16, end: 22 } }],
      metadata: { displayText: "Ask @agent with @skill", custom: { retained: true }, quotes: [quote] },
    },
  } satisfies Extract<SessionInboxInfo, { type: "user" }>
  const loaded = queuedPrompt(item)
  const replacement = loaded.find(
    (part): part is ImageAttachmentPart => part.type === "image" && part.filename === "replace.bin",
  )
  if (!replacement) throw new Error("Missing queued binary attachment")
  const kept = loaded.find((part): part is ImageAttachmentPart => part.type === "image" && part.filename === "keep.png")
  if (!kept) throw new Error("Missing queued image attachment")
  const prompt = [
    ...loaded.filter((part) => part.type !== "image"),
    kept,
    {
      ...replacement,
      blob: {
        id: "data:application/octet-stream;base64,bmV3IGJpbmFyeQ==",
        url: "data:application/octet-stream;base64,bmV3IGJpbmFyeQ==",
      },
    },
  ]
  const uploads: string[] = []
  const destination: AttachmentDestination = {
    input: { image: true, pdf: true },
    local: false,
    upload: (file) => {
      uploads.push(file.name)
      return Promise.resolve(`/remote/${file.name}`)
    },
  }

  const result = await editedPromptInput(
    "ses_current",
    "/current",
    item,
    prompt,
    "Ask @agent with @skill",
    destination,
    [quote],
  )

  expect(result.files.map((file) => ({ uri: file.uri, name: file.name, mention: file.mention }))).toEqual([
    { uri: "file:///workspace/reference.txt", name: "reference.txt", mention: undefined },
    {
      uri: "data:image/png;base64,a2VlcCBpbWFnZQ==",
      name: "keep.png",
      mention: undefined,
    },
  ])
  expect(uploads).toEqual(["replace.bin"])
  expect(result.agents).toEqual([{ name: "agent", mention: { text: "@agent", start: 4, end: 10 } }])
  expect(result.skills).toEqual([{ id: "skill", mention: { text: "@skill", start: 16, end: 22 } }])
  expect(result.metadata).toMatchObject({
    custom: { retained: true },
    displayText: "Ask @agent with @skill",
    quotes: [quote],
    attachments: [{ name: "replace.bin", mime: "application/octet-stream", path: "/remote/replace.bin" }],
  })
  expect(result.text.match(/Attached file: `\/remote\/replace\.bin`/g)).toHaveLength(1)
})

test("queued staged image citations preserve remapped ranges through snippet expansion", async () => {
  const text = "#s [large.png]"
  const result = await editedPromptInput(
    "ses_1",
    "/repo",
    undefined,
    [
      { type: "snippet", id: "s", name: "s", content: "#s", expansion: "expanded", start: 0, end: 2 },
      { type: "text", content: " [large.png]", start: 2, end: text.length },
      {
        type: "path",
        id: "large",
        filename: "large.png",
        mime: "image/png",
        path: "/tmp/large.png",
        mention: { text: "[large.png]", start: 3, end: text.length },
      },
    ],
    text,
    nativeDestination,
    [],
  )
  const item: Extract<SessionInboxInfo, { type: "user" }> = {
    id: "queued",
    sessionID: "ses_1",
    time: { created: 1 },
    type: "user",
    delivery: "queue",
    payload: { text: result.text, metadata: result.metadata },
  }
  expect(queuedPrompt(item)).toContainEqual({
    type: "path",
    id: "queued:path:0",
    filename: "large.png",
    mime: "image/png",
    path: "/tmp/large.png",
    mention: { text: "[large.png]", start: 9, end: 20 },
  })
})

test("queue edits can remove restored path attachments and their rendered note", async () => {
  const attachment = { name: "archive.zip", mime: "application/zip", path: "/remote/archive.zip" }
  const comment = { path: "src/index.ts", comment: "Keep this behavior" }
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    time: { created: 1 },
    type: "user",
    delivery: "queue",
    payload: {
      text: "Inspect archive\nAttached file: `/remote/archive.zip`",
      metadata: { displayText: "Inspect archive", comments: [comment], attachments: [attachment], custom: true },
    },
  } satisfies Extract<SessionInboxInfo, { type: "user" }>
  const prompt = [{ type: "text" as const, content: "Inspect archive carefully", start: 0, end: 25 }]

  const result = await editedPromptInput(
    "ses_current",
    "/current",
    item,
    prompt,
    "Inspect archive carefully",
    nativeDestination,
    [],
  )

  expect(queuedPromptAttachments(item)).toMatchObject([{ type: "path", path: attachment.path }])
  expect(result.metadata).toMatchObject({ attachments: [], comments: [comment], custom: true })
  expect(result.text).not.toContain("Attached file:")
})

test("queue edits replace matching hidden path metadata without duplicating its note", async () => {
  const attachment = { name: "archive.zip", mime: "application/zip", path: "/remote/archive.zip" }
  const item = {
    id: "msg_original",
    sessionID: "ses_current",
    time: { created: 1 },
    type: "user",
    delivery: "queue",
    payload: {
      text: "Inspect archive\nAttached file: `/remote/archive.zip`",
      metadata: { displayText: "Inspect archive", comments: [], attachments: [attachment] },
    },
  } satisfies Extract<SessionInboxInfo, { type: "user" }>
  const prompt: ImageAttachmentPart[] = [
    {
      type: "image",
      id: "replacement",
      filename: "archive.zip",
      sourcePath: "/remote/archive.zip",
      mime: "application/zip",
      blob: { id: "data:application/zip;base64,bmV3", url: "data:application/zip;base64,bmV3" },
    },
  ]
  const destination: AttachmentDestination = {
    input: { image: false, pdf: false },
    local: true,
    upload: () => Promise.reject(new Error("Local source paths must not upload")),
  }

  const result = await editedPromptInput("ses_current", "/current", item, prompt, "Inspect archive", destination, [])

  expect(result.metadata.attachments).toEqual([attachment])
  expect(result.text.match(/Attached file: `\/remote\/archive\.zip`/g)).toHaveLength(1)
})
