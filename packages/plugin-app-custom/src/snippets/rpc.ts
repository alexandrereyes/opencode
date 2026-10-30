export * as Snippets from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Project } from "@opencode/schema/project"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

export const ID = Schema.NonEmptyString.annotate({ identifier: "Snippets.ID" })
export type ID = typeof ID.Type

export interface Info extends Schema.Schema.Type<typeof Info> {}
export const Info = Schema.Struct({
  id: ID,
  name: Schema.String.check(Schema.isPattern(/^[^\s#]+$/)),
  description: Schema.String,
  aliases: Schema.Array(Schema.String),
  content: Schema.String.check(Schema.isPattern(/\S/)),
  project: optional(Project.ID),
}).annotate({ identifier: "Snippets.Info" })

const Empty = Schema.Struct({})

/**
 * `save` refused a handle that another snippet of the same scope already has (rev. 2026-10-30: aliases count too).
 * `name` is the saved snippet's name; `field` and `value` say which of its handles collided, `existing` with whom.
 * Older servers send only `name`.
 */
export const Conflict = Schema.Struct({
  name: Schema.String,
  field: optional(Schema.Literals(["name", "alias"])),
  value: optional(Schema.String),
  existing: optional(Schema.String),
})

/** `save` refused a malformed name or alias, or an alias repeated in the same snippet (rev. 2026-10-30). */
export const Invalid = Schema.Struct({
  field: Schema.Literals(["name", "aliases"]),
  reason: Schema.Literals(["format", "duplicate"]),
  value: Schema.String,
})

export const Definition = Rpc.define({
  id: "custom.snippets",
  methods: {
    list: {
      input: Schema.toStandardSchemaV1(Empty),
      output: Schema.toStandardSchemaV1(Schema.Struct({ items: Schema.Array(Info) })),
    },
    save: {
      input: Schema.toStandardSchemaV1(Info),
      output: Schema.toStandardSchemaV1(Info),
      errors: {
        conflict: Schema.toStandardSchemaV1(Conflict),
        invalid: Schema.toStandardSchemaV1(Invalid),
      },
    },
    remove: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ id: ID })),
      output: Schema.toStandardSchemaV1(Empty),
    },
  },
  events: {
    updated: { schema: Schema.toStandardSchemaV1(Empty) },
  },
})
