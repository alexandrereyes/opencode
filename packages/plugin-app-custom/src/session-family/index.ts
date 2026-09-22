import { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { Effect, Schema } from "effect"
import { Family } from "./rpc.js"

const encodeSession = Schema.encodeSync(Session.Info)
const encodeForm = Schema.encodeSync(Form.Info)
const encodePermission = Schema.encodeSync(Permission.Request)

type FamilyContext = {
  readonly family: Plugin.Context["session"]["family"]
  readonly get: Plugin.Context["session"]["get"]
  readonly pending: Plugin.Context["request"]["pending"]
}

export const snapshot = Effect.fn("Family.snapshot")(function* (ctx: FamilyContext, sessionID: Session.ID) {
  const family = yield* ctx.family({ sessionID })
  const pending = yield* ctx.pending()
  const permissions = pending.flatMap((item) => item.permissions)
  const forms = pending
    .flatMap((item) => item.forms)
    .filter((form) => form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider")
  // Resolve only pending owners, sharing ancestor results across the snapshot.
  const members = new Map<string, number>([[sessionID, 0]])
  const depthOf = (id: string): Effect.Effect<number> =>
    Effect.gen(function* () {
      if (id === "global") return -1
      const known = members.get(id)
      if (known !== undefined) return known
      const session = yield* ctx
        .get({ sessionID: Session.ID.make(id) })
        .pipe(Effect.catch(() => Effect.succeed(undefined)))
      members.set(id, -1)
      const parent = session?.parentID ? yield* depthOf(session.parentID) : -1
      const depth = parent < 0 ? -1 : parent + 1
      members.set(id, depth)
      return depth
    })
  yield* Effect.forEach([...new Set([...permissions, ...forms].map((item) => item.sessionID))], depthOf)
  const order = (a: { sessionID: string; created?: number }, b: { sessionID: string; created?: number }) =>
    (members.get(a.sessionID) ?? -1) - (members.get(b.sessionID) ?? -1) || (a.created ?? 0) - (b.created ?? 0)
  return {
    count: family.count,
    cost: family.cost,
    active: family.active.map((item) => encodeSession(item)),
    forms: forms
      .filter((form) => (members.get(form.sessionID) ?? -1) >= 0)
      .toSorted(order)
      .map((item) => encodeForm(item)),
    permissions: permissions
      .filter((request) => (members.get(request.sessionID) ?? -1) >= 0)
      .toSorted(order)
      .map((item) => encodePermission(item)),
  }
})

export const registerFamily = Effect.fn("Family.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Family.Definition, {
      revert: (input, context) =>
        ctx.session
          .familyBoundaries({ sessionID: input.sessionID, message: { type: "user", createdAtOrAfter: input.cutoff } })
          .pipe(
            Effect.mapError(() =>
              context.error("read_failed", "Unable to read revert boundaries", { sessionID: input.sessionID }),
            ),
          ),
      clear: (input, context) =>
        ctx.session
          .familyBoundaries({ sessionID: input.sessionID })
          .pipe(
            Effect.mapError(() =>
              context.error("read_failed", "Unable to read staged reverts", { sessionID: input.sessionID }),
            ),
          ),
      snapshot: (input, context) =>
        snapshot(
          { family: ctx.session.family, get: ctx.session.get, pending: ctx.request.pending },
          input.sessionID,
        ).pipe(
          Effect.mapError(() =>
            context.error("read_failed", "Unable to read session family", { sessionID: input.sessionID }),
          ),
        ),
      page: (input, context) =>
        ctx.session.family({ ...input, limit: input.limit ?? 10 }).pipe(
          Effect.map((result) => ({
            data: result.data.map((item) => encodeSession(item)),
            ...(result.next ? { next: result.next } : {}),
          })),
          Effect.mapError(() =>
            context.error("read_failed", "Unable to read session family", { sessionID: input.sessionID }),
          ),
        ),
    })
    .pipe(Effect.orDie)
})
