import { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Effect } from "effect"
import { Archive } from "./rpc.js"

interface ArchiveContext {
  readonly interrupt: Plugin.Context["session"]["interrupt"]
  readonly wait: Plugin.Context["session"]["wait"]
  readonly scan: Plugin.Context["session"]["scan"]
  readonly archive: Plugin.Context["session"]["archive"]
}

export const registerArchive = Effect.fn("Archive.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Archive.Definition, {
      archive: (input, context) =>
        archive(
          {
            interrupt: ctx.session.interrupt,
            wait: ctx.session.wait,
            scan: ctx.session.scan,
            archive: ctx.session.archive,
          },
          input,
        ).pipe(
          Effect.mapError((error) => context.error("operation_failed", message(error), { message: message(error) })),
        ),
    })
    .pipe(Effect.orDie)
})

export const archive: (
  ctx: ArchiveContext,
  input: { readonly sessionID: Session.ID },
) => Effect.Effect<{}, unknown> = Effect.fn("Archive.archive")(function* (ctx, input) {
  yield* ctx.interrupt({ sessionID: input.sessionID, continue: false })
  yield* ctx.wait({ sessionID: input.sessionID })
  const children = yield* scanChildren(ctx, input.sessionID)
  yield* Effect.forEach(children, (sessionID) => archive(ctx, { sessionID }), { concurrency: 1, discard: true })
  yield* ctx.archive({ sessionID: input.sessionID })
  return {}
})

function scanChildren(ctx: ArchiveContext, parentID: Session.ID, after?: Session.ID): Effect.Effect<Session.ID[]> {
  return ctx.scan({ parentID, after, limit: 1000 }).pipe(
    Effect.flatMap((page) => {
      const ids = page.data.map((row) => row.session.id)
      if (!page.next) return Effect.succeed(ids)
      return scanChildren(ctx, parentID, page.next).pipe(Effect.map((rest) => [...ids, ...rest]))
    }),
  )
}

function message(error: unknown) {
  if (error instanceof Error) return error.message
  return String(error)
}
