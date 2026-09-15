export * as Chats from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Schema } from "effect"

const Empty = Schema.Struct({})
const OperationFailed = Schema.Struct({ message: Schema.String })

export const Definition = Rpc.define({
  id: "custom.chats",
  methods: {
    info: {
      input: Schema.toStandardSchemaV1(Empty),
      output: Schema.toStandardSchemaV1(Schema.Struct({ root: AbsolutePath })),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
    allocate: {
      input: Schema.toStandardSchemaV1(Empty),
      output: Schema.toStandardSchemaV1(Schema.Struct({ id: Schema.String, directory: AbsolutePath })),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
    claim: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({ id: Schema.String, directory: AbsolutePath, sessionID: Session.ID }),
      ),
      output: Schema.toStandardSchemaV1(Empty),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
    confirm: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({ id: Schema.String, directory: AbsolutePath, sessionID: Session.ID }),
      ),
      output: Schema.toStandardSchemaV1(Empty),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
  },
  events: {},
})
