export * as Snippet from "./snippet.js"

import { Schema } from "effect"
import { ephemeral, inventory } from "./event.js"
import { optional } from "./schema.js"
import { Project } from "./project.js"

export const ID = Schema.NonEmptyString.annotate({ identifier: "Snippet.ID" })
export type ID = typeof ID.Type

export const Info = Schema.Struct({
  id: ID,
  name: Schema.String.check(Schema.isPattern(/^[^\s#]+$/)),
  description: Schema.String,
  aliases: Schema.Array(Schema.String),
  content: Schema.String.check(Schema.isPattern(/\S/)),
  project: optional(Project.ID),
}).annotate({ identifier: "Snippet.Info" })
export interface Info extends Schema.Schema.Type<typeof Info> {}

// Current event: invalidates every connected client's server-owned snippet catalog.
const Updated = ephemeral({ type: "snippet.updated", schema: {} })
export const Event = { Updated, Definitions: inventory(Updated) }
