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
  /** When `reset` cleared the record: turns spoken before it, late replies and summaries of older calls stay out. */
  resetAt: Schema.optionalKey(Schema.Number),
})
export type Record = typeof Record.Type
export const Target = Schema.Struct({ version: Schema.Literal(version), scope: Scope })
/**
 * `reset`: `at` is when the app cleared its own memory (epoch ms, the clock of its turns' `at`; since 03/11), so a
 * reset that waited in its queue still keeps the turns said after it. Without it, the server's time.
 */
export const Reset = Schema.Struct({
  ...Target.fields,
  at: Schema.optionalKey(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
})
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
const Measure = Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))
const Ports = Schema.Array(Label).check(Schema.isMaxLength(4))
/**
 * A call's audio quality as the iPhone or Mac app measured it from WebRTC statistics (`VoiceQualityMeter`, rev.
 * 2026-11-03): 5 s windows summed over the call so far. Percentages are 0–100, times in milliseconds; a measure the
 * statistics never had is absent. Numbers and short labels only.
 */
export const Quality = Schema.Struct({
  seconds: Measure,
  windows: Measure,
  /** Windows past a limit: concealed > 3 %, loss either way > 2 % or jitter > 30 ms. */
  badWindows: Measure,
  links: Measure,
  lossInPct: Schema.optionalKey(Measure),
  lossOutPct: Schema.optionalKey(Measure),
  concealedPct: Schema.optionalKey(Measure),
  concealmentEvents: Schema.optionalKey(Measure),
  stretchedPct: Schema.optionalKey(Measure),
  compressedPct: Schema.optionalKey(Measure),
  jitterMs: Schema.optionalKey(Measure),
  jitterMaxMs: Schema.optionalKey(Measure),
  bufferMs: Schema.optionalKey(Measure),
  rttMs: Schema.optionalKey(Measure),
  rttMaxMs: Schema.optionalKey(Measure),
  /** The worst window: seconds since the call's first sample and the measure furthest past its limit. */
  worst: Schema.optionalKey(
    Schema.Struct({
      atSeconds: Measure,
      cause: Label,
      concealedPct: Schema.optionalKey(Measure),
      lossInPct: Schema.optionalKey(Measure),
      lossOutPct: Schema.optionalKey(Measure),
      jitterMs: Schema.optionalKey(Measure),
    }),
  ),
  routes: Schema.Array(Schema.Struct({ inputs: Ports, outputs: Ports, sampleRate: Schema.optionalKey(Measure) })).check(
    Schema.isMaxLength(4),
  ),
  routeChanges: Measure,
  /** Local candidates the media used, `type/protocol/network`: never an address. */
  paths: Schema.Array(Label).check(Schema.isMaxLength(4)),
})
export type Quality = typeof Quality.Type
/**
 * Why an app's GPT Live call failed, was lost or ended, without speech: a category, the error code or event type,
 * the provider's sanitized error message and param, the last command sent and the one an error named, GPT Live's ID of
 * the call, the names of the last events and the device's state. Logged by the server as `Voice diagnostics`.
 */
export const Diagnostic = Schema.Struct({
  kind: Schema.Literals(["failed", "lost", "interrupted", "ended", "tolerated"]),
  reason: Label,
  code: Schema.optionalKey(Short),
  /** Sanitized by the app (`VoiceDiagnosticText`) and again by the server: no long quoted span, no control characters. */
  detail: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(300))),
  /** The type of the last command the app sent on the data channel, and how long before the report. */
  lastSent: Schema.optionalKey(Label),
  lastSentSeconds: Schema.optionalKey(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
  /** GPT Live's ID of the call (`rtc_…`, the creation's `Location`), once one was created (rev. 2026-11-02). */
  remoteCall: Schema.optionalKey(Label),
  /** The command a GPT Live `error` named by its `event_id`, and how long before the report it was sent. */
  failedCommand: Schema.optionalKey(Label),
  failedCommandSeconds: Schema.optionalKey(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
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
  /** On the reports of a call's end (`ended`, `lost`, `failed`) since 03/11; older servers drop the unknown key. */
  quality: Schema.optionalKey(Quality),
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
    reset: {
      input: Schema.toStandardSchemaV1(Reset),
      output: Schema.toStandardSchemaV1(Schema.Struct({ ...Target.fields, resetAt: Schema.Number })),
      errors,
    },
    diagnostics: {
      input: Schema.toStandardSchemaV1(Diagnostics),
      output: Schema.toStandardSchemaV1(Schema.Struct({ accepted: Schema.Number })),
    },
  },
  events: {},
})
