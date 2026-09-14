import { expect } from "bun:test"
import { SdkPlugins } from "@opencode/core/plugin/sdk"
import { define } from "@opencode/plugin/effect/plugin"
import { Rpc } from "@opencode/schema/rpc"
import { Context, Effect, Layer, Schema } from "effect"
import { HttpEffect, HttpRouter, HttpServer } from "effect/unstable/http"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"
import { AfterResponse } from "../src/after-response"

const Broken = Rpc.define({
  id: "broken",
  methods: {
    handler: { input: Schema.String, output: Schema.String },
    schema: {
      input: Schema.String.check(
        Schema.makeFilter(() => {
          throw new Error("private schema detail")
        }),
      ),
      output: Schema.String,
    },
  },
  events: {},
})

it.live("only successful RPC output arms a response callback; embedded calls have no response capability", () =>
  Effect.gen(function* () {
    const directory = yield* tmpdirScoped()
    const context = yield* Layer.build(
      createEmbeddedRoutes({
        database: { path: ":memory:" },
        models: { fetch: false },
        config: { directory: directory.path, project: false, content: "{}" },
        fs: { filewatcher: false },
      }).pipe(Layer.provide(HttpServer.layerServices)),
    )
    const sdk = Context.get(context, SdkPlugins.Service)
    const callbacks: Array<() => void> = []
    const observed: boolean[] = []
    const definition = Rpc.define({
      id: "response",
      methods: {
        run: { input: Schema.String, output: Schema.String.check(Schema.isMinLength(3)) },
      },
      events: {},
    })
    yield* sdk.register(
      define({
        id: "response-test",
        effect: (ctx) =>
          ctx.rpc
            .register(definition, {
              run: (input, call) =>
                Effect.sync(() => {
                  observed.push(call.afterResponse !== undefined)
                  call.afterResponse?.(() => {})
                  return input
                }),
            })
            .pipe(Effect.asVoid, Effect.orDie),
      }),
    )
    const router = Context.get(context, HttpRouter.HttpRouter).asHttpEffect()
    const handler = router.pipe(
      Effect.provideService(AfterResponse, (callback) => callbacks.push(callback)),
      HttpEffect.toWebHandlerWith(context),
    )
    const embedded = router.pipe(HttpEffect.toWebHandlerWith(context))
    const url = new URL("/api/rpc/response/run", "http://opencode.local")
    url.searchParams.set("location[directory]", directory.path)
    const make = (input: string) =>
      new Request(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ input }),
      })
    expect((yield* Effect.promise(() => handler(make("")))).status).toBe(500)
    expect(callbacks).toHaveLength(0)
    expect((yield* Effect.promise(() => handler(make("valid")))).status).toBe(200)
    expect(callbacks).toHaveLength(1)
    expect((yield* Effect.promise(() => embedded(make("valid")))).status).toBe(200)
    expect(observed).toEqual([true, true, false])
  }),
)

for (const method of ["handler", "schema"] as const) {
  it.live(`returns HTTP 500 without exposing the ${method} defect`, () =>
    Effect.gen(function* () {
      const directory = yield* tmpdirScoped()
      const context = yield* Layer.build(
        createEmbeddedRoutes({
          database: { path: ":memory:" },
          models: { fetch: false },
          config: { directory: directory.path, project: false, content: "{}" },
          fs: { filewatcher: false },
        }).pipe(Layer.provide(HttpServer.layerServices)),
      )
      const sdk = Context.get(context, SdkPlugins.Service)
      yield* sdk.register(
        define({
          id: "broken-rpc",
          effect: (ctx) =>
            ctx.rpc
              .register(Broken, {
                handler: () => Effect.die(new Error("private handler detail")),
                schema: Effect.succeed,
              })
              .pipe(Effect.asVoid, Effect.orDie),
        }),
      )
      const handler = Context.get(context, HttpRouter.HttpRouter)
        .asHttpEffect()
        .pipe(HttpEffect.toWebHandlerWith(context))
      const url = new URL(`/api/rpc/broken/${method}`, "http://opencode.local")
      url.searchParams.set("location[directory]", directory.path)
      const response = yield* Effect.promise(() =>
        handler(
          new Request(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ input: "hello" }),
          }),
        ),
      )
      expect(response.status).toBe(500)
      expect(yield* Effect.promise(() => response.json())).toEqual({
        _tag: "RpcInternalError",
        type: "rpc.internal",
        message: "RPC call failed",
      })
    }),
  )
}
