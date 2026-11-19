// The detached execution of one attempt group (`docs/bancada.md`, "Execution"): prepares the working folder, builds,
// plans, waits for the devices and runs the parts, writing everything into the attempt's folder. A single file that
// imports nothing but `node:*` and Bun: the Bancada process copies it into the attempt's folder and runs that copy, so
// an execution needs only its folder (a release swapped meanwhile, or a container that mounts only that folder,
// changes nothing). Started as `<bun> <folder>/runner.(ts|js) --opencode-bancada-run <folder>`.
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

export const runFlag = "--opencode-bancada-run"

/** `attempt.json`, written by the process before the start, by rename, and never changed (format 1). */
export type Attempt = {
  readonly format: 1
  readonly job: string
  readonly group: string
  readonly attempt: number
  readonly commit: string
  readonly token: string
  readonly workdir: string
  /** The folder held an earlier execution: a build that fails is tried once more after `scrub`. */
  readonly reused: boolean
  /** argv lists run in `workdir` before the builds, and to clean everything before building again. */
  readonly prepare: ReadonlyArray<ReadonlyArray<string>>
  readonly scrub: ReadonlyArray<ReadonlyArray<string>>
  readonly parts: ReadonlyArray<{
    readonly part: string
    readonly build?: ReadonlyArray<string>
    readonly plan?: ReadonlyArray<string>
    readonly run: ReadonlyArray<string>
    readonly args: ReadonlyArray<string>
    readonly secrets?: string
    readonly only?: ReadonlyArray<string>
  }>
  /** Awake time each stage may take: preparing (and waiting for devices), each build or plan, the run. */
  readonly deadlines: { readonly prepareMs: number; readonly buildMs: number; readonly runMs: number }
  readonly timing?: {
    readonly pollMs?: number
    readonly heartbeatMs?: number
    readonly awakeClampMs?: number
    readonly killGraceMs?: number
  }
  readonly lowPriority: boolean
  /** Extra variables for the project's commands (`BANCADA_DOCKER_LABEL` where there is Docker). */
  readonly env?: Readonly<Record<string, string>>
}

/** `parts/<part>/status.json`, written once by rename when the part's last command stops. */
export type PartStatus = {
  readonly stage: "build" | "plan" | "run"
  readonly exit?: number
  readonly signal?: string
  readonly cause?: "prazo" | "cancelado" | "runner_erro"
  readonly reason?: string
  readonly endedAt: number
  readonly awakeMs: number
}

/**
 * `runner.json`: who took the attempt, created only if absent and with its whole content. Its runner (pid and the
 * process's start time, as the system gives it), or the Bancada process that gave up on a start that never came.
 */
export type Claim =
  | { readonly pid: number; readonly startedAt: string }
  | { readonly revoked: true; readonly at: number }

/**
 * One event of `events.jsonl`. `command.start` (written the moment a command starts), `command.identity` (its start
 * time, when the system answers) and `command.end` are what the process reads to end orphans.
 */
export type Event = { readonly type: string; readonly pid?: number; readonly startedAt?: string }

type Ended =
  | { readonly exit: number; readonly signal?: string; readonly reason?: string }
  | { readonly cause: "prazo" | "cancelado" }

/**
 * Awake time: each step adds what passed since the last one, but never more than `clampMs`, so a machine that slept
 * does not count its sleep against any deadline (a step cannot run while it sleeps).
 */
export function awake(total: number, last: number, now: number, clampMs: number) {
  return total + Math.min(Math.max(0, now - last), clampMs)
}

