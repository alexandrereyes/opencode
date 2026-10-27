import type { Plugin } from "@opencode/plugin/effect"
import { Form } from "@opencode/schema/form"
import type { Permission } from "@opencode/schema/permission"
import { Session } from "@opencode/schema/session"
import { Clock, Effect } from "effect"
import { clip, limits, projectName } from "../live-activity/tracker.js"
import { fail } from "./failure.js"
import type { Watch } from "./rpc.js"

export type RequestsContext = {
  request: Pick<Plugin.Context["request"], "pending">
  session: Pick<Plugin.Context["session"], "get"> & { form: Pick<Plugin.Context["session"]["form"], "reply"> }
  permission: Pick<Plugin.Context["permission"], "reply">
}

type Pending =
  | { readonly kind: "question"; readonly form: Form.Info }
  | { readonly kind: "permission"; readonly request: Permission.Request }

const recommended = /\s*\((?:recommended|recomendad[ao])\)\s*$/i

/**
 * Pending questions and permissions as the watch sees them. Only requests owned by a nonarchived top-level session
 * or one of its subagents are reachable; the watch never names a session or directory itself.
 */
export function makeRequests(ctx: RequestsContext) {
  const find = Effect.fn("Watch.findRequest")(function* (requestID: string) {
    const pending = (yield* ctx.request.pending()).flatMap((snapshot): Pending[] => [
      ...snapshot.forms
        .filter((form) => form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider")
        .map((form) => ({ kind: "question" as const, form })),
      ...snapshot.permissions.map((request) => ({ kind: "permission" as const, request })),
    ])
    const found = pending.find((item) => (item.kind === "question" ? item.form.id : item.request.id) === requestID)
    if (!found) return undefined
    const owner = found.kind === "question" ? found.form.sessionID : found.request.sessionID
    const root = yield* top(owner)
    if (!root) return undefined
    return { pending: found, owner, root }
  })

  const top = (sessionID: string, depth = 0): Effect.Effect<Session.Info | undefined> =>
    Effect.gen(function* () {
      if (sessionID === "global" || depth > 32) return undefined
      const session = yield* ctx.session
        .get({ sessionID: Session.ID.make(sessionID) })
        .pipe(Effect.orElseSucceed(() => undefined))
      if (!session) return undefined
      if (session.parentID) return yield* top(session.parentID, depth + 1)
      return session.time.archived ? undefined : session
    })

  const get = Effect.fn("Watch.request")(function* (requestID: string) {
    const found = yield* find(requestID)
    if (!found) return yield* fail(404, "not_found", "O pedido não está mais pendente.")
    const now = yield* Clock.currentTimeMillis
    const ref = {
      requestID,
      sessionID: found.root.id,
      title: clip(found.root.title?.trim() ? found.root.title : "Sem título", limits.title),
      project: projectName(found.root.location.directory, found.root.subpath),
    }
    if (found.pending.kind === "permission") {
      const request = found.pending.request
      return {
        kind: "permission",
        ...ref,
        since: request.created ?? now,
        action: request.action,
        resources: request.resources,
        summary: clip([request.action, request.resources.join(" ")].filter(Boolean).join(" · "), limits.text),
      } satisfies Watch.WatchRequest
    }
    const form = found.pending.form
    return {
      kind: "question",
      ...ref,
      since: form.created ?? now,
      questions: questions(form) ?? [],
    } satisfies Watch.WatchRequest
  })

  const reply = Effect.fn("Watch.reply")(function* (requestID: string, input: Watch.WatchReply) {
    const found = yield* find(requestID)
    if (!found) return yield* fail(409, "not_pending", "O pedido já foi respondido.")
    if (found.pending.kind === "permission") {
      if (input.kind !== "permission") return yield* fail(400, "wrong_kind", "Este pedido é uma permissão.")
      yield* ctx.permission
        .reply({
          sessionID: Session.ID.make(found.owner),
          requestID: found.pending.request.id,
          decision: input.decision,
        })
        .pipe(Effect.catch(() => rejected(requestID)))
      return { ok: true as const }
    }
    if (input.kind !== "question") return yield* fail(400, "wrong_kind", "Este pedido é uma pergunta.")
    const form = found.pending.form
    const answer = yield* answers(form, input)
    yield* ctx.session.form
      .reply({ sessionID: found.owner, formID: form.id, answer })
      .pipe(Effect.catch(() => rejected(requestID)))
    return { ok: true as const }
  })

  /** Already answered elsewhere is a conflict; a native validation refusal of a pending one is a bad answer. */
  const rejected = (requestID: string) =>
    find(requestID).pipe(
      Effect.flatMap((still) =>
        still
          ? Effect.fail(fail(400, "invalid_answer", "A resposta não foi aceita."))
          : Effect.fail(fail(409, "not_pending", "O pedido já foi respondido.")),
      ),
    )

  return { get, reply }
}

/** The questions the watch can render, or `undefined` when any active field needs the iPhone. */
export function questions(form: Form.Info): Watch.Question[] | undefined {
  const mapped = form.fields
    .filter((field) => field.type === "external" || !field.hidden)
    .map((field): Watch.Question | undefined => {
      if (field.type === "external" || field.when?.length) return undefined
      const text = field.description?.trim() || field.title?.trim() || form.title
      if (field.type === "boolean")
        return {
          id: field.key,
          text,
          options: [
            { id: "true", label: "Sim" },
            { id: "false", label: "Não" },
          ],
          multiple: false,
          allowText: false,
        }
      if (field.type === "string" && !field.format && !field.pattern)
        return {
          id: field.key,
          text,
          options: (field.options ?? []).map(option),
          multiple: false,
          allowText: !field.options?.length || field.custom === true,
        }
      if (field.type === "multiselect")
        return {
          id: field.key,
          text,
          options: field.options.map(option),
          multiple: true,
          allowText: field.custom === true,
        }
      return undefined
    })
  if (mapped.some((item) => item === undefined)) return undefined
  return mapped.filter((item) => item !== undefined)
}

function option(input: Form.Option) {
  const label = input.label.replace(recommended, "")
  return { id: input.value, label, ...(label !== input.label ? { recommended: true } : {}) }
}

/** Builds the native form answer; each value must be one the question offered, or free text where allowed. */
const answers = Effect.fn("Watch.answers")(function* (
  form: Form.Info,
  input: Extract<Watch.WatchReply, { kind: "question" }>,
) {
  const offered = questions(form)
  if (!offered?.length) return yield* fail(400, "unsupported_form", "Responda esta pergunta no iPhone.")
  const unknown = input.answers.find((answer) => !offered.some((question) => question.id === answer.questionID))
  if (unknown) return yield* fail(400, "invalid_answer", "A resposta não corresponde à pergunta.")
  const entries: (readonly [string, Form.Value])[] = []
  for (const question of offered) {
    const field = form.fields.find((item) => item.key === question.id)
    const answer = input.answers.find((item) => item.questionID === question.id)
    const chosen = answer?.optionIDs ?? []
    const text = question.allowText ? answer?.text?.trim() : undefined
    if (
      chosen.some((id) => !question.options.some((item) => item.id === id)) ||
      (answer?.text?.trim() && !question.allowText)
    )
      return yield* fail(400, "invalid_answer", "A resposta não corresponde à pergunta.")
    if (field?.type === "boolean" && chosen.length === 1) entries.push([question.id, chosen[0] === "true"])
    else if (field?.type === "multiselect" && (chosen.length || text))
      entries.push([question.id, [...chosen, ...(text ? [text] : [])]])
    else if (field?.type === "string" && chosen.length === 1) entries.push([question.id, chosen[0]])
    else if (field?.type === "string" && !chosen.length && text) entries.push([question.id, text])
    else if (chosen.length > 1 || answer)
      return yield* fail(400, "invalid_answer", "A resposta não corresponde à pergunta.")
  }
  return Object.fromEntries(entries)
})
