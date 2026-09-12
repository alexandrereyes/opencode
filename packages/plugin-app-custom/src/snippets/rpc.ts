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
        conflict: Schema.toStandardSchemaV1(Schema.Struct({ name: Schema.String })),
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
