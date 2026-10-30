import type { Context } from "../context.js"
import type { RpcRegistration } from "@opencode/plugin/effect/rpc"
import { Effect, Schema } from "effect"
import { Snippets } from "./rpc.js"
import { problem, type Problem } from "./rules.js"

const key = "snippets:catalog"
const decode = Schema.decodeUnknownSync(Schema.Array(Snippets.Info))
const encode = Schema.encodeSync(Schema.Array(Snippets.Info))

export const registerSnippets = Effect.fn("Snippets.register")(function* (ctx: Context) {
  yield* ctx.storage.update(key, (current) => [encode(decode(current ?? [])), undefined])
  const registration: RpcRegistration<typeof Snippets.Definition> = yield* ctx.rpc
    .register(Snippets.Definition, {
      list: () => ctx.storage.get(key).pipe(Effect.map((value) => ({ items: decode(value ?? []) }))),
      save: (snippet, context) =>
        Effect.gen(function* () {
          // The rules run inside the atomic update, against the catalog the write would replace.
          const refused = yield* ctx.storage.update<Problem | undefined>(key, (current) => {
            const items = decode(current ?? [])
            const found = problem(items, snippet)
            if (found) return [encode(items), found]
            return [encode([...items.filter((item) => item.id !== snippet.id), snippet]), undefined]
          })
          if (refused?.type === "conflict")
            return yield* Effect.fail(
              context.error(
                "conflict",
                `"${refused.data.value}" is already a name or alias of #${refused.data.existing} in this scope.`,
                refused.data,
              ),
            )
          if (refused?.type === "invalid")
            return yield* Effect.fail(
              context.error(
                "invalid",
                refused.data.reason === "duplicate"
                  ? `The alias "${refused.data.value}" repeats the name or another alias.`
                  : `"${refused.data.value}" may only have letters, digits, - and _.`,
                refused.data,
              ),
            )
          yield* registration.events.emit("updated", {}).pipe(Effect.orDie)
          return snippet
        }),
      remove: ({ id }) =>
        Effect.gen(function* () {
          yield* ctx.storage.update(key, (current) => [
            encode(decode(current ?? []).filter((item) => item.id !== id)),
            undefined,
          ])
          yield* registration.events.emit("updated", {}).pipe(Effect.orDie)
          return {}
        }),
    })
    .pipe(Effect.orDie)
})
