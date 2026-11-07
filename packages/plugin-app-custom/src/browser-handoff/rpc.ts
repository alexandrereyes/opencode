export * as BrowserHandoffs from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

/**
 * Contract: `packages/plugin-app-custom/docs/browser-handoff.md`; finishing a handoff from the apps:
 * `docs/browse-handoff-remoto.md`. Times are epoch milliseconds.
 */

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
  /**
   * rev. 2026-11-07 (`browse-handoff-remoto.md`): the `custom.resources` resource (`chrome:browse:<browse session>`)
   * that shows this handoff's tab and takes Alexandre's input while it waits. Absent when the call names no browse
   * session, the relay cannot be reached, and on older servers: then the apps offer no way to finish it remotely.
   */
  resourceID: optional(Schema.String),
}).annotate({ identifier: "BrowserHandoffs.Handoff" })

/**
 * How a handoff stopped waiting: `completed` (the call returned after Continue), `timeout` (browse gave up waiting),
 * `cancelled` (the call or its session was interrupted, deleted or archived) or `failed` (the call failed otherwise).
 */
export const Outcome = Schema.Literals(["completed", "timeout", "cancelled", "failed"]).annotate({
  identifier: "BrowserHandoffs.Outcome",
})
export type Outcome = typeof Outcome.Type

export interface Ended extends Schema.Schema.Type<typeof Ended> {}
export const Ended = Schema.Struct({
  id: Schema.String,
  resourceID: optional(Schema.String),
  outcome: Outcome,
}).annotate({ identifier: "BrowserHandoffs.Ended" })

export interface Changed extends Schema.Schema.Type<typeof Changed> {}
export const Changed = Schema.Struct({
  sessionID: Schema.String,
  /** rev. 2026-11-07: present when a waiting handoff of the session ended; absent when one started waiting. */
  ended: optional(Ended),
}).annotate({ identifier: "BrowserHandoffs.Changed" })

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
    changed: { schema: Schema.toStandardSchemaV1(Changed) },
  },
})
