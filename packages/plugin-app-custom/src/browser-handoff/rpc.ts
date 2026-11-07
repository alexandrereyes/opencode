export * as BrowserHandoffs from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

/** Contract: `packages/plugin-app-custom/docs/browser-handoff.md`. Times are epoch milliseconds. */

/** A browse `execute` call that has been waiting on Alexandre in the browser for at least the grace period. */
export interface Handoff extends Schema.Schema.Type<typeof Handoff> {}
export const Handoff = Schema.Struct({
  id: Schema.String,
  /** The session that runs the call: the top-level session or one of its subagents. */
  sessionID: Schema.String,
  /** The tool part that waits: Code Mode's `execute`, or browse's own call when it is a direct tool. */
  callID: Schema.String,
  messageID: Schema.String,
  /** What the agent asked for (`handoff("…")`), at most 120 characters, or a default when it passed no text. */
  message: Schema.String,
  /** When the call started. */
  since: Schema.Number,
}).annotate({ identifier: "BrowserHandoffs.Handoff" })

export const ListOutput = Schema.Struct({ data: Schema.Array(Handoff) })

export const Definition = Rpc.define({
  id: "custom.browser-handoffs",
  methods: {
    list: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: optional(Schema.String) })),
      output: Schema.toStandardSchemaV1(ListOutput),
    },
  },
  events: {
    /** A handoff of the session started waiting (after the grace period) or ended. */
    changed: { schema: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Schema.String })) },
  },
})
