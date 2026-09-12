import path from "node:path"
import { describe, expect } from "bun:test"
import { Effect, Schema } from "effect"
import { AbsolutePath } from "@opencode/core/schema"
import { Agent } from "@opencode/core/agent"
import { Bus } from "@opencode/core/bus"
import { Location } from "@opencode/core/location"
import { Plugin } from "@opencode/core/plugin"
import { PluginHost } from "@opencode/core/plugin/host"
import { PluginModule } from "@opencode/core/plugin/module"
import { Session } from "@opencode/core/session"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionMessage } from "@opencode/core/session/message"
import { Tool } from "@opencode/core/tool"
import { OpenCodeTools } from "@opencode/core/tool/plugin/opencode"
import { Watcher } from "@opencode/core/filesystem/watcher"
import { fromPromise } from "@opencode/plugin/promise/adapter"
import { MessagePage } from "@opencode/plugin/message"
import { Model } from "@opencode/schema/model"
import { Money } from "@opencode/schema/money"
import { Provider } from "@opencode/schema/provider"
import { ReadOutput } from "../../plugin-app-custom/src/session-read"
import { testEffect } from "./lib/effect"
import { codeModeListings, executeTool, toolIdentity, waitForCodeModeTool } from "./lib/tool"
import { tmpdirScoped } from "./fixture/tmpdir"
import { OfflinePluginTestLayer } from "./plugin/fixture"

const CodeModeOutput = Schema.Struct({ output: Schema.String })
const decodeReadOutput = (value: unknown) =>
  Schema.decodeUnknownSync(Schema.fromJsonString(ReadOutput))(Schema.decodeUnknownSync(CodeModeOutput)(value).output)

const it = testEffect(OfflinePluginTestLayer)

