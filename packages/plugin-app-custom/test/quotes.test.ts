import { expect, test } from "bun:test"
import { Schema } from "effect"
import {
  addAttachment,
  clearQuotes,
  decodeAttachment,
  dismissQuotes,
  Doc,
  empty,
  importQuotes,
  removeQuote,
  saveQuote,
  type Result,
} from "../src/quotes"
import { Quotes } from "../src/quotes/rpc"

const quote = (id: string, extra: Partial<Quotes.QuoteInput> = {}): Quotes.QuoteInput => ({
  id,
  messageID: "msg_answer",
  partID: "prt_text",
  text: `quoted ${id}`,
  comment: "",
  anchor: { start: 0, end: 9, exact: `quoted ${id}`.slice(0, 9), coordinate: "source", prefix: "", suffix: " rest" },
  ...extra,
})
const image = decodeAttachment(Buffer.from("png bytes").toString("base64"))!
const attachment = { id: image.id, mime: "image/png", filename: "shot.png", size: image.bytes.length }

function ok<A>(result: Result<A>) {
  if (!result.ok) throw new Error(`unexpected failure: ${result.failure.type}`)
  return result
}

test("contract round-trips through the stored document and rejects reversed anchors", () => {
  const saved = ok(saveQuote(empty, quote("a", { commentPrompt: [{ type: "text", content: "x" }] }), 10)).doc
  expect(Schema.decodeUnknownSync(Doc)(Schema.encodeSync(Doc)(saved))).toEqual(saved)
  expect(Quotes.Definition.id).toBe("custom.quotes")
  expect(Object.keys(Quotes.Definition.methods)).toEqual([
    "info",
    "list",
    "save",
    "remove",
    "clear",
    "import",
    "dismiss",
    "upload",
    "attachment",
  ])
  expect(() => Schema.decodeUnknownSync(Quotes.Anchor)({ start: 5, end: 2, exact: "" })).toThrow()
  expect(() => Schema.decodeUnknownSync(Quotes.AttachmentID)("not-a-hash")).toThrow()
})

test("saving creates in order and updates in place with last write winning", () => {
  const first = ok(saveQuote(empty, quote("a"), 10))
  const second = ok(saveQuote(first.doc, quote("b"), 20))
  const edited = ok(saveQuote(second.doc, quote("a", { comment: "later" }), 30))
  expect(edited.doc.quotes.map((item) => [item.id, item.comment])).toEqual([
    ["a", "later"],
    ["b", ""],
  ])
  expect(edited.value).toMatchObject({ createdAt: 10, updatedAt: 30, revision: 3 })
  expect(edited.doc.revision).toBe(3)
})

test("sent quotes are tombstoned so stale saves and imports cannot bring them back", () => {
  const saved = ok(saveQuote(ok(saveQuote(empty, quote("a"), 1)).doc, quote("b"), 2)).doc
  const sent = clearQuotes(saved, { ids: ["a"], reason: "sent" }, 3)
  expect(sent.quotes.map((item) => item.id)).toEqual(["b"])
  expect(saveQuote(sent, quote("a", { comment: "stale edit" }), 4)).toEqual({
    ok: false,
    failure: { type: "already_sent", data: { ids: ["a"] } },
  })
  expect(ok(importQuotes(sent, [quote("a")], 5)).value).toEqual({ imported: [], skipped: ["a"] })
  expect(clearQuotes(sent, { ids: ["a"], reason: "sent" }, 6)).toBe(sent)
  const discarded = clearQuotes(sent, { reason: "discarded" }, 7)
  expect(discarded.quotes).toEqual([])
  expect(ok(saveQuote(discarded, quote("b"), 8)).doc.quotes).toHaveLength(1)
  expect(removeQuote(discarded, "missing", 9)).toBe(discarded)
})

test("import is idempotent by ID and by content, and never overwrites server state", () => {
  const server = ok(saveQuote(empty, quote("a", { comment: "server" }), 1)).doc
  const first = ok(importQuotes(server, [quote("a", { comment: "local" }), quote("b"), { ...quote("b"), id: "b2" }], 2))
  expect(first.value).toEqual({ imported: ["b"], skipped: ["a", "b2"] })
  expect(first.doc.quotes.find((item) => item.id === "a")?.comment).toBe("server")
  const again = ok(importQuotes(first.doc, [quote("b"), { ...quote("b"), id: "c" }], 3))
  expect(again.value).toEqual({ imported: [], skipped: ["b", "c"] })
  expect(again.doc).toBe(first.doc)
})

