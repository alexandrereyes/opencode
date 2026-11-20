import { closeSync, existsSync, openSync } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Option, Schema } from "effect"
import type { Ending } from "../../results.js"
import { CodeMissing, type Launch, type Launcher, type Placed, type Status } from "../executor.js"
import type { Git } from "../git.js"
import { createOnce, runFlag, type Attempt, type Claim, type Event, type PartStatus } from "../runner.js"
import { contractAt } from "../snapshot.js"
import { prepareCommands, scrubCommands, type Workdirs } from "../workdir.js"

/**
 * What the system says about a process: `alive` with its start time, `dead` with proof, or `unknown` when it could not
 * be asked. With the pid, the start time is the process's identity: a reused pid has another one. Never the command
 * line, never the parent (when a parent dies its children's ppid becomes 1 and a live process would look dead, prova
 * E1). `unknown` is never `dead`: on a Mac at load 600 a `ps` that misses its deadline or a `fork` that fails is the
 * expected case; whoever asked keeps what it knew and asks again next time (`docs/bancada.md`, "Execution").
 */
export type Liveness =
  | { readonly state: "alive"; readonly started: string }
  | { readonly state: "dead" }
  | { readonly state: "unknown" }

const dead: Liveness = { state: "dead" }
const unknown: Liveness = { state: "unknown" }

/** Deadline of one `ps` on macOS. */
export const psTimeoutMs = 5_000

export async function liveness(pid: number, platform: NodeJS.Platform = process.platform): Promise<Liveness> {
  if (!Number.isInteger(pid) || pid <= 0) return dead
  const signal = signalZero(pid)
  if (signal === "absent") return dead
  if (platform === "linux")
    return fromStat(
      await Bun.file(`/proc/${pid}/stat`)
        .text()
        .then(
          (text) => ({ text }),
          (error: unknown) => ({ error: code(error) }),
        ),
    )
  const answer = await ps(pid)
  return fromPs(answer, () => signalZero(pid) === "absent")
}

/**
 * `/proc/<pid>/stat`: the state is field 3 and the start time field 22, counted after the command name. A missing
 * file is proof the process is gone; any other failure to read it is not.
 */
export function fromStat(read: { readonly text: string } | { readonly error: string | undefined }): Liveness {
  if ("error" in read) return read.error === "ENOENT" || read.error === "ESRCH" ? dead : unknown
  // The command name sits in parentheses and may hold spaces and parentheses itself.
  const close = read.text.lastIndexOf(")")
  if (close < 0) return unknown
  const fields = read.text.slice(close + 2).split(" ")
  if (fields[0] === "Z" || fields[0] === "X") return dead
  const started = fields[19]
  return started ? { state: "alive", started } : unknown
}

/**
 * `ps -o stat=,lstart= -p <pid>` on macOS (`S    Thu Nov 19 17:31:12 2026`). Exit 1 with nothing printed is also what
 * `ps` answers when it fails by itself (`ps -p 999999`: "process id too large"), so it proves the process gone only if
 * `kill(pid, 0)` asked afterwards says `ESRCH` (`absent`). A `ps` that did not run or missed its deadline is no answer.
 */
export function fromPs(
  result: { readonly code: number; readonly stdout: string } | undefined,
  absent: () => boolean,
): Liveness {
  if (!result) return unknown
  const line = result.stdout.trim()
  if (result.code === 1 && line === "") return absent() ? dead : unknown
  if (result.code !== 0 || line === "") return unknown
  if (line.startsWith("Z")) return dead
  const space = line.search(/\s/)
  const started = space < 0 ? "" : line.slice(space).trim()
  return started ? { state: "alive", started } : unknown
}

/** `kill(pid, 0)`: `ESRCH` proves the pid does not exist; `EPERM` means it exists and belongs to someone else. */
function signalZero(pid: number): "present" | "absent" | "unknown" {
  try {
    process.kill(pid, 0)
    return "present"
  } catch (error) {
    if (code(error) === "ESRCH") return "absent"
    return code(error) === "EPERM" ? "present" : "unknown"
  }
}

/**
 * The environment of every `ps` that reads a start time, here and in the runner: without it the text follows the
 * asker's language and time zone ("Thu Nov 19 19:40:31", "qui 19 nov 19:40:31", "Thu Nov 19 22:40:31" for one process
 * on the Mac) and a live runner would pass for another process with its pid.
 */
