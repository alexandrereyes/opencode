export * as SessionFamily from "./session-family.js"

import { Schema } from "effect"
import { Session } from "./session.js"
import { NonNegativeInt, PositiveInt, optional } from "./schema.js"

export interface Input extends Schema.Schema.Type<typeof Input> {}
export const Input = Schema.Struct({
  sessionID: Session.ID,
  after: Session.ID.pipe(optional),
  // Omit limit to read only the summary and active descendants.
  limit: PositiveInt.check(Schema.isLessThanOrEqualTo(100)).pipe(optional),
}).annotate({ identifier: "SessionFamily.Input" })

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  count: NonNegativeInt,
  cost: Schema.Finite,
  data: Schema.Array(Session.Info),
  next: Session.ID.pipe(optional),
  active: Schema.Array(Session.Info),
}).annotate({ identifier: "SessionFamily.Info" })
