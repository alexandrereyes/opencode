import { mkdir, rename, cp, rm, chmod, mkdtemp } from "node:fs/promises"
import path from "node:path"
import os from "node:os"
import { Effect, Schema } from "effect"
import { ProcessLock } from "@opencode/core/util/process-lock"

const Config = Schema.Struct({
  home: Schema.String,
  repository: Schema.String,
  bun: Schema.String,
  port: Schema.Number,
})
export type Config = typeof Config.Type
const Release = Schema.Struct({ commit: Schema.String, directory: Schema.String })
export type Release = typeof Release.Type
const decodeRelease = Schema.decodeUnknownSync(Schema.fromJsonString(Release))
class TransientError extends Error {}

export async function command(args: string[], cwd: string, env: NodeJS.ProcessEnv = process.env) {
  const child = Bun.spawn(args, { cwd, env, stdout: "pipe", stderr: "pipe" })
  const [code, out, err] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  return { code, out: out.trim(), err: err.trim() }
}

async function requireCommand(args: string[], cwd: string, env?: NodeJS.ProcessEnv) {
  const result = await command(args, cwd, env)
  if (result.code) {
    const message = `${args[0]} failed (${result.code}): ${result.err || result.out}`
    if (
      /ENOTFOUND|ECONN|ETIMEDOUT|ConnectionRefused|FailedToOpenSocket|unable to access|Could not resolve|network|HTTP.*(?:429|502|503|504)/i.test(
        message,
      )
    )
      throw new TransientError(message)
    throw new Error(message)
  }
  return result.out
}

export async function atomic(file: string, value: unknown) {
  const temporary = `${file}.${crypto.randomUUID()}`
  await Bun.write(temporary, JSON.stringify(value, null, 2) + "\n")
  await chmod(temporary, 0o600)
  await rename(temporary, file)
}

export function locked<A>(file: string, run: () => Promise<A>) {
  return Effect.runPromise(
    Effect.scoped(
      Effect.gen(function* () {
        yield* ProcessLock.acquire(file)
        return yield* Effect.tryPromise({ try: run, catch: (error) => error })
      }),
    ),
  )
}

export async function retry<A>(run: () => Promise<A>, delay = 5_000): Promise<A> {
  for (const attempt of [0, 1, 2]) {
    try {
      return await run()
    } catch (error) {
      if (attempt === 2) throw error
      console.log(`Transient operation failed; retry ${attempt + 1}/2`)
      await Bun.sleep(delay * (attempt + 1))
    }
  }
  throw new Error("Unreachable retry state")
}

/** Fetch/merge/check/push is independent of whether a release can be activated. */
export async function synchronize(input: {
  repository: string
  worktrees: string
  check: (directory: string) => Promise<void>
  repair: (directory: string, reason: string) => Promise<void>
}) {
  const git = (...args: string[]) => requireCommand(["git", ...args], input.repository)
  // Network errors stop here, before either merge or an agent is attempted.
  await retry(() => git("fetch", "origin", "custom:refs/remotes/origin/custom"))
  await retry(() => git("fetch", "upstream", "beta:refs/remotes/upstream/beta"))
  const base = await git("rev-parse", "refs/remotes/origin/custom")
  const upstream = await git("rev-parse", "refs/remotes/upstream/beta")
  const branch = `sync-${new Date().toISOString().slice(0, 10).replaceAll("-", "")}-${crypto.randomUUID().slice(0, 8)}`
  const directory = path.join(input.worktrees, branch)
  await git("worktree", "add", "-b", branch, directory, base)
  const merge = await command(["git", "merge", "--no-edit", upstream], directory)
  const checked =
    merge.code === 0
      ? await input.check(directory).then(
          async () => ({
            ok: !(await requireCommand(["git", "status", "--porcelain", "--untracked-files=no"], directory)),
            reason: "Validation modified tracked files; review required",
          }),
          (error: unknown) => {
            if (error instanceof TransientError) throw error
            return { ok: false, reason: String(error) }
          },
        )
      : { ok: false, reason: `Merge conflict with upstream beta ${upstream}` }
  if (!checked.ok) {
    await input.repair(directory, checked.reason)
    if (await requireCommand(["git", "diff", "--name-only", "--diff-filter=U"], directory))
      throw new Error(`Repair left conflicts; retained ${directory}`)
    await input.check(directory)
    await requireCommand(["git", "add", "-A"], directory)
    const changed = await command(["git", "diff", "--cached", "--quiet"], directory)
    const merging = await Bun.file(
      path.join(await requireCommand(["git", "rev-parse", "--absolute-git-dir"], directory), "MERGE_HEAD"),
    ).exists()
    if (changed.code || merging)
      await requireCommand(["git", "commit", "-m", "fix(custom): reconcile upstream beta update"], directory)
    await retry(() => requireCommand(["git", "push", "origin", `HEAD:refs/heads/${branch}`], directory))
    return { kind: "review" as const, branch, directory, base, upstream }
  }
  const commit = await requireCommand(["git", "rev-parse", "HEAD"], directory)
  if (await requireCommand(["git", "status", "--porcelain", "--untracked-files=no"], directory))
    throw new Error("Validation modified tracked files; review required")
  await retry(() => git("fetch", "origin", "custom:refs/remotes/origin/custom"))
  if ((await git("rev-parse", "refs/remotes/origin/custom")) !== base)
    throw new Error(`custom advanced concurrently; retained validated ${branch}, retry next run`)
  // Ordinary fast-forward push is the final concurrency check. Never force a branch.
  await retry(() => requireCommand(["git", "push", "origin", "HEAD:refs/heads/custom"], directory))
  return { kind: "integrated" as const, commit, directory, branch }
}

