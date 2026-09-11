export * as WorktreeGit from "./git.js"

import { Effect, Option } from "effect"
import { Worktree } from "@opencode/schema/worktree"
import { FSUtil } from "@opencode/util/fs-util"
import { Git } from "../git.js"
import { canonical, DirectoryUnavailableError } from "./directory.js"
import type { ListEntry, Strategy } from "../worktree.js"

export const make = Effect.gen(function* () {
  const fs = yield* FSUtil.Service
  const git = yield* Git.Service

  const inspect = Effect.fn("Worktree.Git.inspect")(function* (directory: Worktree.RemoveInput["directory"]) {
    const repository = yield* git.repo.discover(directory)
    if (!repository) return yield* new DirectoryUnavailableError({ directory })
    const entries = yield* git.worktree.list(repository)
    const linked = yield* Effect.findFirst(entries, (entry) =>
      canonical(fs, entry.directory).pipe(Effect.map((candidate) => candidate === directory && entry.kind === "linked")),
    )
    if (Option.isNone(linked))
      return yield* new Worktree.OperationError({ message: `Directory is not a linked Git worktree: ${directory}` })
    const metadata = yield* git.worktree.inspect(repository)
    return {
      directory,
      identity: metadata.identity,
      branch: metadata.branch,
      dirty: metadata.dirty,
      localBranch:
        metadata.branch && metadata.defaultBranches.length && !metadata.defaultBranches.includes(metadata.branch)
          ? { name: metadata.branch }
          : undefined,
      remoteBranch:
        metadata.upstream?.defaultBranch && metadata.upstream.branch !== metadata.upstream.defaultBranch
          ? { name: metadata.upstream.remote, branch: metadata.upstream.branch }
          : undefined,
    } satisfies Worktree.Inspection
  })

  const cleanup = <A>(
    name: string,
    remote: string | undefined,
    operation: Effect.Effect<A, Git.WorktreeError>,
  ): Effect.Effect<Worktree.CleanupResult> =>
    operation.pipe(
      Effect.as({ name, remote, deleted: true }),
      Effect.catch((error) => Effect.succeed({ name, remote, deleted: false, error: error.message })),
    )

  return {
    id: Worktree.StrategyID.make("git"),
    create: Effect.fn("Worktree.Git.create")(function* (input) {
      const repository = yield* git.repo.discover(input.sourceDirectory)
      if (!repository) return yield* new DirectoryUnavailableError({ directory: input.sourceDirectory })
      yield* git.worktree.create({ repository, directory: input.directory, ref: input.branch })
      return { directory: yield* canonical(fs, input.directory) }
    }),
    remove: Effect.fn("Worktree.Git.remove")(function* (input) {
      const inspection = yield* inspect(input.directory)
      const options = "branch" in input ? input : undefined
      if (options && options.identity !== inspection.identity)
        return yield* new Worktree.OperationError({ message: "The worktree identity changed" })
      if (options && (options.branch ?? undefined) !== inspection.branch)
        return yield* new Worktree.OperationError({ message: "The worktree branch changed" })
      if (options?.deleteLocalBranch && options.branch !== inspection.localBranch?.name)
        return yield* new Worktree.OperationError({ message: "The local branch is unavailable or changed" })
      if (
        options?.deleteRemoteBranch &&
        (!options.remote ||
          options.remote.name !== inspection.remoteBranch?.name ||
          options.remote.branch !== inspection.remoteBranch.branch)
      )
        return yield* new Worktree.OperationError({ message: "The remote branch is unavailable or changed" })
      const repository = yield* git.repo.discover(input.directory)
      if (!repository) return yield* new DirectoryUnavailableError({ directory: input.directory })
      yield* git.worktree.remove({ repository, directory: input.directory, force: input.force })
      return {
        directory: input.directory,
        localBranch:
          options?.deleteLocalBranch && inspection.localBranch
            ? yield* cleanup(
                inspection.localBranch.name,
                undefined,
                git.worktree.deleteLocalBranch(repository, inspection.localBranch.name),
              )
            : undefined,
        remoteBranch:
          options?.deleteRemoteBranch && inspection.remoteBranch
            ? yield* cleanup(
                inspection.remoteBranch.branch,
                inspection.remoteBranch.name,
                git.worktree.deleteRemoteBranch(repository, {
                  remote: inspection.remoteBranch.name,
                  branch: inspection.remoteBranch.branch,
                }),
              )
            : undefined,
      } satisfies Worktree.RemoveResult
    }),
    inspect,
    list: Effect.fn("Worktree.Git.list")(function* (directory) {
      const repository = yield* git.repo.discover(directory)
      if (!repository) return yield* new DirectoryUnavailableError({ directory })
      const entries = yield* git.worktree.list(repository)
      return yield* Effect.forEach(entries, (entry) =>
        canonical(fs, entry.directory).pipe(
          Effect.map((directory) => ({ directory, type: entry.kind === "main" ? "root" : "worktree" }) as const),
          Effect.catchTag("Worktree.DirectoryUnavailableError", () => Effect.undefined),
        ),
      ).pipe(Effect.map((items) => items.filter((item): item is ListEntry => item !== undefined)))
    }),
  } satisfies Strategy
})