describe("custom session read tool", () => {
  it.live("loads, reads durable cross-project pages, and unloads through the plugin registry", () =>
    Effect.gen(function* () {
      const plugins = yield* Plugin.Service
      const modules = yield* PluginModule.make().pipe(Effect.provide(Watcher.testLayer))
      const custom = yield* modules.load({
        type: "add",
        target: path.join(import.meta.dir, "../../plugin-app-custom/src/index.ts"),
        options: {},
      })
      if ("pending" in custom) throw new Error("Custom plugin was not loaded")
      const builtIn = { id: OpenCodeTools.Plugin.id, revision: "test", effect: OpenCodeTools.Plugin.effect }
      yield* plugins.activate([builtIn, custom])

      const tmp = yield* tmpdirScoped()
      const foreign = yield* tmpdirScoped()
      const sessions = yield* Session.Service
      const bus = yield* Bus.Service
      const referenced = yield* sessions.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(foreign.path) }),
        title: "Referenced work",
      })
      const caller = yield* sessions.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(tmp.path) }),
        title: "Caller",
      })
      for (const text of ["first", "second", "third"]) {
        const id = SessionMessage.ID.create()
        yield* sessions.prompt({ sessionID: referenced.id, id, text, resume: false })
        yield* bus.publish(SessionEvent.InboxDelivered, { sessionID: referenced.id, inboxID: id })
      }
      const expectedIDs = (yield* sessions.messages({ sessionID: referenced.id, order: "desc", limit: 2 })).map(
        (message) => message.id,
      )
      const host = yield* PluginHost.make(plugins)
      expect((yield* host.message.list({ sessionID: referenced.id, limit: 2 })).data.map((message) => message.id)).toEqual(
        expectedIDs,
      )
      expect(yield* host.message.list({ sessionID: referenced.id, cursor: "invalid" }).pipe(Effect.flip)).toBe(
        "Invalid cursor",
      )
      const boundary = expectedIDs[0]
      if (!boundary) yield* Effect.die("Expected a message boundary")
      const cursor = MessagePage.Cursor.make({ id: boundary, order: "desc", direction: "next" })
      expect(yield* host.message.list({ sessionID: referenced.id, cursor, order: "desc" }).pipe(Effect.flip)).toMatchObject(
        { message: "Cursor cannot be combined with order" },
      )
      const missingCursor = MessagePage.Cursor.make({
        id: SessionMessage.ID.make("msg_missing"),
        order: "desc",
        direction: "next",
      })
      expect(yield* host.message.list({ sessionID: referenced.id, cursor: missingCursor })).toEqual({
        data: [],
        cursor: { previous: undefined, next: undefined },
      })
      const promise = fromPromise({
        id: "test.promise-message-list",
        setup: async (ctx) => {
          const page = await ctx.message.list({ sessionID: referenced.id, limit: 2 })
          expect(page.data.map((message) => message.id)).toEqual(expectedIDs)
          expect(await ctx.message.list({ sessionID: referenced.id, cursor: missingCursor })).toEqual({
            data: [],
            cursor: {},
          })
        },
      })
      yield* plugins.activate([builtIn, custom, { id: promise.id, revision: "test", effect: promise.effect }])

      const registry = yield* Tool.Service
      yield* waitForCodeModeTool(registry, "opencode.session_read")
      const first = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-1",
          name: "execute",
          input: { code: `return await tools.opencode.session_read({ sessionID: "${referenced.id}", limit: 2 })` },
        },
      })
      expect(first.status).toBe("completed")
      const firstPage = decodeReadOutput(first.output)
      expect(firstPage).toMatchObject({
        session: { id: referenced.id, title: "Referenced work", directory: foreign.path },
        messages: [
          { type: "user", text: "third" },
          { type: "user", text: "second" },
        ],
      })
      const next = firstPage.next
      expect(next).toBeString()

      const second = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-2",
          name: "execute",
          input: {
            code: `return await tools.opencode.session_read({ sessionID: "${referenced.id}", limit: 2, cursor: "${next}" })`,
          },
        },
      })
      const secondPage = decodeReadOutput(second.output)
      expect(secondPage).toMatchObject({ messages: [{ type: "user", text: "first" }] })
      expect(secondPage.next).toBeUndefined()

      const assistantID = SessionMessage.ID.create()
      yield* bus.publish(SessionEvent.Step.Started, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        agent: Agent.ID.make("build"),
        model: { providerID: Provider.ID.make("test"), id: Model.ID.make("test") },
      })
      yield* bus.publish(SessionEvent.Reasoning.Started, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        ordinal: 0,
      })
      yield* bus.publish(SessionEvent.Reasoning.Ended, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        ordinal: 0,
        text: "private reasoning",
      })
      yield* bus.publish(SessionEvent.Tool.Input.Started, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        id: "tool-1",
        name: "read",
      })
      yield* bus.publish(SessionEvent.Tool.Input.Ended, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        id: "tool-1",
        text: '{"filePath":"secret"}',
      })
      yield* bus.publish(SessionEvent.Tool.Called, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        id: "tool-1",
        input: { filePath: "secret" },
        executed: false,
      })
      yield* bus.publish(SessionEvent.Tool.Success, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        id: "tool-1",
        content: [{ type: "text", text: "private tool output" }],
        executed: false,
      })
      yield* bus.publish(SessionEvent.Text.Started, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        ordinal: 2,
      })
      yield* bus.publish(SessionEvent.Text.Ended, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        ordinal: 2,
        text: "public answer",
      })
      yield* bus.publish(SessionEvent.Step.Ended, {
        sessionID: referenced.id,
        assistantMessageID: assistantID,
        finish: "stop",
        cost: Money.USD.make(0),
        tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      })
      const filtered = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-filtered",
          name: "execute",
          input: { code: `return await tools.opencode.session_read({ sessionID: "${referenced.id}", limit: 1 })` },
        },
      })
      expect(decodeReadOutput(filtered.output).messages).toEqual([
        { id: assistantID, type: "assistant", text: "[tool read: completed]\npublic answer" },
      ])

      const largeID = SessionMessage.ID.create()
      yield* sessions.prompt({ sessionID: referenced.id, id: largeID, text: "x".repeat(25_000), resume: false })
      yield* bus.publish(SessionEvent.InboxDelivered, { sessionID: referenced.id, inboxID: largeID })
      const bounded = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-bounded",
          name: "execute",
          input: { code: `return await tools.opencode.session_read({ sessionID: "${referenced.id}", limit: 1 })` },
        },
      })
      const boundedPage = decodeReadOutput(bounded.output)
      expect(boundedPage.messages[0]).toMatchObject({ truncated: true })
      expect(boundedPage.messages[0]?.text).toHaveLength(20_000)
      expect(boundedPage.next).toBe(largeID)

      const missing = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-missing",
          name: "execute",
          input: {
            code: 'return await tools.opencode.session_read({ sessionID: "ses_missing_12345678901234567890" })',
          },
        },
      })
      expect(missing).toMatchObject({
        status: "completed",
        output: {
          error: true,
          output: "Unable to read session ses_missing_12345678901234567890",
          toolCalls: [{ tool: "opencode.session_read", status: "error" }],
        },
      })

      const untitled = yield* sessions.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(foreign.path) }),
      })
      const untitledMessageID = SessionMessage.ID.create()
      yield* sessions.prompt({ sessionID: untitled.id, id: untitledMessageID, text: "untitled", resume: false })
      yield* bus.publish(SessionEvent.InboxDelivered, { sessionID: untitled.id, inboxID: untitledMessageID })
      const untitledResult = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-untitled",
          name: "execute",
          input: { code: `return await tools.opencode.session_read({ sessionID: "${untitled.id}" })` },
        },
      })
      expect(decodeReadOutput(untitledResult.output)).toEqual({
        session: { id: untitled.id, directory: AbsolutePath.make(foreign.path) },
        messages: [{ id: untitledMessageID, type: "user", text: "untitled" }],
      })

      const defaults = yield* sessions.create({
        location: Location.Ref.make({ directory: AbsolutePath.make(foreign.path) }),
      })
      yield* Effect.forEach(
        Array.from({ length: 21 }, (_, index) => `message ${index}`),
        (text) =>
          Effect.gen(function* () {
            const id = SessionMessage.ID.create()
            yield* sessions.prompt({ sessionID: defaults.id, id, text, resume: false })
            yield* bus.publish(SessionEvent.InboxDelivered, { sessionID: defaults.id, inboxID: id })
          }),
      )
      const defaultResult = yield* executeTool(registry, {
        sessionID: caller.id,
        ...toolIdentity,
        call: {
          type: "tool-call",
          id: "call-session-read-default",
          name: "execute",
          input: { code: `return await tools.opencode.session_read({ sessionID: "${defaults.id}" })` },
        },
      })
      const defaultPage = decodeReadOutput(defaultResult.output)
      expect(defaultPage.messages).toHaveLength(20)
      expect(defaultPage.next).toBeDefined()

      expect((yield* plugins.list()).find((item) => item.id === "custom.app-mentions")?.state.status).toBe("active")
      yield* plugins.activate([builtIn])
      const snapshot = yield* registry.snapshot()
      const paths = snapshot.codeModeCatalog
        ? codeModeListings(snapshot.codeModeCatalog).map((entry) => entry.path)
        : []
      expect(paths).toContain("opencode.session_rename")
      expect(paths).toContain("opencode.session_move")
      expect(paths).not.toContain("opencode.session_read")
    }),
  )
})
