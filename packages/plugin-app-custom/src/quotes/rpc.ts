export * as Quotes from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Schema } from "effect"

/**
 * Pending chat quotes (selected assistant text plus a user comment) shared by every client of one server.
 * Sent quotes stay in the carrying user message's `metadata.quotes`; this store holds only drafts.
 * The full contract, including anchor resolution and migration, lives in `docs/quotes.md`.
 */
export const limits = {
  quotesPerSession: 100,
  idLength: 128,
  textLength: 32_768,
  anchorContext: 256,
  commentPromptBytes: 262_144,
  attachmentsPerQuote: 10,
  attachmentBytes: 20 * 1024 * 1024,
  sessionAttachmentBytes: 64 * 1024 * 1024,
  attachmentGraceMs: 60 * 60 * 1000,
  sentHistory: 1000,
  dismissed: 1000,
}

const Text = Schema.String.check(Schema.isMaxLength(limits.textLength))
const Identifier = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(limits.idLength))
const Context = Schema.String.check(Schema.isMaxLength(limits.anchorContext))
const Offset = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))
const Time = Schema.Number

export const ID = Identifier.annotate({ identifier: "Quotes.ID" })
export type ID = typeof ID.Type

/** Lowercase hex SHA-256 of the attachment bytes, computed by the server; equal bytes share one ID. */
export const AttachmentID = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)).annotate({
  identifier: "Quotes.AttachmentID",
})
export type AttachmentID = typeof AttachmentID.Type

const Mime = Schema.String.check(Schema.isMaxLength(255), Schema.isPattern(/^[\w.+-]+\/[\w.+-]+$/))
const Filename = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(255))

/**
 * Offsets are UTF-16 code units, `[start, end)`. `coordinate` names the text they count: `rendered` (absent on
 * web drafts) is the plain text of the rendered part, `source` is the part's raw Markdown. `prefix`/`suffix` are up
 * to 256 characters of rendered plain text around the selection, used to resolve the anchor in the other
 * coordinate system.
 */
export interface Anchor extends Schema.Schema.Type<typeof Anchor> {}
export const Anchor = Schema.Struct({
  start: Offset,
  end: Offset,
  exact: Text,
  coordinate: optional(Schema.Literals(["rendered", "source"])),
  prefix: optional(Context),
  suffix: optional(Context),
})
  .check(Schema.makeFilter((anchor) => anchor.end >= anchor.start || "anchor end must not precede start"))
  .annotate({ identifier: "Quotes.Anchor" })

export interface Attachment extends Schema.Schema.Type<typeof Attachment> {}
export const Attachment = Schema.Struct({
  id: AttachmentID,
  mime: Mime,
  filename: optional(Filename),
  size: Schema.Int,
}).annotate({ identifier: "Quotes.Attachment" })

const QuoteFields = {
  id: ID,
  /** Quoted assistant message and text part. */
  messageID: Identifier,
  partID: Identifier,
  /** Copyable quoted text, as the client shows it. */
  text: Text,
  comment: Text,
  /** Opaque composer parts of the comment (web `Prompt` shape); attachments reference `Attachment.id`. */
  commentPrompt: optional(Schema.Array(Schema.Json)),
  anchor: optional(Anchor),
}

export interface QuoteInput extends Schema.Schema.Type<typeof QuoteInput> {}
export const QuoteInput = Schema.Struct({
  ...QuoteFields,
  /** IDs returned by `upload`, in display order. */
  attachments: optional(Schema.Array(AttachmentID).check(Schema.isMaxLength(limits.attachmentsPerQuote))),
}).annotate({ identifier: "Quotes.QuoteInput" })

export interface Quote extends Schema.Schema.Type<typeof Quote> {}
export const Quote = Schema.Struct({
  ...QuoteFields,
  attachments: Schema.Array(Attachment),
  createdAt: Time,
  updatedAt: Time,
  /** Session revision of this quote's last write. */
  revision: Schema.Number,
}).annotate({ identifier: "Quotes.Quote" })

