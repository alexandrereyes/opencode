import type { Plugin } from "@opencode/plugin/effect"
import { Effect, Semaphore, type Schema } from "effect"

/**
 * Plugin storage with a read-modify-write `update` that is atomic for every Location instance of this plugin. Values
 * are never `null`: the host's KV column is NOT NULL and the write would die.
 */
export type Storage = Omit<Plugin.Context["storage"], "set"> & {
  readonly set: (key: string, value: Exclude<Schema.Json, null>) => Effect.Effect<void>
  /**
   * Replaces `key` with the callback's next value, or removes it when that is `undefined`, and returns its result; a
   * throwing callback writes nothing.
   */
  readonly update: <A>(
    key: string,
    update: (current: Schema.Json | undefined) => readonly [next: Exclude<Schema.Json, null> | undefined, result: A],
  ) => Effect.Effect<A>
}

declare global {
  var opencodeCustomStorageLock: Semaphore.Semaphore | undefined
}

/**
 * Serializes this plugin's storage writes across the process, as the database's write lock serialized the former host
 * update. A global slot, not module scope: the plugin loader evaluates this module again for every Location, so only a
 * global is shared by all Location instances. One server process owns the database.
 */
function lock() {
  globalThis.opencodeCustomStorageLock ??= Semaphore.makeUnsafe(1)
  return globalThis.opencodeCustomStorageLock
}

export function atomic(storage: Plugin.Context["storage"]): Storage {
  return {
    get: storage.get,
    scan: storage.scan,
    set: (key, value) => lock().withPermit(storage.set(key, value)),
    remove: (key) => lock().withPermit(storage.remove(key)),
    update: (key, update) =>
      lock().withPermit(
        Effect.gen(function* () {
          const [next, result] = update(yield* storage.get(key))
          yield* next === undefined ? storage.remove(key) : storage.set(key, next)
          return result
        }),
      ),
  }
}
