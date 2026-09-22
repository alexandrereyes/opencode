export * as Family from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { SessionFamily } from "@opencode/schema/session-family"
import { Session } from "@opencode/schema/session"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { Schema } from "effect"

export const Snapshot = Schema.Struct({
  count: SessionFamily.Info.fields.count,
  cost: SessionFamily.Info.fields.cost,
  active: Schema.toEncoded(SessionFamily.Info.fields.active),
  forms: Schema.Array(Schema.toEncoded(Form.Info)),
  permissions: Schema.Array(Schema.toEncoded(Permission.Request)),
})
export type Snapshot = typeof Snapshot.Type

export const Page = Schema.Struct({
  data: Schema.toEncoded(SessionFamily.Info.fields.data),
  next: SessionFamily.Info.fields.next,
})
export type Page = typeof Page.Type

export const Definition = Rpc.define({
  id: "custom.session-family",
  methods: {
    snapshot: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })),
      output: Schema.toStandardSchemaV1(Snapshot),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
    page: {
      input: Schema.toStandardSchemaV1(SessionFamily.Input),
      output: Schema.toStandardSchemaV1(Page),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
  },
  events: {},
})