test("limits reject over-full sessions, oversized prompts and missing attachments without partial writes", () => {
  const full = Array.from({ length: Quotes.limits.quotesPerSession }, (_, index) => quote(`q${index}`))
  const filled = ok(importQuotes(empty, full, 1)).doc
  expect(saveQuote(filled, quote("extra"), 2)).toMatchObject({ ok: false, failure: { type: "limit_exceeded" } })
  expect(ok(saveQuote(filled, quote("q0", { comment: "edit still allowed" }), 2)).doc.quotes).toHaveLength(100)
  expect(importQuotes(ok(saveQuote(empty, quote("a"), 1)).doc, full, 2)).toMatchObject({
    ok: false,
    failure: { type: "limit_exceeded", data: { limit: "quotesPerSession" } },
  })
  const prompt = [{ type: "text", content: "x".repeat(Quotes.limits.commentPromptBytes) }]
  expect(saveQuote(empty, quote("a", { commentPrompt: prompt }), 1)).toMatchObject({
    ok: false,
    failure: { type: "limit_exceeded", data: { limit: "commentPromptBytes" } },
  })
  expect(importQuotes(empty, [quote("a", { attachments: [image.id] }), quote("b")], 1)).toEqual({
    ok: false,
    failure: { type: "attachment_missing", data: { ids: [image.id] } },
  })
  const big = { ...attachment, id: "f".repeat(64), size: Quotes.limits.sessionAttachmentBytes }
  const withBig = ok(addAttachment(empty, big, 1)).doc
  expect(addAttachment(withBig, attachment, 2)).toMatchObject({
    ok: false,
    failure: { type: "limit_exceeded", data: { limit: "sessionAttachmentBytes" } },
  })
})

test("attachments are content-addressed, listed as metadata and collected once unreferenced", () => {
  expect(decodeAttachment("not base64!")).toBeUndefined()
  expect(decodeAttachment("")).toBeUndefined()
  expect(image.id).toBe(decodeAttachment(Buffer.from("png bytes").toString("base64"))!.id)
  const uploaded = ok(addAttachment(empty, attachment, 0)).doc
  expect(ok(addAttachment(uploaded, attachment, 5)).doc.attachments).toHaveLength(1)
  const saved = ok(saveQuote(uploaded, quote("a", { attachments: [image.id, image.id] }), 1))
  expect(saved.value.attachments).toEqual([attachment])
  const later = Quotes.limits.attachmentGraceMs * 2
  expect(ok(saveQuote(saved.doc, quote("b"), later)).doc.attachments).toHaveLength(1)
  expect(removeQuote(saved.doc, "a", 2).attachments).toEqual([])
  expect(clearQuotes(saved.doc, { reason: "sent" }, 2).attachments).toEqual([])
  expect(ok(saveQuote(saved.doc, quote("a"), 2)).doc.attachments).toEqual([])
  const shared = ok(saveQuote(saved.doc, quote("b", { attachments: [image.id] }), 2)).doc
  expect(removeQuote(shared, "a", 3).attachments).toHaveLength(1)
  expect(ok(saveQuote(uploaded, quote("c"), 1)).doc.attachments).toHaveLength(1)
  expect(ok(saveQuote(uploaded, quote("c"), later)).doc.attachments).toEqual([])
})

test("dismissals add once and stay bounded", () => {
  const first = dismissQuotes(empty, ["a", "a", "b"])
  expect(first).toMatchObject({ revision: 1, dismissed: ["a", "b"] })
  expect(dismissQuotes(first, ["b"])).toBe(first)
  const many = dismissQuotes(
    first,
    Array.from({ length: Quotes.limits.dismissed }, (_, index) => `d${index}`),
  )
  expect(many.dismissed).toHaveLength(Quotes.limits.dismissed)
  expect(many.dismissed[0]).toBe("d0")
})
