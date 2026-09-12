import { describe, expect } from "bun:test"
import { Effect } from "effect"
import { KV } from "@opencode/core/kv"
import { PluginHost } from "@opencode/core/plugin/host"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { testEffect } from "./lib/effect"

const it = testEffect(LayerNode.compile(KV.node))

describe("plugin storage", () => {
  it.effect("updates one plugin key atomically across host instances and rolls back thrown callbacks", () =>
    Effect.gen(function* () {
      const kv = yield* KV.Service
      const first = PluginHost.storage(kv, "example.plugin")
      const second = PluginHost.storage(kv, "example.plugin")
      yield* first.set("counter", 0)
      yield* Effect.all(
        Array.from({ length: 50 }, (_, index) =>
          (index % 2 ? first : second).update("counter", (current) => [Number(current) + 1, undefined]),
        ),
        { concurrency: "unbounded" },
      )
      expect(yield* first.get("counter")).toBe(50)

      const exit = yield* first
        .update("counter", () => {
          throw new Error("rollback")
        })
        .pipe(Effect.exit)
      expect(exit._tag).toBe("Failure")
      expect(yield* first.get("counter")).toBe(50)
    }),
  )

  it.effect("adopts an unnamespaced key once without replacing an existing target or restoring a deleted target", () =>
    Effect.gen(function* () {
      const kv = yield* KV.Service
      const first = PluginHost.storage(kv, "first.plugin")
      const second = PluginHost.storage(kv, "second.plugin")
      const legacy = [{ id: "legacy", content: "kept" }]
      yield* kv.set("catalog", legacy)

      expect(
        (yield* Effect.all([first.adoptLegacy("catalog"), first.adoptLegacy("catalog")], { concurrency: 2 })).sort(),
      ).toEqual([false, true])
      expect(yield* first.get("catalog")).toEqual(legacy)
      expect(yield* second.get("catalog")).toBeUndefined()

      yield* first.remove("catalog")
      yield* kv.set("catalog", [{ id: "new-legacy", content: "must-not-return" }])
      expect(yield* first.adoptLegacy("catalog")).toBe(false)
      expect(yield* first.get("catalog")).toBeUndefined()

      yield* second.set("catalog", [{ id: "current", content: "wins" }])
      expect(yield* second.adoptLegacy("catalog")).toBe(false)
      expect(yield* second.get("catalog")).toEqual([{ id: "current", content: "wins" }])

      yield* kv.set("plugin:foreign:key", "private")
      expect((yield* second.adoptLegacy("plugin:foreign:key").pipe(Effect.exit))._tag).toBe("Failure")
      expect(yield* second.get("plugin:foreign:key")).toBeUndefined()
    }),
  )
})
