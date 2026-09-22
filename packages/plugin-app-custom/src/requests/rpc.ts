export * as Requests from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Permission } from "@opencode/schema/permission"
import { Schema } from "effect"

export const Definition = Rpc.define({
  id: "custom.requests",
  methods: {
    permissions: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Schema.Array(Schema.toEncoded(Permission.Request))),
    },
  },
  events: {},
})
