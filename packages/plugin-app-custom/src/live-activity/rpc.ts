export * as LiveActivity from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

/** Contract: `packages/plugin-app-custom/docs/live-activity.md`. All times are epoch milliseconds. */

export const themeRoles = [
  "background",
  "surface",
  "border",
  "textStrong",
  "text",
  "textSecondary",
  "textWeak",
  "primary",
  "success",
  "warning",
  "error",
  "accent",
] as const

export const Theme = Schema.Record(
  Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(32)),
  Schema.String.check(Schema.isPattern(/^#[0-9a-fA-F]{8}$/)),
)
  .check(
    Schema.isMaxProperties(24),
    Schema.makeFilter((theme) => themeRoles.every((role) => role in theme), {
      expected: `a theme with the roles ${themeRoles.join(", ")}`,
    }),
  )
  .annotate({ identifier: "LiveActivity.Theme" })
export type Theme = typeof Theme.Type

export interface Attributes extends Schema.Schema.Type<typeof Attributes> {}
export const Attributes = Schema.Struct({
  serverKey: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100)),
  theme: Theme,
}).annotate({ identifier: "LiveActivity.Attributes" })

/** `subagents`: finished child sessions of the run; `todos` (rev. 2026-10-30): completed items of its Progresso. */
export const Unit = Schema.Literals(["subagents", "todos"]).annotate({ identifier: "LiveActivity.Unit" })

export interface Progress extends Schema.Schema.Type<typeof Progress> {}
export const Progress = Schema.Struct({
  done: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  total: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
  unit: Unit,
  /** `todos` only: the item in hand ("Agora: …"), ≤ 60 chars. */
  current: optional(Schema.String),
}).annotate({ identifier: "LiveActivity.Progress" })

const SessionRef = {
  sessionID: Schema.String,
  title: Schema.String,
  project: Schema.String,
  directory: Schema.String,
  /** Joined state only (`docs/unified-summary.md`): the `instanceID` of the server the session lives on. */
  server: optional(Schema.String),
}

export interface Focus extends Schema.Schema.Type<typeof Focus> {}
export const Focus = Schema.Struct({
  ...SessionRef,
  startedAt: Schema.Number,
  activity: optional(Schema.String),
  progress: optional(Progress),
}).annotate({ identifier: "LiveActivity.Focus" })

/** `browser` (rev. 2026-11-07): a browse handoff waits on Alexandre in the browser (`docs/browser-handoff.md`). */
export const AttentionKind = Schema.Literals(["question", "permission", "browser"]).annotate({
  identifier: "LiveActivity.AttentionKind",
})
export type AttentionKind = typeof AttentionKind.Type

export interface Attention extends Schema.Schema.Type<typeof Attention> {}
export const Attention = Schema.Struct({
  ...SessionRef,
  kind: AttentionKind,
  since: Schema.Number,
  text: optional(Schema.String),
  /**
   * rev. 2026-11-07, kind `browser` only (`browse-handoff-remoto.md`): the resource that shows the handoff's tab, when
   * it has one.
   */
  resourceID: optional(Schema.String),
}).annotate({ identifier: "LiveActivity.Attention" })

export const RowStatus = Schema.Literals(["question", "permission", "browser", "failed", "working", "idle"]).annotate({
  identifier: "LiveActivity.RowStatus",
})
export type RowStatus = typeof RowStatus.Type

export interface Row extends Schema.Schema.Type<typeof Row> {}
export const Row = Schema.Struct({
  ...SessionRef,
  status: RowStatus,
  progress: optional(Progress),
}).annotate({ identifier: "LiveActivity.Row" })

export const NeedKind = Schema.Literals(["question", "permission", "browser", "failed", "unread"]).annotate({
  identifier: "LiveActivity.NeedKind",
})
export type NeedKind = typeof NeedKind.Type

/** rev. 2026-10-29: one session that needs Alexandre, as in the Sessões "Precisa de você" section. */
export interface Need extends Schema.Schema.Type<typeof Need> {}
export const Need = Schema.Struct({
  ...SessionRef,
  kind: NeedKind,
  since: Schema.Number,
}).annotate({ identifier: "LiveActivity.Need" })

export interface Counts extends Schema.Schema.Type<typeof Counts> {}
export const Counts = Schema.Struct({
  working: Schema.Int,
  question: Schema.Int,
  permission: Schema.Int,
  failed: Schema.Int,
  idle: Schema.Int,
  /** rev. 2026-10-28; optional so builds from before it keep decoding. */
  unread: optional(Schema.Int),
  /** rev. 2026-11-07: sessions waiting on a browse handoff; present only when nonzero. */
  browser: optional(Schema.Int),
}).annotate({ identifier: "LiveActivity.Counts" })