export const psEnv = { LC_ALL: "C", TZ: "UTC", PATH: "/usr/bin:/bin" }

async function ps(pid: number) {
  const child = spawn(["/bin/ps", "-o", "stat=,lstart=", "-p", String(pid)])
  if (!child) return undefined
  const [stdout, exit] = await Promise.all([new Response(child.stdout).text(), child.exited])
  // Killed by the deadline: no answer.
  return child.signalCode ? undefined : { code: exit, stdout }
}

/** A `fork` that fails (the Mac out of processes or memory) is no answer, not an error to raise. */
function spawn(argv: string[]) {
  try {
    return Bun.spawn(argv, { env: psEnv, stdin: "ignore", stdout: "pipe", stderr: "ignore", timeout: psTimeoutMs })
  } catch {
    return undefined
  }
}

function code(error: unknown) {
  return typeof error === "object" && error !== null && "code" in error && typeof error.code === "string"
    ? error.code
    : undefined
}

/** Where the runner to copy is: beside the daemon in source and `dist`, or the release's single bundle itself. */
export function runnerSource(module = fileURLToPath(import.meta.url)) {
  const beside = path.join(path.dirname(module), "..", module.endsWith(".ts") ? "runner.ts" : "runner.js")
  return existsSync(beside) ? beside : module
}

export type Deadlines = Attempt["deadlines"]

export const defaults = {
  deadlines: { prepareMs: 10 * 60_000, buildMs: 30 * 60_000, runMs: 60 * 60_000 } satisfies Deadlines,
  /** How long a start this process gave may wait for its runner to take the attempt before it is revoked. */
  startGraceMs: 60_000,
  /** A heartbeat younger than this many beats proves the runner alive without asking the system. */
  beats: 3,
  heartbeatMs: 5_000,
  killGraceMs: 10_000,
  /** Orphans that cannot be proven ours (or gone) for this long raise an alert in the log. */
  stuckAlertMs: 10 * 60_000,
  /** How long an answer about a runner asked off the round stays good for the round that takes it. */
  answerMs: 30_000,
  logTailLines: 30,
}

/**
 * Executions as detached processes (`docs/bancada.md`, "Execution"): the Mac, a Linux without Docker, and the tests.
 * Starting an attempt brings its commit into a working folder, reads the contract of that commit (only what it says
 * runs, never a command from a message), writes `attempts/<job>/<part>-<attempt>/attempt.json`, copies the runner there
 * and starts it in a session of its own, so neither the server's nor this process's end touches it. Its state is read
 * back from that folder alone; who is alive is decided by the heartbeat, then by pid and start time, and "could not
 * ask" is never "dead". Only `start` and the reaping take long, and the executor runs them off its round.
 */
