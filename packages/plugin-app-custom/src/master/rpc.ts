export * as Master from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Model } from "@opencode/schema/model"
import { Schema } from "effect"

export const Info = Schema.Struct({
  version: Schema.Literal(1),
  agent: Schema.String,
  model: Schema.optionalKey(Model.Ref),
})

export const Definition = Rpc.define({
  id: "custom.master",
  methods: {
    info: { input: Schema.toStandardSchemaV1(Schema.Struct({})), output: Schema.toStandardSchemaV1(Info) },
  },
  events: {},
})
