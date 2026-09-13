import { OpenCode } from "@opencode/client"
import { Plugin } from "@opencode/plugin"
import { Schema } from "effect"
import { LegacyAssignment, PublicApiUndo } from "./index.js"
import { UiUndoRpc } from "./rpc.js"

const Options = Schema.Struct({ baseUrl: Schema.String, password: Schema.String })
const RecordInput = Schema.Struct({
  childSessionID: Schema.String,
  inputID: Schema.String,
  assignedSeq: Schema.Number,
  origin: Schema.Struct({
    parentSessionID: Schema.String,
    parentMessageID: Schema.String,
    toolCallID: Schema.String,
  }),
})
const StageInput = Schema.Struct({ rootSessionID: Schema.String, rootMessageID: Schema.String })
const RootInput = Schema.Struct({ rootSessionID: Schema.String })
const LegacyInput = Schema.Struct({ rows: Schema.Array(LegacyAssignment) })
const SubagentResult = Schema.Struct({ metadata: Schema.Struct({ sessionID: Schema.String }) })
const LateSubagentNotification = Schema.Struct({
  type: Schema.Literal("session.inbox.enqueued"),
  data: Schema.Struct({
    sessionID: Schema.String,
    inboxID: Schema.String,
    item: Schema.Struct({
      type: Schema.Literal("synthetic"),
      payload: Schema.Struct({
        metadata: Schema.Struct({
          source: Schema.Literal("subagent"),
          childID: Schema.String,
        }),
      }),
    }),
  }),
})

/** Experimental only: not exported or registered by the production package. */
export default Plugin.define({
  id: "poc.ui-undo",
  async setup(ctx) {
    const options = Schema.decodeUnknownSync(Options)(ctx.options)
    const undo = new PublicApiUndo(
      OpenCode.make({
        baseUrl: options.baseUrl,
        headers: { authorization: `Basic ${btoa(`opencode:${options.password}`)}` },
      }),
      ctx.storage,
    )
    const staging = new Map<string, Promise<unknown>>()
    await ctx.session.hook("prompt", async (event) => {
      await ctx.storage.set(`ui-undo/capture/input/${event.sessionID}/${event.messageID}`, {
        kind: "input",
        sessionID: event.sessionID,
        inputID: event.messageID,
      })
      await undo.commitForMember(event.sessionID, { nativeWillCommit: true })
    })
    const registration = await ctx.rpc.register(UiUndoRpc, {
      record: async (input) => {
        await undo.recordProvenance(Schema.decodeUnknownSync(RecordInput)(input))
        return true
      },
      importLegacy: async (input) => undo.importLegacy(Schema.decodeUnknownSync(LegacyInput)(input).rows),
      stage: async (input) => {
        const decoded = Schema.decodeUnknownSync(StageInput)(input)
        const pending = undo.stage(decoded)
        staging.set(decoded.rootSessionID, pending)
        try {
          return { phase: (await pending).phase }
        } finally {
          if (staging.get(decoded.rootSessionID) === pending) staging.delete(decoded.rootSessionID)
        }
      },
      redo: async (input) => {
        await undo.redo(Schema.decodeUnknownSync(RootInput)(input).rootSessionID)
        return true
      },
    })
    await ctx.tool.hook("execute.after", async (event) => {
      if (event.tool !== "subagent" || event.status !== "completed" || !Schema.is(SubagentResult)(event.result)) return
      await ctx.storage.set(`ui-undo/capture/origin/${event.sessionID}/${event.messageID}/${event.id}`, {
        kind: "origin",
        parentSessionID: event.sessionID,
        parentMessageID: event.messageID,
        toolCallID: event.id,
        childSessionID: event.result.metadata.sessionID,
      })
    })
    const controller = new AbortController()
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        if (event.type !== "session.inbox.enqueued") continue
        if (Schema.is(LateSubagentNotification)(event)) {
          const cancelled = await undo
            .cancelLateSubagentNotification({
              sessionID: event.data.sessionID,
              inboxID: event.data.inboxID,
              childSessionID: event.data.item.payload.metadata.childID,
            })
            .catch(() => false)
          if (cancelled) {
            await registration.events.emit("lateCancellation", {
              sessionID: event.data.sessionID,
              inboxID: event.data.inboxID,
              outcome: "cancelled",
            })
            continue
          }
          await staging.get(event.data.sessionID)?.catch(() => {})
          await undo.commitForMember(event.data.sessionID)
          await registration.events.emit("lateCancellation", {
            sessionID: event.data.sessionID,
            inboxID: event.data.inboxID,
            outcome: "too-late",
          })
          continue
        }
        await undo.commitForMember(event.data.sessionID)
      }
    })().catch((error: unknown) => {
      if (!controller.signal.aborted) console.error(error)
    })
    return () => controller.abort()
  },
})
