export * as Worktree from "./worktree.js"

import { Schema } from "effect"
import { durable, ephemeral, inventory } from "./event.js"
import { AbsolutePath, optional } from "./schema.js"
import { Project } from "./project.js"

export const StrategyID = Schema.Trim.pipe(Schema.check(Schema.isNonEmpty()), Schema.brand("Worktree.StrategyID"))
export type StrategyID = typeof StrategyID.Type

export const CreateInput = Schema.Struct({
  strategy: optional(StrategyID),
  from: optional(AbsolutePath),
  branch: optional(Schema.Trim.pipe(Schema.check(Schema.isNonEmpty()))),
  directory: optional(AbsolutePath).annotate({
    description:
      "Parent directory for the new worktree. Uses the location's configuration, then defaults to the server's data directory under worktree/<first six project ID characters>.",
  }),
  name: optional(Schema.String),
}).annotate({ identifier: "Worktree.CreateInput" })
export interface CreateInput extends Schema.Schema.Type<typeof CreateInput> {}

export const RemoveInput = Schema.Struct({
  directory: AbsolutePath,
  force: Schema.Boolean,
}).annotate({ identifier: "Worktree.RemoveInput" })
export interface RemoveInput extends Schema.Schema.Type<typeof RemoveInput> {}

export const DeleteInput = Schema.Struct({
  ...RemoveInput.fields,
  identity: Schema.String,
  branch: Schema.NullOr(Schema.String),
  remote: optional(
    Schema.Struct({
      name: Schema.String,
      branch: Schema.String,
    }),
  ),
  deleteLocalBranch: optional(Schema.Boolean),
  deleteRemoteBranch: optional(Schema.Boolean),
}).annotate({ identifier: "Worktree.DeleteInput" })
export interface DeleteInput extends Schema.Schema.Type<typeof DeleteInput> {}

export const RemovalOption = Schema.Struct({
  name: Schema.String,
}).annotate({ identifier: "Worktree.RemovalOption" })
export interface RemovalOption extends Schema.Schema.Type<typeof RemovalOption> {}

export const RemoteRemovalOption = Schema.Struct({
  name: Schema.String,
  branch: Schema.String,
}).annotate({ identifier: "Worktree.RemoteRemovalOption" })
export interface RemoteRemovalOption extends Schema.Schema.Type<typeof RemoteRemovalOption> {}

export const Inspection = Schema.Struct({
  directory: AbsolutePath,
  identity: Schema.String,
  branch: optional(Schema.String),
  dirty: Schema.Boolean,
  localBranch: optional(RemovalOption),
  remoteBranch: optional(RemoteRemovalOption),
}).annotate({ identifier: "Worktree.Inspection" })
export interface Inspection extends Schema.Schema.Type<typeof Inspection> {}

export const CleanupResult = Schema.Struct({
  name: Schema.String,
  remote: optional(Schema.String),
  deleted: Schema.Boolean,
  error: optional(Schema.String),
}).annotate({ identifier: "Worktree.CleanupResult" })
export interface CleanupResult extends Schema.Schema.Type<typeof CleanupResult> {}

export const RemoveResult = Schema.Struct({
  directory: AbsolutePath,
  localBranch: optional(CleanupResult),
  remoteBranch: optional(CleanupResult),
}).annotate({ identifier: "Worktree.RemoveResult" })
export interface RemoveResult extends Schema.Schema.Type<typeof RemoveResult> {}

export const Info = Schema.Struct({
  directory: AbsolutePath,
}).annotate({ identifier: "Worktree.Info" })
export interface Info extends Schema.Schema.Type<typeof Info> {}

export const Directory = Schema.Struct({
  directory: AbsolutePath,
  strategy: optional(Schema.String),
}).annotate({ identifier: "Worktree.Directory" })
export interface Directory extends Schema.Schema.Type<typeof Directory> {}

export const ListEntry = Schema.Struct({
  directory: AbsolutePath,
  type: Schema.Literals(["root", "worktree"]),
}).annotate({ identifier: "Worktree.ListEntry" })
export interface ListEntry extends Schema.Schema.Type<typeof ListEntry> {}

export class OperationError extends Schema.TaggedError<OperationError>()("Worktree.OperationError", {
  message: Schema.String,
  forceRequired: optional(Schema.Boolean),
}) {}

export const List = Schema.Array(Directory).annotate({ identifier: "Worktree.List" })
export type List = typeof List.Type

const Updated = ephemeral({
  type: "worktree.updated",
  schema: { projectID: Project.ID },
})

const Resolved = durable({
  type: "worktree.resolved",
  durable: { aggregate: "projectID", version: 1 },
  schema: {
    projectID: Project.ID,
    directory: AbsolutePath,
    previous: Project.ID,
    adopted: optional(Schema.Array(Project.ID)),
  },
})

export const Event = { Updated, Resolved, Definitions: inventory(Updated, Resolved) }

export function adopt(
  session: { readonly projectID: string; readonly directory: string; readonly workspaceID?: string },
  event: {
    readonly projectID: string
    readonly directory: string
    readonly previous: string
    readonly adopted?: ReadonlyArray<string>
  },
) {
  if (session.workspaceID) return
  if (
    session.projectID !== event.previous &&
    session.projectID !== Project.ID.global &&
    !event.adopted?.includes(session.projectID)
  )
    return
  if (session.projectID === event.projectID) return
  const normalize = (value: string) =>
    value
      .replaceAll("\\", "/")
      .split("/")
      .reduce((result, segment) => {
        if (!segment || segment === ".") return result
        if (segment === "..") return result.slice(0, result.lastIndexOf("/"))
        return `${result}/${segment}`
      }, "")
  const directory = normalize(session.directory)
  const root = normalize(event.directory)
  const windows = /^\/[a-z]:/i.test(root)
  const key = windows ? directory.toLowerCase() : directory
  const parent = windows ? root.toLowerCase() : root
  if (key !== parent && !key.startsWith(parent + "/")) return
  return {
    projectID: event.projectID,
    subpath: key === parent ? undefined : directory.slice(root.length + 1),
  }
}
