import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { Updates } from "./rpc.js"
import { executorFor } from "@opencode/plugin-app-custom/updates/runtime"

export const registerUpdates = Effect.fn("CustomUpdates.register")(function* (ctx: Plugin.Context) {
  const home = process.env.OPENCODE_DISTRIBUTION_HOME
  const commit = process.env.OPENCODE_DISTRIBUTION_RELEASE
  if (!home || !commit) return
  const owner = yield* Effect.promise(() => executorFor(home, commit, ctx.app.version))
  yield* ctx.rpc
    .register(Updates.Definition, {
      check: () => Effect.promise(owner.check),
      install: (input, context) => {
        if (!context.afterResponse)
          return Effect.fail(context.error("unavailable", "Activation requires an HTTP response lifecycle", {}))
        const afterResponse = context.afterResponse
        return Effect.tryPromise(() => owner.install(input)).pipe(
          Effect.mapError((error) => context.error("failed", String(error.cause), {})),
          Effect.tap(() =>
            Effect.sync(() => {
              if (input.commit !== commit) afterResponse(owner.shutdown)
            }),
          ),
        )
      },
    })
    .pipe(Effect.orDie)
})
