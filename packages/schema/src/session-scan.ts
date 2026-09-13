export * as SessionScan from "./session-scan.js"

import { Schema } from "effect"
import { Session } from "./session.js"
import { PositiveInt, optional } from "./schema.js"

export interface Input extends Schema.Schema.Type<typeof Input> {}
export const Input = Schema.Struct({
  after: Session.ID.pipe(optional),
  limit: PositiveInt.pipe(optional),
  sessionID: Session.ID.pipe(optional),
  archived: Schema.Boolean.pipe(optional),
}).annotate({ identifier: "SessionScan.Input" })

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  session: Session.Info,
  messageAt: Schema.Finite.pipe(optional),
  completionAt: Schema.Finite.pipe(optional),
}).annotate({ identifier: "SessionScan.Info" })

export interface Page extends Schema.Schema.Type<typeof Page> {}
export const Page = Schema.Struct({
  data: Schema.Array(Info),
  next: Session.ID.pipe(optional),
}).annotate({ identifier: "SessionScan.Page" })
