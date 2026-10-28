export * as Voice from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const version = 2
export const Scope = Schema.Literal("global")
export type Scope = typeof Scope.Type
const ID = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
export const Turn = Schema.Struct({
  id: ID,
  role: Schema.Literals(["user", "assistant"]),
  text: Schema.String.check(Schema.isMaxLength(64_000)),
  at: Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0)),
  interrupted: Schema.optionalKey(Schema.Boolean),
})
export type Turn = typeof Turn.Type
export const Record = Schema.Struct({
  version: Schema.Literal(1),
  summary: Schema.String,
  turns: Schema.Array(Turn),
  approxTokens: Schema.Number,
  updatedAt: Schema.Number,
  // Compaction removes old verbatim turns, not their retry identities.
  seenTurnIDs: Schema.optionalKey(Schema.Array(ID)),
})
export type Record = typeof Record.Type
export const Target = Schema.Struct({ version: Schema.Literal(version), scope: Scope })
export const Append = Schema.Struct({
  ...Target.fields,
  turns: Schema.Array(Turn).check(Schema.isMinLength(1), Schema.isMaxLength(128)),
})
const errors = { operation_failed: Schema.toStandardSchemaV1(Schema.Struct({ message: Schema.String })) }
export const Master = Schema.Struct({ state: Schema.Literals(["running", "idle"]), text: Schema.String })
export type Master = typeof Master.Type
export const Context = Schema.Struct({
  ...Target.fields,
  summary: Schema.String,
  turns: Schema.Array(Turn),
  approxTokens: Schema.Number,
  updatedAt: Schema.Number,
  truncated: Schema.Boolean,
  master: Schema.optionalKey(Master),
})

export const Definition = Rpc.define({
  id: "custom.voice",
  methods: {
    info: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(
        Schema.Struct({
          version: Schema.Literal(version),
          storage: Schema.Literal("kv"),
          contextFormat: Schema.Literal("initial_items"),
          scopes: Schema.Array(Scope),
          maxInitialItems: Schema.Number,
          maxInitialTokens: Schema.Number,
          compactTokens: Schema.Number,
          compactTurns: Schema.Number,
        }),
      ),
    },
    instructions: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Schema.Struct({ instructions: Schema.String })),
      errors,
    },
    append: {
      input: Schema.toStandardSchemaV1(Append),
      output: Schema.toStandardSchemaV1(
        Schema.Struct({
          ...Target.fields,
          appended: Schema.Number,
          approxTokens: Schema.Number,
          updatedAt: Schema.Number,
          compactionScheduled: Schema.Boolean,
        }),
      ),
      errors,
    },
    context: { input: Schema.toStandardSchemaV1(Target), output: Schema.toStandardSchemaV1(Context), errors },
    end: {
      input: Schema.toStandardSchemaV1(Target),
      output: Schema.toStandardSchemaV1(Schema.Struct({ ...Target.fields, compactionScheduled: Schema.Boolean })),
      errors,
    },
  },
  events: {},
})
