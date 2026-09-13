import { watch } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { llmClient } from "@opencode/core/effect/app-node-platform"
import { Bus } from "@opencode/core/bus"
import { Job } from "@opencode/core/job"
import { KV } from "@opencode/core/kv"
import { LocationServiceMap } from "@opencode/core/location-service-map"
import { Session } from "@opencode/core/session"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionRunnerModel } from "@opencode/core/session/runner/model"
import { Shell } from "@opencode/core/shell"
import { Agent } from "@opencode/schema/agent"
import { Location } from "@opencode/schema/location"
import { AbsolutePath } from "@opencode/schema/schema"
import { makeGlobalNode } from "@opencode/util/effect/app-node"
import { Global } from "@opencode/util/global"
import { Context, Deferred, Effect, Exit, Fiber, Layer } from "effect"
import { HttpEffect, HttpRouter, HttpServer } from "effect/unstable/http"
import { LanguageModel, LLMClient } from "../../ai/src"
import { OpenAIChat } from "../../ai/src/protocols/openai-chat"
import { TestLLM } from "../../ai/src/testing"
import { tempGlobalLayer } from "../../core/test/fixture/global"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"

it.live(
  "HTTP undo stops a background shell and suppresses its cancellation notice",
  () =>
    Effect.gen(function* () {
      const directory = yield* tmpdirScoped()
      const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
      const pluginPackage = path.join(directory.path, "plugin")
      yield* Effect.promise(async () => {
        await fs.mkdir(pluginPackage)
        await fs.writeFile(
          path.join(pluginPackage, "package.json"),
          JSON.stringify({ type: "module", exports: "./index.ts" }),
        )
        await fs.writeFile(path.join(pluginPackage, "index.ts"), `export { default } from ${JSON.stringify(plugin)}\n`)
      })
      const llm = yield* TestLLM.Test.pipe(Effect.provide(TestLLM.testLayer()))
      const ready = yield* Deferred.make<void>()
      const completionReady = yield* Deferred.make<void>()
      const pausedReady = yield* Deferred.make<void>()
      const notificationEntered = yield* Deferred.make<void>()
      const notificationFinished = yield* Deferred.make<void>()
      const releaseNotification = yield* Deferred.make<void>()
      const insideNotificationEntered = yield* Deferred.make<void>()
      const releaseInsideNotification = yield* Deferred.make<void>()
      let notificationDelay: "none" | "before" = "none"
      const started = path.join(directory.path, "started")
      const release = path.join(directory.path, "release")
      const completionStarted = path.join(directory.path, "completion-started")
      const completionRelease = path.join(directory.path, "completion-release")
      const pausedStarted = path.join(directory.path, "paused-started")
      const pausedRelease = path.join(directory.path, "paused-release")
      yield* Effect.acquireRelease(
        Effect.sync(() =>
          watch(directory.path, (_event, filename) => {
            if (filename === "started") Deferred.doneUnsafe(ready, Exit.void)
            if (filename === "completion-started") Deferred.doneUnsafe(completionReady, Exit.void)
            if (filename === "paused-started") Deferred.doneUnsafe(pausedReady, Exit.void)
          }),
        ),
        (watcher) => Effect.sync(() => watcher.close()),
      )
      yield* Effect.addFinalizer(() =>
        Effect.promise(() =>
          Promise.all([Bun.write(release, ""), Bun.write(completionRelease, ""), Bun.write(pausedRelease, "")]),
        ).pipe(Effect.asVoid),
      )
      const command =
        process.platform === "win32"
          ? `Write-Output 'ready'; New-Item '${started}' -ItemType File | Out-Null; while (!(Test-Path '${release}')) { Start-Sleep -Milliseconds 10 }`
          : `printf 'ready\n'; touch '${started}'; while [ ! -f '${release}' ]; do sleep 60; done`
      const model = SessionRunnerModel.resolved(
        LanguageModel.make({ id: "revert-shell-model", provider: "test", route: OpenAIChat.route }),
        {
          capabilities: { tools: true, input: ["text"], output: ["text"] },
          cost: [],
          limit: { context: 200_000, output: 8_192 },
        },
      )
      const jobNode = makeGlobalNode({
        service: Job.Service,
        layer: Layer.effect(
          Job.Service,
          Effect.gen(function* () {
            const jobs = yield* Job.make
            return Job.Service.of({
              ...jobs,
              guard: (generation, effect) =>
                notificationDelay === "before"
                  ? Deferred.succeed(notificationEntered, undefined).pipe(
                      Effect.andThen(Deferred.await(releaseNotification)),
                      Effect.andThen(jobs.guard(generation, effect)),
                      Effect.ensuring(Deferred.succeed(notificationFinished, undefined)),
                    )
                  : jobs.guard(generation, effect),
            })
          }),
        ),
        deps: [KV.node],
      })
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
                plugins: [pluginPackage],
                permissions: [{ action: "*", resource: "*", effect: "allow" }],
              }),
            },
          },
          [
            Global.node.replace(tempGlobalLayer),
            Job.node.replace(jobNode),
            llmClient.replace(Layer.succeed(LLMClient.Service, llm)),
            SessionRunnerModel.node.replace(
              Layer.succeed(SessionRunnerModel.Service, { resolve: () => Effect.succeed(model) }),
            ),
          ],
        ).pipe(Layer.provide(HttpServer.layerServices)),
      )
      const sessions = Context.get(context, Session.Service)
      const bus = Context.get(context, Bus.Service)
      const jobs = Context.get(context, Job.Service)
      const locations = Context.get(context, LocationServiceMap.Service)
      const handler = Context.get(context, HttpRouter.HttpRouter)
        .asHttpEffect()
        .pipe(HttpEffect.toWebHandlerWith(context))
      const parent = yield* sessions.create({
        title: "Revert shell parent",
        agent: Agent.ID.make("build"),
        model: model.ref,
        location: Location.Ref.make({ directory: AbsolutePath.make(directory.path) }),
      })
      const shell = yield* Shell.Service.pipe(Effect.provide(locations.get(parent.location)))
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

      yield* llm.serve((request) =>
        JSON.stringify(request.messages).includes("call_background_shell")
          ? TestLLM.text("shell launched", "parent_shell_launched")
          : TestLLM.tool("call_background_shell", "shell", { command, background: true }),
      )
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "launch-shell", resume: false })
      yield* sessions.resume(parent.id)
      yield* Deferred.await(ready).pipe(Effect.timeout("5 seconds"))

      const running = yield* shell.list()
      expect(running).toHaveLength(1)
      const runningShell = running[0]
      if (!runningShell) return yield* Effect.die("Expected a running background shell")
      expect((yield* jobs.pendingBackground).find((job) => job.id === runningShell.id)).toBeDefined()
      const stopped = yield* shell
        .wait(runningShell.id)
        .pipe(Effect.exit, Effect.forkScoped({ startImmediately: true }))

      yield* post("revert/stage", { messageID: boundary.id })
      expect(Exit.isFailure(yield* Fiber.join(stopped).pipe(Effect.timeout("5 seconds")))).toBe(true)
      expect((yield* shell.list()).map((item) => item.id)).not.toContain(runningShell.id)
      expect((yield* jobs.get(runningShell.id))?.status).toBe("cancelled")
      expect((yield* jobs.pendingBackground).find((job) => job.id === runningShell.id)).toBeUndefined()

      yield* post("revert/commit", {}, 204)
      yield* llm.serve(() => TestLLM.text("continued cleanly", "parent_after_revert"))
      yield* post("prompt", { text: "continue-after-undo", resume: false })
      yield* sessions.resume(parent.id)

      const messages = JSON.stringify(yield* sessions.messages({ sessionID: parent.id }))
      expect(messages).toContain("continue-after-undo")
      expect(messages).toContain("continued cleanly")
      expect(messages).not.toContain("Command cancelled")
      expect(messages).not.toContain('state="cancelled"')
      expect(yield* sessions.inbox(parent.id)).toEqual([])
      expect((yield* jobs.pendingBackground).find((job) => job.id === runningShell.id)).toBeUndefined()

      const completionCommand =
        process.platform === "win32"
          ? `New-Item '${completionStarted}' -ItemType File | Out-Null; while (!(Test-Path '${completionRelease}')) { Start-Sleep -Milliseconds 10 }; Write-Output 'obsolete result'`
          : `touch '${completionStarted}'; while [ ! -f '${completionRelease}' ]; do sleep 0.01; done; printf 'obsolete result\n'`
      yield* llm.serve((request) =>
        JSON.stringify(request.messages).includes("call_completing_shell")
          ? TestLLM.text("completion shell launched", "parent_completion_shell_launched")
          : TestLLM.tool("call_completing_shell", "shell", { command: completionCommand, background: true }),
      )
      const completionBoundary = yield* sessions.prompt({
        sessionID: parent.id,
        text: "launch-completing-shell",
        resume: false,
      })
      yield* sessions.resume(parent.id)
      yield* Deferred.await(completionReady).pipe(Effect.timeout("5 seconds"))
      const requestsBeforeUndo = (yield* llm.requests()).length
      const completingShell = (yield* shell.list())[0]
      if (!completingShell) return yield* Effect.die("Expected a completing background shell")
      notificationDelay = "before"
      yield* Effect.promise(() => Bun.write(completionRelease, ""))
      yield* Deferred.await(notificationEntered).pipe(Effect.timeout("5 seconds"))

      yield* post("revert/stage", { messageID: completionBoundary.id })
      yield* post("revert/commit", {}, 204)
      yield* Deferred.succeed(releaseNotification, undefined)
      yield* Deferred.await(notificationFinished)
      expect(yield* sessions.inbox(parent.id)).toEqual([])
      expect(yield* llm.requests()).toHaveLength(requestsBeforeUndo)
      yield* llm.serve(() => TestLLM.text("continued without obsolete output", "parent_after_completion_revert"))
      yield* post("prompt", { text: "continue-after-completion-undo", resume: false })
      yield* sessions.resume(parent.id)

      const finalMessages = JSON.stringify(yield* sessions.messages({ sessionID: parent.id }))
      expect(finalMessages).toContain("continue-after-completion-undo")
      expect(finalMessages).not.toContain("obsolete result")
      expect(yield* sessions.inbox(parent.id)).toEqual([])
      expect((yield* jobs.pendingBackground).find((job) => job.id === completingShell.id)).toBeUndefined()

      notificationDelay = "none"
      const pausedCommand =
        process.platform === "win32"
          ? `New-Item '${pausedStarted}' -ItemType File | Out-Null; while (!(Test-Path '${pausedRelease}')) { Start-Sleep -Milliseconds 10 }; Write-Output 'obsolete paused completion'`
          : `touch '${pausedStarted}'; while [ ! -f '${pausedRelease}' ]; do sleep 0.01; done; printf 'obsolete paused completion\n'`
      yield* llm.serve((request) =>
        JSON.stringify(request.messages).includes("call_paused_shell")
          ? TestLLM.text("paused shell launched", "parent_paused_shell_launched")
          : TestLLM.tool("call_paused_shell", "shell", { command: pausedCommand, background: true }),
      )
      const pausedBoundary = yield* sessions.prompt({
        sessionID: parent.id,
        text: "prepare-paused-completion",
        resume: false,
      })
      yield* sessions.resume(parent.id)
      yield* Deferred.await(pausedReady)
      const pausedShell = (yield* shell.list())[0]
      if (!pausedShell) return yield* Effect.die("Expected paused completion shell")
      yield* bus.project(SessionEvent.InboxEnqueued, (event) => {
        if (event.data.sessionID !== parent.id || event.data.item.type !== "synthetic") return Effect.void
        if (event.data.item.payload.description !== pausedCommand) return Effect.void
        return Deferred.succeed(insideNotificationEntered, undefined).pipe(
          Effect.andThen(Deferred.await(releaseInsideNotification)),
        )
      })
      yield* Effect.promise(() => Bun.write(pausedRelease, ""))
      yield* Deferred.await(insideNotificationEntered)
      const stagedWhilePaused = yield* sessions.revert
        .stage({ sessionID: parent.id, messageID: pausedBoundary.id })
        .pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Effect.yieldNow
      expect(stagedWhilePaused.pollUnsafe()).toBeUndefined()
      yield* Deferred.succeed(releaseInsideNotification, undefined)
      yield* Fiber.join(stagedWhilePaused)
      yield* sessions.wait(parent.id)
      yield* post("revert/commit", {}, 204)
      expect(yield* sessions.inbox(parent.id)).toEqual([])
      expect((yield* jobs.pendingBackground).find((job) => job.id === pausedShell.id)).toBeUndefined()

      expect(JSON.stringify(yield* sessions.messages({ sessionID: parent.id }))).not.toContain(
        "obsolete paused completion",
      )
      expect(yield* sessions.inbox(parent.id)).toEqual([])
    }).pipe(Effect.scoped),
  30_000,
)
