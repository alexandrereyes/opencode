import { Plugin } from "@opencode/plugin/effect"
import type { RpcRegistration } from "@opencode/plugin/effect/rpc"
import { Effect, Schema } from "effect"
import { Snippets } from "./rpc.js"

const key = "snippets:catalog"
const decode = Schema.decodeUnknownSync(Schema.Array(Snippets.Info))
const encode = Schema.encodeSync(Schema.Array(Snippets.Info))

export const registerSnippets = Effect.fn("Snippets.register")(function* (ctx: Plugin.Context) {
  yield* ctx.storage.adoptLegacy(key)
  yield* ctx.storage.update(key, (current) => [encode(decode(current ?? [])), undefined])
  const registration: RpcRegistration<typeof Snippets.Definition> = yield* ctx.rpc
    .register(Snippets.Definition, {
      list: () => ctx.storage.get(key).pipe(Effect.map((value) => ({ items: decode(value ?? []) }))),
      save: (snippet, context) =>
        Effect.gen(function* () {
          const result = yield* ctx.storage.update<{ conflict: boolean }>(key, (current) => {
            const items = decode(current ?? [])
            if (
              items.some(
                (item) =>
                  item.id !== snippet.id &&
                  item.project === snippet.project &&
                  item.name.toLowerCase() === snippet.name.toLowerCase(),
              )
            ) {
              return [encode(items), { conflict: true as const }]
            }
            return [encode([...items.filter((item) => item.id !== snippet.id), snippet]), { conflict: false as const }]
          })
          if (result.conflict)
            return yield* Effect.fail(
              context.error("conflict", "A snippet with this name already exists in this scope.", {
                name: snippet.name,
              }),
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
