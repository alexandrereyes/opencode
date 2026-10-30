import { createHash } from "node:crypto"
import type { Context } from "../storage.js"
import type { RpcRegistration } from "@opencode/plugin/effect/rpc"
import type { Session } from "@opencode/schema/session"
import { Effect, Exit, Schema, Stream } from "effect"
import { Quotes } from "./rpc.js"

const StoredAttachment = Schema.Struct({ ...Quotes.Attachment.fields, createdAt: Schema.Number })
export const Doc = Schema.Struct({
  version: Schema.Literal(1),
  revision: Schema.Number,
  quotes: Schema.Array(Quotes.Quote),
  /** Uploaded bytes live under their own key; this index keeps listings small and bounds the session total. */
  attachments: Schema.Array(StoredAttachment),
  /** Tombstones of quotes that went out in an admitted prompt, oldest first. */
  sent: Schema.Array(Quotes.ID),
  dismissed: Schema.Array(Quotes.ID),
})
export type Doc = typeof Doc.Type
export const empty: Doc = { version: 1, revision: 0, quotes: [], attachments: [], sent: [], dismissed: [] }
const decode = Schema.decodeUnknownSync(Doc)
const encode = Schema.encodeSync(Doc)
const docKey = (sessionID: string) => `quotes:session:${sessionID}`
const attachmentKey = (sessionID: string, id: string) => `quotes:attachment:${sessionID}:${id}`
const AttachmentBytes = Schema.Struct({ data: Schema.String })

export type Failure =
  | { readonly type: "limit_exceeded"; readonly data: { readonly limit: string; readonly max: number } }
  | { readonly type: "attachment_missing"; readonly data: { readonly ids: readonly string[] } }
  | { readonly type: "already_sent"; readonly data: { readonly ids: readonly string[] } }
export type Result<A> =
  | { readonly ok: true; readonly doc: Doc; readonly value: A }
  | { readonly ok: false; readonly failure: Failure }

export function saveQuote(doc: Doc, input: Quotes.QuoteInput, now: number): Result<Quotes.Quote> {
  if (doc.sent.includes(input.id)) return fail({ type: "already_sent", data: { ids: [input.id] } })
  const existing = doc.quotes.find((quote) => quote.id === input.id)
  if (!existing && doc.quotes.length >= Quotes.limits.quotesPerSession) return limit("quotesPerSession")
  const built = buildQuote(doc, input, { createdAt: existing?.createdAt ?? now, now })
  if (!built.ok) return built
  const quotes = existing
    ? doc.quotes.map((quote) => (quote.id === input.id ? built.value : quote))
    : [...doc.quotes, built.value]
  return { ok: true, doc: collect({ ...doc, revision: built.value.revision, quotes }, now, doc), value: built.value }
}

/** Adds quotes the server does not know yet; known, sent or duplicated content is skipped, never overwritten. */
export function importQuotes(
  doc: Doc,
  inputs: readonly Quotes.QuoteInput[],
  now: number,
): Result<{ imported: string[]; skipped: string[] }> {
  const known = new Set(doc.quotes.flatMap((quote) => [quote.id, fingerprint(quote)]))
  const fresh = inputs.filter((input) => {
    if (doc.sent.includes(input.id) || known.has(input.id) || known.has(fingerprint(input))) return false
    known.add(input.id)
    known.add(fingerprint(input))
    return true
  })
  const skipped = inputs.filter((input) => !fresh.includes(input)).map((input) => input.id)
  if (fresh.length === 0) return { ok: true, doc, value: { imported: [], skipped } }
  if (doc.quotes.length + fresh.length > Quotes.limits.quotesPerSession) return limit("quotesPerSession")
  const revision = doc.revision + 1
  const built = fresh.map((input) => buildQuote(doc, input, { createdAt: now, now, revision }))
  const missing = built.flatMap((result) =>
    !result.ok && result.failure.type === "attachment_missing" ? result.failure.data.ids : [],
  )
  if (missing.length > 0) return fail({ type: "attachment_missing", data: { ids: [...new Set(missing)] } })
  const failed = built.find((result) => !result.ok)
  if (failed && !failed.ok) return failed
  const quotes = built.flatMap((result) => (result.ok ? [result.value] : []))
  return {
    ok: true,
    doc: collect({ ...doc, revision, quotes: [...doc.quotes, ...quotes] }, now),
    value: { imported: quotes.map((quote) => quote.id), skipped },
  }
}

