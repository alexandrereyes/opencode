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

export const Unit = Schema.Literals(["subagents"]).annotate({ identifier: "LiveActivity.Unit" })

export interface Progress extends Schema.Schema.Type<typeof Progress> {}
export const Progress = Schema.Struct({
  done: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)),
  total: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
  unit: Unit,
}).annotate({ identifier: "LiveActivity.Progress" })

const SessionRef = {
  sessionID: Schema.String,
  title: Schema.String,
  project: Schema.String,
  directory: Schema.String,
}

export interface Focus extends Schema.Schema.Type<typeof Focus> {}
export const Focus = Schema.Struct({
  ...SessionRef,
  startedAt: Schema.Number,
  activity: optional(Schema.String),
  progress: optional(Progress),
}).annotate({ identifier: "LiveActivity.Focus" })

export const AttentionKind = Schema.Literals(["question", "permission"]).annotate({
  identifier: "LiveActivity.AttentionKind",
})
export type AttentionKind = typeof AttentionKind.Type

export interface Attention extends Schema.Schema.Type<typeof Attention> {}
export const Attention = Schema.Struct({
  ...SessionRef,
  kind: AttentionKind,
  since: Schema.Number,
  text: optional(Schema.String),
}).annotate({ identifier: "LiveActivity.Attention" })

export const RowStatus = Schema.Literals(["question", "permission", "failed", "working", "idle"]).annotate({
  identifier: "LiveActivity.RowStatus",
})
export type RowStatus = typeof RowStatus.Type

export interface Row extends Schema.Schema.Type<typeof Row> {}
export const Row = Schema.Struct({
  ...SessionRef,
  status: RowStatus,
  progress: optional(Progress),
}).annotate({ identifier: "LiveActivity.Row" })

export interface Counts extends Schema.Schema.Type<typeof Counts> {}
export const Counts = Schema.Struct({
  working: Schema.Int,
  question: Schema.Int,
  permission: Schema.Int,
  failed: Schema.Int,
  idle: Schema.Int,
  /** rev. 2026-10-28; optional so builds from before it keep decoding. */
  unread: optional(Schema.Int),
}).annotate({ identifier: "LiveActivity.Counts" })

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
export const StateOutput = Schema.Struct({ state: Schema.NullOr(AgentsState) })

export const Definition = Rpc.define({
  id: "custom.live-activity",
  methods: {
    register: {
      input: Schema.toStandardSchemaV1(RegisterInput),
      output: Schema.toStandardSchemaV1(Schema.Struct({ push: Push })),
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
