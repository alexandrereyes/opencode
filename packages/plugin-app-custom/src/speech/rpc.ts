export * as Speech from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

/** One request; the app sends ~1,500-character pieces cut at sentence ends. */
export const maxCharacters = 2_000

export const Info = Schema.Struct({
  model: Schema.String,
  voice: Schema.String,
  maxCharacters: Schema.Number,
  /** Speaking rate at 1× learned from the audio this server generated, for estimates before audio exists. */
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

/** Positions kept, most recently saved first; older ones are dropped. */
export const maxPositions = 200

const Path = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(4_096))
const Count = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))

/** Where reading stopped, in terms of the speakable text so it survives other devices, speeds and edits. */
export const Position = Schema.Struct({
  /** Absolute path of the Markdown file on this server. */
  path: Path,
  /** SHA-256 of the speakable text the offset refers to. */
  hash: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
  /** Characters of speakable text before the position. */
  offset: Count,
  /** Length of that speakable text. */
  characters: Count,
  /** The sentence being read, to find the place again when the document changes. */
  sentence: Schema.String.check(Schema.isMaxLength(200)),
  /** Elapsed audio at 1× when saved, so an unchanged document reopens showing the same time. */
  seconds: Schema.optionalKey(Schema.Finite.check(Schema.isGreaterThanOrEqualTo(0))),
  updatedAt: Schema.Number,
})
export type Position = typeof Position.Type
export const PositionInput = Schema.Struct({
  path: Path,
  hash: Position.fields.hash,
  offset: Count,
  characters: Count,
  sentence: Position.fields.sentence,
  seconds: Position.fields.seconds,
})
export const PathInput = Schema.Struct({ path: Path })

export const Definition = Rpc.define({
  id: "custom.speech",
  methods: {
    info: { input: Schema.toStandardSchemaV1(Schema.Struct({})), output: Schema.toStandardSchemaV1(Info) },
    synthesize: {
      input: Schema.toStandardSchemaV1(SynthesizeInput),
      output: Schema.toStandardSchemaV1(Audio),
      errors: { unavailable: failure, synthesis_failed: failure },
    },
    getPosition: {
      input: Schema.toStandardSchemaV1(PathInput),
      output: Schema.toStandardSchemaV1(Schema.Struct({ position: Schema.NullOr(Position) })),
    },
    setPosition: { input: Schema.toStandardSchemaV1(PositionInput), output: Schema.toStandardSchemaV1(Position) },
    clearPosition: {
      input: Schema.toStandardSchemaV1(PathInput),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
    },
  },
  events: {},
})
