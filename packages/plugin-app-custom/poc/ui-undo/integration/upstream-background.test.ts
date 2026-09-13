import { expect } from "bun:test"
import path from "node:path"
import { OpenCode } from "@opencode/client"
import { llmClient } from "@opencode/core/effect/app-node-platform"
import { Session } from "@opencode/core/session"
import { SessionRunnerModel } from "@opencode/core/session/runner/model"
import { Agent } from "@opencode/schema/agent"
import { Location } from "@opencode/schema/location"
import { AbsolutePath } from "@opencode/schema/schema"
import { Global } from "@opencode/util/global"
import { Context, Deferred, Effect, Layer, Schema, Stream } from "effect"
import { HttpEffect, HttpRouter, HttpServer } from "effect/unstable/http"
import { LanguageModel, LLMClient } from "../../ai/src"
import { OpenAIChat } from "../../ai/src/protocols/openai-chat"
import { TestLLM } from "../../ai/src/testing"
import { UiUndoRpc } from "./.poc-ui-undo-runtime/rpc"
import { tempGlobalLayer } from "../../core/test/fixture/global"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"

const LateCancellation = Schema.Struct({
  type: Schema.Literal("rpc.poc.ui-undo.lateCancellation"),
  data: Schema.Struct({ sessionID: Schema.String, inboxID: Schema.String, outcome: Schema.String }),
})

