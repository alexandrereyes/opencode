export * as Dictation from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const maxCharacters = 20_000

export const ReviewInput = Schema.Struct({
  /** The transcription as speech recognition produced it. */
  text: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(maxCharacters)),
  /** What the composer already shows (draft, quoted passage, end of the latest messages), only to understand the subject. */
  context: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(maxCharacters))),
})
export type ReviewInput = typeof ReviewInput.Type

export const Review = Schema.Struct({
  /** The revised text, or the transcription unchanged when the review failed, timed out or came back empty. */
  text: Schema.String,
  revised: Schema.Boolean,
})
export type Review = typeof Review.Type

export const Definition = Rpc.define({
  id: "custom.dictation",
  methods: {
    review: { input: Schema.toStandardSchemaV1(ReviewInput), output: Schema.toStandardSchemaV1(Review) },
  },
  events: {},
})
