export * as Watch from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"
import { LiveActivity } from "../live-activity/rpc.js"

/** Contract: `packages/plugin-app-custom/docs/watch.md`. Times are epoch milliseconds. */

export const gatewayURL = "https://watch-mac.alexandrem.com.br"
export const defaultVoiceID = "rio"

const DeviceID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))

export interface Paired extends Schema.Schema.Type<typeof Paired> {}
export const Paired = Schema.Struct({
  deviceID: Schema.String,
  deviceToken: Schema.String,
  gatewayURL: Schema.String,
  access: Schema.Struct({ clientId: Schema.String, clientSecret: Schema.String }),
  voice: Schema.Struct({ voiceID: Schema.String }),
}).annotate({ identifier: "Watch.Paired" })

export interface DeviceView extends Schema.Schema.Type<typeof DeviceView> {}
export const DeviceView = Schema.Struct({
  deviceID: Schema.String,
  name: Schema.String,
  createdAt: Schema.Number,
  lastSeenAt: Schema.Number,
}).annotate({ identifier: "Watch.Device" })

const OperationFailed = Schema.Struct({ message: Schema.String })

export const Definition = Rpc.define({
  id: "custom.watch",
  methods: {
    pair: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({ deviceName: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100)) }),
      ),
      output: Schema.toStandardSchemaV1(Paired),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
    devices: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Schema.Struct({ devices: Schema.Array(DeviceView) })),
    },
    revoke: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ deviceID: DeviceID })),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
    },
  },
  events: {},
})

// Gateway wire types (`/watch/v1`).

export const QuestionOption = Schema.Struct({
  id: Schema.String,
  label: Schema.String,
  recommended: optional(Schema.Boolean),
})
export const Question = Schema.Struct({
  id: Schema.String,
  text: Schema.String,
  options: Schema.Array(QuestionOption),
  multiple: Schema.Boolean,
  allowText: Schema.Boolean,
})
export type Question = typeof Question.Type

const RequestRef = {
  requestID: Schema.String,
  sessionID: Schema.String,
  title: Schema.String,
  project: Schema.String,
  since: Schema.Number,
}

export const WatchRequest = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("question"), ...RequestRef, questions: Schema.Array(Question) }),
  Schema.Struct({
    kind: Schema.Literal("permission"),
    ...RequestRef,
    action: Schema.String,
    resources: Schema.Array(Schema.String),
    summary: Schema.String,
  }),
]).annotate({ identifier: "Watch.Request" })
export type WatchRequest = typeof WatchRequest.Type

export const WatchReply = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal("question"),
    answers: Schema.Array(
      Schema.Struct({
        questionID: Schema.String,
        optionIDs: optional(Schema.Array(Schema.String).check(Schema.isMaxLength(64))),
        text: optional(Schema.String.check(Schema.isMaxLength(12_000))),
      }),
    ).check(Schema.isMaxLength(64)),
  }),
  Schema.Struct({ kind: Schema.Literal("permission"), decision: Schema.Literals(["once", "always", "reject"]) }),
]).annotate({ identifier: "Watch.Reply" })
export type WatchReply = typeof WatchReply.Type

export const WidgetToken = Schema.Struct({
  token: LiveActivity.Token,
  environment: LiveActivity.Environment,
})

export const CallInput = Schema.Struct({
  sdp: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64 * 1024)),
  voiceID: optional(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(40))),
})

export const Heartbeat = Schema.Struct({
  sent: Schema.Number.check(Schema.isGreaterThanOrEqualTo(0)),
  received: Schema.Number.check(Schema.isGreaterThanOrEqualTo(0)),
})

export const Diagnostics = Schema.Struct({
  events: Schema.Array(Schema.Record(Schema.String, Schema.Unknown)).check(Schema.isMaxLength(50)),
})

export type VoiceEventBody =
  | { readonly type: "status"; readonly status: "connecting" | "live" | "ended"; readonly reason?: string }
  | { readonly type: "caption"; readonly role: "user" | "assistant"; readonly text: string; readonly final: boolean }
  | { readonly type: "master"; readonly state: "running" | "idle"; readonly text: string }
  | { readonly type: "error"; readonly code: string; readonly message: string }
export type VoiceEvent = { readonly seq: number; readonly at: number } & VoiceEventBody
