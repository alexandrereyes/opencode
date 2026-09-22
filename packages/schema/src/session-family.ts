export * as SessionFamily from "./session-family.js"

import { Schema } from "effect"
import { Model } from "./model.js"
import { SessionMessage } from "./session-message.js"
import { Session } from "./session.js"
import { TokenUsage } from "./token-usage.js"
import { NonNegativeInt, PositiveInt, optional } from "./schema.js"

export interface Input extends Schema.Schema.Type<typeof Input> {}
export const Input = Schema.Struct({
  sessionID: Session.ID,
  after: Session.ID.pipe(optional),
  // Omit limit to read only the summary and active descendants.
  limit: PositiveInt.check(Schema.isLessThanOrEqualTo(100)).pipe(optional),
}).annotate({ identifier: "SessionFamily.Input" })

/** Latest measured assistant context of a descendant; absent until a step reports tokens. */
export interface Context extends Schema.Schema.Type<typeof Context> {}
export const Context = Schema.Struct({
  id: SessionMessage.ID,
  tokens: TokenUsage.Info,
  model: Model.Ref,
}).annotate({ identifier: "SessionFamily.Context" })

export interface Member extends Schema.Schema.Type<typeof Member> {}
export const Member = Schema.Struct({
  ...Session.Info.fields,
  context: Context.pipe(optional),
}).annotate({ identifier: "SessionFamily.Member" })

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  count: NonNegativeInt,
  cost: Schema.Finite,
  data: Schema.Array(Member),
  next: Session.ID.pipe(optional),
  active: Schema.Array(Session.Info),
}).annotate({ identifier: "SessionFamily.Info" })

/** Read-only descendant boundaries. Omitting message selects existing staged reverts. */
export interface BoundariesInput extends Schema.Schema.Type<typeof BoundariesInput> {}
export const BoundariesInput = Schema.Struct({
  sessionID: Session.ID,
  message: Schema.Struct({
    type: Schema.Literals([
      "agent-switched",
      "model-switched",
      "location-switched",
      "user",
      "synthetic",
      "system",
      "skill",
      "shell",
      "assistant",
      "compaction",
      "idle",
    ] satisfies ReadonlyArray<SessionMessage.Type>),
    createdAtOrAfter: NonNegativeInt,
  }).pipe(optional),
}).annotate({ identifier: "SessionFamily.BoundariesInput" })

export interface Boundary extends Schema.Schema.Type<typeof Boundary> {}
export const Boundary = Schema.Struct({
  sessionID: Session.ID,
  messageID: SessionMessage.ID,
}).annotate({ identifier: "SessionFamily.Boundary" })
export const Boundaries = Schema.Array(Boundary)
