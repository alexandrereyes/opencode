import { Plugin } from "@opencode/plugin/effect"
import { DateTime, Effect, Schema } from "effect"
import { Navigation } from "./rpc.js"
import { Session } from "@opencode/schema/session"

const encodeSession = Schema.encodeSync(Session.Info)

interface NavigationContext {
  readonly scan: Plugin.Context["session"]["scan"]
  readonly pending: Plugin.Context["request"]["pending"]
}

export const registerNavigation = Effect.fn("Navigation.register")(function* (ctx: Plugin.Context) {
  const sessions = ctx.session
  const requests = ctx.request
  yield* ctx.rpc
    .register(Navigation.Definition, {
      list: (input) => list({ scan: sessions.scan, pending: requests.pending }, input),
    })
    .pipe(Effect.orDie)
})

export const list = Effect.fn("Navigation.list")(function* (
  ctx: NavigationContext,
  input: { readonly after?: Session.ID; readonly limit?: number; readonly sessionID?: Session.ID },
) {
  const page = yield* ctx.scan({ ...input, archived: false })
  const pending = yield* ctx.pending()
  const permissions = Map.groupBy(
    pending.flatMap((snapshot) => snapshot.permissions),
    (request) => request.sessionID,
  )
  const questions = Map.groupBy(
    pending
      .flatMap((snapshot) => snapshot.forms)
      .filter((form) => form.metadata?.kind === "question" || form.metadata?.kind === "websearch.provider"),
    (form) => form.sessionID,
  )
  return {
    ...(page.next === undefined ? {} : { next: page.next }),
    data: page.data.map((row) => {
      const viewed = row.session.time.viewed ? DateTime.toEpochMillis(row.session.time.viewed) : 0
      const idle = row.session.time.idle ? DateTime.toEpochMillis(row.session.time.idle) : undefined
      const unreadAt =
        !row.session.parentID && idle !== undefined && idle > viewed
          ? row.completionAt !== undefined && row.completionAt > viewed
            ? row.completionAt
            : row.session.outcome === "succeeded" || row.session.outcome === "failed"
              ? idle
              : undefined
          : undefined
      const sessionPermissions = permissions.get(row.session.id) ?? []
      const sessionQuestions = questions.get(row.session.id) ?? []
      return {
        session: encodeSession(row.session),
        ...(row.messageAt === undefined ? {} : { messageAt: row.messageAt }),
        ...(unreadAt === undefined ? {} : { unreadAt }),
        ...(sessionPermissions.length
          ? { permissionAt: Math.max(...sessionPermissions.map((request) => request.created ?? 0)) }
          : {}),
        ...(sessionQuestions.length
          ? { questionAt: Math.max(...sessionQuestions.map((form) => form.created ?? 0)) }
          : {}),
      }
    }),
  }
})