export async function runAttempt(dir: string) {
  const attempt: Attempt = JSON.parse(fs.readFileSync(path.join(dir, "attempt.json"), "utf8"))
  // The project's commands must not inherit what makes the server's binary behave as Bun, nor anything that would
  // turn on a Bancada of a server a test starts (D13).
  Object.keys(process.env)
    .filter((name) => name === "BUN_BE_BUN" || name.startsWith("OPENCODE_BANCADA"))
    .forEach((name) => delete process.env[name])
  const startedAt = await ownStart()
  if (!startedAt || !createOnce(path.join(dir, "runner.json"), { pid: process.pid, startedAt })) return
  const timing = {
    pollMs: attempt.timing?.pollMs ?? 200,
    heartbeatMs: attempt.timing?.heartbeatMs ?? 5_000,
    clampMs: attempt.timing?.awakeClampMs ?? 15_000,
    killGraceMs: attempt.timing?.killGraceMs ?? 10_000,
  }
  const clock = { awakeMs: 0, last: Date.now(), beat: 0 }
  const tick = () => {
    const now = Date.now()
    clock.awakeMs = awake(clock.awakeMs, clock.last, now, timing.clampMs)
    clock.last = now
    if (now - clock.beat < timing.heartbeatMs) return
    clock.beat = now
    writeJson(path.join(dir, "heartbeat"), { at: now, awakeMs: clock.awakeMs })
  }
  const heartbeat = setInterval(tick, Math.min(timing.heartbeatMs, 1_000))
  const caffeinate =
    process.platform === "darwin"
      ? Bun.spawn(["/usr/bin/caffeinate", "-i", "-w", String(process.pid)], { stdio: ["ignore", "ignore", "ignore"] })
      : undefined
  caffeinate?.unref()
  tick()
  const cancelled = () => fs.existsSync(path.join(dir, "cancel"))
  const event = (type: string, extra: Record<string, unknown> = {}) =>
    fs.appendFileSync(
      path.join(dir, "events.jsonl"),
      JSON.stringify({ at: Date.now(), awakeMs: clock.awakeMs, type, ...extra }) + "\n",
    )
  const ended = new Set<string>()
  const finish = (part: string, status: Omit<PartStatus, "endedAt" | "awakeMs">) => {
    if (ended.has(part)) return
    ended.add(part)
    fs.mkdirSync(path.join(dir, "parts", part), { recursive: true })
    writeJson(path.join(dir, "parts", part, "status.json"), { ...status, endedAt: Date.now(), awakeMs: clock.awakeMs })
  }
  const stage: { current: PartStatus["stage"] } = { current: "build" }

  /**
   * Runs one command in a session of its own and stops it (and everything it started) at the deadline or a cancel.
   * When it ends, whatever it left running in its group dies with it, before its number can go to anyone else. A
   * command that cannot start is that command's result, never the runner's end.
   */
  const execute = async (
    argv: ReadonlyArray<string>,
    options: {
      readonly cwd: string
      readonly log: string
      readonly env?: Record<string, string>
      readonly deadlineMs: number
    },
  ): Promise<Ended> => {
    if (cancelled()) return { cause: "cancelado" }
    const child = spawn([...(attempt.lowPriority ? ["nice", "-n", "10"] : []), ...argv], {
      cwd: options.cwd,
      env: { ...process.env, ...attempt.env, ...options.env },
      log: options.log,
    })
    if (typeof child === "string") {
      event("command.fail", { argv, reason: child })
      return { exit: 126, reason: `o comando não partiu: ${child}` }
    }
    // Recorded before anything can wait: a runner that dies now leaves a command the process still knows.
    event("command.start", { pid: child.pid, argv })
    const identity = startOf(child.pid).then((started) => {
      if (started) event("command.identity", { pid: child.pid, startedAt: started })
    })
    const result = await follow(child, options.deadlineMs)
    await identity
    signal(child.pid, "SIGKILL")
    event("command.end", { pid: child.pid })
    return result
  }
  const follow = async (child: Bun.Subprocess, deadlineMs: number): Promise<Ended> => {
    const started = clock.awakeMs
    for (;;) {
      const done = await Promise.race([child.exited.then(() => true), Bun.sleep(timing.pollMs).then(() => false)])
      tick()
      if (done) return exited(child)
      const cause = cancelled() ? "cancelado" : clock.awakeMs - started > deadlineMs ? "prazo" : undefined
      if (!cause) continue
      await stop(child.pid, child.exited)
      return { cause }
    }
  }
  /** SIGTERM to the command's whole process group, then SIGKILL after the grace. */
  const stop = async (pid: number, exited: Promise<unknown>) => {
    signal(pid, "SIGTERM")
    const gone = await Promise.race([exited.then(() => true), Bun.sleep(timing.killGraceMs).then(() => false)])
    if (!gone) signal(pid, "SIGKILL")
    await exited
  }

  const env = (part: Attempt["parts"][number]) => ({
    BANCADA_JOB: attempt.job,
    BANCADA_TESTE: part.part,
    BANCADA_TENTATIVA: String(attempt.attempt),
    BANCADA_COMMIT: attempt.commit,
    BANCADA_OUT: path.join(dir, "parts", part.part, "out"),
  })
  const command = (argv: ReadonlyArray<string>, part: Attempt["parts"][number]) => [
    path.join(attempt.workdir, argv[0]!),
    ...argv.slice(1),
    ...part.args,
  ]
  const pending = () => attempt.parts.filter((part) => !ended.has(part.part))
  const endAll = (status: Omit<PartStatus, "endedAt" | "awakeMs">) =>
    pending().forEach((part) => finish(part.part, status))
  /** How a command's end closes a part at the current stage: a cause, or its exit (and signal, and reason). */
  const close = (part: string, result: Ended) =>
    finish(
      part,
      "cause" in result ? { stage: stage.current, cause: result.cause } : { stage: stage.current, ...result },
    )

  /** The argv lists of `commands` in the working folder, stopping at the first that does not exit 0. */
  const sequence = async (commands: ReadonlyArray<ReadonlyArray<string>>, log: string): Promise<Ended> => {
    for (const argv of commands) {
      const result = await execute(argv, { cwd: attempt.workdir, log, deadlineMs: attempt.deadlines.prepareMs })
      if (!("exit" in result) || result.exit !== 0) return result
    }
    return { exit: 0 }
  }

  const build = async (part: Attempt["parts"][number], argv: string[]) => {
    event("build.start", { part: part.part })
    const result = await execute(argv, {
      cwd: attempt.workdir,
      log: path.join(dir, "build.log"),
      env: env(part),
      deadlineMs: attempt.deadlines.buildMs,
    })
    event("build.end", { part: part.part, ...result })
    return result
  }
  /** In a reused folder a compile error is tried once more, from a folder cleaned of everything, caches included. */
  const buildOnce = async (part: Attempt["parts"][number], argv: string[]): Promise<Ended> => {
    const first = await build(part, argv)
    const compileError =
      "exit" in first && !first.signal && first.exit !== 0 && first.exit !== 2 && first.exit !== 75 && first.exit < 126
    if (!compileError || !attempt.reused) return first
    event("build.clean", { part: part.part })
    const scrubbed = await sequence(attempt.scrub, path.join(dir, "build.log"))
    if (!("exit" in scrubbed) || scrubbed.exit !== 0) return first
    const prepared = await sequence(attempt.prepare, path.join(dir, "checkout.log"))
    if (!("exit" in prepared) || prepared.exit !== 0) return first
    return build(part, argv)
  }

  const steps = async () => {
    attempt.parts.forEach((part) => fs.mkdirSync(path.join(dir, "parts", part.part, "out"), { recursive: true }))

    event("checkout")
    const checkout = await sequence(attempt.prepare, path.join(dir, "checkout.log"))
    if ("cause" in checkout) endAll({ stage: "build", cause: checkout.cause })
    if ("exit" in checkout && checkout.exit !== 0)
      endAll({ stage: "build", exit: 75, reason: checkout.reason ?? "o checkout falhou" })

    // Builds, in sequence, a repeated command once.
    const builds = new Map<string, Ended>()
    for (const part of pending()) {
      if (!part.build) continue
      const argv = command(part.build, part)
      const key = JSON.stringify(argv)
      const result = builds.get(key) ?? (await buildOnce(part, argv))
      builds.set(key, result)
      if (!("exit" in result) || result.exit !== 0) close(part.part, result)
    }

    stage.current = "plan"
    for (const part of pending()) {
      if (!part.plan) continue
      const result = await execute(command(part.plan, part), {
        cwd: attempt.workdir,
        log: path.join(dir, "parts", part.part, "out", "plan.log"),
        env: env(part),
        deadlineMs: attempt.deadlines.buildMs,
      })
      event("plan.end", { part: part.part, ...result })
      if (!("exit" in result) || result.exit !== 0) close(part.part, result)
    }

    // Devices: the process writes each part's devices.json when they are ready.
    stage.current = "run"
    event("devices.wait")
    const waitStarted = clock.awakeMs
    const unready = () => pending().filter((part) => !fs.existsSync(devices(dir, part.part)))
    while (unready().length > 0) {
      tick()
      if (cancelled()) endAll({ stage: "run", cause: "cancelado" })
      if (clock.awakeMs - waitStarted > attempt.deadlines.prepareMs)
        unready().forEach((part) =>
          finish(part.part, { stage: "run", cause: "prazo", reason: "os aparelhos não ficaram prontos" }),
        )
      await Bun.sleep(timing.pollMs)
    }

    // Runs, in parallel.
    await Promise.all(
      pending().map(async (part) => {
        const out = path.join(dir, "parts", part.part, "out")
        const only = part.only ? path.join(dir, "parts", part.part, "apenas") : undefined
        if (only) fs.writeFileSync(only, part.only!.join("\n") + "\n")
        const argv = command(part.run, part)
        event("run.start", { part: part.part })
        const result = await execute(
          part.secrets ? ["mycred", "run", "--keychain", part.secrets, "--mask", "--", ...argv] : argv,
          {
            cwd: attempt.workdir,
            log: path.join(out, "run.log"),
            env: { ...env(part), BANCADA_DEVICES: devices(dir, part.part), ...(only ? { BANCADA_APENAS: only } : {}) },
            deadlineMs: attempt.deadlines.runMs,
          },
        )
        event("run.end", { part: part.part, ...result })
        close(part.part, result)
      }),
    )
    if (cancelled()) event("cancelled")
  }

  // The runner never dies silently: whatever goes wrong in it closes the parts still open, with the reason.
  await steps().catch((error: unknown) => {
    const reason = error instanceof Error ? error.message : String(error)
    event("runner.error", { reason })
    endAll({ stage: stage.current, cause: "runner_erro", reason })
  })
  clearInterval(heartbeat)
  caffeinate?.kill()
  tick()
}

