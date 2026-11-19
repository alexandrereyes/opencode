// The detached execution of one attempt group (`docs/bancada.md`, "Execution"): prepares the working folder, builds,
// plans, waits for the devices and runs the parts, writing everything into the attempt's folder. A single file that
// imports nothing but `node:*` and Bun: the Bancada process copies it into the attempt's folder and runs that copy, so
// an execution needs only its folder (a release swapped meanwhile, or a container that mounts only that folder,
// changes nothing). Started as `<bun> <folder>/runner.(ts|js) --opencode-bancada-run <folder>`.
import fs from "node:fs"
import path from "node:path"

export const runFlag = "--opencode-bancada-run"

/** `attempt.json`, written by the process before the start and never changed (format 1). */
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
  readonly cause?: "prazo" | "runner_morto" | "cancelado"
  readonly reason?: string
  readonly endedAt: number
  readonly awakeMs: number
}

type Ended = { readonly exit: number; readonly signal?: string } | { readonly cause: "prazo" | "cancelado" }

/**
 * Awake time: each step adds what passed since the last one, but never more than `clampMs`, so a machine that slept
 * does not count its sleep against any deadline (a step cannot run while it sleeps).
 */
export function awake(total: number, last: number, now: number, clampMs: number) {
  return total + Math.min(Math.max(0, now - last), clampMs)
}