async function validate(config: Config, directory: string) {
  // Dependency acquisition is retried separately. Never ask an agent to fix network access.
  await retry(() => requireCommand([config.bun, "install", "--frozen-lockfile"], directory))
  for (const pkg of ["core", "protocol", "client", "server", "cli", "app"])
    await requireCommand([config.bun, "typecheck"], path.join(directory, "packages", pkg))
  await requireCommand(
    [
      config.bun,
      "run",
      "test",
      "test/maintenance.test.ts",
      "test/session-run-coordinator.test.ts",
      "test/job.test.ts",
      "test/generate.test.ts",
      "test/session-generate.test.ts",
      "test/form.test.ts",
      "test/permission.test.ts",
      "test/session-shell.test.ts",
      "test/shell-retention.test.ts",
      "test/pty/pty-session.test.ts",
      "test/session-prompt.test.ts",
      "test/session-execution.test.ts",
    ],
    path.join(directory, "packages/core"),
  )
  await requireCommand([config.bun, "../core/script/test.ts"], path.join(directory, "packages/server"))
  await requireCommand([config.bun, "run", "build"], path.join(directory, "packages/app"))
  await smoke(
    config.bun,
    directory,
    await requireCommand(["git", "rev-parse", "HEAD"], directory),
    path.join(config.home, "worktrees"),
  )
}

async function prepare(config: Config, commit: string) {
  const directory = path.join(config.home, "releases", commit)
  const manifest = path.join(directory, "release.json")
  if (await Bun.file(manifest).exists()) {
    const release = decodeRelease(await Bun.file(manifest).text())
    await atomic(path.join(config.home, "pending.json"), release)
    return release
  }
  const staging = path.join(
    config.home,
    "worktrees",
    `release-${commit.slice(0, 12)}-${crypto.randomUUID().slice(0, 8)}`,
  )
  await requireCommand(["git", "worktree", "add", "--detach", staging, commit], config.repository)
  await retry(() => requireCommand([config.bun, "install", "--frozen-lockfile"], staging))
  await requireCommand([config.bun, "run", "build"], path.join(staging, "packages/app"))
  await smoke(config.bun, staging, commit, path.join(config.home, "worktrees"))
  await requireCommand(["git", "worktree", "move", staging, directory], config.repository)
  const release = { directory, commit }
  await atomic(manifest, release)
  await atomic(path.join(config.home, "pending.json"), release)
  console.log(`Prepared ${commit}; activation waits for idle`)
  return release
}

async function readRelease(config: Config, name: string) {
  const file = Bun.file(path.join(config.home, `${name}.json`))
  return (await file.exists()) ? decodeRelease(await file.text()) : undefined
}

