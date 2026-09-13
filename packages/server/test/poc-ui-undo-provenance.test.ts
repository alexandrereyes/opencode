import { expect } from "bun:test"
import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { OpenCode } from "@opencode/client"
import { Bus } from "@opencode/core/bus"
import { Database } from "@opencode/core/database/database"
import { Session } from "@opencode/core/session"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionInbox } from "@opencode/core/session/inbox"
import { Agent } from "@opencode/core/agent"
import { Location } from "@opencode/schema/location"
import { Model } from "@opencode/schema/model"
import { Money } from "@opencode/schema/money"
import { Provider } from "@opencode/schema/provider"
import { AbsolutePath } from "@opencode/schema/schema"
import { SessionMessage } from "@opencode/schema/session-message"
import { Global } from "@opencode/util/global"
import { Context, Effect, Layer } from "effect"
import { HttpEffect, HttpRouter, HttpServer } from "effect/unstable/http"
import { PublicApiUndo, type Storage } from "../../plugin-app-custom/poc/ui-undo/index"
import { tempGlobalLayer } from "../../core/test/fixture/global"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { createEmbeddedRoutes } from "../src/routes"

it.live("migrates exact causal provenance through the public session log", () =>
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
    const context = yield* Layer.build(
      createEmbeddedRoutes(
        {
          database: { path: ":memory:" },
          events: { persist: true },
          models: { fetch: false },
          fs: { filewatcher: false, fff: false },
          config: { project: false, content: JSON.stringify({ snapshots: false, plugins: [pluginPackage] }) },
        },
        [Global.node.replace(tempGlobalLayer)],
      ).pipe(Layer.provide(HttpServer.layerServices)),
    )
    const sessions = Context.get(context, Session.Service)
    const database = Context.get(context, Database.Service)
    const bus = Context.get(context, Bus.Service)
    const parent = yield* sessions.create({
      location: Location.Ref.make({ directory: AbsolutePath.make(directory.path) }),
    })
    const child = yield* sessions.create({ parentID: parent.id })
    const boundary = yield* sessions.prompt({ sessionID: parent.id, text: "boundary", resume: false })
    yield* SessionInbox.promote(database.db, bus, parent.id, "steer")
    const originMessageID = SessionMessage.ID.create()
    yield* bus.publish(SessionEvent.Step.Started, {
      sessionID: parent.id,
      assistantMessageID: originMessageID,
      agent: Agent.defaultID,
      model: { providerID: Provider.ID.make("fixture"), id: Model.ID.make("fixture") },
    })
    yield* bus.publish(SessionEvent.Step.Ended, {
      sessionID: parent.id,
      assistantMessageID: originMessageID,
      finish: "stop",
      cost: Money.USD.zero,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    })
    const childInput = yield* sessions.prompt({
      sessionID: child.id,
      text: "child input",
      resume: false,
      causal: { parentSessionID: parent.id, messageID: originMessageID, toolCallID: "call" },
    })
    yield* SessionInbox.promote(database.db, bus, child.id, "steer")

    const handler = Context.get(context, HttpRouter.HttpRouter)
      .asHttpEffect()
      .pipe(HttpEffect.toWebHandlerWith(context))
    const localFetch: typeof fetch = Object.assign(
      (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => handler(new Request(input, init)),
      { preconnect: fetch.preconnect },
    )
    const client = OpenCode.make({
      baseUrl: "http://opencode.local",
      fetch: localFetch,
    })
    const values = new Map<string, unknown>()
    const storage: Storage = {
      get: async (key) => values.get(key),
      set: async (key, value) => void values.set(key, value),
      remove: async (key) => void values.delete(key),
      scan: async ({ prefix }) => ({
        entries: [...values].filter(([key]) => key.startsWith(prefix)).map(([key, value]) => ({ key, value })),
      }),
    }
    const undo = new PublicApiUndo(client, storage)
    yield* Effect.promise(() => undo.migrateProvenance(parent.id, { assignmentEvents: true }))
    const plan = yield* Effect.promise(() => undo.plan({ rootSessionID: parent.id, rootMessageID: boundary.id }))

    expect(plan.participants).toEqual([
      { sessionID: child.id, messageID: childInput.id, pendingIDs: [], files: true, depth: 1 },
    ])
    yield* Effect.promise(() =>
      client.session.revert.stage({ sessionID: parent.id, messageID: boundary.id, files: false }),
    )
    expect((yield* sessions.get(child.id)).revert).toBeDefined()
    const observation = yield* Effect.sync(() => {
      const controller = new AbortController()
      const ready = Promise.withResolvers<void>()
      const result = (async () => {
        const order: string[] = []
        for await (const event of client.event.subscribe({ signal: controller.signal })) {
          if (event.type === "server.connected") {
            ready.resolve()
            continue
          }
          if (!("data" in event) || !("sessionID" in event.data) || event.data.sessionID !== parent.id) continue
          if (event.type !== "session.revert.committed" && event.type !== "session.inbox.enqueued") continue
          order.push(event.type)
          if (order.length === 2) {
            controller.abort()
            return order
          }
        }
        throw new Error("Oracle event stream ended early")
      })()
      return { ready: ready.promise, result }
    })
    yield* Effect.promise(() => observation.ready).pipe(Effect.timeout("5 seconds"))
    yield* Effect.promise(() =>
      client.session.synthetic({ sessionID: parent.id, text: "external synthetic", resume: false }),
    )
    const order = yield* Effect.promise(() => observation.result).pipe(Effect.timeout("5 seconds"))
    expect((yield* sessions.get(parent.id)).revert).toBeUndefined()
    expect((yield* sessions.get(child.id)).revert).toBeUndefined()
    expect(order).toEqual(["session.revert.committed", "session.inbox.enqueued"])
  }).pipe(Effect.scoped),
)

it.live("default server log does not replay durable history for migration", () =>
  Effect.gen(function* () {
    const directory = yield* tmpdirScoped()
    const context = yield* Layer.build(
      createEmbeddedRoutes(
        {
          database: { path: ":memory:" },
          models: { fetch: false },
          fs: { filewatcher: false, fff: false },
          config: { project: false, content: JSON.stringify({ snapshots: false, plugins: [] }) },
        },
        [Global.node.replace(tempGlobalLayer)],
      ).pipe(Layer.provide(HttpServer.layerServices)),
    )
    const session = yield* Context.get(context, Session.Service).create({
      location: Location.Ref.make({ directory: AbsolutePath.make(directory.path) }),
    })
    const handler = Context.get(context, HttpRouter.HttpRouter)
      .asHttpEffect()
      .pipe(HttpEffect.toWebHandlerWith(context))
    const localFetch: typeof fetch = Object.assign(
      (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => handler(new Request(input, init)),
      { preconnect: fetch.preconnect },
    )
    const client = OpenCode.make({ baseUrl: "http://opencode.local", fetch: localFetch })
    const items = yield* Effect.promise(async () => {
      const result = []
      for await (const item of client.session.log({ sessionID: session.id, follow: false })) result.push(item)
      return result
    })

    expect(items).toEqual([{ type: "log.synced", aggregateID: session.id, seq: 0 }])
  }).pipe(Effect.scoped),
)
