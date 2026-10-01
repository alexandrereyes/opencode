import { describe, expect, test } from "bun:test"
import type { SessionInboxInfo } from "@opencode/client/promise"
import { Session } from "@opencode/schema/session"
import { EditorState } from "@codemirror/state"
import { Skill } from "@opencode/schema/skill"
import { editedPromptInput, queuedPrompt, queuedPromptAttachments, queuedPromptRows, queuedPromptUndo } from "./queue"
import type { ImageAttachmentPart, Prompt, SessionPart } from "@/composer/state"
import type { AttachmentDestination, DeliveredAttachment } from "@/composer/attachments/deliver"
import type { ChatQuote } from "@/composer/schema"
import { buildPromptRequest } from "@/composer/request"
import { isAttachment } from "@/composer/prompt-parts"
import { chatQuoteAttachments } from "@/composer/chat-quote"
import type { ComposerAttachment } from "@/composer/types"
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
  upload: (file) => Promise.resolve(`/remote/${file.name}`),
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
      text: "Ask @agent with @skill\nAttached file: `/remote/remove.pdf`",
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
  expect(uploads).toEqual(["keep.png", "replace.bin"])
  expect(result.agents).toEqual([{ name: "agent", mention: { text: "@agent", start: 4, end: 10 } }])
  expect(result.skills).toEqual([{ id: "skill", mention: { text: "@skill", start: 16, end: 22 } }])
  expect(result.metadata).toMatchObject({
    custom: { retained: true },
    displayText: "Ask @agent with @skill",
    quotes: [quote],
    attachments: [{ name: "replace.bin", mime: "application/octet-stream", path: "/remote/replace.bin" }],
  })
  expect(result.text.match(/Attached file: `\/remote\/replace\.bin`/g)).toHaveLength(1)
  expect(result.text.match(/Attached file: `\/remote\/keep\.png`/g)).toHaveLength(1)
  expect(result.text.match(/Attached file:/g)).toHaveLength(2)
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

