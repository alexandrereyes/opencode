export * as Directories from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const CreateFailure = Schema.Literals(["invalid-path", "exists", "missing-parent", "denied", "failed"]).annotate({
  identifier: "Directories.CreateFailure",
})
export type CreateFailure = typeof CreateFailure.Type

export const Definition = Rpc.define({
  id: "custom.directories",
  methods: {
    home: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Schema.Struct({ path: Schema.String })),
    },
    create: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ path: Schema.String })),
      output: Schema.toStandardSchemaV1(Schema.Struct({ path: Schema.String })),
      errors: {
        create_failed: Schema.toStandardSchemaV1(Schema.Struct({ reason: CreateFailure })),
      },
    },
  },
  events: {},
})
