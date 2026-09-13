import { expect } from "bun:test"
import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { $ } from "bun"
import { Bus } from "@opencode/core/bus"
import { Database } from "@opencode/core/database/database"
import { LocationServiceMap } from "@opencode/core/location-service-map"
import { Session } from "@opencode/core/session"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionInbox } from "@opencode/core/session/inbox"
import { Snapshot } from "@opencode/core/snapshot"
import { Agent } from "@opencode/core/agent"
import { Location } from "@opencode/schema/location"
import { Money } from "@opencode/schema/money"
import { Model } from "@opencode/schema/model"
import { Provider } from "@opencode/schema/provider"
import { AbsolutePath } from "@opencode/schema/schema"
import { SessionMessage } from "@opencode/schema/session-message"
import { Global } from "@opencode/util/global"
import { Context, Effect, Layer } from "effect"
import { HttpServer } from "effect/unstable/http"
import { tempGlobalLayer } from "../../core/test/fixture/global"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"

it.live(
  "oracle restores globally earliest snapshots for crossed overlapping files",
  () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const directory = path.join(tmp.path, "project")
      const first = path.join(directory, "first.txt")
      const second = path.join(directory, "second.txt")
      const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
      const pluginPackage = path.join(tmp.path, "plugin")
      yield* Effect.promise(async () => {
        await fs.mkdir(directory)
        await fs.mkdir(pluginPackage)
        await fs.writeFile(
          path.join(pluginPackage, "package.json"),
          JSON.stringify({ type: "module", exports: "./index.ts" }),
        )
        await fs.writeFile(path.join(pluginPackage, "index.ts"), `export { default } from ${JSON.stringify(plugin)}\n`)
        await $`git init -q`.cwd(directory).quiet()
        await Promise.all([Bun.write(first, "base\n"), Bun.write(second, "base\n")])
        await $`git -c core.fsmonitor=false add .`.cwd(directory).quiet()
      })
      const context = yield* Layer.build(
        createEmbeddedRoutes(
          {
            database: { path: ":memory:" },
            models: { fetch: false },
            fs: { filewatcher: false, fff: false },
            config: { project: false, content: JSON.stringify({ plugins: [pluginPackage] }) },
          },
          [Global.node.replace(tempGlobalLayer)],
        ).pipe(Layer.provide(HttpServer.layerServices)),
      )
      const sessions = Context.get(context, Session.Service)
      const database = Context.get(context, Database.Service)
      const bus = Context.get(context, Bus.Service)
      const locations = Context.get(context, LocationServiceMap.Service)
      const parent = yield* sessions.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(directory) }),
      })
      const child = yield* sessions.create({ parentID: parent.id })
      const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "delegate edit", resume: false })
      yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
      yield* sessions.prompt({
        sessionID: child.id,
        text: "edit file",
        resume: false,
        causal: { parentSessionID: parent.id, messageID: boundary.id, toolCallID: "edit" },
      })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      yield* recordEdit(child, first, "child first\n")
      yield* recordEdit(parent, second, "parent second\n")
      yield* recordEdit(child, second, "child second\n")
      yield* recordEdit(parent, first, "parent first\n")

      yield* sessions.revert.stage({ sessionID: parent.id, messageID: boundary.id })

      expect({
        first: yield* Effect.promise(() => Bun.file(first).text()),
        second: yield* Effect.promise(() => Bun.file(second).text()),
      }).toEqual({ first: "base\n", second: "base\n" })

      function recordEdit(session: Session.Info, file: string, content: string) {
        return Effect.gen(function* () {
          const snapshot = yield* Snapshot.Service
          const before = yield* snapshot.capture()
          if (!before) return yield* Effect.die("Expected start snapshot")
          const assistantMessageID = SessionMessage.ID.create()
          yield* bus.publish(SessionEvent.Step.Started, {
            sessionID: session.id,
            assistantMessageID,
            agent: Agent.defaultID,
            model: { id: Model.ID.make("fixture"), providerID: Provider.ID.make("fixture") },
            snapshot: before,
          })
          yield* Effect.promise(() => Bun.write(file, content))
          const after = yield* snapshot.capture()
          if (!after) return yield* Effect.die("Expected end snapshot")
          yield* bus.publish(SessionEvent.Step.Ended, {
            sessionID: session.id,
            assistantMessageID,
            finish: "stop",
            cost: Money.USD.zero,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            snapshot: after,
            files: yield* snapshot.files({ from: before, to: after }),
          })
        }).pipe(Effect.provide(locations.get(session.location)))
      }
    }).pipe(Effect.scoped),
  { timeout: 15_000 },
)
