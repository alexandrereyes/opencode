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

const Label = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(64))
const Short = Schema.String.check(Schema.isMaxLength(120))
/**
 * Why an app's GPT Live call failed, was lost or ended, without speech: a category, the error code or event type,
 * the names of the last events and the device's state. Logged by the server as `Voice diagnostics`.
 */
export const Diagnostic = Schema.Struct({
  kind: Schema.Literals(["failed", "lost", "interrupted", "ended", "tolerated"]),
  reason: Label,
  code: Schema.optionalKey(Short),
  platform: Schema.Literals(["ios", "macos"]),
  build: Short,
  at: Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0)),
  call: Schema.optionalKey(Short),
  connectedSeconds: Schema.optionalKey(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
  phase: Label,
  recovering: Schema.Boolean,
  events: Schema.Array(Label).check(Schema.isMaxLength(24)),
  app: Schema.Struct({ state: Schema.Literals(["active", "inactive", "background"]), locked: Schema.Boolean }),
  audio: Schema.optionalKey(
    Schema.Struct({
      category: Short,
      mode: Short,
      inputs: Schema.Array(Label).check(Schema.isMaxLength(4)),
      outputs: Schema.Array(Label).check(Schema.isMaxLength(4)),
      otherAudio: Schema.optionalKey(Schema.Boolean),
    }),
  ),
  network: Schema.optionalKey(Short),
})
export type Diagnostic = typeof Diagnostic.Type
export const Diagnostics = Schema.Struct({
  events: Schema.Array(Diagnostic).check(Schema.isMinLength(1), Schema.isMaxLength(20)),
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
    diagnostics: {
      input: Schema.toStandardSchemaV1(Diagnostics),
      output: Schema.toStandardSchemaV1(Schema.Struct({ accepted: Schema.Number })),
    },
  },
  events: {},
})
