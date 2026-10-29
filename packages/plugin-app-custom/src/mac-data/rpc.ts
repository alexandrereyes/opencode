export * as MacData from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional, PositiveInt } from "@opencode/schema/schema"
import { Schema } from "effect"

const When = Schema.String.check(
  Schema.isPattern(/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:\d{2})?)?$/),
)
const Names = Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))).check(
  Schema.isMaxLength(20),
)
const Text = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
const Limit = (max: number) => PositiveInt.check(Schema.isLessThanOrEqualTo(max))

/** The `mac_query` input, forwarded unchanged to the Mac app. */
export const Query = Schema.Union([
  Schema.Struct({
    source: Schema.Literal("calendar"),
    from: Schema.optionalKey(When),
    to: Schema.optionalKey(When),
    calendars: Schema.optionalKey(Names),
    query: Schema.optionalKey(Text),
    limit: Schema.optionalKey(Limit(200)),
  }),
  Schema.Struct({
    source: Schema.Literal("reminders"),
    status: Schema.optionalKey(Schema.Literals(["pending", "completed", "all"])),
    from: Schema.optionalKey(When),
    to: Schema.optionalKey(When),
    lists: Schema.optionalKey(Names),
    query: Schema.optionalKey(Text),
    limit: Schema.optionalKey(Limit(200)),
  }),
  Schema.Struct({
    source: Schema.Literal("contacts"),
    query: Text,
    limit: Schema.optionalKey(Limit(50)),
  }),
  Schema.Struct({ source: Schema.Literal("status") }),
]).annotate({ identifier: "MacData.Query" })
export type Query = typeof Query.Type

const DeviceID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))
const RequestID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(100))

export interface Attach extends Schema.Schema.Type<typeof Attach> {}
export const Attach = Schema.Struct({
  deviceID: DeviceID,
  name: Schema.String.check(Schema.isMaxLength(200)),
  model: optional(Schema.String.check(Schema.isMaxLength(100))),
  system: optional(Schema.String.check(Schema.isMaxLength(100))),
}).annotate({ identifier: "MacData.Attach" })

export interface Request extends Schema.Schema.Type<typeof Request> {}
export const Request = Schema.Struct({
  requestID: RequestID,
  deviceID: DeviceID,
  query: Query,
  /** Epoch milliseconds after which the server no longer waits. */
  deadline: Schema.Number,
  /** Location whose plugin instance waits for the answer; the app sends `respond` there. */
  directory: Schema.String,
}).annotate({ identifier: "MacData.Request" })

export const Definition = Rpc.define({
  id: "custom.mac",
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
      // The tool decodes the answer itself, so a malformed one fails the call at once instead of timing out.
      input: Schema.toStandardSchemaV1(
        Schema.Struct({ deviceID: DeviceID, requestID: RequestID, answer: Schema.Json }),
      ),
      output: Schema.toStandardSchemaV1(Schema.Struct({ accepted: Schema.Boolean })),
    },
  },
  events: {
    request: { schema: Schema.toStandardSchemaV1(Schema.Struct({ request: Request })) },
  },
})