it.live(
  "normal plugin observes late background delivery too late and must commit the undo",
  () =>
    Effect.gen(function* () {
      const directory = yield* tmpdirScoped()
      const baseUrl = "http://127.0.0.1:42107"
      const pluginPackage = path.join(import.meta.dir, ".poc-ui-undo-runtime/plugin-package")
      const llm = yield* TestLLM.Test.pipe(Effect.provide(TestLLM.testLayer()))
      const childStarted = yield* Deferred.make<void>()
      const childStopped = yield* Deferred.make<void>()
      const model = SessionRunnerModel.resolved(
        LanguageModel.make({ id: "fixture", provider: "fixture", route: OpenAIChat.route }),
        {
          capabilities: { tools: true, input: ["text"], output: ["text"] },
          cost: [],
          limit: { context: 200_000, output: 8_192 },
        },
      )
      const context = yield* Layer.build(
        createEmbeddedRoutes(
          {
            database: { path: ":memory:" },
            models: { fetch: false },
            fs: { filewatcher: false, fff: false },
            config: {
              project: false,
              content: JSON.stringify({
                snapshots: false,
                plugins: [{ package: pluginPackage, options: { baseUrl, password: "fixture" } }],
                permissions: [{ action: "*", resource: "*", effect: "allow" }],
                agents: { worker: { mode: "subagent", description: "worker" } },
              }),
            },
          },
          [
            Global.node.replace(tempGlobalLayer),
            llmClient.replace(Layer.succeed(LLMClient.Service, llm)),
            SessionRunnerModel.node.replace(
              Layer.succeed(SessionRunnerModel.Service, { resolve: () => Effect.succeed(model) }),
            ),
          ],
        ).pipe(Layer.provide(HttpServer.layerServices)),
      )
      const sessions = Context.get(context, Session.Service)
      const parent = yield* sessions.create({
        agent: Agent.ID.make("build"),
        model: model.ref,
        location: Location.Ref.make({ directory: AbsolutePath.make(directory.path) }),
      })
      yield* llm.serve((request) => {
        const text = JSON.stringify(request.messages)
        const users = JSON.stringify(request.messages.filter((message) => message.role === "user"))
        if (users.includes("late-child"))
          return Stream.fromEffect(Deferred.succeed(childStarted, undefined)).pipe(
            Stream.drain,
            Stream.concat(Stream.never),
            Stream.ensuring(Deferred.succeed(childStopped, undefined)),
          )
        if (text.includes("background-child")) return TestLLM.text("background started", "root-done")
        return TestLLM.tool("background-child", "subagent", {
          agent: "worker",
          description: "late child",
          prompt: "late-child",
          background: true,
        })
      })
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "start late child", resume: false })
      yield* sessions.resume(parent.id)
      yield* Deferred.await(childStarted).pipe(Effect.timeout("5 seconds"))
      const child = (yield* sessions.list({ parentID: parent.id })).data[0]
      if (!child) return yield* Effect.die("Expected child")

      const handler = Context.get(context, HttpRouter.HttpRouter)
        .asHttpEffect()
        .pipe(HttpEffect.toWebHandlerWith(context))
      const server = yield* Effect.acquireRelease(
        Effect.sync(() => Bun.serve({ hostname: "127.0.0.1", port: 42107, fetch: (request) => handler(request) })),
        (server) => Effect.sync(() => server.stop(true)),
      )
      const client = OpenCode.make({ baseUrl })
      yield* Effect.promise(() => client.plugin.awaitActivation({ location: { directory: directory.path } }))
      const parentMessages = (yield* Effect.promise(() => client.message.list({ sessionID: parent.id, order: "asc" })))
        .data
      const origin = parentMessages.find(
        (message) =>
          message.type === "assistant" &&
          message.content.some((part) => part.type === "tool" && part.id === "background-child"),
      )
      const childInput = (yield* Effect.promise(() =>
        client.message.list({ sessionID: child.id, order: "asc", type: "user" }),
      )).data[0]
      if (!origin || !childInput) return yield* Effect.die("Expected public origin and child input")
      const rpc = client.rpc(UiUndoRpc)
      const rpcOptions = { location: { directory: directory.path } }
      yield* Effect.promise(() =>
        rpc.record(
          {
            childSessionID: child.id,
            inputID: childInput.id,
            assignedSeq: 0,
            origin: { parentSessionID: parent.id, parentMessageID: origin.id, toolCallID: "background-child" },
          },
          rpcOptions,
        ),
      )
      const observation = yield* Effect.sync(() => {
        const controller = new AbortController()
        const ready = Promise.withResolvers<void>()
        const result = (async () => {
          const order: string[] = []
          let inboxID: string | undefined
          let outcome: string | undefined
          for await (const event of client.event.subscribe({ signal: controller.signal })) {
            if (event.type === "server.connected") {
              ready.resolve()
              continue
            }
            if (Schema.is(LateCancellation)(event) && event.data.sessionID === parent.id) outcome = event.data.outcome
            if (!("data" in event) || !("sessionID" in event.data) || event.data.sessionID !== parent.id) continue
            if (
              event.type === "session.inbox.enqueued" &&
              event.data.item.type === "synthetic" &&
              event.data.item.payload.text.includes("Subagent cancelled")
            ) {
              inboxID = event.data.inboxID
              order.push(event.type)
            }
            if (event.type === "session.inbox.delivered" && event.data.inboxID === inboxID) {
              order.push(event.type)
            }
            if (order.length < 2 || !outcome) continue
            controller.abort()
            return { order, outcome }
          }
          throw new Error("Event stream ended before cancellation notification")
        })()
        return { ready: ready.promise, result }
      })
      yield* Effect.promise(() => observation.ready).pipe(Effect.timeout("5 seconds"))
      yield* Effect.promise(() => rpc.stage({ rootSessionID: parent.id, rootMessageID: boundary.id }, rpcOptions))
      yield* Deferred.await(childStopped).pipe(Effect.timeout("5 seconds"))
      const observed = yield* Effect.promise(() => observation.result).pipe(Effect.timeout("5 seconds"))

      const visible = JSON.stringify({
        inbox: yield* sessions.inbox(parent.id),
        messages: yield* sessions.messages({ sessionID: parent.id }),
      })
      expect(visible).not.toContain("Subagent cancelled")
      expect((yield* sessions.get(parent.id)).revert).toBeUndefined()
      expect((yield* sessions.get(child.id)).revert).toBeUndefined()
      expect(observed.order).toEqual(["session.inbox.enqueued", "session.inbox.delivered"])
      expect(observed.outcome).toBe("too-late")
      expect(server.port).toBe(42107)
    }).pipe(Effect.scoped),
  20_000,
)
