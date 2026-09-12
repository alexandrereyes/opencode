import path from "node:path"
import { describe, expect } from "bun:test"
import AppMentionsPlugin from "../../../plugin-app-custom/src/index"
import { AppMentions } from "../../../plugin-app-custom/src/rpc"
import { Mcp } from "@opencode/core/mcp/index"
import { ConfigMCP } from "@opencode/schema/config/mcp"
import { PluginHost } from "@opencode/core/plugin/host"
import { Rpc } from "@opencode/core/rpc"
import { Plugin } from "@opencode/plugin"
import { fromPromise } from "@opencode/plugin/promise/adapter"
import { Effect, Fiber, Latch, Ref } from "effect"
import { TestClock } from "effect/testing"
import { testEffect } from "../lib/effect"
import { hostEnvironmentLayer } from "../fixture/environment"
import { PluginTestLayer } from "./fixture"

const it = testEffect(PluginTestLayer)

const mcp = (options?: {
  readonly missing?: boolean
  readonly error?: boolean
  readonly callTool?: Mcp.Interface["callTool"]
}) =>
  Mcp.Service.of({
    transform: () => Effect.die("unused mcp.transform"),
    reload: () => Effect.die("unused mcp.reload"),
    servers: () =>
      Effect.succeed(
        options?.missing
          ? []
          : [new Mcp.ServerInfo({ name: Mcp.ServerName.make("open-computer-use"), status: { status: "connected" } })],
      ),
    add: () => Effect.die("unused mcp.add"),
    connect: () => Effect.die("unused mcp.connect"),
    disconnect: () => Effect.die("unused mcp.disconnect"),
    remove: () => Effect.die("unused mcp.remove"),
    tools: () => Effect.succeed([]),
    callTool:
      options?.callTool ??
      ((input) =>
        Effect.succeed(
          new Mcp.ToolResult({
            server: Mcp.ServerName.make(input.server),
            tool: input.name,
            isError: options?.error ?? false,
            content: [
              {
                type: "text",
                text: "Safari — com.apple.Safari [running]\nSafari — com.apple.Safari [running]",
              },
            ],
          }),
        )),
    instructions: () => Effect.succeed([]),
    prompts: () => Effect.succeed([]),
    prompt: () => Effect.undefined,
    resourceCatalog: () => Effect.succeed(Mcp.ResourceCatalog.make({ resources: [], templates: [] })),
    readResource: () => Effect.undefined,
  })

const call = Effect.fn(function* (service: Mcp.Interface) {
  const host = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(
    Effect.provideService(Mcp.Service, service),
  )
  yield* AppMentionsPlugin.effect(host)
  const rpc = yield* Rpc.Service
  return yield* rpc.client(AppMentions.Definition).list({})
})

const withFixtureMcp = <A, E, R>(run: (service: Mcp.Interface) => Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const service = yield* Mcp.Service
    yield* service.add(
      "open-computer-use",
      new ConfigMCP.Local({
        type: "local",
        command: [
          process.execPath,
          path.join(import.meta.dir, "../../../plugin-app-custom/test/fixture/mcp-server.ts"),
        ],
      }),
    )
    yield* service.tools()
    return yield* run(service)
  }).pipe(Effect.provide(Mcp.layer()), Effect.provide(hostEnvironmentLayer))

