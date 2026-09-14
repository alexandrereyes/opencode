export * as Updates from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const Target = Schema.Struct({
  commit: Schema.String.check(Schema.isPattern(/^[a-f0-9]{40}$/)),
  version: Schema.String.check(Schema.isPattern(/^0\.0\.0-custom-\d+\.\d+$/)),
})
export type Target = typeof Target.Type

export const State = Schema.Union([
  Schema.Struct({ status: Schema.Literal("disabled") }),
  Schema.Struct({ status: Schema.Literal("up-to-date") }),
  Schema.Struct({ status: Schema.Literal("ready"), ...Target.fields }),
  Schema.Struct({ status: Schema.Literal("installing"), ...Target.fields }),
])
export type State = typeof State.Type

export const Definition = Rpc.define({
  id: "custom.updates",
  methods: {
    check: { input: Schema.toStandardSchemaV1(Schema.Struct({})), output: Schema.toStandardSchemaV1(State) },
    install: {
      input: Schema.toStandardSchemaV1(Target),
      output: Schema.toStandardSchemaV1(Target),
      errors: {
        unavailable: Schema.toStandardSchemaV1(Schema.Struct({})),
        failed: Schema.toStandardSchemaV1(Schema.Struct({})),
      },
    },
  },
  events: {},
})
