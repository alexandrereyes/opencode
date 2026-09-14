import { OpenCode } from "@opencode/client/promise"
import { Session, SessionMessage } from "@opencode/schema"
import { Flock } from "@opencode/util/flock"
import { createHash } from "node:crypto"
import { lstat, mkdir, realpath, rename } from "node:fs/promises"
import path from "node:path"
import { Schema } from "effect"

const absolute = Schema.String.check(Schema.isPattern(/^\//))
const sha = Schema.String.check(Schema.isPattern(/^[0-9a-f]{40,64}$/))
const remoteBranch = Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9][a-zA-Z0-9._/-]*$/))
const automationBranchName = Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+){0,2}$/))
const Phase = Schema.Literals([
  "planned",
  "worktree-created",
  "merging",
  "merged",
  "validating",
  "validated",
  "committing",
  "committed",
  "pushing",
  "published",
  "resolved",
])

export const UpstreamDeployment = Schema.Struct({
  repository: Schema.NonEmptyString,
  branch: remoteBranch,
  bun: absolute,
  upstream: Schema.NonEmptyString,
  upstreamBranch: remoteBranch,
  worktreeRoot: absolute,
  worktreeName: Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/)),
  validation: Schema.Array(
    Schema.Struct({
      cwd: Schema.String,
      argv: Schema.NonEmptyArray(Schema.NonEmptyString),
    }),
  ),
})

export const UpstreamSyncState = Schema.Struct({
  format: Schema.Literal(2),
  status: Schema.Literals(["active", "blocked", "resolved"]),
  phase: Phase,
  custom: sha,
  upstream: sha,
  worktree: absolute,
  branch: automationBranchName,
  sessionID: Session.ID,
  promptID: SessionMessage.ID,
  sessionCreated: Schema.Boolean,
  promptSent: Schema.Boolean,
  error: Schema.optionalKey(Schema.String),
})

type State = typeof UpstreamSyncState.Type
type Config = typeof UpstreamDeployment.Type
type Checkpoint = State["phase"] | "merge-finished" | "pushed"

export function defaultValidation(bun: string) {
  const typechecks = ["app", "cli", "client", "core", "plugin", "plugin-app-custom", "server"].map((name) => ({
    cwd: `packages/${name}`,
    argv: [bun, "typecheck"],
  }))
  return [
    { cwd: ".", argv: [bun, "install", "--frozen-lockfile"] },
    ...typechecks,
    { cwd: "packages/client", argv: [bun, "run", "check:generated"] },
    { cwd: "packages/plugin-app-custom", argv: [bun, "test"] },
    {
      cwd: "packages/server",
      argv: [bun, "test", "test/after-response.test.ts", "test/rpc-handler-errors.test.ts", "test/process.test.ts"],
    },
    {
      cwd: "packages/cli",
      argv: [
        bun,
        "test",
        "test/tui-updater.test.ts",
        "test/updater-install.test.ts",
        "test/updater-poll.test.ts",
        "src/services/updater.test.ts",
      ],
    },
    { cwd: ".", argv: [bun, "run", "packages/cli/script/build.ts", "--single", "--skip-install"] },
  ]
}

/** Integrates the configured upstream target before release preparation. */
export async function syncUpstream(home: string, options?: { checkpoint?: (phase: Checkpoint) => void }) {
  const config = Schema.decodeUnknownSync(Schema.fromJsonString(UpstreamDeployment))(
    await Bun.file(path.join(home, "deployment.json")).text(),
  )
  await using lock = await Flock.acquire("upstream-sync", { dir: path.join(home, "locks"), timeoutMs: 1_000 })
  const repository = path.join(home, "repository")
  if (!(await Bun.file(path.join(repository, "HEAD")).exists()))
    await requireCommand(["git", "clone", "--bare", "--no-hardlinks", config.repository, repository], home)
  await configureUpstream(repository, config.upstream)
  await fetch(repository, "origin", config.branch)
  await fetch(repository, "upstream", config.upstreamBranch)
  const custom = await revision(repository, `refs/remotes/origin/${config.branch}`)
  const upstream = await revision(repository, `refs/remotes/upstream/${config.upstreamBranch}`)
  const previous = await readState(home)

  if (previous && previous.status !== "resolved")
    return resume({ home, repository, config, state: previous, custom, checkpoint: options?.checkpoint })
  if (previous && (await attemptExists(repository, previous))) {
    if (!(await ancestor(repository, previous.upstream, custom)))
      return block(home, previous, "A persisted resolved attempt still has unpublished Git state")
    const cleaned = await cleanup(repository, previous, custom)
    if (!cleaned) return block(home, previous, "A persisted resolved attempt is not safe to clean")
  }
  if (await ancestor(repository, upstream, custom)) return { status: "ready" as const, custom }

  const state = makeState(custom, upstream, path.join(config.worktreeRoot, `${config.worktreeName}-upstream-merge`))
  await writeState(home, state)
  options?.checkpoint?.("planned")
  return resume({ home, repository, config, state, custom, checkpoint: options?.checkpoint })
}

