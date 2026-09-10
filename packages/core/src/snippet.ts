export * as Snippet from "./snippet.js"

import { Context, Effect, Layer, Schema, Semaphore } from "effect"
import { Snippet } from "@opencode/schema/snippet"
import { makeGlobalNode } from "@opencode/util/effect/app-node"
import { KV } from "./kv.js"
import { Bus } from "./bus.js"

export const Info = Snippet.Info
export type Info = Snippet.Info

export class ConflictError extends Schema.TaggedError<ConflictError>()("SnippetConflictError", {
  name: Schema.String,
}) {}

export interface Interface {
  readonly list: () => Effect.Effect<readonly Info[]>
  readonly save: (snippet: Info) => Effect.Effect<Info, ConflictError>
  readonly remove: (id: string) => Effect.Effect<void>
}

export class Service extends Context.Service<Service, Interface>()("@opencode/Snippet") {}

const layer = Layer.effect(
  Service,
  Effect.gen(function* () {
    const kv = yield* KV.Service
    const bus = yield* Bus.Service
    const lock = yield* Semaphore.make(1)
    const key = "snippets:catalog"
    const decode = Schema.decodeUnknownSync(Schema.Array(Info))
    const encode = Schema.encodeSync(Schema.Array(Info))
    const list = Effect.fn("Snippet.list")(function* () {
      return decode((yield* kv.get(key)) ?? [])
    })
    return Service.of({
      list,
      save: Effect.fn("Snippet.save")(function* (snippet) {
        // Serialize the catalog's read-modify-write so concurrent clients retain each other's entries.
        yield* lock.withPermit(
          Effect.gen(function* () {
            const items = yield* list()
            if (
              items.some(
                (item) =>
                  item.id !== snippet.id &&
                  item.project === snippet.project &&
                  item.name.toLowerCase() === snippet.name.toLowerCase(),
              )
            ) {
              return yield* new ConflictError({ name: snippet.name })
            }
            yield* kv.set(key, encode([...items.filter((item) => item.id !== snippet.id), snippet]))
          }),
        )
        yield* bus.publish(Snippet.Event.Updated, {}, { global: true })
        return snippet
      }),
      remove: Effect.fn("Snippet.remove")(function* (id) {
        yield* lock.withPermit(
          Effect.gen(function* () {
            yield* kv.set(key, encode((yield* list()).filter((item) => item.id !== id)))
          }),
        )
        yield* bus.publish(Snippet.Event.Updated, {}, { global: true })
      }),
    })
  }),
)

export const node = makeGlobalNode({ service: Service, layer, deps: [KV.node, Bus.node] })