function runtimeEnv(config: Config, release: Release): NodeJS.ProcessEnv {
  return {
    ...process.env,
    XDG_CONFIG_HOME: path.join(config.home, "config"),
    XDG_DATA_HOME: path.join(config.home, "data"),
    XDG_STATE_HOME: path.join(config.home, "state"),
    XDG_CACHE_HOME: path.join(config.home, "cache"),
    OPENCODE_CUSTOM_HOME: config.home,
    OPENCODE_CUSTOM_COMMIT: release.commit,
    OPENCODE_CUSTOM_PORT: String(config.port),
    OPENCODE_CONFIG_DIR: path.join(config.home, "config/opencode"),
  }
}

async function request(config: Config, route: string, payload?: unknown) {
  const password = (await Bun.file(path.join(config.home, "password")).text()).trim()
  return fetch(`http://127.0.0.1:${config.port}${route}`, {
    method: payload === undefined ? "GET" : "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
      "content-type": "application/json",
    },
    body: payload === undefined ? undefined : JSON.stringify(payload),
    signal: AbortSignal.timeout(10_000),
  })
}

const Health = Schema.Struct({ healthy: Schema.Boolean, version: Schema.String, pid: Schema.Number })
const LeaseResult = Schema.Struct({
  lease: Schema.NullOr(
    Schema.Struct({ identity: Schema.String, token: Schema.String, expires: Schema.Number, pid: Schema.Number }),
  ),
  reason: Schema.String,
})

async function health(config: Config, release: Release, pid: number) {
  const response = await request(config, "/api/health").catch(() => undefined)
  if (response?.status !== 200) return false
  const body = Schema.decodeUnknownSync(Health)(await response.json())
  return body.healthy && body.pid === pid && body.version === release.commit
}

async function stopIdle(config: Config, release: Release, child: { pid: number; exited: Promise<number> }) {
  if (!(await health(config, release, child.pid))) {
    console.log("Activation deferred: server health unknown")
    return false
  }
  const response = await request(config, "/api/server/maintenance", {})
  if (response.status !== 200) {
    console.log("Activation deferred: maintenance unavailable")
    return false
  }
  const result = Schema.decodeUnknownSync(LeaseResult)(await response.json())
  if (!result.lease) {
    console.log(`Activation deferred: ${result.reason}`)
    return false
  }
  if (result.lease.pid !== child.pid) throw new Error("Maintenance process identity mismatch")
  const committed = await request(config, "/api/server/maintenance/commit", {
    identity: result.lease.identity,
    token: result.lease.token,
  }).catch(() => undefined)
  if (
    committed?.status !== 200 ||
    !Schema.decodeUnknownSync(Schema.Struct({ committed: Schema.Boolean }))(await committed.json()).committed
  ) {
    console.log("Activation deferred: shutdown acknowledgement unknown")
    return false
  }
  const stopped = await waitExit(child.exited, 30_000)
  if (!stopped) {
    await request(config, "/api/server/maintenance/cancel", { token: result.lease.token }).catch(() => undefined)
    console.log("Activation deferred: leased shutdown did not finish")
    return false
  }
  return true
}

export async function activate(
  config: Config,
  release: Release,
  pending: Release,
  child: { pid: number; exited: Promise<number> },
) {
  if (!(await stopIdle(config, release, child))) return false
  const backup = path.join(config.home, "backups", `${Date.now()}-${release.commit}`)
  await mkdir(backup, { recursive: true })
  // Copy persistence only after the owned backend exits, including WAL and file-backed values.
  await cp(path.join(config.home, "data"), path.join(backup, "data"), { recursive: true })
  await atomic(path.join(backup, "release.json"), release)
  await atomic(path.join(config.home, "previous.json"), { ...release, backup })
  // Record the binary before migration: a crash restarts this same binary, never an older schema reader.
  await atomic(path.join(config.home, "current.json"), pending)
  console.log(`Activating ${pending.commit}; persistence backup ${backup}`)
  return true
}

async function waitExit(exit: Promise<number>, duration: number) {
  const timer = { id: undefined as ReturnType<typeof setTimeout> | undefined }
  try {
    return await Promise.race([
      exit.then(() => true),
      new Promise<boolean>((resolve) => {
        timer.id = setTimeout(() => resolve(false), duration)
      }),
    ])
  } finally {
    clearTimeout(timer.id)
  }
}

