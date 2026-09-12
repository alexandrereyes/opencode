export * as Subscriptions from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export interface BankedResets extends Schema.Schema.Type<typeof BankedResets> {}
export const BankedResets = Schema.Struct({
  available: Schema.Number,
  earliestExpiresAt: Schema.NullOr(Schema.String),
  latestExpiresAt: Schema.NullOr(Schema.String),
  nonExpiring: Schema.Number,
}).annotate({ identifier: "Subscriptions.BankedResets" })

export interface Account extends Schema.Schema.Type<typeof Account> {}
export const Account = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  enabled: Schema.Boolean,
  plan: Schema.NullOr(Schema.String),
  authenticated: Schema.Boolean,
  cooldownSeconds: Schema.Number,
  bankedResets: Schema.NullOr(BankedResets),
  remaining: Schema.NullOr(Schema.Number),
  resetAt: Schema.NullOr(Schema.String),
  observedAt: Schema.NullOr(Schema.String),
  stale: Schema.Boolean,
  hasCapacity: Schema.NullOr(Schema.Boolean),
}).annotate({ identifier: "Subscriptions.Account" })

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  status: Schema.Literals(["ok", "unconfigured", "unavailable"]),
  accounts: Schema.Array(Account),
}).annotate({ identifier: "Subscriptions.Info" })

export const Definition = Rpc.define({
  id: "custom.subscriptions",
  methods: {
    list: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Info),
    },
  },
  events: {},
})