describe("queuedPromptUndo", () => {
  // Mirrors the admitted payload of a real submission: data URIs become inline files.
  const admit = (prompt: Prompt, attachments: DeliveredAttachment[], quotes: ChatQuote[] = []) => {
    const text = prompt.map((part) => ("content" in part ? part.content : "")).join("")
    const request = buildPromptRequest({ prompt, context: [], attachments, text, sessionDirectory: "/repo", quotes })
    return {
      ...queued[0],
      payload: {
        text: request.text,
        files: request.files.map((file) =>
          file.uri.startsWith("data:")
            ? {
                data: file.uri.slice(file.uri.indexOf(",") + 1),
                mime: file.mime,
                source: { type: "inline" as const },
                name: file.name,
                mention: file.mention,
              }
            : {
                data: "",
                mime: file.mime,
                source: { type: "uri" as const, uri: file.uri },
                name: file.name,
                mention: file.mention,
              },
        ),
        agents: request.agents,
        skills: request.skills,
        metadata: {
          displayText: request.displayText,
          apps: request.apps,
          sessions: request.sessions,
          comments: request.comments,
          quotes: request.quotes,
          attachments: request.attachments,
        },
      },
    } satisfies Extract<SessionInboxInfo, { type: "user" }>
  }
  const image: ImageAttachmentPart = {
    type: "image",
    id: "shot",
    filename: "shot.png",
    mime: "image/png",
    blob: { id: "data:image/png;base64,aGk=", url: "data:image/png;base64,aGk=" },
    mention: { text: "[shot.png]", start: 48, end: 58 },
  }
  const path = {
    type: "path" as const,
    id: "log",
    filename: "run.log",
    mime: "text/plain",
    path: "/remote/run.log",
    mention: { text: "[run.log]", start: 63, end: 72 },
  }
  const session: SessionPart = {
    type: "session",
    content: "@Earlier",
    start: 72,
    end: 80,
    session: { id: Session.ID.make("ses_earlier"), server: "local", title: "Earlier" },
  }
  const prompt: Prompt = [
    { type: "text", content: "Compare ", start: 0, end: 8 },
    {
      type: "file",
      content: "@src/a.ts",
      start: 8,
      end: 17,
      path: "src/a.ts",
      selection: { startLine: 2, endLine: 4, startChar: 0, endChar: 0 },
    },
    { type: "text", content: " with ", start: 17, end: 23 },
    { type: "agent", content: "@build", start: 23, end: 29, name: "build" },
    { type: "text", content: " using ", start: 29, end: 36 },
    {
      type: "skill",
      content: "$review",
      start: 36,
      end: 43,
      id: Skill.ID.make("review"),
      name: Skill.Name.make("review"),
    },
    { type: "text", content: " see [shot.png] and [run.log]", start: 43, end: 72 },
    session,
    image,
    path,
  ]
  const quote: ChatQuote = { id: "q1", messageID: "msg_a", partID: "prt_a", text: "earlier answer", comment: "why?" }

  test("restores structured parts, attachments, and quotes, and resends the same request", () => {
    const deliveries: DeliveredAttachment[] = [
      { type: "inline", attachment: image, dataUrl: "data:image/png;base64,aGk=", path: "/remote/shot.png" },
      { type: "path", attachment: path, path: path.path },
    ]
    const item = admit(prompt, deliveries, [quote])

    const restored = queuedPromptUndo(item, "/repo")
    expect(restored?.quotes).toEqual([quote])
    expect(restored?.prompt.map((part) => part.type)).toEqual(prompt.map((part) => part.type))
    const attachments = restored!.prompt.filter(isAttachment)
    const again = admit(
      restored!.prompt,
      [
        {
          type: "inline",
          attachment: attachments[0] as ImageAttachmentPart,
          dataUrl: "data:image/png;base64,aGk=",
          path: "/remote/shot.png",
        },
        { type: "path", attachment: attachments[1]!, path: path.path },
      ],
      restored!.quotes,
    )
    expect(again.payload).toEqual(item.payload)
  })

  test("restores quote comment attachments from the trailing files and resends the same request", () => {
    const picture: ImageAttachmentPart = {
      type: "image",
      id: "pic",
      filename: "pic.png",
      mime: "image/png",
      blob: { id: "hash-pic", url: "blob:local" },
      mention: { text: "[pic.png]", start: 4, end: 13 },
    }
    const doc = {
      type: "path" as const,
      id: "doc",
      filename: "doc.pdf",
      mime: "application/pdf",
      path: "/remote/doc.pdf",
    }
    const commented: ChatQuote = {
      ...quote,
      comment: "see [pic.png]",
      commentPrompt: [{ type: "text", content: "see [pic.png]", start: 0, end: 13 }, picture, doc],
    }
    const deliveries = (main: ComposerAttachment[], quoted: ComposerAttachment[]): DeliveredAttachment[] => [
      {
        type: "inline",
        attachment: main[0] as ImageAttachmentPart,
        dataUrl: "data:image/png;base64,aGk=",
        path: "/remote/shot.png",
      },
      { type: "path", attachment: main[1]!, path: path.path },
      {
        type: "inline",
        attachment: quoted[0] as ImageAttachmentPart,
        dataUrl: "data:image/png;base64,cGlj",
        path: "/remote/pic.png",
      },
      { type: "path", attachment: quoted[1]!, path: doc.path },
    ]
    const item = admit(prompt, deliveries([image, path], [picture, doc]), [commented])
    expect(item.payload.text).toContain(
      "Image attached to this comment: pic.png\nFile attached to this comment: `/remote/doc.pdf`",
    )
    expect(item.payload.files.at(-1)).toMatchObject({ data: "cGlj", source: { type: "inline" }, mention: undefined })
    expect(item.payload.metadata.quotes[0]?.commentPrompt?.[1]).toEqual({
      ...picture,
      blob: { id: "hash-pic", url: "" },
    })

    expect(
      queuedPrompt(item)
        .filter(isAttachment)
        .map((part) => part.id),
    ).toEqual([queuedPrompt(item).find((part) => part.type === "image")!.id, `${item.id}:path:0`])
    const restored = queuedPromptUndo(item, "/repo")
    expect(restored?.prompt.map((part) => part.type)).toEqual(prompt.map((part) => part.type))
    expect(restored?.quotes[0]?.commentPrompt?.slice(1)).toEqual([
      { ...picture, blob: { id: "data:image/png;base64,cGlj", url: "data:image/png;base64,cGlj" } },
      doc,
    ])
    const again = admit(
      restored!.prompt,
      deliveries(restored!.prompt.filter(isAttachment), chatQuoteAttachments(restored!.quotes)),
      restored!.quotes,
    )
    expect(again.payload.text).toBe(item.payload.text)
    expect(again.payload.files).toEqual(item.payload.files)
  })

  test("keeps MCP resource references as text", () => {
    const text = "Read @guide"
    const item = admit(
      [
        { type: "text", content: "Read ", start: 0, end: 5 },
        {
          type: "file",
          content: "@guide",
          start: 5,
          end: 11,
          path: "docs://guide",
          url: "docs://guide",
          source: {
            type: "resource",
            text: { value: "@guide", start: 0, end: 6 },
            clientName: "docs",
            uri: "docs://guide",
          },
        },
      ],
      [],
    )
    expect(item.payload.text).toBe(`${text}\nMCP resource docs://guide (server: docs)`)
    expect(queuedPromptUndo(item, "/repo")?.prompt).toEqual([
      { type: "text", content: text, start: 0, end: 11 },
      { type: "text", content: "\nMCP resource docs://guide (server: docs)", start: 11, end: 52 },
    ])
  })

  test("refuses prompts whose context the draft cannot hold", () => {
    const comment = admit([{ type: "text", content: "fix it", start: 0, end: 6 }], [])
    const withComment = {
      ...comment,
      payload: {
        ...comment.payload,
        text: `${comment.payload.text}\nThe user made the following comment regarding line 2 of src/a.ts: tighten`,
        files: [
          {
            data: "",
            mime: "text/plain",
            source: { type: "uri" as const, uri: "file:///repo/src/a.ts?start=2&end=2" },
          },
        ],
        metadata: { ...comment.payload.metadata, comments: [{ path: "src/a.ts", comment: "tighten" }] },
      },
    }
    const hidden = { ...comment, payload: { ...comment.payload, files: withComment.payload.files } }

    expect(queuedPromptUndo(withComment, "/repo")).toBeUndefined()
    expect(queuedPromptUndo(hidden, "/repo")).toBeUndefined()
  })
})
