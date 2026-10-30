export * as Navigation from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { SessionScan } from "@opencode/schema/session-scan"
import { Schema } from "effect"

/** A session's Progresso while it shows (rev. 2026-10-30, `docs/progress.md`). */
export interface Progress extends Schema.Schema.Type<typeof Progress> {}
export const Progress = Schema.Struct({
  done: Schema.Int,
  finished: Schema.Int,
  total: Schema.Int,
  current: Schema.String,
  todos: Schema.Array(
    Schema.Struct({
      content: Schema.String,
      status: Schema.Literals(["pending", "in_progress", "completed", "cancelled"]),
    }),
  ),
}).annotate({ identifier: "Navigation.Progress" })

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  session: Schema.toEncoded(SessionScan.Info.fields.session),
  messageAt: SessionScan.Info.fields.messageAt,
  unreadAt: Schema.Finite.pipe(Schema.optional),
  permissionAt: Schema.Finite.pipe(Schema.optional),
  questionAt: Schema.Finite.pipe(Schema.optional),
  permissionCount: Schema.Int.pipe(Schema.optional),
  questionCount: Schema.Int.pipe(Schema.optional),
  /** Background work other than subagents (shell commands) still running for this session. */
  backgroundCount: Schema.Int.pipe(Schema.optional),
  /** The title (a shell's command) of the newest such work. */
  backgroundTitle: Schema.String.pipe(Schema.optional),
  progress: Progress.pipe(Schema.optional),
}).annotate({ identifier: "Navigation.Info" })

export interface Page extends Schema.Schema.Type<typeof Page> {}
export const Page = Schema.Struct({
  data: Schema.Array(Info),
  next: SessionScan.Page.fields.next,
}).annotate({ identifier: "Navigation.Page" })

export const Definition = Rpc.define({
  id: "custom.navigation",
  methods: {
    list: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({
          after: SessionScan.Input.fields.after,
          limit: SessionScan.Input.fields.limit,
          sessionID: SessionScan.Input.fields.sessionID,
        }),
      ),
      output: Schema.toStandardSchemaV1(Page),
    },
  },
  events: {},
})
