import { describe, expect } from "bun:test"
import { KV } from "@opencode/core/kv"
import { PluginHost } from "@opencode/core/plugin/host"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Effect, Exit } from "effect"
import { testEffect } from "../../core/test/lib/effect"
import type { atomic } from "../src/storage"
import { storage } from "./fixture/storage"

const it = testEffect(LayerNode.compile(KV.node))

// The plugin loader evaluates the plugin module again for every Location; two query strings give two evaluations.
const evaluate = (instance: string): Promise<{ readonly atomic: typeof atomic }> =>
  import(`../src/storage.ts?${instance}`)

describe("plugin storage", () => {
  it.live("serializes updates from separately evaluated plugin instances and keeps thrown callbacks unwritten", () =>
    Effect.gen(function* () {
      const kv = yield* KV.Service
      const [first, second] = yield* Effect.promise(() => Promise.all([evaluate("first"), evaluate("second")]))
      expect(first.atomic).not.toBe(second.atomic)
      // Yield between the read and the write, as a preempted fiber or an asynchronous database would.
      const host = () => {
        const storage = PluginHost.storage(kv, "example.plugin")
        return { ...storage, get: (key: string) => storage.get(key).pipe(Effect.tap(() => Effect.sleep("1 millis"))) }
      }
      const storages = [first.atomic(host()), second.atomic(host())]
      yield* storages[0].set("counter", 0)
      const results = yield* Effect.all(
        Array.from({ length: 50 }, (_, index) =>
          storages[index % 2].update("counter", (current) => {
            const next = Number(current) + 1
            return [next, next]
          }),
        ),
        { concurrency: "unbounded" },
      )
      expect(results.toSorted((a, b) => a - b)).toEqual(Array.from({ length: 50 }, (_, index) => index + 1))
      expect(yield* storages[1].get("counter")).toBe(50)

      const exit = yield* storages[1]
        .update("counter", () => {
          throw new Error("rollback")
        })
        .pipe(Effect.exit)
      expect(exit._tag).toBe("Failure")
      expect(yield* storages[0].get("counter")).toBe(50)
    }),
  )

  it.live("removes a key whose next value is undefined; null dies in the KV table and in the test fake alike", () =>
    Effect.gen(function* () {
      const host = PluginHost.storage(yield* KV.Service, "example.plugin")
      const { atomic } = yield* Effect.promise(() => evaluate("remove"))
      const shared = atomic(host)
      yield* shared.set("window", { since: 1 })
      expect(yield* shared.update("window", (current) => [undefined, current])).toEqual({ since: 1 })
      expect(yield* shared.get("window")).toBeUndefined()
      expect((yield* shared.scan({ prefix: "window" })).entries).toEqual([])
      expect(yield* shared.update("window", (current) => [undefined, current])).toBeUndefined()

      for (const target of [host, storage()]) {
        expect(Exit.hasDies(yield* target.set("window", null).pipe(Effect.exit))).toBe(true)
      }
      // @ts-expect-error The plugin's own storage refuses `null` before it runs.
      expect(Exit.hasDies(yield* shared.set("window", null).pipe(Effect.exit))).toBe(true)
    }),
  )
})