/**
 * A process's start time as the Bancada process reads it (`launcher/process.ts`): field 22 of `/proc/<pid>/stat` on
 * Linux; `ps -o lstart=` on macOS, in the C language and UTC (never the asker's), with a short deadline. Undefined
 * when it cannot be read.
 */
export async function startOf(pid: number, platform: NodeJS.Platform = process.platform) {
  if (platform === "linux") {
    const stat = readText(`/proc/${pid}/stat`)
    return stat?.slice(stat.lastIndexOf(")") + 2).split(" ")[19] || undefined
  }
  const child = spawn(["/bin/ps", "-o", "lstart=", "-p", String(pid)], {
    env: { LC_ALL: "C", TZ: "UTC", PATH: "/usr/bin:/bin" },
    timeoutMs: 5_000,
  })
  if (typeof child === "string" || !child.stdout || typeof child.stdout === "number") return undefined
  const [text, code] = await Promise.all([new Response(child.stdout).text(), child.exited])
  return code === 0 ? text.trim() || undefined : undefined
}

/**
 * Creates `file` with its whole content only if it does not exist: written aside, then linked under its name (the link
 * fails when the name exists). Used for `runner.json`, by the runner taking the attempt and by the process revoking it.
 */
export function createOnce(file: string, content: unknown) {
  const aside = `${file}.${process.pid}.${Date.now()}.tmp`
  fs.writeFileSync(aside, JSON.stringify(content))
  const created = link(aside, file)
  fs.rmSync(aside, { force: true })
  return created
}

