export * as Device from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

export const Source = Schema.Literals(["device", "network", "location", "health", "motion", "photos"]).annotate({
  identifier: "Device.Source",
})
export type Source = typeof Source.Type

export const Metric = Schema.Literals([
  "sleep",
  "steps",
  "activeEnergy",
  "restingHeartRate",
  "hrv",
  "workouts",
  "weight",
]).annotate({ identifier: "Device.Metric" })
export type Metric = typeof Metric.Type

/** `YYYY-MM-DD` in the iPhone's time zone. */
export const Day = Schema.String.check(Schema.isPattern(/^\d{4}-\d{2}-\d{2}$/))

export interface Query extends Schema.Schema.Type<typeof Query> {}
export const Query = Schema.Struct({
  source: Source,
  metrics: optional(Schema.Array(Metric).check(Schema.isMinLength(1), Schema.isMaxLength(7))),
  from: optional(Day),
  to: optional(Day),
  granularity: optional(Schema.Literals(["day", "sample"])),
  limit: optional(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 10 }))),
  thumbnails: optional(Schema.Boolean),
}).annotate({ identifier: "Device.Query" })

export const Authorization = Schema.Literals([
  "notDetermined",
  "authorized",
  "limited",
  "requested",
  "denied",
  "restricted",
  "unavailable",
]).annotate({ identifier: "Device.Authorization" })

export interface SourceState extends Schema.Schema.Type<typeof SourceState> {}
export const SourceState = Schema.Struct({
  source: Source,
  enabled: Schema.Boolean,
  authorization: Authorization,
}).annotate({ identifier: "Device.SourceState" })

const DeviceID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))
const RequestID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))

export interface Attach extends Schema.Schema.Type<typeof Attach> {}
export const Attach = Schema.Struct({
  deviceID: DeviceID,
  name: Schema.String.check(Schema.isMaxLength(200)),
  model: optional(Schema.String.check(Schema.isMaxLength(100))),
  system: optional(Schema.String.check(Schema.isMaxLength(100))),
  sources: Schema.Array(SourceState).check(Schema.isMaxLength(20)),
}).annotate({ identifier: "Device.Attach" })

export interface File extends Schema.Schema.Type<typeof File> {}
export const File = Schema.Struct({
  name: Schema.String.check(Schema.isMaxLength(200)),
  mime: Schema.Literals(["image/jpeg", "image/png", "image/heic"]),
  /** Base64 without a data URI prefix. */
  data: Schema.String.check(Schema.isMaxLength(400_000)),
}).annotate({ identifier: "Device.File" })

export const Status = Schema.Literals([
  "ok",
  "offline",
  "timeout",
  "locked",
  "disabled",
  "denied",
  "unavailable",
  "error",
]).annotate({ identifier: "Device.Status" })
export type Status = typeof Status.Type

/** What the iPhone answers. `data` is source-specific JSON; `note` explains partial answers. */
export interface Answer extends Schema.Schema.Type<typeof Answer> {}
export const Answer = Schema.Struct({
  status: Status,
  collectedAt: optional(Schema.Number),
  data: optional(Schema.Json),
  files: optional(Schema.Array(File).check(Schema.isMaxLength(10))),
  note: optional(Schema.String.check(Schema.isMaxLength(2_000))),
  truncated: optional(Schema.Boolean),
}).annotate({ identifier: "Device.Answer" })

export interface Request extends Schema.Schema.Type<typeof Request> {}
export const Request = Schema.Struct({
  requestID: RequestID,
  deviceID: DeviceID,
  query: Query,
  /** Epoch milliseconds after which the server no longer waits. */
  deadline: Schema.Number,
  /** Location whose plugin instance waits for the answer; the app sends `respond` there. */
  directory: Schema.String,
}).annotate({ identifier: "Device.Request" })

export const Definition = Rpc.define({
  id: "custom.device",
  methods: {
    attach: {
      input: Schema.toStandardSchemaV1(Attach),
      output: Schema.toStandardSchemaV1(Schema.Struct({ leaseSeconds: Schema.Number })),
    },
    detach: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ deviceID: DeviceID })),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
    },
    respond: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ deviceID: DeviceID, requestID: RequestID, answer: Answer })),
      output: Schema.toStandardSchemaV1(Schema.Struct({ accepted: Schema.Boolean })),
    },
  },
  events: {
    request: { schema: Schema.toStandardSchemaV1(Schema.Struct({ request: Request })) },
  },
})
