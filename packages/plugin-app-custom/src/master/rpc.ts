export * as Master from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Agent } from "@opencode/schema/agent"
import { Model } from "@opencode/schema/model"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Schema } from "effect"
import { Preferences } from "../preferences/rpc.js"

export const agentID = Agent.ID.make("mestra")

export const Info = Schema.Struct({
  version: Schema.Literal(1),
  agent: Schema.String,
  model: Schema.optionalKey(Model.Ref),
})

export const EnsureInput = Schema.Struct({
  model: Schema.optionalKey(Model.Ref),
  /** A voice call is about to delegate: the master gets the voice-call note until the call ends. */
  voice: Schema.optionalKey(Schema.Boolean),
})
export const Ensured = Schema.Struct({
  sessionID: Session.ID,
  directory: AbsolutePath,
  created: Schema.Boolean,
  preferences: Preferences.Profile,
})

export const Definition = Rpc.define({
  id: "custom.master",
  methods: {
    info: { input: Schema.toStandardSchemaV1(Schema.Struct({})), output: Schema.toStandardSchemaV1(Info) },
    ensure: {
      input: Schema.toStandardSchemaV1(EnsureInput),
      output: Schema.toStandardSchemaV1(Ensured),
      errors: { operation_failed: Schema.toStandardSchemaV1(Schema.Struct({ message: Schema.String })) },
    },
  },
  events: {},
})