describe("app mentions plugin integration", () => {
  it.live("runs the real plugin through PluginHost, RPC, and a fixture MCP server", () =>
    Effect.gen(function* () {
      expect(yield* withFixtureMcp(call)).toEqual({
        apps: [
          {
            server: "open-computer-use",
            name: "Safari",
            bundleID: "com.apple.Safari",
            running: true,
          },
        ],
      })
    }),
  )

  it.effect("returns an empty list for missing servers and MCP error results", () =>
    Effect.gen(function* () {
      expect(yield* call(mcp({ missing: true }))).toEqual({ apps: [] })
      expect(yield* call(mcp({ error: true }))).toEqual({ apps: [] })
      expect(
        yield* call(
          mcp({
            callTool: () =>
              Effect.fail(
                new Mcp.ToolCallError({
                  server: Mcp.ServerName.make("open-computer-use"),
                  tool: "list_apps",
                  message: "fixture failure",
                }),
              ),
          }),
        ),
      ).toEqual({ apps: [] })
    }),
  )

  it.effect("times out discovery after five seconds and cancels the MCP call", () =>
    Effect.gen(function* () {
      const interrupted = yield* Ref.make(false)
      const pending = yield* call(
        mcp({ callTool: () => Effect.never.pipe(Effect.ensuring(Ref.set(interrupted, true))) }),
      ).pipe(Effect.forkChild({ startImmediately: true }))
      yield* TestClock.adjust("5 seconds")
      expect(yield* Fiber.join(pending)).toEqual({ apps: [] })
      expect(yield* Ref.get(interrupted)).toBe(true)
    }),
  )

  it.effect("interrupts Effect MCP calls", () =>
    Effect.gen(function* () {
      const interrupted = yield* Ref.make(false)
      const host = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(
        Effect.provideService(
          Mcp.Service,
          mcp({ callTool: () => Effect.never.pipe(Effect.ensuring(Ref.set(interrupted, true))) }),
        ),
      )
      const fiber = yield* host.mcp
        .callTool({ server: "open-computer-use", name: "list_apps" })
        .pipe(Effect.forkChild({ startImmediately: true }))
      yield* Fiber.interrupt(fiber)
      expect(yield* Ref.get(interrupted)).toBe(true)
    }),
  )

  it.effect("exposes generic structured MCP results and plugin-owned errors", () =>
    Effect.gen(function* () {
      const host = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(
        Effect.provideService(
          Mcp.Service,
          mcp({
            callTool: (input) =>
              Effect.succeed(
                new Mcp.ToolResult({
                  server: Mcp.ServerName.make(input.server),
                  tool: input.name,
                  isError: false,
                  structured: { count: 2 },
                  content: [],
                }),
              ),
          }),
        ),
      )
      expect(yield* host.mcp.callTool({ server: "fixture", name: "structured" })).toMatchObject({
        server: "fixture",
        tool: "structured",
        isError: false,
        structured: { count: 2 },
      })

      const failure = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(
        Effect.provideService(
          Mcp.Service,
          mcp({ callTool: () => Effect.fail(new Mcp.NotFoundError({ server: Mcp.ServerName.make("missing") })) }),
        ),
        Effect.flatMap((context) => context.mcp.callTool({ server: "missing", name: "tool" })),
        Effect.flip,
      )
      expect(failure).toMatchObject({
        _tag: "Plugin.MCP.CallToolError",
        server: "missing",
        tool: "tool",
        message: "MCP server not found: missing",
      })
    }),
  )

  it.effect("propagates Promise AbortSignals through the adapter", () =>
    Effect.gen(function* () {
      const interrupted = yield* Ref.make(false)
      const host = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(
        Effect.provideService(
          Mcp.Service,
          mcp({ callTool: () => Effect.never.pipe(Effect.ensuring(Ref.set(interrupted, true))) }),
        ),
      )
      const plugin = fromPromise(
        Plugin.define({
          id: "test.promise-mcp-cancellation",
          setup: async (ctx) => {
            const controller = new AbortController()
            const pending = ctx.mcp.callTool(
              { server: "open-computer-use", name: "list_apps" },
              { signal: controller.signal },
            )
            controller.abort()
            await pending.catch(() => undefined)
          },
        }),
      )
      yield* plugin.effect(host)
      expect(yield* Ref.get(interrupted)).toBe(true)
    }),
  )

  it.effect("cancels pending Promise MCP calls when the plugin scope closes", () =>
    Effect.gen(function* () {
      const started = yield* Latch.make()
      const interrupted = yield* Ref.make(false)
      const cleaned = yield* Ref.make(false)
      const host = yield* PluginHost.make({ list: () => Effect.succeed([]) }).pipe(
        Effect.provideService(
          Mcp.Service,
          mcp({
            callTool: () =>
              Effect.gen(function* () {
                yield* started.open
                return yield* Effect.never
              }).pipe(Effect.ensuring(Ref.set(interrupted, true))),
          }),
        ),
      )
      const plugin = fromPromise(
        Plugin.define({
          id: "test.promise-mcp-unload",
          setup: async (ctx) => {
            const pending = ctx.mcp.callTool({ server: "open-computer-use", name: "list_apps" }).catch(() => undefined)
            await Effect.runPromise(started.await)
            return async () => {
              await pending
              await Effect.runPromise(Ref.set(cleaned, true))
            }
          },
        }),
      )
      yield* plugin.effect(host).pipe(Effect.scoped)
      expect(yield* Ref.get(interrupted)).toBe(true)
      expect(yield* Ref.get(cleaned)).toBe(true)
    }),
  )
})
