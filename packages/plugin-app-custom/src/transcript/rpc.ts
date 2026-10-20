export * as Transcript from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { optional, PositiveInt } from "@opencode/schema/schema"
import { Schema } from "effect"

export const ListInput = Schema.Struct({
  sessionID: Session.ID,
  limit: Schema.optionalKey(PositiveInt.check(Schema.isLessThanOrEqualTo(200))),
  order: Schema.optionalKey(Schema.Literals(["asc", "desc"])),
  cursor: Schema.optionalKey(Schema.String),
})

export const Page = Schema.Struct({
  data: Schema.Array(SessionMessage.Info),
  cursor: Schema.Struct({ previous: optional(Schema.String), next: optional(Schema.String) }),
})

export const Definition = Rpc.define({
  id: "custom.transcript",
  methods: {
    list: {
      input: Schema.toStandardSchemaV1(ListInput),
      output: Schema.toStandardSchemaV1(Schema.toEncoded(Page)),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
  },
  events: {},
})

type Content = { readonly type: "text" } | { readonly type: "file"; readonly uri: string; readonly mime: string }

/**
 * Empties inline tool-result payloads while keeping their media type. The web transcript never
 * displays them (the read card loads its image by path); stored history keeps the originals for the model.
 */
export function omitInlineMedia<T extends Content>(content: readonly [T, ...T[]]): [T, ...T[]] {
  const [first, ...rest] = content
  return [empty(first), ...rest.map(empty)]
}

function empty<T extends Content>(item: T): T {
  if (item.type !== "file" || !item.uri.startsWith("data:")) return item
  return { ...item, uri: `data:${item.mime};base64,` }
}
