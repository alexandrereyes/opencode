import { expect } from "bun:test"
import { Context, Deferred, Effect, Exit, Fiber, Layer } from "effect"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { Bus } from "@opencode/core/bus"
import { KV } from "@opencode/core/kv"
import { PersistentPty } from "@opencode/core/persistent-pty"
import { SessionFamily } from "@opencode/core/session/family"
import { Worktree } from "@opencode/core/worktree"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Location } from "@opencode/core/location"
import { LocationServiceMap } from "@opencode/core/location-service-map"
import { LocationWatcher } from "@opencode/core/filesystem/location-watcher"
import { Form } from "@opencode/core/form"
import { PluginHost } from "@opencode/core/plugin/host"
import { Session } from "@opencode/core/session"
import { AbsolutePath } from "@opencode/core/schema"
import { Global } from "@opencode/util/global"
import { tempGlobalLayer } from "../fixture/global"
import { tmpdirScoped } from "../fixture/tmpdir"
import { offlineModels } from "../fixture/models"
import { testEffect } from "../lib/effect"

for (const failure of ["defect", "interrupt"] as const) {
  testEffect(Layer.empty).live(`pending requests skip booting ${failure}s without losing healthy snapshots`, () =>
    Effect.gen(function* () {
      const entered = yield* Deferred.make<void>()
      const release = yield* Deferred.make<void>()
      const builds = { count: 0 }
      const layer = AppNodeBuilder.build(
        LayerNode.group([
          LocationServiceMap.node,
          Bus.node,
          KV.node,
          Session.node,
          SessionFamily.node,
          PersistentPty.node,
          Worktree.node,
        ]),
        [
          Global.node.replace(tempGlobalLayer),
          offlineModels,
          LocationWatcher.node.replace(
            LocationWatcher.node.mapLayer((layer) =>
              layer.pipe(
                Layer.tap(() =>
                  Effect.gen(function* () {
                    if (++builds.count !== 2) return
                    // Hold the second real graph build while pending() runs.
                    yield* Deferred.succeed(entered, undefined)
                    yield* Deferred.await(release)
                    return yield* failure === "interrupt" ? Effect.interrupt : Effect.die("location boot failed")
                  }),
                ),
              ),
            ),
          ),
        ],
      )
      yield* Effect.gen(function* () {
        const healthy = yield* tmpdirScoped()
        const broken = yield* tmpdirScoped()
        const locations = yield* LocationServiceMap.Service
        const ref = Location.Ref.make({ directory: AbsolutePath.make(healthy.path) })
        const services = yield* locations.contextEffect(ref)
        const host = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(Effect.provide(services))
        const forms = Context.get(services, Form.Service)
        yield* forms
          .ask({
            sessionID: Session.ID.create(),
            title: "Healthy request",
            fields: [{ key: "answer", type: "string" }],
          })
          .pipe(Effect.forkScoped({ startImmediately: true }))
        const expected = yield* host.request.pending()
        expect(expected[0]?.forms).toHaveLength(1)
        const boot = yield* locations
          .contextEffect(Location.Ref.make({ directory: AbsolutePath.make(broken.path) }))
          .pipe(Effect.scoped, Effect.exit, Effect.forkScoped)
        yield* Effect.addFinalizer(() => Deferred.succeed(release, undefined))
        yield* Deferred.await(entered)
        // An in-flight boot is skipped rather than awaited.
        expect(yield* host.request.pending().pipe(Effect.timeout("2 seconds"))).toEqual(expected)
        yield* Deferred.succeed(release, undefined)
        expect(Exit.isFailure(yield* Fiber.join(boot))).toBe(true)
        expect(yield* host.request.pending()).toEqual(expected)
      }).pipe(Effect.provide(layer))
    }),
  )
}
