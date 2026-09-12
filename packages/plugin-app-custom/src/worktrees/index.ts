import { randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import path from "node:path"
import { Plugin } from "@opencode/plugin/effect"
import { AbsolutePath } from "@opencode/schema/schema"
import { Effect } from "effect"
import { Worktrees } from "./rpc.js"

interface Repository {
  readonly worktree: string
  readonly gitDirectory: string
  readonly commonDirectory: string
}

interface CommandResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

export interface WorktreeContext {
  readonly list: Plugin.Context["worktree"]["list"]
  readonly remove: Plugin.Context["worktree"]["remove"]
}

export const registerWorktrees = Effect.fn("Worktrees.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(Worktrees.Definition, {
      inspect: (input, context) =>
        inspectWorktree({ list: ctx.worktree.list, remove: ctx.worktree.remove }, input.directory).pipe(
          Effect.mapError((error) => operationFailed(error, context.error)),
        ),
      delete: (input, context) =>
        removeWorktree({ list: ctx.worktree.list, remove: ctx.worktree.remove }, input).pipe(
          Effect.mapError((error) => operationFailed(error, context.error)),
        ),
    })
    .pipe(Effect.orDie)
})

export function inspectWorktree(ctx: WorktreeContext, directory: string) {
  return Effect.gen(function* () {
    const target = yield* Effect.tryPromise(() => canonical(directory)).pipe(
      Effect.mapError((error) => new Error(message(error))),
    )
    const inventory = yield* ctx.list().pipe(Effect.mapError((error) => new Error(message(error))))
    return yield* Effect.tryPromise({
      try: async (signal) => {
        const stored = await findStored(inventory, target)
        if (stored.strategy !== "git") throw new Error(`Worktree strategy ${stored.strategy} cannot inspect removal`)
        const repository = await discover(target, signal)
        const entries = await worktreeList(repository, signal)
        const linked = entries.find((entry) => entry.directory === target && entry.kind === "linked")
        if (!linked) throw new Error(`Directory is not a linked Git worktree: ${target}`)
        await verifyOwner(inventory, entries, target)
        const status = await command(["git", "status", "--porcelain"], repository.worktree, signal)
        requireSuccess(status, "Failed to inspect Git worktree")
        const identity = await identityFor(repository.gitDirectory)
        const branch = await optionalCommand(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], target, signal)
        const remotes = (await optionalCommand(["git", "remote"], target, signal))?.split(/\r?\n/).filter(Boolean) ?? []
        const defaults = (
          await Promise.all(
            remotes.map(async (remote) => {
              const ref = await optionalCommand(["git", "symbolic-ref", `refs/remotes/${remote}/HEAD`], target, signal)
              const prefix = `refs/remotes/${remote}/`
              return ref?.startsWith(prefix) ? ref.slice(prefix.length) : undefined
            }),
          )
        ).filter((item): item is string => !!item)
        if (!branch) return { directory: target, identity, dirty: status.stdout.length > 0 }
        const upstream = await optionalCommand(
          ["git", "for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)", `refs/heads/${branch}`],
          target,
          signal,
        )
        const [remote, upstreamRef] = upstream?.split("\0") ?? []
        const upstreamBranch = upstreamRef?.replace(/^refs\/heads\//, "")
        const remoteExists =
          remote && remote !== "."
            ? await optionalCommand(["git", "remote", "get-url", remote], target, signal)
            : undefined
        const defaultBranch = remote
          ? (await optionalCommand(["git", "symbolic-ref", `refs/remotes/${remote}/HEAD`], target, signal))?.replace(
              `refs/remotes/${remote}/`,
              "",
            )
          : undefined
        return {
          directory: target,
          identity,
          branch,
          dirty: status.stdout.length > 0,
          localBranch: defaults.length && !defaults.includes(branch) ? { name: branch } : undefined,
          remoteBranch:
            remoteExists && remote && upstreamBranch && defaultBranch && upstreamBranch !== defaultBranch
              ? { name: remote, branch: upstreamBranch }
              : undefined,
        }
      },
      catch: (cause) => new Error(message(cause)),
    })
  })
}

export function removeWorktree(ctx: WorktreeContext, input: Worktrees.DeleteInput) {
  return Effect.gen(function* () {
    const current = yield* inspectWorktree(ctx, input.directory)
    if (input.identity !== current.identity) return yield* Effect.fail(new Error("The worktree identity changed"))
    if ((input.branch ?? undefined) !== current.branch)
      return yield* Effect.fail(new Error("The worktree branch changed"))
    if (input.deleteLocalBranch && input.branch !== current.localBranch?.name)
      return yield* Effect.fail(new Error("The local branch is unavailable or changed"))
    if (
      input.deleteRemoteBranch &&
      (!input.remote ||
        input.remote.name !== current.remoteBranch?.name ||
        input.remote.branch !== current.remoteBranch.branch)
    )
      return yield* Effect.fail(new Error("The remote branch is unavailable or changed"))
    const repository = yield* Effect.tryPromise((signal) => discover(current.directory, signal)).pipe(
      Effect.mapError((error) => new Error(message(error))),
    )
    yield* ctx
      .remove({ directory: current.directory, force: input.force })
      .pipe(Effect.mapError((error) => new Error(message(error), { cause: error })))
    const cleanup = (
      name: string,
      remote: string | undefined,
      args: string[],
    ): Effect.Effect<Worktrees.CleanupResult> =>
      Effect.tryPromise(async (signal) => {
        const result = await command(args, repository.commonDirectory, signal)
        return result.exitCode === 0
          ? { name, remote, deleted: true as const }
          : {
              name,
              remote,
              deleted: false as const,
              error: result.stderr.trim() || result.stdout.trim() || "Git failed",
            }
      }).pipe(Effect.catch((error) => Effect.succeed({ name, remote, deleted: false, error: message(error) })))
    return {
      directory: current.directory,
      localBranch:
        input.deleteLocalBranch && current.localBranch
          ? yield* cleanup(current.localBranch.name, undefined, [
              "git",
              "--git-dir",
              repository.commonDirectory,
              "branch",
              "-d",
              "--",
              current.localBranch.name,
            ])
          : undefined,
      remoteBranch:
        input.deleteRemoteBranch && current.remoteBranch
          ? yield* cleanup(current.remoteBranch.branch, current.remoteBranch.name, [
              "git",
              "--git-dir",
              repository.commonDirectory,
              "push",
              "--delete",
              current.remoteBranch.name,
              current.remoteBranch.branch,
            ])
          : undefined,
    }
  })
}