async function resume(input: {
  home: string
  repository: string
  config: Config
  state: State
  custom: string
  checkpoint?: (phase: Checkpoint) => void
}): Promise<
  | { status: "ready"; custom: string }
  | { status: "blocked"; reason: string; state: State }
> {
  if (await ancestor(input.repository, input.state.upstream, input.custom)) {
    const cleaned = await cleanup(input.repository, input.state, input.custom)
    if (!cleaned)
      return block(input.home, input.state, "origin/custom contains the target, but the persisted attempt is not clean and published")
    const resolved = { ...input.state, status: "resolved" as const, phase: "resolved" as const, error: undefined }
    await writeState(input.home, resolved)
    return { status: "ready", custom: input.custom }
  }
  if (input.state.status === "blocked") {
    await ensureSession(input.home, input.state)
    return { status: "blocked", reason: input.state.phase, state: (await readState(input.home)) ?? input.state }
  }

  const prepared = await ensureWorktree(input.repository, input.state)
  if (typeof prepared === "string") return block(input.home, input.state, prepared)
  const state = prepared.phase === input.state.phase ? input.state : prepared
  if (state !== input.state) {
    await writeState(input.home, state)
    input.checkpoint?.("worktree-created")
  }
  const inspection = await inspect(input.repository, state)
  if (typeof inspection === "string") return block(input.home, state, inspection)
  if (inspection.conflicts.length > 0)
    return block(input.home, state, `Merge conflicts require review: ${inspection.conflicts.join(", ")}`)
  if (inspection.dirty && !inspection.mergeHead)
    return block(input.home, state, "The automation worktree has changes outside an in-progress merge")

  if (state.phase === "planned" || state.phase === "worktree-created") {
    if (inspection.head !== state.custom || inspection.dirty || inspection.mergeHead)
      return block(input.home, state, "The worktree changed before the automation merge started")
    const merging = { ...state, phase: "merging" as const }
    await writeState(input.home, merging)
    input.checkpoint?.("merging")
    const result = await run(["git", "merge", "--no-commit", "--no-ff", state.upstream], state.worktree)
    input.checkpoint?.("merge-finished")
    if (result.code !== 0) {
      const conflicts = await unmerged(state.worktree)
      if (conflicts.length > 0) return block(input.home, merging, `Merge conflicts require review: ${conflicts.join(", ")}`)
      return block(input.home, merging, `git merge failed: ${summarize(result.stderr)}`)
    }
    const merged = { ...merging, phase: "merged" as const }
    await writeState(input.home, merged)
    input.checkpoint?.("merged")
    return validateAndCommit({ ...input, state: merged })
  }

  if (state.phase === "merging") {
    if (inspection.mergeHead && inspection.mergeHead !== state.upstream)
      return block(input.home, state, "MERGE_HEAD does not match the frozen upstream SHA")
    if (inspection.mergeHead) {
      const merged = { ...state, phase: "merged" as const }
      await writeState(input.home, merged)
      return validateAndCommit({ ...input, state: merged })
    }
    if (inspection.head === state.custom && !inspection.dirty) {
      const retry = { ...state, phase: "worktree-created" as const }
      await writeState(input.home, retry)
      return resume({ ...input, state: retry })
    }
    return block(input.home, state, "Merge execution was interrupted in an unknown Git state")
  }

  if (state.phase === "merged") return validateAndCommit({ ...input, state })
  if (state.phase === "validating")
    return block(input.home, state, "Validation was interrupted and may have changed the worktree")
  if (state.phase === "validated") return commitAndPush({ ...input, state })
  if (state.phase === "committing") {
    if (inspection.mergeHead)
      return block(input.home, state, "Commit or a commit hook was interrupted with the merge still in progress")
    if (!(await validMergeCommit(input.repository, state, inspection.head)))
      return block(input.home, state, "Commit completed in an unexpected form")
    const committed = { ...state, phase: "committed" as const }
    await writeState(input.home, committed)
    return push({ ...input, state: committed })
  }
  if (state.phase === "committed" || state.phase === "pushing") {
    if (!(await validMergeCommit(input.repository, state, inspection.head)))
      return block(input.home, state, "The local merge commit is missing or no longer matches the frozen pair")
    if (input.custom !== state.custom)
      return block(input.home, state, "origin/custom advanced before the local merge commit was published")
    return push({ ...input, state })
  }
  if (state.phase === "published")
    return block(input.home, state, "Push was recorded, but origin/custom does not contain the frozen upstream target")
  return block(input.home, state, `Cannot resume phase ${state.phase}`)
}

