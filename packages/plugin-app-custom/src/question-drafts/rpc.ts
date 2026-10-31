export * as QuestionDrafts from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Schema } from "effect"

/**
 * Unsent answers of a pending question form (a `form.created` request), shared by every client of one server so a
 * form started on one device can be finished on another. The server forgets a draft when its form is answered or
 * cancelled, its session is archived or deleted, or nobody touched it for `staleDays`.
 * The full contract lives in `docs/question-drafts.md`.
 */
export const limits = {
  draftsPerSession: 50,
  fieldsPerDraft: 100,
  itemsPerField: 100,
  keyLength: 256,
  textLength: 32_768,
  staleDays: 14,
}

const Key = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(limits.keyLength))
const Text = Schema.String.check(Schema.isMaxLength(limits.textLength))
const Items = Schema.Array(Text).check(Schema.isMaxLength(limits.itemsPerField))

/** One question's unsent answer: the options marked, the free text and a multiple choice's own added items. */
export interface Field extends Schema.Schema.Type<typeof Field> {}
export const Field = Schema.Struct({
  selected: Items,
  text: Text,
  added: Items,
}).annotate({ identifier: "QuestionDrafts.Field" })

export interface Draft extends Schema.Schema.Type<typeof Draft> {}
export const Draft = Schema.Struct({
  requestID: Key,
  fields: Schema.Record(Key, Field),
  updatedAt: Schema.Number,
  /** Session revision of this draft's last write. */
  revision: Schema.Number,
}).annotate({ identifier: "QuestionDrafts.Draft" })

const Target = { sessionID: Session.ID, requestID: Key }
const standard = Schema.toStandardSchemaV1

export const Definition = Rpc.define({
  id: "custom.question-drafts",
  methods: {
    get: {
      input: standard(Schema.Struct(Target)),
      output: standard(Schema.Struct({ draft: Schema.NullOr(Draft) })),
    },
    /** Merges the given fields into the draft; fields not sent keep their stored value. */
    save: {
      input: standard(
        Schema.Struct({
          ...Target,
          fields: Schema.Record(Key, Field),
          /** Opaque ID of the saving client, echoed in `updated` so it can skip its own change. */
          client: optional(Key),
        }),
      ),
      output: standard(Draft),
      errors: {
        session_not_found: standard(Schema.Struct({ sessionID: Schema.String })),
        limit_exceeded: standard(Schema.Struct({ limit: Schema.String, max: Schema.Number })),
      },
    },
    clear: {
      input: standard(Schema.Struct({ ...Target, client: optional(Key) })),
      output: standard(Schema.Struct({ revision: Schema.Number })),
    },
  },
  events: {
    updated: {
      schema: standard(
        Schema.Struct({
          sessionID: Session.ID,
          requestID: Key,
          revision: Schema.Number,
          /** The draft is gone (cleared, answered, cancelled). */
          cleared: Schema.Boolean,
          client: optional(Key),
        }),
      ),
    },
  },
})