export function makeProcessLauncher(input: {
  readonly state: string
  readonly workdirs: Workdirs
  readonly git: Git
  readonly now: () => number
  readonly random: () => string
  readonly deadlines?: Deadlines
  readonly timing?: Attempt["timing"]
  readonly startGraceMs?: number
  readonly lowPriority?: boolean
  readonly runner?: string
  /** Asks for a round: an answer about a process came, or a reaping ended. */
  readonly wake?: () => void
  /** Whose way of asking about a process: `/proc` on Linux, `ps` off the round elsewhere. */
  readonly platform?: NodeJS.Platform
  readonly log?: (line: string) => void
}): Launcher {
  const folder = (key: { job: string; group: string }) => path.join(input.state, "attempts", key.job, key.group)
  /** A group's name: the owner of its working folder, and what a start this process gave is kept by. */
  const name = (key: { job: string; group: string }) => `${key.job}/${key.group}`
  /** When this process last started each attempt: the grace of a start counts from here, never from a file's date. */
  const given = new Map<string, number>()
  const reaping = new Set<string>()
  const stuck = new Map<string, { since: number; alerted: boolean }>()
  /** Answers about runners asked off the round, by attempt and `runner.json` (a pid alone may be someone else's later). */
  const asked = new Map<string, { result?: Liveness; at?: number }>()
  const json = async <T>(file: string) =>
    (await Bun.file(file)
      .json()
      .catch(() => undefined)) as T | undefined
  const text = (file: string) =>
    Bun.file(file)
      .text()
      .catch(() => "")
  const tail = async (file: string) =>
    (await text(file)).trimEnd().split("\n").slice(-defaults.logTailLines).join("\n").slice(-4_000)
  /** `attempt.json` when it is whole; a cut one (written before renames, or a broken disk) is written again. */
  const stored = async (dir: string) => {
    const attempt = await json<Stored>(path.join(dir, "attempt.json"))
    return attempt?.format === 1 ? attempt : undefined
  }

  /**
   * On the Mac a `ps` may take seconds under load, and the round never waits: the question runs on its own and the
   * next round takes the answer, if it is that attempt's and that runner's and younger than `answerMs`; it goes when
   * used, when old, or when the attempt ends. On Linux it is a read of `/proc`.
   */
  const platform = input.platform ?? process.platform
  const ask = async (key: Placed, claim: { pid: number; startedAt: string }): Promise<Liveness> => {
    if (platform === "linux") return liveness(claim.pid, platform)
    const id = `${name(key)}:${claim.pid}:${claim.startedAt}`
    const entry = asked.get(id)
    if (entry?.result && entry.at !== undefined && input.now() - entry.at <= defaults.answerMs) {
      asked.delete(id)
      return entry.result
    }
    if (entry && !entry.result) return unknown
    const fresh: { result?: Liveness; at?: number } = {}
    asked.set(id, fresh)
    void liveness(claim.pid, platform)
      .then((answer) => {
        fresh.result = answer
        fresh.at = input.now()
        input.wake?.()
      })
      .catch((error: unknown) => {
        asked.delete(id)
        input.log?.(`asking about runner ${claim.pid} failed: ${String(error)}`)
      })
    return unknown
  }
  const forget = (key: { job: string; group: string }) =>
    [...asked.keys()].filter((id) => id.startsWith(`${name(key)}:`)).forEach((id) => asked.delete(id))
  /**
   * The runner of a live attempt: a fresh heartbeat proves it alive; only a stale one asks the system. Giving back
   * (`reap`) asks the system at once: after a normal end the heartbeat stays fresh for three beats.
   */
  const runner = async (
    key: Placed,
    dir: string,
    attempt: Stored,
    claim: { pid: number; startedAt: string },
    from: "round" | "reap",
  ) => {
    const beat = from === "round" ? await json<{ at: number }>(path.join(dir, "heartbeat")) : undefined
    const every = attempt.timing?.heartbeatMs ?? defaults.heartbeatMs
    if (beat && input.now() - beat.at < defaults.beats * every) return "alive"
    const life = from === "reap" ? await liveness(claim.pid, platform) : await ask(key, claim)
    if (life.state === "unknown") return "unknown"
    return life.state === "alive" && life.started === claim.startedAt ? "alive" : "dead"
  }

  /** How an attempt ended, from its folder: the status the runner wrote, the project's two files, the log's end. */
  const ending = async (dir: string, attempt: Stored, part: string, status: PartStatus | undefined) => {
    const events = await text(path.join(dir, "events.jsonl"))
    const stage = status?.stage ?? (events.includes('"type":"run.start"') ? "run" : "build")
    const out = path.join(dir, "parts", part, "out")
    const log =
      stage === "build" ? path.join(dir, "build.log") : path.join(out, stage === "plan" ? "plan.log" : "run.log")
    const only = attempt.parts.find((item) => item.part === part)?.only
    return {
      stage,
      ...(status?.exit === undefined ? {} : { exit: status.exit }),
      ...(status?.signal ? { signal: status.signal } : {}),
      ...(status ? (status.cause ? { cause: status.cause } : {}) : { cause: "runner_morto" as const }),
      ...(status?.reason ? { reason: status.reason } : {}),
      ...(status?.sleptMs ? { sleptMs: status.sleptMs } : {}),
      planned: await json(path.join(out, "planned.json")),
      summary: await json(path.join(out, "summary.json")),
      ...(only ? { only } : {}),
      logTail: await tail(log),
    } satisfies Ending
  }

  const status = async (key: Placed): Promise<Status> => {
    const answer = await follow(key)
    if (answer.state === "done" || answer.state === "gone") forget(key)
    return answer
  }
  const follow = async (key: Placed): Promise<Status> => {
    const dir = folder(key)
    const read = () => json<PartStatus>(path.join(dir, "parts", key.part, "status.json"))
    const attempt = await stored(dir)
    const written = await read()
    if (attempt && written) return { state: "done", ending: await ending(dir, attempt, key.part, written) }
    const claim = await json<Claim>(path.join(dir, "runner.json"))
    if (!claim) return unclaimed(key, dir)
    if ("revoked" in claim) return { state: "gone", reason: "a execução não começou" }
    if (!attempt) throw new Error("o attempt.json de uma tentativa em curso não pôde ser lido")
    const life = await runner(key, dir, attempt, claim, "round")
    if (life === "unknown") throw new Error("não foi possível saber se a execução segue")
    if (life === "alive")
      return {
        state: (await text(path.join(dir, "events.jsonl"))).includes('"type":"run.start"') ? "rodando" : "compilando",
      }
    // The runner is gone (or another process took its pid): it may have written the status just before.
    return { state: "done", ending: await ending(dir, attempt, key.part, await read()) }
  }

  /**
   * No runner took the attempt yet; it may just be late (a Mac at its limit, or asleep right after the start). One this
   * process never started is started again (a restart). Past the grace, giving up takes the attempt from the runner by
   * the door it uses to take it: `runner.json` created by this process, so one that comes later leaves at once.
   */
  const unclaimed = async (key: Placed, dir: string): Promise<Status> => {
    const at = given.get(name(key))
    if (at === undefined) return { state: "unstarted" }
    if (input.now() - at <= (input.startGraceMs ?? defaults.startGraceMs)) return { state: "compilando" }
    if (createOnce(path.join(dir, "runner.json"), { revoked: true, at: input.now() } satisfies Claim))
      return { state: "gone", reason: "a execução não começou" }
    // A runner took it just now.
    return follow(key)
  }

  /**
   * What an attempt that no longer lives still holds goes back only when nothing it started runs: its runner is dead,
   * and each command group without `command.end` is ended with proof it is ours (`docs/bancada.md`, "Orphans").
   */
  const sweep = async (key: { job: string; group: string }) => {
    const dir = folder(key)
    const attempt = await stored(dir)
    const claim = await json<Claim>(path.join(dir, "runner.json"))
    if (
      attempt &&
      claim &&
      "pid" in claim &&
      (await runner({ ...key, part: "", attempt: 0 }, dir, attempt, claim, "reap")) !== "dead"
    )
      return { free: false, commit: attempt.commit }
    const open = openCommands(await text(path.join(dir, "events.jsonl")))
    const grace = attempt?.timing?.killGraceMs ?? defaults.killGraceMs
    const results = await Promise.all(open.map((command) => orphan(command.pid, command.startedAt, grace)))
    return { free: results.every(Boolean), ...(attempt ? { commit: attempt.commit } : {}) }
  }

  return {
    start: async (launch) => {
      const dir = folder(launch)
      if (await Bun.file(path.join(dir, "runner.json")).exists()) return
      if (!(await stored(dir))) await write(launch, dir)
      const source = input.runner ?? runnerSource()
      const copy = path.join(dir, `runner${path.extname(source) || ".js"}`)
      if (!(await Bun.file(copy).exists())) {
        const aside = `${copy}.${input.random()}.tmp`
        await fs.copyFile(source, aside)
        await fs.rename(aside, copy)
      }
      const log = openSync(path.join(dir, "runner.log"), "a", 0o600)
      const child = Bun.spawn([process.execPath, copy, runFlag, dir], {
        cwd: dir,
        detached: true,
        env: { ...process.env, BUN_BE_BUN: "1" },
        stdin: "ignore",
        stdout: log,
        stderr: log,
      })
      closeSync(log)
      child.unref()
      given.set(name(launch), input.now())
    },

    status,

    cancel: async (key) => {
      const dir = path.join(folder(key), "parts", key.part)
      if (await fs.exists(dir)) await Bun.write(path.join(dir, "cancel"), String(input.now()))
    },

    stop: async (key) => {
      const dir = folder(key)
      const attempt = await stored(dir)
      const claim = await json<Claim>(path.join(dir, "runner.json"))
      if (!claim || !("pid" in claim)) return
      await orphan(claim.pid, claim.startedAt, attempt?.timing?.killGraceMs ?? defaults.killGraceMs, platform)
    },

    reap: async (live) => {
      const alive = new Set(live.map(name))
      for (const held of input.workdirs.held()) {
        const slash = held.owner.indexOf("/")
        const job = held.owner.slice(0, slash)
        const group = held.owner.slice(slash + 1)
        if (alive.has(held.owner) || reaping.has(held.owner) || slash < 1 || !group) continue
        reaping.add(held.owner)
        // Off the round, and never a loose rejection (it would end this process): a failure is tried next round.
        void sweep({ job, group })
          .then((result) => {
            if (result.free) {
              stuck.delete(held.owner)
              return input.workdirs.release(held, result.commit)
            }
            const known = stuck.get(held.owner) ?? { since: input.now(), alerted: false }
            stuck.set(held.owner, known)
            if (known.alerted || input.now() - known.since < defaults.stuckAlertMs) return
            known.alerted = true
            input.log?.(
              `alert: ${held.owner} still holds ${held.path}: processes it started could not be proven gone or ours`,
            )
          })
          .catch((error: unknown) => input.log?.(`giving back what ${held.owner} holds failed: ${String(error)}`))
          .finally(() => {
            reaping.delete(held.owner)
            input.wake?.()
          })
      }
    },

    held: (key) => reaping.has(name(key)) || input.workdirs.held().some((held) => held.owner === name(key)),

    cleanup: async (key) => {
      if (input.workdirs.held().some((held) => held.owner === name(key)))
        throw new Error("a pasta de trabalho ainda está presa à tentativa")
      forget(key)
      const dir = folder(key)
      const attempt = await stored(dir)
      if (attempt)
        await input.workdirs.forget({ id: attempt.workdirID, project: attempt.project, path: attempt.workdir }, key.job)
      await fs.rm(dir, { recursive: true, force: true })
      await fs.rmdir(path.dirname(dir)).catch(() => undefined)
      given.delete(name(key))
    },
  }

  /** The commit into a working folder, the contract of that commit, and `attempt.json` (by rename), before the start. */
  async function write(launch: Launch, dir: string) {
    const workdir = await input.workdirs.acquire(launch.code.project, launch.code.commit, name(launch))
    const fetched = await input.workdirs.fetch(workdir, launch.code.commit, {
      job: launch.job,
      ...(launch.repository ? { local: { repository: launch.repository } } : {}),
      ...(launch.code.inRemote && launch.code.remotes[0] ? { remote: { url: launch.code.remotes[0] } } : {}),
      ...(launch.bundle ? { bundle: { file: launch.bundle } } : {}),
    })
    if (!fetched.ok) {
      input.workdirs.release(workdir)
      const reason = `o código não chegou (${fetched.tried.join("; ") || "nenhuma fonte"})`
      // Without the origin's bundle yet, the executor asks for it through the hub; with it, the bundle was bad.
      throw launch.bundle ? new Error(reason) : new CodeMissing(reason)
    }
    const contract = await contractAt(input.git, workdir.path, launch.code.commit, launch.code.project)
    const missing = contract.ok ? launch.parts.filter((part) => !contract.contract.tests[part.part]) : []
    if (!contract.ok || missing.length > 0) {
      input.workdirs.release(workdir)
      throw new Error(
        contract.ok
          ? missing.map((part) => `o teste ${part.part} não existe neste commit`).join("; ")
          : contract.problems.join("; "),
      )
    }
    const deadlines = input.deadlines ?? defaults.deadlines
    const tests = launch.parts.map((part) => ({ part, test: contract.contract.tests[part.part]! }))
    // One runner runs the group: the longest deadline of its parts.
    const longest = Math.max(0, ...tests.map((item) => item.test.deadlineMin ?? 0))
    const attempt: Stored = {
      format: 1,
      job: launch.job,
      group: launch.group,
      attempt: launch.parts[0]!.attempt,
      commit: launch.code.commit,
      token: input.random(),
      workdir: workdir.path,
      workdirID: workdir.id,
      project: launch.code.project,
      reused: workdir.reused === true,
      prepare: prepareCommands(launch.code.commit, contract.contract.caches),
      scrub: scrubCommands(),
      parts: tests.map(({ part, test }) => ({
        part: part.part,
        attempt: part.attempt,
        ...(test.build ? { build: test.build } : {}),
        ...(test.plan ? { plan: test.plan } : {}),
        run: test.run,
        args: part.spec.args,
        ...(test.secrets ? { secrets: test.secrets } : {}),
        ...(part.only ? { only: part.only } : {}),
      })),
      deadlines: longest ? { ...deadlines, runMs: longest * 60_000 } : deadlines,
      ...(input.timing ? { timing: input.timing } : {}),
      lowPriority: input.lowPriority === true,
    }
    for (const part of launch.parts) {
      await fs.mkdir(path.join(dir, "parts", part.part, "out"), { recursive: true })
      if (part.devices === 0)
        await Bun.write(
          path.join(dir, "parts", part.part, "devices.json"),
          JSON.stringify({ versao: 1, aparelhos: [] }),
        )
    }
    await Bun.write(path.join(dir, "attempt.json.tmp"), JSON.stringify(attempt, null, 2))
    await fs.rename(path.join(dir, "attempt.json.tmp"), path.join(dir, "attempt.json"))
  }
}