export interface State extends Schema.Schema.Type<typeof State> {}
export const State = Schema.Struct({
  sessionID: Session.ID,
  /** Increases on every change of this session's quotes or dismissals. */
  revision: Schema.Number,
  /** Display order: the number shown next to a quote is its index + 1. */
  quotes: Schema.Array(Quote),
  /** Sent quote IDs whose marks were hidden; `metadata.quotes` of the sent message is unchanged. */
  dismissed: Schema.Array(ID),
}).annotate({ identifier: "Quotes.State" })

const Target = { sessionID: Session.ID }
const Revision = Schema.Struct({ revision: Schema.Number })
const Empty = Schema.Struct({})
const SessionNotFound = Schema.Struct({ sessionID: Schema.String })
const LimitExceeded = Schema.Struct({ limit: Schema.String, max: Schema.Number })
const Ids = Schema.Struct({ ids: Schema.Array(Schema.String) })
const standard = Schema.toStandardSchemaV1

export const Definition = Rpc.define({
  id: "custom.quotes",
  methods: {
    info: {
      input: standard(Empty),
      output: standard(
        Schema.Struct({
          version: Schema.Literal(1),
          limits: Schema.Struct({
            quotesPerSession: Schema.Number,
            textLength: Schema.Number,
            anchorContext: Schema.Number,
            commentPromptBytes: Schema.Number,
            attachmentsPerQuote: Schema.Number,
            attachmentBytes: Schema.Number,
            sessionAttachmentBytes: Schema.Number,
          }),
        }),
      ),
    },
    list: { input: standard(Schema.Struct(Target)), output: standard(State) },
    save: {
      input: standard(Schema.Struct({ ...Target, quote: QuoteInput })),
      output: standard(Schema.Struct({ revision: Schema.Number, quote: Quote })),
      errors: {
        session_not_found: standard(SessionNotFound),
        limit_exceeded: standard(LimitExceeded),
        attachment_missing: standard(Ids),
        already_sent: standard(Ids),
      },
    },
    remove: { input: standard(Schema.Struct({ ...Target, id: ID })), output: standard(Revision) },
    clear: {
      input: standard(
        Schema.Struct({
          ...Target,
          /** Omit to clear every quote of the session. */
          ids: optional(Schema.Array(ID)),
          /** `sent`: the quotes went out in a prompt the server admitted; they can never be saved again. */
          reason: Schema.Literals(["sent", "discarded"]),
        }),
      ),
      output: standard(Revision),
    },
    import: {
      input: standard(
        Schema.Struct({
          ...Target,
          quotes: Schema.Array(QuoteInput).check(Schema.isMaxLength(limits.quotesPerSession)),
        }),
      ),
      output: standard(Schema.Struct({ state: State, imported: Schema.Array(ID), skipped: Schema.Array(ID) })),
      errors: {
        session_not_found: standard(SessionNotFound),
        limit_exceeded: standard(LimitExceeded),
        attachment_missing: standard(Ids),
      },
    },
    dismiss: {
      input: standard(Schema.Struct({ ...Target, ids: Schema.Array(ID).check(Schema.isMaxLength(limits.dismissed)) })),
      output: standard(Revision),
    },
    upload: {
      input: standard(
        Schema.Struct({
          ...Target,
          mime: Mime,
          filename: optional(Filename),
          /** Standard base64 of the bytes. */
          data: Schema.String.check(Schema.isMaxLength(Math.ceil(limits.attachmentBytes / 3) * 4)),
        }),
      ),
      output: standard(Attachment),
      errors: {
        session_not_found: standard(SessionNotFound),
        limit_exceeded: standard(LimitExceeded),
        invalid_data: standard(Empty),
      },
    },
    attachment: {
      input: standard(Schema.Struct({ ...Target, id: AttachmentID })),
      output: standard(Schema.Struct({ ...Attachment.fields, data: Schema.String })),
      errors: { not_found: standard(Schema.Struct({ id: Schema.String })) },
    },
  },
  events: {
    updated: { schema: standard(Schema.Struct({ sessionID: Session.ID, revision: Schema.Number })) },
  },
})
