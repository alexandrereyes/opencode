export * as Archive from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Session } from "@opencode/schema/session"
import { Schema } from "effect"

const OperationFailed = Schema.Struct({ message: Schema.String })

export const Definition = Rpc.define({
  id: "custom.archive",
  methods: {
    archive: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
  },
  events: {},
})
