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

})
