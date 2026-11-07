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
  /**
   * rev. 2026-11-07 (`docs/browser-handoff.md`): browse calls of this session waiting on Alexandre in the browser;
   * when the newest started, how many, and the newest one's message.
   */
  browserAt: Schema.Finite.pipe(Schema.optional),
  browserCount: Schema.Int.pipe(Schema.optional),
  browserText: Schema.String.pipe(Schema.optional),
  /**
   * Background work other than subagents (shell commands) still running for this session that someone waits on: the
   * session is top-level or still executes, so its end wakes a turn that reaches Alexandre. It keeps the family working.
   */
  backgroundCount: Schema.Int.pipe(Schema.optional),
  /** The title (a shell's command) of the newest such work. */
  backgroundTitle: Schema.String.pipe(Schema.optional),
  /**
   * Shells a subagent left running after its turn ended (an emulator, a dev server): nobody waits on them, so they
   * never keep the family working (rev. 2026-11-06). Absent on older servers, which counted them in `backgroundCount`.
   */
  detachedCount: Schema.Int.pipe(Schema.optional),
  /** The command of the newest such shell. */
  detachedTitle: Schema.String.pipe(Schema.optional),
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