async function validateAndCommit(input: {
  home: string
  repository: string
  config: Config
  state: State
  custom: string
  checkpoint?: (phase: Checkpoint) => void
}) {
  const validating = { ...input.state, phase: "validating" as const }
  await writeState(input.home, validating)
  input.checkpoint?.("validating")
  const error = await validate(input.config, input.state.worktree)
  if (error) return block(input.home, validating, error)
  const validated = { ...validating, phase: "validated" as const }
  await writeState(input.home, validated)
  input.checkpoint?.("validated")
  return commitAndPush({ ...input, state: validated })
}

async function commitAndPush(input: {
  home: string
  repository: string
  config: Config
  state: State
  custom: string
  checkpoint?: (phase: Checkpoint) => void
}) {
  await fetch(input.repository, "origin", input.config.branch)
  const custom = await revision(input.repository, `refs/remotes/origin/${input.config.branch}`)
  if (custom !== input.state.custom)
    return block(input.home, input.state, "origin/custom advanced after validation; the merge was preserved for review")
  const committing = { ...input.state, phase: "committing" as const }
  await writeState(input.home, committing)
  input.checkpoint?.("committing")
  const result = await run(
    [
      "git",
      "-c",
      "user.name=OpenCode Upstream Sync",
      "-c",
      "user.email=opencode-upstream-sync@localhost",
      "commit",
      "-m",
      `chore: merge upstream ${input.config.upstreamBranch}`,
    ],
    input.state.worktree,
  )
  if (result.code !== 0) return block(input.home, committing, `git commit or hook failed: ${summarize(result.stderr)}`)
  const committed = { ...committing, phase: "committed" as const }
  await writeState(input.home, committed)
  input.checkpoint?.("committed")
  return push({ ...input, state: committed })
}

async function push(input: {
  home: string
  repository: string
  config: Config
  state: State
  custom: string
  checkpoint?: (phase: Checkpoint) => void
}) {
  const pushing = { ...input.state, phase: "pushing" as const, error: undefined }
  await writeState(input.home, pushing)
  input.checkpoint?.("pushing")
  const result = await run(["git", "push", "origin", `HEAD:refs/heads/${input.config.branch}`], input.state.worktree)
  if (result.code !== 0) {
    await fetch(input.repository, "origin", input.config.branch)
    const custom = await revision(input.repository, `refs/remotes/origin/${input.config.branch}`)
    if (custom !== input.state.custom)
      return block(input.home, pushing, `Push was rejected after origin/custom changed: ${summarize(result.stderr)}`)
    const retry = { ...pushing, error: `Push failed and will be retried: ${summarize(result.stderr)}` }
    await writeState(input.home, retry)
    return { status: "blocked" as const, reason: "push-rejected", state: retry }
  }
  input.checkpoint?.("pushed")
  const published = { ...pushing, phase: "published" as const }
  await writeState(input.home, published)
  await fetch(input.repository, "origin", input.config.branch)
  const custom = await revision(input.repository, `refs/remotes/origin/${input.config.branch}`)
  return resume({ ...input, state: published, custom })
}

function makeState(custom: string, upstream: string, worktree: string): State {
  const digest = createHash("sha256").update(`${custom}:${upstream}`).digest("hex")
  return Schema.decodeUnknownSync(UpstreamSyncState)({
    format: 2,
    status: "active",
    phase: "planned",
    custom,
    upstream,
    worktree,
    branch: "upstream-merge",
    sessionID: `ses_upstream_${digest}`,
    promptID: `msg_upstream_${digest}`,
    sessionCreated: false,
    promptSent: false,
  })
}