const decodeEvent = Schema.decodeUnknownOption(
  Schema.fromJsonString(
    Schema.Struct({
      type: Schema.String,
      pid: Schema.optional(Schema.Number),
      startedAt: Schema.optional(Schema.String),
    }),
  ),
)

/**
 * The commands of `events.jsonl` without `command.end`, with the start time a `command.identity` line gave. A line
 * that is not whole JSON (a disk that filled up midway) is skipped: one bad line never hides the others.
 */
export function openCommands(text: string) {
  const events = text.split("\n").flatMap((line) => Option.toArray(decodeEvent(line))) as Event[]
  const ended = new Set(events.flatMap((event) => (event.type === "command.end" && event.pid ? [event.pid] : [])))
  const identity = new Map(
    events.flatMap((event) =>
      event.type === "command.identity" && event.pid && event.startedAt ? [[event.pid, event.startedAt] as const] : [],
    ),
  )
  return events
    .flatMap((event) => (event.type === "command.start" && event.pid && !ended.has(event.pid) ? [event.pid] : []))
    .map((pid) => ({ pid, startedAt: identity.get(pid) }))
}

/**
 * Ends a command group a dead runner left, only with proof it is ours (`docs/bancada.md`, "Orphans"); true when nothing
 * of it is left. Its leader alive with the start time recorded: ours, SIGTERM to the group, the grace, SIGKILL. Alive
 * with another start time: the number was reused, so nothing of ours is left. Gone while the group still has members:
 * the system never reuses a number that is still a live group's id, so they are ours: SIGKILL. Could not ask, or no
 * start time recorded with the leader alive: touch nothing, ask again on the next round.
 */
