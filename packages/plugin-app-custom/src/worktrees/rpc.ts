export * as Worktrees from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { AbsolutePath, optional } from "@opencode/schema/schema"
import { Schema } from "effect"

export interface DeleteInput extends Schema.Schema.Type<typeof DeleteInput> {}
export const DeleteInput = Schema.Struct({
  directory: AbsolutePath,
  force: Schema.Boolean,
  identity: Schema.String,
  branch: Schema.NullOr(Schema.String),
  remote: optional(Schema.Struct({ name: Schema.String, branch: Schema.String })),
  deleteLocalBranch: optional(Schema.Boolean),
  deleteRemoteBranch: optional(Schema.Boolean),
}).annotate({ identifier: "Worktrees.DeleteInput" })

export interface RemovalOption extends Schema.Schema.Type<typeof RemovalOption> {}
export const RemovalOption = Schema.Struct({ name: Schema.String }).annotate({
  identifier: "Worktrees.RemovalOption",
})

export interface RemoteRemovalOption extends Schema.Schema.Type<typeof RemoteRemovalOption> {}
export const RemoteRemovalOption = Schema.Struct({ name: Schema.String, branch: Schema.String }).annotate({
  identifier: "Worktrees.RemoteRemovalOption",
})

export interface Inspection extends Schema.Schema.Type<typeof Inspection> {}
export const Inspection = Schema.Struct({
  directory: AbsolutePath,
  identity: Schema.String,
  branch: optional(Schema.String),
  dirty: Schema.Boolean,
  localBranch: optional(RemovalOption),
  remoteBranch: optional(RemoteRemovalOption),
}).annotate({ identifier: "Worktrees.Inspection" })

export interface CleanupResult extends Schema.Schema.Type<typeof CleanupResult> {}
export const CleanupResult = Schema.Struct({
  name: Schema.String,
  remote: optional(Schema.String),
  deleted: Schema.Boolean,
  error: optional(Schema.String),
}).annotate({ identifier: "Worktrees.CleanupResult" })

export interface RemoveResult extends Schema.Schema.Type<typeof RemoveResult> {}
export const RemoveResult = Schema.Struct({
  directory: AbsolutePath,
  localBranch: optional(CleanupResult),
  remoteBranch: optional(CleanupResult),
}).annotate({ identifier: "Worktrees.RemoveResult" })

const OperationFailed = Schema.Struct({ message: Schema.String, forceRequired: optional(Schema.Boolean) })

export const Definition = Rpc.define({
  id: "custom.worktrees",
  methods: {
    inspect: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ directory: AbsolutePath })),
      output: Schema.toStandardSchemaV1(Inspection),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
    delete: {
      input: Schema.toStandardSchemaV1(DeleteInput),
      output: Schema.toStandardSchemaV1(RemoveResult),
      errors: { operation_failed: Schema.toStandardSchemaV1(OperationFailed) },
    },
  },
  events: {},
})
