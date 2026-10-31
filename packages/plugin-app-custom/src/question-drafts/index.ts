import type { RpcRegistration } from "@opencode/plugin/effect/rpc"
import type { Session } from "@opencode/schema/session"
import { Effect, Exit, Schema, Stream } from "effect"
import type { Context } from "../context.js"
import { QuestionDrafts } from "./rpc.js"

/** One document per session in the plugin's storage, like `custom.quotes`: a draft lives and dies with its session. */
export const Doc = Schema.Struct({
  version: Schema.Literal(1),
  revision: Schema.Number,
  drafts: Schema.Array(QuestionDrafts.Draft),
})
export type Doc = typeof Doc.Type
export const empty: Doc = { version: 1, revision: 0, drafts: [] }
const decode = Schema.decodeUnknownSync(Doc)
const encode = Schema.encodeSync(Doc)
const docKey = (sessionID: string) => `question-drafts:session:${sessionID}`
const staleMs = QuestionDrafts.limits.staleDays * 24 * 60 * 60 * 1000

export type Failure = { readonly limit: string; readonly max: number }

/** Merges `fields` into the request's draft. Drafts untouched for `staleDays` are dropped on the way. */
export function saveDraft(
  doc: Doc,
  input: { readonly requestID: string; readonly fields: Readonly<Record<string, QuestionDrafts.Field>> },
  now: number,
): { readonly ok: true; readonly doc: Doc; readonly draft: QuestionDrafts.Draft } | { readonly ok: false; readonly failure: Failure } {
  const drafts = doc.drafts.filter((draft) => now - draft.updatedAt < staleMs)
  const existing = drafts.find((draft) => draft.requestID === input.requestID)
  if (!existing && drafts.length >= QuestionDrafts.limits.draftsPerSession)
    return { ok: false, failure: { limit: "draftsPerSession", max: QuestionDrafts.limits.draftsPerSession } }
  const fields = { ...existing?.fields, ...input.fields }
  if (Object.keys(fields).length > QuestionDrafts.limits.fieldsPerDraft)
    return { ok: false, failure: { limit: "fieldsPerDraft", max: QuestionDrafts.limits.fieldsPerDraft } }
  const revision = doc.revision + 1
  const draft = { requestID: input.requestID, fields, updatedAt: now, revision }
  return {
    ok: true,
    doc: {
      ...doc,
      revision,
      drafts: existing
        ? drafts.map((item) => (item.requestID === input.requestID ? draft : item))
        : [...drafts, draft],
    },
    draft,
  }
}

/** Drops one request's draft; the document is unchanged (same revision) when there was none. */
export function clearDraft(doc: Doc, requestID: string): Doc {
  if (!doc.drafts.some((draft) => draft.requestID === requestID)) return doc
  return { ...doc, revision: doc.revision + 1, drafts: doc.drafts.filter((draft) => draft.requestID !== requestID) }
}

export const registerQuestionDrafts = Effect.fn("QuestionDrafts.register")(function* (ctx: Context) {
  const read = (sessionID: string) =>
    ctx.storage.get(docKey(sessionID)).pipe(Effect.map((value) => (value === undefined ? empty : decode(value))))
  const exists = (sessionID: Session.ID) => ctx.session.get({ sessionID }).pipe(Effect.exit, Effect.map(Exit.isSuccess))
  const announce = (sessionID: Session.ID, requestID: string, revision: number, cleared: boolean, client?: string) =>
    registration.events
      .emit("updated", { sessionID, requestID, revision, cleared, ...(client === undefined ? {} : { client }) })
      .pipe(Effect.orDie)
  const clear = (sessionID: Session.ID, requestID: string, client?: string) =>
    Effect.gen(function* () {
      const [before, after] = yield* ctx.storage.update(docKey(sessionID), (current) => {
        const doc = current === undefined ? empty : decode(current)
        const next = clearDraft(doc, requestID)
        return [encode(next), [doc, next] as const]
      })
      if (after.revision !== before.revision) yield* announce(sessionID, requestID, after.revision, true, client)
      return { revision: after.revision }
    })
  const forget = (sessionID: string) => ctx.storage.remove(docKey(sessionID))

  const registration: RpcRegistration<typeof QuestionDrafts.Definition> = yield* ctx.rpc
    .register(QuestionDrafts.Definition, {
      get: (input) =>
        read(input.sessionID).pipe(
          Effect.map((doc) => ({
            draft:
              doc.drafts.find((draft) => draft.requestID === input.requestID && Date.now() - draft.updatedAt < staleMs) ??
              null,
          })),
        ),
      save: (input, context) =>
        Effect.gen(function* () {
          if (!(yield* exists(input.sessionID)))
            return yield* Effect.fail(
              context.error("session_not_found", "Session not found.", { sessionID: input.sessionID }),
            )
          const result = yield* ctx.storage.update(docKey(input.sessionID), (current) => {
            const doc = current === undefined ? empty : decode(current)
            const saved = saveDraft(doc, input, Date.now())
            return [encode(saved.ok ? saved.doc : doc), saved] as const
          })
          if (!result.ok)
            return yield* Effect.fail(
              context.error("limit_exceeded", `Question draft limit exceeded: ${result.failure.limit}.`, result.failure),
            )
          yield* announce(input.sessionID, input.requestID, result.draft.revision, false, input.client)
          return result.draft
        }),
      clear: (input) => clear(input.sessionID, input.requestID, input.client),
    })
    .pipe(Effect.orDie)

  // Answered, cancelled (dismissed, interrupted or expired), archived or deleted: nothing is left behind.
  yield* ctx.event
    .subscribe({ types: ["form.replied", "form.cancelled", "session.archived", "session.deleted"] })
    .pipe(
      Stream.runForEach((event) =>
        (event.type === "form.replied" || event.type === "form.cancelled"
          ? clear(event.data.sessionID as Session.ID, event.data.id)
          : forget(event.data.sessionID)
        ).pipe(Effect.catchCause((cause) => Effect.logWarning("question draft cleanup failed", { cause }))),
      ),
      Effect.catchCause((cause) => Effect.logWarning("question draft cleanup subscription failed", { cause })),
      Effect.forkScoped({ startImmediately: true }),
    )
})