/** The runner's own start time; a loaded Mac may miss a `ps`, so it asks a few times before giving up. */
async function ownStart() {
  for (const _ of [1, 2, 3]) {
    const started = await startOf(process.pid)
    if (started) return started
  }
  return undefined
}

/**
 * Starts a command in a session of its own, its output appended to `log`; the reason as text when it cannot start
 * (no execute permission, a `fork` that fails on a machine at its limit).
 */
function spawn(
  argv: string[],
  options: {
    readonly cwd?: string
    readonly env?: Record<string, string | undefined>
    readonly log?: string
    readonly timeoutMs?: number
  },
) {
  const log = options.log ? fs.openSync(options.log, "a") : undefined
  const started = attemptSpawn(() =>
    Bun.spawn(argv, {
      ...(options.cwd ? { cwd: options.cwd } : {}),
      ...(options.env ? { env: options.env } : {}),
      ...(options.timeoutMs ? { timeout: options.timeoutMs } : {}),
      stdin: "ignore",
      stdout: log ?? "pipe",
      stderr: log ?? "ignore",
      detached: log !== undefined,
    }),
  )
  if (log !== undefined) fs.closeSync(log)
  return started
}

function attemptSpawn(start: () => Bun.Subprocess) {
  try {
    return start()
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

/** How a command ended; killed by a signal it counts as `128 + n`, as a shell reports it. */
function exited(child: Bun.Subprocess): Ended {
  if (!child.signalCode) return { exit: child.exitCode ?? 128 }
  const number = os.constants.signals[child.signalCode as keyof typeof os.constants.signals] ?? 0
  return { exit: child.exitCode ?? 128 + number, signal: String(child.signalCode) }
}

function link(from: string, to: string) {
  try {
    fs.linkSync(from, to)
    return true
  } catch {
    return false
  }
}

function readText(file: string) {
  try {
    return fs.readFileSync(file, "utf8")
  } catch {
    return undefined
  }
}

function signal(pid: number, name: "SIGTERM" | "SIGKILL") {
  try {
    process.kill(-pid, name)
  } catch {
    // The group is already gone.
  }
}

function devices(dir: string, part: string) {
  return path.join(dir, "parts", part, "devices.json")
}

function writeJson(file: string, value: unknown) {
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(value))
  fs.renameSync(`${file}.tmp`, file)
}

const flagAt = process.argv.indexOf(runFlag)
if (flagAt >= 0 && process.argv[flagAt + 1]) await runAttempt(process.argv[flagAt + 1]!)