async function ensureWorktree(repository: string, state: State) {
  if (await lstat(state.worktree).catch(() => undefined)) return state
  const branch = await run(["git", "rev-parse", "--verify", `refs/heads/${state.branch}^{commit}`], repository)
  if (branch.code === 0) {
    if (branch.stdout.trim() !== state.custom) return "Automation branch exists at an unexpected commit"
    await mkdir(path.dirname(state.worktree), { recursive: true })
    await requireCommand(["git", "worktree", "add", state.worktree, state.branch], repository)
    return { ...state, phase: "worktree-created" as const }
  }
  if (state.phase !== "planned" && state.phase !== "worktree-created" && state.phase !== "merging")
    return `Automation worktree disappeared during phase ${state.phase}`
  await mkdir(path.dirname(state.worktree), { recursive: true })
  await requireCommand(["git", "worktree", "add", "-b", state.branch, state.worktree, state.custom], repository)
  return { ...state, phase: "worktree-created" as const }
}

async function inspect(repository: string, state: State) {
  const common = await run(["git", "rev-parse", "--git-common-dir"], state.worktree)
  if (common.code !== 0) return "Automation worktree is not a Git worktree"
  if ((await realpath(path.resolve(state.worktree, common.stdout.trim()))) !== (await realpath(repository)))
    return "Automation worktree belongs to another repository"
  if ((await requireCommand(["git", "branch", "--show-current"], state.worktree)).trim() !== state.branch)
    return "Automation worktree is on another branch"
  const status = await requireCommand(["git", "status", "--porcelain=v1"], state.worktree)
  const mergeHead = await run(["git", "rev-parse", "--verify", "MERGE_HEAD^{commit}"], state.worktree)
  return {
    head: (await requireCommand(["git", "rev-parse", "HEAD^{commit}"], state.worktree)).trim(),
    dirty: status !== "",
    mergeHead: mergeHead.code === 0 ? mergeHead.stdout.trim() : undefined,
    conflicts: await unmerged(state.worktree),
  }
}

async function validMergeCommit(repository: string, state: State, head: string) {
  const parents = (await requireCommand(["git", "show", "-s", "--format=%P", head], repository)).trim().split(" ")
  return parents.includes(state.custom) && parents.includes(state.upstream)
}

async function cleanup(repository: string, state: State, custom: string) {
  if (!(await lstat(state.worktree).catch(() => undefined))) {
    const branch = await run(["git", "rev-parse", "--verify", `refs/heads/${state.branch}^{commit}`], repository)
    if (branch.code !== 0) return true
    const head = branch.stdout.trim()
    if (!(await ancestor(repository, head, custom))) return false
    await requireCommand(["git", "update-ref", "-d", `refs/heads/${state.branch}`, head], repository)
    return true
  }
  const inspection = await inspect(repository, state)
  if (typeof inspection === "string" || inspection.dirty || !(await ancestor(repository, inspection.head, custom))) return false
  await requireCommand(["git", "worktree", "remove", state.worktree], repository)
  await requireCommand(["git", "update-ref", "-d", `refs/heads/${state.branch}`, inspection.head], repository)
  return true
}

async function attemptExists(repository: string, state: State) {
  if (await lstat(state.worktree).catch(() => undefined)) return true
  return (await run(["git", "rev-parse", "--verify", `refs/heads/${state.branch}^{commit}`], repository)).code === 0
}

async function block(home: string, state: State, error: string) {
  const blocked = { ...state, status: "blocked" as const, error: summarize(error) }
  await writeState(home, blocked)
  await ensureSession(home, blocked)
  return { status: "blocked" as const, reason: blocked.phase, state: (await readState(home)) ?? blocked }
}

