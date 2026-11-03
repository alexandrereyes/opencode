import type { Plugin } from "@opencode/plugin/effect"
import { Effect, Schema } from "effect"
import type { Storage } from "../../src/storage"

/**
 * One plugin storage in memory, shared by every Location's instance as the host's KV namespace is. It keeps the KV
 * table's rule: `value` is NOT NULL, so writing `null` dies as the database write does, and `update` removes the key
 * when its next value is `undefined`.
 */
export function storage(initial: Iterable<readonly [string, Schema.Json]> = []) {
  const values = new Map<string, Schema.Json>(initial)
  const write = (key: string, value: Schema.Json) => {
    if (value === null) throw new Error(`NOT NULL constraint failed: kv.value (${key})`)
    values.set(key, value)
  }
  // `set` keeps the host's type, which takes `null`, so a test can show that the write is refused.
  const shared: Pick<Plugin.Context["storage"], "get" | "set" | "remove"> & Pick<Storage, "update"> = {
    get: (key) => Effect.sync(() => values.get(key)),
    set: (key, value) => Effect.sync(() => write(key, value)),
    remove: (key) => Effect.sync(() => void values.delete(key)),
    update: (key, update) =>
      Effect.sync(() => {
        const [next, result] = update(values.get(key))
        if (next === undefined) values.delete(key)
        if (next !== undefined) write(key, next)
        return result
      }),
  }
  return { ...shared, values }
}