/** Real production UI and source backend smoke test with private persistence and an ephemeral port. */
export async function smoke(bun: string, directory: string, commit: string, temporary: string) {
  const home = await mkdtemp(path.join(temporary, "custom-smoke-"))
  for (const dir of ["data/opencode", "state", "config/opencode", "logs", "cache"])
    await mkdir(path.join(home, dir), { recursive: true })
  await Bun.write(path.join(home, "password"), crypto.randomUUID())
  const config = { home, repository: directory, bun, port: 0 }
  const child = Bun.spawn([bun, "packages/cli/script/custom-server.ts"], {
    cwd: directory,
    env: { ...runtimeEnv(config, { directory, commit }), OPENCODE_CUSTOM_SMOKE: "1" },
    stdin: "pipe",
    stdout: Bun.file(path.join(home, "server.log")),
    stderr: Bun.file(path.join(home, "server.log")),
  })
  try {
    const deadline = Date.now() + 60_000
    while (Date.now() < deadline) {
      if (child.exitCode !== null) throw new Error(`Smoke backend exited; log ${home}/server.log`)
      const file = Bun.file(path.join(home, "server.json"))
      if (await file.exists()) {
        const registration = Schema.decodeUnknownSync(
          Schema.fromJsonString(Schema.Struct({ url: Schema.String, pid: Schema.Number, version: Schema.String })),
        )(await file.text())
        config.port = Number(new URL(registration.url).port)
        if (await health(config, { directory, commit }, child.pid)) break
      }
      await Bun.sleep(100)
    }
    if (!(await health(config, { directory, commit }, child.pid)))
      throw new Error(`Smoke startup timed out; log ${home}/server.log`)
    const ui = await request(config, "/")
    if (ui.status !== 200 || !(await ui.text()).includes("<html")) throw new Error("Production UI smoke failed")
    const response = await request(config, "/api/server/maintenance", {})
    if (response.status !== 200) throw new Error("Maintenance smoke failed")
    const result = Schema.decodeUnknownSync(LeaseResult)(await response.json())
    if (!result.lease) throw new Error(`Fresh smoke backend is not idle: ${result.reason}`)
    if ((await request(config, "/api/session")).status !== 503) throw new Error("Admission barrier smoke failed")
    const committed = await request(config, "/api/server/maintenance/commit", {
      token: result.lease.token,
      identity: result.lease.identity,
    }).catch(() => undefined)
    if (committed && committed.status !== 200) throw new Error("Commit smoke failed")
    if (!(await waitExit(child.exited, 30_000))) throw new Error("Leased shutdown smoke failed")
    console.log(`Source backend + production UI smoke passed: ${commit}`)
  } finally {
    child.stdin.end()
    if (!(await waitExit(child.exited, 30_000))) child.kill()
    await child.exited
  }
}

/** Only the supervisor owns this child. No discovery/ensure, saved PID signaling, or official service calls. */
async function serve(config: Config) {
  for (;;) {
    if (await Bun.file(path.join(config.home, "pause.json")).exists()) {
      await atomic(path.join(config.home, "paused.json"), { paused: true })
      await Bun.sleep(300_000)
      continue
    }
    await rm(path.join(config.home, "paused.json"), { force: true })
    const release = await readRelease(config, "current")
    if (!release) throw new Error("No current release. Run bootstrap first.")
    const log = Bun.file(path.join(config.home, "logs", `server-${release.commit}-${Date.now()}.log`))
    const child = Bun.spawn([config.bun, "packages/cli/script/custom-server.ts"], {
      cwd: release.directory,
      env: runtimeEnv(config, release),
      stdin: "pipe",
      stdout: log,
      stderr: log,
    })
    // Parent EOF is the backend's lifeline; launchd restarting this supervisor cannot leave an orphan.
    const stop = () => {
      child.stdin.end()
    }
    process.once("SIGTERM", stop)
    process.once("SIGINT", stop)
    try {
      for (;;) {
        const exited = await waitExit(child.exited, 300_000)
        if (exited) throw new Error(`Backend exited; inspect ${log.name}`)
        try {
          if (await Bun.file(path.join(config.home, "pause.json")).exists()) {
            if (await stopIdle(config, release, child)) break
            continue
          }
          const pending = await readRelease(config, "pending")
          if (!pending || pending.commit === release.commit) continue
          if (!(await activate(config, release, pending, child))) continue
          break
        } catch (error) {
          // Unknown state must keep the current backend running, even when control HTTP or disk reads fail.
          console.error(`Activation deferred: ${String(error)}`)
        }
      }
    } finally {
      process.off("SIGTERM", stop)
      process.off("SIGINT", stop)
      stop()
      await child.exited
    }
  }
}