export async function orphan(
  pid: number,
  startedAt: string | undefined,
  graceMs: number,
  platform: NodeJS.Platform = process.platform,
) {
  const leader = await liveness(pid, platform)
  if (leader.state === "unknown") return false
  if (leader.state === "alive" && (!startedAt || leader.started !== startedAt)) return startedAt !== undefined
  if (leader.state === "alive") {
    group(pid, "SIGTERM")
    await settle(pid, graceMs)
  }
  if (groupAlive(pid)) group(pid, "SIGKILL")
  await settle(pid, 1_000)
  return !groupAlive(pid)
}

/** Waits up to `ms` for a process group to be empty. */
async function settle(pid: number, ms: number) {
  const deadline = Date.now() + ms
  while (groupAlive(pid) && Date.now() < deadline) await Bun.sleep(50)
}

/** `kill(-pgid, 0)`: the group still has members (`EPERM` too: they exist, someone else's). */
function groupAlive(pid: number) {
  try {
    process.kill(-pid, 0)
    return true
  } catch (error) {
    return code(error) === "EPERM"
  }
}

function group(pid: number, name: "SIGTERM" | "SIGKILL") {
  try {
    process.kill(-pid, name)
  } catch {
    // The group is already gone.
  }
}

/** `attempt.json` as this process writes it: the runner's fields and where its working folder is. */
type Stored = Attempt & { readonly workdirID: string; readonly project: string }
