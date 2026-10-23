export * as Voice from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Schema } from "effect"

const ID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
const Text = Schema.String.check(Schema.isMaxLength(64_000))
export const Speech = Schema.Struct({ itemID: ID, text: Text, interrupted: Schema.optionalKey(Schema.Boolean) })
const Call = { version: Schema.Literal(1), callID: ID }
export const Turn = Schema.Union([
  Schema.Struct({
    ...Call,
    turnID: ID,
    type: Schema.Literal("exchange"),
    user: Schema.optionalKey(Speech),
    assistant: Schema.optionalKey(Speech),
  }),
  Schema.Struct({ ...Call, turnID: ID, type: Schema.Literal("notice"), itemID: ID, text: Text }),
])
export type Turn = typeof Turn.Type
export const End = Schema.Struct(Call)
const Empty = Schema.Struct({})
const ErrorData = Schema.Struct({ message: Schema.String })
const errors = { operation_failed: Schema.toStandardSchemaV1(ErrorData) }

export const Definition = Rpc.define({
  id: "custom.voice",
  methods: {
    info: {
      input: Schema.toStandardSchemaV1(Empty),
      output: Schema.toStandardSchemaV1(
        Schema.Struct({
          version: Schema.Literal(1),
          agent: Schema.String,
          provider: Schema.String,
          model: Schema.String,
        }),
      ),
    },
    turn: {
      input: Schema.toStandardSchemaV1(Turn),
      output: Schema.toStandardSchemaV1(
        Schema.Struct({ version: Schema.Literal(1), sessionID: Session.ID, messageID: SessionMessage.ID }),
      ),
      errors,
    },
    context: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ version: Schema.Literal(1) })),
      output: Schema.toStandardSchemaV1(
        Schema.Struct({ version: Schema.Literal(1), sessionID: Session.ID, text: Schema.String }),
      ),
      errors,
    },
    end: {
      input: Schema.toStandardSchemaV1(End),
      output: Schema.toStandardSchemaV1(Schema.Struct({ version: Schema.Literal(1), sessionID: Session.ID })),
      errors,
    },
  },
  events: {},
})