async function findStored(inventory: readonly { directory: string; strategy?: string }[], directory: string) {
  const entries = await Promise.all(
    inventory.map(async (item) => ({ ...item, canonical: await canonical(item.directory) })),
  )
  const stored = entries.find((item) => item.canonical === directory)
  if (!stored?.strategy) throw new Error(`Invalid worktree directory: ${directory}`)
  return stored
}

async function verifyOwner(
  inventory: readonly { directory: string; strategy?: string }[],
  entries: readonly { directory: string; kind: "main" | "linked" }[],
  target: string,
) {
  const owner = entries.find((entry) => entry.kind === "main")?.directory
  const roots = await Promise.all(inventory.filter((item) => !item.strategy).map((item) => canonical(item.directory)))
  if (!owner || !roots.some((root) => root === owner))
    throw new Error(`Directory is not a worktree of the requested project: ${target}`)
}

async function discover(directory: string, signal: AbortSignal): Promise<Repository> {
  const result = await command(
    ["git", "rev-parse", "--git-dir", "--git-common-dir", "--show-toplevel"],
    directory,
    signal,
  )
  requireSuccess(result, `Worktree directory unavailable: ${directory}`)
  const [gitDirectory, commonDirectory, worktree] = result.stdout.split(/\r?\n/)
  if (!gitDirectory || !commonDirectory || !worktree) throw new Error(`Worktree directory unavailable: ${directory}`)
  return {
    worktree: path.resolve(directory, worktree),
    gitDirectory: path.resolve(directory, gitDirectory),
    commonDirectory: path.resolve(directory, commonDirectory),
  }
}

async function worktreeList(repository: Repository, signal: AbortSignal) {
  const result = await command(["git", "worktree", "list", "--porcelain"], repository.worktree, signal)
  requireSuccess(result, "Failed to list Git worktrees")
  return Promise.all(
    result.stdout
      .trim()
      .split(/\r?\n\r?\n/)
      .flatMap((block, index) => {
        const directory = block
          .split(/\r?\n/)
          .find((line) => line.startsWith("worktree "))
          ?.slice(9)
          .trim()
        return directory ? [{ directory, kind: index === 0 ? ("main" as const) : ("linked" as const) }] : []
      })
      .map(async (entry) => ({ ...entry, directory: await canonical(entry.directory) })),
  )
}

async function identityFor(gitDirectory: string) {
  const file = path.join(gitDirectory, "opencode.identity")
  try {
    return (await fs.readFile(file, "utf8")).trim()
  } catch (error) {
    if (!(error instanceof globalThis.Error && "code" in error && error.code === "ENOENT")) throw error
  }
  const identity = randomUUID()
  try {
    await fs.writeFile(file, identity, { flag: "wx", mode: 0o600 })
    return identity
  } catch (error) {
    if (!(error instanceof globalThis.Error && "code" in error && error.code === "EEXIST")) throw error
    return (await fs.readFile(file, "utf8")).trim()
  }
}

async function command(args: string[], cwd: string, signal: AbortSignal): Promise<CommandResult> {
  const child = Bun.spawn(args, { cwd, signal, stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  return { exitCode, stdout, stderr }
}

async function canonical(directory: string) {
  return AbsolutePath.make(path.normalize(await fs.realpath(directory)))
}

async function optionalCommand(args: string[], cwd: string, signal: AbortSignal) {
  const result = await command(args, cwd, signal)
  return result.exitCode === 0 ? result.stdout.trim() || undefined : undefined
}

function requireSuccess(result: CommandResult, fallback: string) {
  if (result.exitCode !== 0) throw new Error(result.stderr.trim() || result.stdout.trim() || fallback)
}

export function operationFailed<A>(
  error: globalThis.Error,
  create: (type: "operation_failed", message: string, data: { message: string; forceRequired?: boolean }) => A,
) {
  return create("operation_failed", error.message, {
    message: error.message,
    forceRequired: forceRequired(error),
  })
}

function forceRequired(error: globalThis.Error) {
  const values: unknown[] = [error, error.cause]
  for (const value of values) {
    if (typeof value !== "object" || value === null) continue
    if ("forceRequired" in value && value.forceRequired === true) return true
    if (!("data" in value)) continue
    const data = value.data
    if (typeof data === "object" && data !== null && "forceRequired" in data && data.forceRequired === true) return true
  }
  return /contains modified or untracked files|is dirty/i.test(error.message) ? true : undefined
}

function message(value: unknown) {
  return value instanceof globalThis.Error ? value.message : String(value)
}