/** One server of a joined state (`docs/unified-summary.md`); the first is the one that wrote it. */
export interface Server extends Schema.Schema.Type<typeof Server> {}
export const Server = Schema.Struct({
  instanceID: Schema.String,
  name: Schema.String,
  /** The badge's initials, by the apps' rule (`ServerSwitcher.initials`). */
  short: Schema.String,
  /** Present (`true`) while this server is away: its work in progress is not in the state, what waited there is. */
  offline: optional(Schema.Boolean),
}).annotate({ identifier: "LiveActivity.Server" })

export interface AgentsState extends Schema.Schema.Type<typeof AgentsState> {}
export const AgentsState = Schema.Struct({
  v: Schema.Literal(1),
  updatedAt: Schema.Number,
  host: Schema.String,
  counts: Counts,
  activeTotal: Schema.Int,
  focus: optional(Focus),
  attention: Schema.Array(Attention),
  attentionTotal: Schema.Int,
  sessions: Schema.Array(Row),
  /** rev. 2026-10-29; optional so older builds and backends keep decoding. */
  needs: optional(Schema.Array(Need)),
  /** Joined state only (`docs/unified-summary.md`): every server it covers, the writer first. */
  servers: optional(Schema.Array(Server)),
}).annotate({ identifier: "LiveActivity.AgentsState" })

const DeviceID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))
export const Token = Schema.String.check(Schema.isPattern(/^[0-9a-f]+$/), Schema.isMaxLength(512))
const ActivityID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
export const Environment = Schema.Literals(["sandbox", "production"]).annotate({
  identifier: "LiveActivity.Environment",
})
export type Environment = typeof Environment.Type

export interface RegisterInput extends Schema.Schema.Type<typeof RegisterInput> {}
export const RegisterInput = Schema.Struct({
  deviceID: DeviceID,
  serverKey: Attributes.fields.serverKey,
  environment: Environment,
  theme: Theme,
  pushToStartToken: optional(Schema.NullOr(Token)),
  /**
   * `all` (`docs/unified-summary.md`): this device's activity is the one of the "Todos" scope, written with the joined
   * state by a server that reads its peers' summaries. Absent: this server's own state, as always.
   */
  scope: optional(Schema.Literal("all")),
}).annotate({ identifier: "LiveActivity.RegisterInput" })

export interface ActivityInput extends Schema.Schema.Type<typeof ActivityInput> {}
export const ActivityInput = Schema.Struct({
  deviceID: DeviceID,
  activityID: ActivityID,
  pushToken: Token,
}).annotate({ identifier: "LiveActivity.ActivityInput" })

export interface EndedInput extends Schema.Schema.Type<typeof EndedInput> {}
export const EndedInput = Schema.Struct({
  deviceID: DeviceID,
  activityID: ActivityID,
  reason: Schema.Literals(["ended", "dismissed"]),
}).annotate({ identifier: "LiveActivity.EndedInput" })

export const Push = Schema.Literals(["configured", "unconfigured"]).annotate({ identifier: "LiveActivity.Push" })
export type Push = typeof Push.Type

const Empty = Schema.Struct({})
/** `unified`: the joined state, only from a server that reads its peers' summaries (`docs/unified-summary.md`). */
export const StateOutput = Schema.Struct({ state: Schema.NullOr(AgentsState), unified: optional(AgentsState) })
/** `scope: "all"` confirms that this registration gets the joined state; absent, it gets this server's own. */
export const RegisterOutput = Schema.Struct({ push: Push, scope: optional(Schema.Literal("all")) })

export const Definition = Rpc.define({
  id: "custom.live-activity",
  methods: {
    register: {
      input: Schema.toStandardSchemaV1(RegisterInput),
      output: Schema.toStandardSchemaV1(RegisterOutput),
    },
    activity: {
      input: Schema.toStandardSchemaV1(ActivityInput),
      output: Schema.toStandardSchemaV1(Empty),
    },
    ended: {
      input: Schema.toStandardSchemaV1(EndedInput),
      output: Schema.toStandardSchemaV1(Empty),
    },
    unregister: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ deviceID: DeviceID })),
      output: Schema.toStandardSchemaV1(Empty),
    },
    snapshot: {
      input: Schema.toStandardSchemaV1(Empty),
      output: Schema.toStandardSchemaV1(StateOutput),
    },
  },
  events: {
    changed: { schema: Schema.toStandardSchemaV1(StateOutput) },
  },
})
