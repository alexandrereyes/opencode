export * as Speech from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

/** One request; the app sends ~1,500-character pieces cut at sentence ends. */
export const maxCharacters = 2_000

export const Info = Schema.Struct({
  model: Schema.String,
  voice: Schema.String,
  maxCharacters: Schema.Number,
  /** Measured speaking rate at 1×, for duration estimates before audio exists. */
  charactersPerSecond: Schema.Number,
  /** Approximate generation cost per second of audio, for confirmation prompts. */
  usdPerSecond: Schema.Number,
})
export type Info = typeof Info.Type

export const SynthesizeInput = Schema.Struct({
  text: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(maxCharacters)),
  /** A Gemini prebuilt voice name; the server default otherwise. */
  voice: Schema.optionalKey(Schema.String.check(Schema.isPattern(/^[A-Z][a-z]{2,20}$/))),
})

export const Audio = Schema.Struct({
  /** Base64 audio bytes. */
  audio: Schema.String,
  mime: Schema.Literals(["audio/mp4", "audio/wav"]),
  cached: Schema.Boolean,
})
export type Audio = typeof Audio.Type

const failure = Schema.toStandardSchemaV1(Schema.Struct({ message: Schema.String }))

export const Definition = Rpc.define({
  id: "custom.speech",
  methods: {
    info: { input: Schema.toStandardSchemaV1(Schema.Struct({})), output: Schema.toStandardSchemaV1(Info) },
    synthesize: {
      input: Schema.toStandardSchemaV1(SynthesizeInput),
      output: Schema.toStandardSchemaV1(Audio),
      errors: { unavailable: failure, synthesis_failed: failure },
    },
  },
  events: {},
})
