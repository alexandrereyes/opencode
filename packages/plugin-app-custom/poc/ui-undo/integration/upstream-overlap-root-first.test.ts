import { expect } from "bun:test"
import fs from "node:fs/promises"
import path from "node:path"
import { $ } from "bun"
import { OpenCode } from "@opencode/client"
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
import { HttpEffect, HttpRouter, HttpServer } from "effect/unstable/http"
import { PublicApiUndo, type Storage } from "./.poc-ui-undo-runtime/index"
import { tempGlobalLayer } from "../../core/test/fixture/global"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"

it.live(
  "root-first public orchestration still cannot reproduce crossed overlapping snapshots",
  () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      const directory = path.join(tmp.path, "project")
      const first = path.join(directory, "first.txt")
      const second = path.join(directory, "second.txt")
      yield* Effect.promise(async () => {
        await fs.mkdir(directory)
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
            config: { project: false, content: JSON.stringify({ plugins: [] }) },
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
      const childInput = yield* sessions.prompt({ sessionID: child.id, text: "edit file", resume: false })
      yield* SessionInbox.promote(database.db, bus, child.id, "steer")
      yield* recordEdit(child, first, "child first\n")
      yield* recordEdit(parent, second, "parent second\n")
      yield* recordEdit(child, second, "child second\n")
      yield* recordEdit(parent, first, "parent first\n")

      const handler = Context.get(context, HttpRouter.HttpRouter)
        .asHttpEffect()
        .pipe(HttpEffect.toWebHandlerWith(context))
      const localFetch: typeof fetch = Object.assign(
        (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => handler(new Request(input, init)),
        { preconnect: fetch.preconnect },
      )
      const values = new Map<string, unknown>()
      const storage: Storage = {
        get: async (key) => values.get(key),
        set: async (key, value) => void values.set(key, value),
        remove: async (key) => void values.delete(key),
        scan: async ({ prefix }) => ({
          entries: [...values].filter(([key]) => key.startsWith(prefix)).map(([key, value]) => ({ key, value })),
        }),
      }
      const undo = new PublicApiUndo(OpenCode.make({ baseUrl: "http://opencode.local", fetch: localFetch }), storage, {
        stageOrder: "root-first",
      })
      yield* Effect.promise(() =>
        undo.recordProvenance({
          childSessionID: child.id,
          inputID: childInput.id,
          assignedSeq: 0,
          origin: { parentSessionID: parent.id, parentMessageID: boundary.id, toolCallID: "edit" },
        }),
      )
      yield* Effect.promise(() => undo.stage({ rootSessionID: parent.id, rootMessageID: boundary.id }))

      expect({
        first: yield* Effect.promise(() => Bun.file(first).text()),
        second: yield* Effect.promise(() => Bun.file(second).text()),
      }).toEqual({ first: "base\n", second: "parent second\n" })

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