async function ensureSession(home: string, state: State) {
  if (!(await lstat(state.worktree).catch(() => undefined))) return
  const serviceFile = path.join(home, "config/opencode/service-custom.json")
  if (!(await Bun.file(serviceFile).exists())) return
  const service = Schema.decodeUnknownSync(
    Schema.Struct({ hostname: Schema.Literal("127.0.0.1"), port: Schema.Int, password: Schema.NonEmptyString }),
  )(await Bun.file(serviceFile).json())
  const client = OpenCode.make({
    baseUrl: `http://${service.hostname}:${service.port}`,
    headers: { authorization: `Basic ${btoa(`opencode:${service.password}`)}` },
  })
  const options = { signal: AbortSignal.timeout(5_000) }
  const created = state.sessionCreated
    ? state
    : await client.session
        .create({ id: state.sessionID, title: "Resolve upstream merge", location: { directory: state.worktree } }, options)
        .then(async () => {
          const next = { ...state, sessionCreated: true }
          await writeState(home, next)
          return next
        })
        .catch(() => state)
  if (!created.sessionCreated || created.promptSent) return
  await client.session
    .prompt(
      {
        sessionID: state.sessionID,
        id: state.promptID,
        text: [
          "Analyze the preserved upstream merge attempt and explain a proposed resolution.",
          "Do not edit files, stage changes, resolve conflicts, commit, or push until the user explicitly responds authorizing that work.",
          `Blocked phase: ${state.phase}`,
          `Reason: ${state.error ?? "manual review required"}`,
          `Frozen custom SHA: ${state.custom}`,
          `Frozen upstream SHA: ${state.upstream}`,
          `Worktree: ${state.worktree}`,
        ].join("\n"),
      },
      options,
    )
    .then(() => writeState(home, { ...created, promptSent: true }))
    .catch(() => undefined)
}

async function validate(config: Config, worktree: string) {
  for (const validation of config.validation) {
    const cwd = path.resolve(worktree, validation.cwd)
    if (cwd !== worktree && !cwd.startsWith(`${worktree}${path.sep}`)) return "Validation cwd escapes worktree"
    const result = await run([...validation.argv], cwd)
    if (result.code !== 0)
      return `Validation failed (${validation.argv.join(" ")}): ${summarize(result.stderr || result.stdout)}`
  }
}

async function configureUpstream(repository: string, url: string) {
  const existing = await run(["git", "remote", "get-url", "upstream"], repository)
  if (existing.code !== 0) return requireCommand(["git", "remote", "add", "upstream", url], repository)
  if (existing.stdout.trim() === url) return
  await requireCommand(["git", "remote", "set-url", "upstream", url], repository)
}

async function fetch(repository: string, remote: string, branch: string) {
  await requireCommand(
    ["git", "fetch", "--no-tags", remote, `+refs/heads/${branch}:refs/remotes/${remote}/${branch}`],
    repository,
  )
}

async function revision(repository: string, ref: string) {
  return (await requireCommand(["git", "rev-parse", `${ref}^{commit}`], repository)).trim()
}

async function ancestor(repository: string, base: string, head: string) {
  const result = await run(["git", "merge-base", "--is-ancestor", base, head], repository)
  if (result.code === 0) return true
  if (result.code === 1) return false
  throw new Error(`git merge-base failed: ${result.stderr}`)
}

async function unmerged(worktree: string) {
  return (await requireCommand(["git", "diff", "--name-only", "--diff-filter=U"], worktree))
    .trim()
    .split("\n")
    .filter(Boolean)
}

async function readState(home: string) {
  const file = Bun.file(path.join(home, "state/upstream-sync.json"))
  if (!(await file.exists())) return undefined
  return Schema.decodeUnknownSync(Schema.fromJsonString(UpstreamSyncState))(await file.text())
}

async function writeState(home: string, state: State) {
  const directory = path.join(home, "state")
  await mkdir(directory, { recursive: true })
  const temporary = path.join(directory, `upstream-sync-${process.pid}.json`)
  await Bun.write(temporary, JSON.stringify(state, null, 2))
  await rename(temporary, path.join(directory, "upstream-sync.json"))
}

function summarize(value: string) {
  return value.trim().replaceAll(/\s+/g, " ").slice(0, 2_000) || "command failed without output"
}

async function requireCommand(args: string[], cwd: string) {
  const result = await run(args, cwd)
  if (result.code !== 0) throw new Error(`Command failed: ${args[0]} ${args.slice(1).join(" ")}\n${result.stderr}`)
  return result.stdout
}

async function run(args: string[], cwd: string) {
  const child = Bun.spawn(args, {
    cwd,
    env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    timeout: 30 * 60_000,
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  return { stdout, stderr, code }
}