export function removeQuote(doc: Doc, id: string, now: number) {
  if (!doc.quotes.some((quote) => quote.id === id)) return doc
  return collect(
    { ...doc, revision: doc.revision + 1, quotes: doc.quotes.filter((quote) => quote.id !== id) },
    now,
    doc,
  )
}

export function clearQuotes(
  doc: Doc,
  input: { readonly ids?: readonly string[]; readonly reason: "sent" | "discarded" },
  now: number,
) {
  const ids = input.ids ?? doc.quotes.map((quote) => quote.id)
  const quotes = doc.quotes.filter((quote) => !ids.includes(quote.id))
  const sent =
    input.reason === "sent"
      ? [...doc.sent.filter((id) => !ids.includes(id)), ...ids].slice(-Quotes.limits.sentHistory)
      : doc.sent
  const tombstoned = input.reason === "sent" && ids.some((id) => !doc.sent.includes(id))
  if (quotes.length === doc.quotes.length && !tombstoned) return doc
  return collect({ ...doc, revision: doc.revision + 1, quotes, sent }, now, doc)
}

export function dismissQuotes(doc: Doc, ids: readonly string[]) {
  const added = [...new Set(ids)].filter((id) => !doc.dismissed.includes(id))
  if (added.length === 0) return doc
  return {
    ...doc,
    revision: doc.revision + 1,
    dismissed: [...doc.dismissed, ...added].slice(-Quotes.limits.dismissed),
  }
}

export function addAttachment(doc: Doc, attachment: Quotes.Attachment, now: number): Result<Quotes.Attachment> {
  const existing = doc.attachments.find((item) => item.id === attachment.id)
  // Re-uploading refreshes the grace period of an attachment that is not referenced yet.
  if (existing)
    return {
      ok: true,
      doc: {
        ...doc,
        attachments: doc.attachments.map((item) => (item.id === attachment.id ? { ...item, createdAt: now } : item)),
      },
      value: withoutTime(existing),
    }
  const total = doc.attachments.reduce((sum, item) => sum + item.size, 0)
  if (total + attachment.size > Quotes.limits.sessionAttachmentBytes) return limit("sessionAttachmentBytes")
  return {
    ok: true,
    doc: collect({ ...doc, attachments: [...doc.attachments, { ...attachment, createdAt: now }] }, now),
    value: attachment,
  }
}

/**
 * Drops attachments a quote stopped referencing in this change, and uploads no quote ever claimed once their
 * grace period is over.
 */
export function collect(doc: Doc, now: number, before: Doc = doc): Doc {
  const referenced = references(doc)
  const released = references(before)
  const attachments = doc.attachments.filter(
    (item) =>
      referenced.has(item.id) || (!released.has(item.id) && now - item.createdAt < Quotes.limits.attachmentGraceMs),
  )
  if (attachments.length === doc.attachments.length) return doc
  return { ...doc, attachments }
}

export function toState(sessionID: Session.ID, doc: Doc): Quotes.State {
  return { sessionID, revision: doc.revision, quotes: doc.quotes, dismissed: doc.dismissed }
}

export function decodeAttachment(data: string) {
  if (data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) return
  const bytes = Buffer.from(data, "base64")
  if (bytes.length === 0) return
  return { bytes, id: createHash("sha256").update(bytes).digest("hex") }
}

