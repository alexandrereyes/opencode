export * as Navigation from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { SessionScan } from "@opencode/schema/session-scan"
import { Schema } from "effect"

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  session: Schema.toEncoded(SessionScan.Info.fields.session),
  messageAt: SessionScan.Info.fields.messageAt,
  unreadAt: Schema.Finite.pipe(Schema.optional),
  permissionAt: Schema.Finite.pipe(Schema.optional),
  questionAt: Schema.Finite.pipe(Schema.optional),
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
