import { expect } from "bun:test"
import { llmClient } from "@opencode/core/effect/app-node-platform"
import { Session } from "@opencode/core/session"
import { SessionRunnerModel } from "@opencode/core/session/runner/model"
import { Agent } from "@opencode/schema/agent"
import { Location } from "@opencode/schema/location"
import { AbsolutePath } from "@opencode/schema/schema"
import { Global } from "@opencode/util/global"
import { Context, Deferred, Effect, Layer, Stream } from "effect"
import { HttpEffect, HttpRouter, HttpServer } from "effect/unstable/http"
import { LanguageModel, LLMClient } from "../../ai/src"
import { OpenAIChat } from "../../ai/src/protocols/openai-chat"
import { TestLLM } from "../../ai/src/testing"
import { tempGlobalLayer } from "../../core/test/fixture/global"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"

it.live(
  "HTTP undo stops a reused background child and admits the next prompt against rewound history",
  () =>
    Effect.gen(function* () {
      const directory = yield* tmpdirScoped()
      const llm = yield* TestLLM.Test.pipe(Effect.provide(TestLLM.testLayer()))
      const started = yield* Deferred.make<void>()
      const stopped = yield* Deferred.make<void>()
      const earlierStarted = yield* Deferred.make<void>()
      const earlierStopped = yield* Deferred.make<void>()
      const model = SessionRunnerModel.resolved(
        LanguageModel.make({ id: "revert-model", provider: "test", route: OpenAIChat.route }),
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
                experimental: { subagent_depth: 3 },
                permissions: [{ action: "*", resource: "*", effect: "allow" }],
                agents: { worker: { mode: "subagent", description: "Revert test worker" } },
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
      const handler = Context.get(context, HttpRouter.HttpRouter)
        .asHttpEffect()
        .pipe(HttpEffect.toWebHandlerWith(context))
      const parent = yield* sessions.create({
        title: "Revert parent",
        agent: Agent.ID.make("build"),
        model: model.ref,
        location: Location.Ref.make({ directory: AbsolutePath.make(directory.path) }),
      })
      const post = (suffix: string, body: unknown = {}, status = 200) =>
        Effect.promise(async () => {
          const response = await handler(
            new Request(`http://opencode.local/api/session/${parent.id}/${suffix}`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify(body),
            }),
          )
          const result = await response.text()
          expect({ status: response.status, result }).toMatchObject({ status })
          return result
        })

      yield* llm.serve((request) => {
        const users = JSON.stringify(request.messages.filter((message) => message.role === "user"))
        if (users.includes("earlier-worker"))
          return Stream.fromEffect(Deferred.succeed(earlierStarted, undefined)).pipe(
            Stream.drain,
            Stream.concat(Stream.never),
            Stream.ensuring(Deferred.succeed(earlierStopped, undefined)),
          )
        if (users.includes("child-initial")) {
          if (JSON.stringify(request.messages).includes("create_earlier_worker"))
            return TestLLM.text("initial-child-answer", "child_initial")
          return TestLLM.tool("create_earlier_worker", "subagent", {
            agent: "worker",
            description: "Earlier independent worker",
            prompt: "earlier-worker",
            background: true,
          })
        }
        if (JSON.stringify(request.messages).includes("create_child"))
          return TestLLM.text("worker created", "parent_initial")
        return TestLLM.tool("create_child", "subagent", {
          agent: "worker",
          description: "Initial worker",
          prompt: "child-initial",
        })
      })
      yield* sessions.prompt({ sessionID: parent.id, text: "create-worker", resume: false })
      yield* sessions.resume(parent.id)
      const children = (yield* sessions.list({ parentID: parent.id })).data
      expect(children, JSON.stringify(yield* sessions.messages({ sessionID: parent.id }))).toHaveLength(1)
      const child = children[0]
      if (!child) throw new Error("Expected a child session")
      expect(
        (yield* sessions.list({ parentID: child.id })).data,
        JSON.stringify(yield* sessions.messages({ sessionID: child.id })),
      ).toHaveLength(1)
      yield* Deferred.await(earlierStarted)

      yield* llm.serve((request) => {
        const users = JSON.stringify(request.messages.filter((message) => message.role === "user"))
        if (users.includes("child-updated"))
          return Stream.fromEffect(Deferred.succeed(started, undefined)).pipe(
            Stream.drain,
            Stream.concat(Stream.never),
            Stream.ensuring(Deferred.succeed(stopped, undefined)),
          )
        if (JSON.stringify(request.messages).includes("continue_child"))
          return TestLLM.text("worker in background", "parent_background")
        return TestLLM.tool("continue_child", "subagent", {
          agent: "worker",
          sessionID: child.id,
          description: "Update worker",
          prompt: "child-updated",
          background: true,
        })
      })
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "update-worker", resume: false })
      yield* sessions.resume(parent.id)
      yield* Deferred.await(started)

      yield* post("revert/stage", { messageID: boundary.id })
      expect(yield* Deferred.isDone(stopped)).toBe(true)
      expect(yield* Deferred.isDone(earlierStopped)).toBe(false)
      expect((yield* sessions.get(child.id)).revert).toBeDefined()

      // Redo restores the child's staged history without restarting cancelled execution.
      yield* post("revert/clear", {}, 204)
      expect((yield* sessions.get(child.id)).revert).toBeUndefined()
      expect(JSON.stringify(yield* sessions.messages({ sessionID: child.id }))).toContain("child-updated")
      yield* post("revert/stage", { messageID: boundary.id })

      yield* llm.serve((request) => {
        const users = JSON.stringify(request.messages.filter((message) => message.role === "user"))
        if (users.includes("child-new")) {
          expect(users).toContain("child-initial")
          expect(users).not.toContain("child-updated")
          return TestLLM.text("new child branch", "child_new")
        }
        if (JSON.stringify(request.messages).includes("new_child")) return TestLLM.text("new branch", "parent_new")
        return TestLLM.tool("new_child", "subagent", {
          agent: "worker",
          sessionID: child.id,
          description: "Continue after undo",
          prompt: "child-new",
        })
      })
      yield* post("prompt", { text: "new-iteration", resume: false })
      yield* sessions.resume(parent.id)
      const history = JSON.stringify(yield* sessions.messages({ sessionID: child.id }))
      expect(history).toContain("child-initial")
      expect(history).toContain("initial-child-answer")
      expect(history).toContain("child-new")
      expect(history).not.toContain("child-updated")
      expect((yield* sessions.get(child.id)).revert).toBeUndefined()
      expect(yield* sessions.inbox(parent.id)).toEqual([])
      const messages = JSON.stringify(yield* sessions.messages({ sessionID: parent.id }))
      expect(messages).toContain("new-iteration")
      expect(messages).not.toContain("Subagent cancelled")
      expect(yield* Deferred.isDone(earlierStopped)).toBe(false)
    }).pipe(Effect.scoped),
  30_000,
)