export const registerQuotes = Effect.fn("Quotes.register")(function* (ctx: Context) {
  const read = (sessionID: string) =>
    ctx.storage.get(docKey(sessionID)).pipe(Effect.map((value) => (value === undefined ? empty : decode(value))))
  const exists = (sessionID: Session.ID) => ctx.session.get({ sessionID }).pipe(Effect.exit, Effect.map(Exit.isSuccess))
  // Applies one change atomically; a failed change keeps the stored document untouched.
  const change = <A>(sessionID: Session.ID, apply: (doc: Doc) => Result<A>) =>
    Effect.gen(function* () {
      const outcome = yield* ctx.storage.update<{ result: Result<A>; before: Doc }>(docKey(sessionID), (current) => {
        const doc = current === undefined ? empty : decode(current)
        const result = apply(doc)
        return [encode(result.ok ? result.doc : doc), { result, before: doc }]
      })
      if (!outcome.result.ok) return outcome.result
      const after = outcome.result.doc
      yield* Effect.forEach(
        outcome.before.attachments.filter((item) => !after.attachments.some((next) => next.id === item.id)),
        (item) => ctx.storage.remove(attachmentKey(sessionID, item.id)),
        { discard: true },
      )
      if (after.revision !== outcome.before.revision)
        yield* registration.events.emit("updated", { sessionID, revision: after.revision }).pipe(Effect.orDie)
      return outcome.result
    })
  const now = () => Date.now()

  const registration: RpcRegistration<typeof Quotes.Definition> = yield* ctx.rpc
    .register(Quotes.Definition, {
      info: () =>
        Effect.succeed({
          version: 1 as const,
          limits: {
            quotesPerSession: Quotes.limits.quotesPerSession,
            textLength: Quotes.limits.textLength,
            anchorContext: Quotes.limits.anchorContext,
            commentPromptBytes: Quotes.limits.commentPromptBytes,
            attachmentsPerQuote: Quotes.limits.attachmentsPerQuote,
            attachmentBytes: Quotes.limits.attachmentBytes,
            sessionAttachmentBytes: Quotes.limits.sessionAttachmentBytes,
          },
        }),
      list: (input) => read(input.sessionID).pipe(Effect.map((doc) => toState(input.sessionID, doc))),
      save: (input, context) =>
        Effect.gen(function* () {
          if (!(yield* exists(input.sessionID)))
            return yield* Effect.fail(
              context.error("session_not_found", "Session not found.", { sessionID: input.sessionID }),
            )
          const result = yield* change(input.sessionID, (doc) => saveQuote(doc, input.quote, now()))
          if (result.ok) return { revision: result.doc.revision, quote: result.value }
          const failure = result.failure
          if (failure.type === "limit_exceeded")
            return yield* Effect.fail(context.error(failure.type, message(failure), failure.data))
          if (failure.type === "attachment_missing")
            return yield* Effect.fail(context.error(failure.type, message(failure), failure.data))
          return yield* Effect.fail(context.error(failure.type, message(failure), failure.data))
        }),
      remove: (input) =>
        change(input.sessionID, (doc) => ({ ok: true, doc: removeQuote(doc, input.id, now()), value: undefined })).pipe(
          Effect.map((result) => ({ revision: result.ok ? result.doc.revision : 0 })),
        ),
      clear: (input) =>
        change(input.sessionID, (doc) => ({ ok: true, doc: clearQuotes(doc, input, now()), value: undefined })).pipe(
          Effect.map((result) => ({ revision: result.ok ? result.doc.revision : 0 })),
        ),
      dismiss: (input) =>
        change(input.sessionID, (doc) => ({ ok: true, doc: dismissQuotes(doc, input.ids), value: undefined })).pipe(
          Effect.map((result) => ({ revision: result.ok ? result.doc.revision : 0 })),
        ),
      import: (input, context) =>
        Effect.gen(function* () {
          if (!(yield* exists(input.sessionID)))
            return yield* Effect.fail(
              context.error("session_not_found", "Session not found.", { sessionID: input.sessionID }),
            )
          const result = yield* change(input.sessionID, (doc) => importQuotes(doc, input.quotes, now()))
          if (result.ok) return { state: toState(input.sessionID, result.doc), ...result.value }
          const failure = result.failure
          if (failure.type === "limit_exceeded")
            return yield* Effect.fail(context.error(failure.type, message(failure), failure.data))
          if (failure.type === "attachment_missing")
            return yield* Effect.fail(context.error(failure.type, message(failure), failure.data))
          return yield* Effect.die(new Error("import never reports sent quotes"))
        }),
      upload: (input, context) =>
        Effect.gen(function* () {
          if (!(yield* exists(input.sessionID)))
            return yield* Effect.fail(
              context.error("session_not_found", "Session not found.", { sessionID: input.sessionID }),
            )
          const decoded = decodeAttachment(input.data)
          if (!decoded) return yield* Effect.fail(context.error("invalid_data", "Attachment data is not base64.", {}))
          if (decoded.bytes.length > Quotes.limits.attachmentBytes)
            return yield* Effect.fail(
              context.error("limit_exceeded", "Attachment is too large.", {
                limit: "attachmentBytes",
                max: Quotes.limits.attachmentBytes,
              }),
            )
          const attachment = {
            id: decoded.id,
            mime: input.mime,
            ...(input.filename === undefined ? {} : { filename: input.filename }),
            size: decoded.bytes.length,
          }
          const result = yield* change(input.sessionID, (doc) => addAttachment(doc, attachment, now()))
          if (!result.ok) {
            const failure = result.failure
            if (failure.type !== "limit_exceeded") return yield* Effect.die(new Error("unexpected upload failure"))
            return yield* Effect.fail(context.error(failure.type, message(failure), failure.data))
          }
          yield* ctx.storage.set(attachmentKey(input.sessionID, decoded.id), { data: decoded.bytes.toString("base64") })
          return result.value
        }),
      attachment: (input, context) =>
        Effect.gen(function* () {
          const meta = (yield* read(input.sessionID)).attachments.find((item) => item.id === input.id)
          const stored = yield* ctx.storage.get(attachmentKey(input.sessionID, input.id))
          if (!meta || stored === undefined)
            return yield* Effect.fail(context.error("not_found", "Attachment not found.", { id: input.id }))
          return { ...withoutTime(meta), data: Schema.decodeUnknownSync(AttachmentBytes)(stored).data }
        }),
    })
    .pipe(Effect.orDie)

  yield* ctx.event.subscribe().pipe(
    Stream.filter((event) => event.type === "session.deleted"),
    Stream.runForEach((event) =>
      Effect.gen(function* () {
        const sessionID = event.data.sessionID
        const doc = yield* read(sessionID)
        yield* Effect.forEach(doc.attachments, (item) => ctx.storage.remove(attachmentKey(sessionID, item.id)), {
          discard: true,
        })
        yield* ctx.storage.remove(docKey(sessionID))
      }).pipe(Effect.catchCause((cause) => Effect.logWarning("chat quote cleanup failed", { cause }))),
    ),
    Effect.catchCause((cause) => Effect.logWarning("chat quote cleanup subscription failed", { cause })),
    Effect.forkScoped({ startImmediately: true }),
  )
})

