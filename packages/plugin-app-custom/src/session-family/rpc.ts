export * as Family from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { SessionFamily } from "@opencode/schema/session-family"
import { Session } from "@opencode/schema/session"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { Schema } from "effect"
import { Navigation } from "../navigation/rpc.js"

export const Snapshot = Schema.Struct({
  count: SessionFamily.Info.fields.count,
  cost: SessionFamily.Info.fields.cost,
  active: Schema.toEncoded(SessionFamily.Info.fields.active),
  forms: Schema.Array(Schema.toEncoded(Form.Info)),
  permissions: Schema.Array(Schema.toEncoded(Permission.Request)),
  /**
   * The Progresso of each descendant showing one, by Session ID (rev. 2026-10-30, `docs/progress.md`): the same
   * rule and source as the Sessões rows. Absent when none shows one, and on older servers.
   */
  progress: Schema.Record(Schema.String, Navigation.Progress).pipe(Schema.optional),
})
export type Snapshot = typeof Snapshot.Type

export const Page = Schema.Struct({
  data: Schema.toEncoded(SessionFamily.Info.fields.data),
  next: SessionFamily.Info.fields.next,
})
export type Page = typeof Page.Type

export const Definition = Rpc.define({
  id: "custom.session-family",
  methods: {
    revert: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({
          sessionID: Session.ID,
          cutoff: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0)),
        }),
      ),
      output: Schema.toStandardSchemaV1(SessionFamily.Boundaries),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
    clear: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })),
      output: Schema.toStandardSchemaV1(SessionFamily.Boundaries),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
    snapshot: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })),
      output: Schema.toStandardSchemaV1(Snapshot),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
    page: {
      input: Schema.toStandardSchemaV1(SessionFamily.Input),
      output: Schema.toStandardSchemaV1(Page),
      errors: { read_failed: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Session.ID })) },
    },
  },
  events: {},
})