export async function runAttempt(dir: string) {
  const attempt: Attempt = JSON.parse(fs.readFileSync(path.join(dir, "attempt.json"), "utf8"))
  // Set only so the compiled server binary behaves as Bun; the project's commands must not inherit it.
  delete process.env.BUN_BE_BUN
  delete process.env.OPENCODE_BANCADA_PARENT
  delete process.env.OPENCODE_BANCADA_STATE
  if (!claim(dir)) return
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
  const groups = new Set<number>()
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

  /** Runs one command in a session of its own; stops it (and everything it started) at the deadline or a cancel. */
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
    const log = fs.openSync(options.log, "a")
    const child = Bun.spawn([...(attempt.lowPriority ? ["nice", "-n", "10"] : []), ...argv], {
      cwd: options.cwd,
      env: { ...process.env, ...attempt.env, ...options.env },
      stdin: "ignore",
      stdout: log,
      stderr: log,
      detached: true,
    })
    fs.closeSync(log)
    groups.add(child.pid)
    event("command.start", { pid: child.pid, argv })
    const started = clock.awakeMs
    for (;;) {
      const done = await Promise.race([child.exited.then(() => true), Bun.sleep(timing.pollMs).then(() => false)])
      tick()
      if (done)
        return { exit: child.exitCode ?? 128, ...(child.signalCode ? { signal: String(child.signalCode) } : {}) }
      const cause = cancelled() ? "cancelado" : clock.awakeMs - started > options.deadlineMs ? "prazo" : undefined
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
  attempt.parts.forEach((part) => fs.mkdirSync(path.join(dir, "parts", part.part, "out"), { recursive: true }))
  const pending = () => attempt.parts.filter((part) => !ended.has(part.part))
  const endAll = (status: Omit<PartStatus, "endedAt" | "awakeMs">) =>
    pending().forEach((part) => finish(part.part, status))

  /** The argv lists of `commands` in the working folder, stopping at the first that does not exit 0. */
  const sequence = async (commands: ReadonlyArray<ReadonlyArray<string>>, log: string): Promise<Ended> => {
    for (const argv of commands) {
      const result = await execute(argv, { cwd: attempt.workdir, log, deadlineMs: attempt.deadlines.prepareMs })
      if (!("exit" in result) || result.exit !== 0) return result
    }
    return { exit: 0 }
  }

  // Checkout.
  event("checkout")
  const checkout = await sequence(attempt.prepare, path.join(dir, "checkout.log"))
  if ("cause" in checkout) endAll({ stage: "build", cause: checkout.cause })
  else if (checkout.exit !== 0) endAll({ stage: "build", exit: 75, reason: "o checkout falhou" })

  // Builds, in sequence, a repeated command once.
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
    const compileError = "exit" in first && first.exit !== 0 && first.exit !== 2 && first.exit !== 75
    if (!compileError || !attempt.reused) return first
    event("build.clean", { part: part.part })
    const scrubbed = await sequence(attempt.scrub, path.join(dir, "build.log"))
    if (!("exit" in scrubbed) || scrubbed.exit !== 0) return first
    const prepared = await sequence(attempt.prepare, path.join(dir, "checkout.log"))
    if (!("exit" in prepared) || prepared.exit !== 0) return first
    return build(part, argv)
  }
  const builds = new Map<string, Ended>()
  for (const part of pending()) {
    if (!part.build) continue
    const argv = command(part.build, part)
    const key = JSON.stringify(argv)
    const result = builds.get(key) ?? (await buildOnce(part, argv))
    builds.set(key, result)
    if ("cause" in result) finish(part.part, { stage: "build", cause: result.cause })
    else if (result.exit !== 0) finish(part.part, { stage: "build", exit: result.exit, ...signalOf(result) })
  }

  // Plans.
  for (const part of pending()) {
    if (!part.plan) continue
    const result = await execute(command(part.plan, part), {
      cwd: attempt.workdir,
      log: path.join(dir, "parts", part.part, "out", "plan.log"),
      env: env(part),
      deadlineMs: attempt.deadlines.buildMs,
    })
    event("plan.end", { part: part.part, ...result })
    if ("cause" in result) finish(part.part, { stage: "plan", cause: result.cause })
    else if (result.exit !== 0) finish(part.part, { stage: "plan", exit: result.exit, ...signalOf(result) })
  }

  // Devices: the process writes each part's devices.json when they are ready.
  event("devices.wait")
  const waitStarted = clock.awakeMs
  while (pending().some((part) => !fs.existsSync(devices(dir, part.part)))) {
    if (cancelled()) endAll({ stage: "run", cause: "cancelado" })
    else if (clock.awakeMs - waitStarted > attempt.deadlines.prepareMs)
      pending()
        .filter((part) => !fs.existsSync(devices(dir, part.part)))
        .forEach((part) =>
          finish(part.part, { stage: "run", cause: "prazo", reason: "os aparelhos não ficaram prontos" }),
        )
    else await Bun.sleep(timing.pollMs)
    tick()
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
      if ("cause" in result) finish(part.part, { stage: "run", cause: result.cause })
      else finish(part.part, { stage: "run", exit: result.exit, ...signalOf(result) })
    }),
  )
  if (cancelled()) event("cancelled")

  // Whatever the commands left running in their groups goes too.
  groups.forEach((pid) => signal(pid, "SIGKILL"))
  clearInterval(heartbeat)
  caffeinate?.kill()
  tick()
}

/**
 * Takes the attempt: `runner.json` is created only if absent, so a second start (the process came back before this
 * runner wrote it) leaves at once. It holds this process's pid and start time, the identity the process checks.
 */
function claim(dir: string) {
  const file = path.join(dir, "runner.json")
  const content = JSON.stringify({ pid: process.pid, startedAt: ownStart() })
  try {
    fs.writeFileSync(file, content, { flag: "wx" })
    return true
  } catch {
    return false
  }
}

/** This process's start time, as the process reads it (`launcher/process.ts`): `/proc` field 22, or `ps` lstart. */
function ownStart() {
  if (process.platform === "linux") {
    const stat = fs.readFileSync("/proc/self/stat", "utf8")
    return stat.slice(stat.lastIndexOf(")") + 2).split(" ")[19] ?? ""
  }
  const result = Bun.spawnSync(["/bin/ps", "-o", "lstart=", "-p", String(process.pid)])
  return result.stdout.toString().trim()
}

function signal(pid: number, name: "SIGTERM" | "SIGKILL") {
  try {
    process.kill(-pid, name)
  } catch {
    // The group is already gone.
  }
}

function signalOf(result: Ended) {
  return "signal" in result && result.signal ? { signal: result.signal } : {}
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