function buildQuote(
  doc: Doc,
  input: Quotes.QuoteInput,
  time: { readonly createdAt: number; readonly now: number; readonly revision?: number },
): Result<Quotes.Quote> {
  if (input.commentPrompt && Buffer.byteLength(JSON.stringify(input.commentPrompt)) > Quotes.limits.commentPromptBytes)
    return limit("commentPromptBytes")
  const ids = input.attachments ?? []
  const missing = ids.filter((id) => !doc.attachments.some((item) => item.id === id))
  if (missing.length > 0) return fail({ type: "attachment_missing", data: { ids: missing } })
  const quote: Quotes.Quote = {
    id: input.id,
    messageID: input.messageID,
    partID: input.partID,
    text: input.text,
    comment: input.comment,
    ...(input.commentPrompt === undefined ? {} : { commentPrompt: input.commentPrompt }),
    ...(input.anchor === undefined ? {} : { anchor: input.anchor }),
    attachments: [...new Set(ids)].flatMap((id) => doc.attachments.filter((item) => item.id === id).map(withoutTime)),
    createdAt: time.createdAt,
    updatedAt: time.now,
    revision: time.revision ?? doc.revision + 1,
  }
  return { ok: true, doc, value: quote }
}

function references(doc: Doc) {
  return new Set(doc.quotes.flatMap((quote) => quote.attachments.map((item) => item.id)))
}

function fingerprint(quote: Pick<Quotes.QuoteInput, "messageID" | "partID" | "text" | "comment" | "anchor">) {
  return JSON.stringify([
    quote.messageID,
    quote.partID,
    quote.text,
    quote.anchor?.start,
    quote.anchor?.end,
    quote.anchor?.exact,
    quote.comment,
  ])
}

function withoutTime(item: Quotes.Attachment & { readonly createdAt?: number }): Quotes.Attachment {
  return {
    id: item.id,
    mime: item.mime,
    ...(item.filename === undefined ? {} : { filename: item.filename }),
    size: item.size,
  }
}

function limit(name: keyof typeof Quotes.limits): Result<never> {
  return fail({ type: "limit_exceeded", data: { limit: name, max: Quotes.limits[name] } })
}

function fail(failure: Failure): Result<never> {
  return { ok: false, failure }
}

function message(failure: Failure) {
  if (failure.type === "limit_exceeded") return `Chat quote limit exceeded: ${failure.data.limit}.`
  if (failure.type === "attachment_missing") return "Upload the referenced attachments first."
  return "The quote was already sent."
}
