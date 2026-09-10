import { describe, expect } from "bun:test"
import { Effect, Layer, Schema } from "effect"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { makeLocationNode } from "@opencode/util/effect/app-node"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Global } from "@opencode/util/global"
import { Database } from "@opencode/core/database/database"
import { Bus } from "@opencode/core/bus"
import { Location } from "@opencode/core/location"
import { Project } from "@opencode/core/project"
import { AbsolutePath } from "@opencode/core/schema"
import { Session } from "@opencode/core/session"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionExecution } from "@opencode/core/session/execution"
import { SessionMessage } from "@opencode/core/session/message"
import { SessionProjector } from "@opencode/core/session/projector"
import { SessionStore } from "@opencode/core/session/store"
import { OpenCodeTools } from "@opencode/core/tool/plugin/opencode"
import { Tool } from "@opencode/core/tool"
import { location } from "./fixture/location"
import { tempGlobalLayer } from "./fixture/global"
import { offlineModels } from "./fixture/models"
import { tmpdirScoped } from "./fixture/tmpdir"
import { testEffect } from "./lib/effect"
import { executeTool, registerToolPlugin, toolIdentity, waitForCodeModeTool } from "./lib/tool"

const CodeModeOutput = Schema.Struct({ output: Schema.String })
const decodeReadOutput = (value: unknown) =>
  Schema.decodeUnknownSync(Schema.fromJsonString(OpenCodeTools.ReadOutput))(
    Schema.decodeUnknownSync(CodeModeOutput)(value).output,
  )

const openCodeToolNode = makeLocationNode({
  name: "test/opencode-tool-plugin",
  layer: Layer.effectDiscard(registerToolPlugin(OpenCodeTools.Plugin)),
  deps: [Tool.node, Session.node],
})

const nodes = LayerNode.group([
  Database.node,
  Bus.node,
  Project.node,
  SessionProjector.node,
  SessionStore.node,
  Session.node,
  Tool.node,
  openCodeToolNode,
])

const withTools = (directory: string) =>
  AppNodeBuilder.build(nodes, [
    Global.node.replace(tempGlobalLayer),
    Bus.node.replace(Bus.configured({ persist: true })),
    SessionExecution.node.replace(SessionExecution.noopLayer),
    Location.node.replace(
      Layer.succeed(Location.Service, Location.Service.of(location({ directory: AbsolutePath.make(directory) }))),
    ),
    offlineModels,
  ])

describe("OpenCode session read tool", () => {
  testEffect(Layer.empty).live("reads bounded pages through the real registry and session services", () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped()
      yield* Effect.gen(function* () {
        const sessions = yield* Session.Service
        const bus = yield* Bus.Service
        const referenced = yield* sessions.create({
          location: Location.Ref.make({ directory: AbsolutePath.make(tmp.path) }),
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
          session: { id: referenced.id, title: "Referenced work", directory: tmp.path },
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
          location: Location.Ref.make({ directory: AbsolutePath.make(tmp.path) }),
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
          session: { id: untitled.id, directory: AbsolutePath.make(tmp.path) },
          messages: [{ id: untitledMessageID, type: "user", text: "untitled" }],
        })
      }).pipe(Effect.provide(withTools(tmp.path)))
    }),
  )
})
