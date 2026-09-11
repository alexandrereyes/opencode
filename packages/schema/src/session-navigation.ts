export * as SessionNavigation from "./session-navigation.js"

import { Schema } from "effect"
import { Session } from "./session.js"
import { optional } from "./schema.js"

/** A transcript-free navigation row. Clocks are milliseconds since the Unix epoch. */
export const Info = Schema.Struct({
  session: Session.Info,
  messageAt: Schema.Finite.pipe(optional),
  /** Latest unread root completion; child completions do not request attention. */
  unreadAt: Schema.Finite.pipe(optional),
  /** Latest outstanding request creation time, including requests owned by child sessions. */
  permissionAt: Schema.Finite.pipe(optional),
  questionAt: Schema.Finite.pipe(optional),
}).annotate({ identifier: "SessionNavigation.Info" })
export interface Info extends Schema.Schema.Type<typeof Info> {}

export const Page = Schema.Struct({
  data: Schema.Array(Info),
  next: Session.ID.pipe(optional),
}).annotate({ identifier: "SessionNavigation.Page" })
export interface Page extends Schema.Schema.Type<typeof Page> {}