function xml(value: string) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
}

async function install(home: string) {
  if (process.platform !== "darwin") throw new Error("The launchd installer requires macOS")
  if (Bun.version !== "1.4.2") throw new Error("Use Bun 1.4.2 for installation; the global Bun is not changed")
  if (await Bun.file(path.join(home, "config.json")).exists())
    throw new Error("Already installed; preserving existing configuration")
  for (const dir of [
    "logs",
    "state",
    "data/opencode",
    "config/opencode",
    "cache",
    "releases",
    "worktrees",
    "backups",
    "bin",
  ])
    await mkdir(path.join(home, dir), { recursive: true, mode: 0o700 })
  await chmod(home, 0o700)
  const bun = path.join(home, "bin/bun")
  await cp(process.execPath, bun)
  await chmod(bun, 0o700)
  const repository = path.join(home, "repository")
  await requireCommand(
    [
      "git",
      "clone",
      "--filter=blob:none",
      "--no-checkout",
      "https://github.com/alexandrereyes/opencode.git",
      repository,
    ],
    home,
  )
  await requireCommand(["git", "remote", "add", "upstream", "https://github.com/anomalyco/opencode.git"], repository)
  const config = { home, repository, bun, port: 4177 }
  await atomic(path.join(home, "config.json"), config)
  await Bun.write(path.join(home, "password"), crypto.randomUUID() + crypto.randomUUID())
  await chmod(path.join(home, "password"), 0o600)
  // Pin the controller checkout too; updates to the controller are an explicit reinstall/review operation.
  const source = path.resolve(import.meta.dir, "../../../..")
  if (await requireCommand(["git", "status", "--porcelain", "--untracked-files=no"], source))
    throw new Error("Commit the controller before installing")
  const controller = path.join(home, "controller")
  const commit = await requireCommand(["git", "rev-parse", "HEAD"], source)
  await requireCommand(["git", "fetch", "origin", commit], repository)
  await requireCommand(["git", "worktree", "add", "--detach", controller, commit], repository)
  await requireCommand([bun, "install", "--frozen-lockfile"], controller)
  const launcher = path.join(home, "bin/opencode-custom")
  await Bun.write(
    launcher,
    `#!/bin/sh\nexec '${bun.replaceAll("'", "'\\''")}' '${controller.replaceAll("'", "'\\''")}/packages/cli/script/custom/update.ts' --home '${home.replaceAll("'", "'\\''")}' "$@"\n`,
  )
  await chmod(launcher, 0o700)
  const agents = path.join(os.homedir(), "Library/LaunchAgents")
  await mkdir(agents, { recursive: true })
  for (const [name, mode] of [
    ["server", "serve"],
    ["daily", "sync"],
  ]) {
    const plist = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>com.alexandrereyes.opencode-custom.${name}</string><key>ProgramArguments</key><array><string>${xml(launcher)}</string><string>${mode}</string></array><key>WorkingDirectory</key><string>${xml(home)}</string><key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(process.env.PATH ?? "/usr/bin:/bin")}</string></dict><key>StandardOutPath</key><string>${xml(home)}/logs/${name}.log</string><key>StandardErrorPath</key><string>${xml(home)}/logs/${name}.log</string>${name === "server" ? "<key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>300</integer>" : "<key>StartCalendarInterval</key><dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>15</integer></dict>"}</dict></plist>\n`
    await Bun.write(path.join(agents, `com.alexandrereyes.opencode-custom.${name}.plist`), plist)
  }
  console.log(`Installed inactive launchd jobs (daily 04:15 local time). Launcher: ${launcher}`)
}

if (import.meta.main) {
  const args = process.argv.slice(2)
  const home = args[0] === "--home" ? path.resolve(args[1]) : path.join(os.homedir(), ".local/share/opencode-custom")
  const mode = args[0] === "--home" ? args[2] : args[0]
  if (mode === "install") await install(home)
  else {
    const config = Schema.decodeUnknownSync(Schema.fromJsonString(Config))(
      await Bun.file(path.join(home, "config.json")).text(),
    )
    await locked(
      path.join(
        home,
        mode === "serve" ? "server.lock" : mode === "sync" || mode === "bootstrap" ? "update.lock" : "control.lock",
      ),
      async () => {
        if (mode === "serve") return serve(config)
        if (mode === "pause") {
          await atomic(path.join(home, "pause.json"), { requested: Date.now() })
          console.log(
            "Pause requested. The supervisor waits for idle; inspect status for paused=true before maintenance.",
          )
          return
        }
        if (mode === "resume") {
          await rm(path.join(home, "paused.json"), { force: true })
          await rm(path.join(home, "pause.json"), { force: true })
          console.log("Resume requested; the supervisor checks every 300 seconds.")
          return
        }
        if (mode === "status") {
          console.log(
            JSON.stringify(
              {
                current: await readRelease(config, "current"),
                pending: await readRelease(config, "pending"),
                previous: await readRelease(config, "previous"),
                paused: await Bun.file(path.join(home, "paused.json")).exists(),
                pauseRequested: await Bun.file(path.join(home, "pause.json")).exists(),
                url: `http://127.0.0.1:${config.port}`,
                jobs: "Inspect launchctl print for loaded state",
              },
              null,
              2,
            ),
          )
          return
        }
        if (mode === "bootstrap") {
          if (await readRelease(config, "current")) throw new Error("Already bootstrapped")
          await retry(() => requireCommand(["git", "fetch", "origin", "custom"], config.repository))
          const release = await prepare(
            config,
            await requireCommand(["git", "rev-parse", "FETCH_HEAD"], config.repository),
          )
          await atomic(path.join(home, "current.json"), release)
          console.log("Bootstrap prepared. launchd jobs remain inactive until explicitly bootstrapped with launchctl.")
          return
        }
        if (mode !== "sync") throw new Error("Usage: opencode-custom install|bootstrap|sync|serve|status|pause|resume")
        const result = await synchronize({
          repository: config.repository,
          worktrees: path.join(home, "worktrees"),
          check: (directory) => validate(config, directory),
          repair: async (directory, reason) => {
            const current = await readRelease(config, "current")
            if (!current) throw new Error("Agent repair requires a bootstrapped custom server; worktree retained")
            const response = await request(config, "/api/health")
            if (response.status !== 200) throw new Error("Agent repair deferred: custom server unavailable")
            const password = (await Bun.file(path.join(home, "password")).text()).trim()
            await requireCommand(
              [
                config.bun,
                path.join(current.directory, "packages/cli/src/index.ts"),
                "run",
                "--auto",
                "--server",
                `http://127.0.0.1:${config.port}`,
                `Resolve this custom/upstream-beta update failure in the current worktree. Preserve the custom features. Do not push, merge into custom, change the updater configuration, start or stop services, or delegate. Read AGENTS.md. Resolve conflicts and validate relevant packages. Leave changes for review. Failure: ${reason}`,
              ],
              directory,
              { ...runtimeEnv(config, current), OPENCODE_PASSWORD: password },
            )
          },
        })
        if (result.kind === "review") {
          await retry(() =>
            requireCommand(
              [
                "gh",
                "pr",
                "create",
                "--repo",
                "alexandrereyes/opencode",
                "--base",
                "custom",
                "--head",
                result.branch,
                "--title",
                "fix(custom): reconcile upstream beta update",
                "--body",
                `Automated repair requires review. Base: ${result.base}. Upstream: ${result.upstream}. Validation passed. No automatic integration.`,
              ],
              result.directory,
            ),
          )
          console.log(`Repair published for review: ${result.branch}`)
          return
        }
        await prepare(config, result.commit)
      },
    )
  }
}
