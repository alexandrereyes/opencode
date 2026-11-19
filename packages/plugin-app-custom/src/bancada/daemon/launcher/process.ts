import { closeSync, existsSync, openSync } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import { fileURLToPath } from "node:url"
import type { Ending } from "../../results.js"
import type { AttemptKey, Launch, Launcher, Status } from "../executor.js"
import type { Git } from "../git.js"
import { runFlag, type Attempt, type PartStatus } from "../runner.js"
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
  return fromPs(await ps(pid))
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
 * `ps -o stat=,lstart= -p <pid>` on macOS (`S    Thu Nov 19 17:31:12 2026`). Exit 1 with nothing printed is proof the
 * process is gone; a `ps` that did not run, missed its deadline or failed otherwise is not.
 */
export function fromPs(result: { readonly code: number; readonly stdout: string } | undefined): Liveness {
  if (!result) return unknown
  const line = result.stdout.trim()
  if (result.code === 1 && line === "") return dead
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
    return Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "ignore", timeout: psTimeoutMs })
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
  /** How long an attempt folder may wait for its runner to write `runner.json` before it counts as never started. */
  startGraceMs: 60_000,
  logTailLines: 30,
}

/**
 * Executions as detached processes (`docs/bancada.md`, "Execution"): the Mac, a Linux without Docker, and the tests.
 * Starting an attempt brings its commit into a working folder, reads the contract of that commit (only what it says
 * runs, never a command from a message), writes `attempts/<job>/<part>-<attempt>/attempt.json`, copies the runner there
 * and starts it in a session of its own, so neither the server's nor this process's end touches it. Its state is read
 * back from that folder alone; who is alive is decided by pid and start time, and "could not ask" is never "dead".
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
}): Launcher {
  const folder = (key: AttemptKey) => path.join(input.state, "attempts", key.job, `${key.part}-${key.attempt}`)
  const json = async <T>(file: string) =>
    (await Bun.file(file)
      .json()
      .catch(() => undefined)) as T | undefined
  const tail = async (file: string) => {
    const text = await Bun.file(file)
      .text()
      .catch(() => "")
    return text.trimEnd().split("\n").slice(-defaults.logTailLines).join("\n").slice(-4_000)
  }

  /** How an attempt ended, from its folder: the status the runner wrote, the project's two files, the log's end. */
  const ending = async (dir: string, attempt: Stored, part: string, status: PartStatus | undefined) => {
    const events = await Bun.file(path.join(dir, "events.jsonl"))
      .text()
      .catch(() => "")
    const stage = status?.stage ?? (events.includes('"type":"run.start"') ? "run" : "build")
    const out = path.join(dir, "parts", part, "out")
    const log =
      stage === "build" ? path.join(dir, "build.log") : path.join(out, stage === "plan" ? "plan.log" : "run.log")
    const only = attempt.parts.find((item) => item.part === part)?.only
    return {
      stage,
      ...(status?.exit === undefined ? {} : { exit: status.exit }),
      ...(status ? (status.cause ? { cause: status.cause } : {}) : { cause: "runner_morto" as const }),
      planned: await json(path.join(out, "planned.json")),
      summary: await json(path.join(out, "summary.json")),
      ...(only ? { only } : {}),
      logTail: await tail(log),
    } satisfies Ending
  }

  return {
    start: async (launch) => {
      const dir = folder(launch)
      if (await Bun.file(path.join(dir, "runner.json")).exists()) return
      if (!(await Bun.file(path.join(dir, "attempt.json")).exists())) await write(launch, dir)
      const source = input.runner ?? runnerSource()
      const copy = path.join(dir, `runner${path.extname(source) || ".js"}`)
      await fs.copyFile(source, copy)
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
    },

    status: async (key): Promise<Status> => {
      const dir = folder(key)
      const attempt = await json<Stored>(path.join(dir, "attempt.json"))
      if (!attempt) return { state: "gone", reason: "a execução não começou" }
      const read = () => json<PartStatus>(path.join(dir, "parts", key.part, "status.json"))
      const written = await read()
      if (written) return { state: "done", ending: await ending(dir, attempt, key.part, written) }
      const runner = await json<{ pid: number; startedAt: string }>(path.join(dir, "runner.json"))
      if (!runner) {
        const age = input.now() - (await fs.stat(path.join(dir, "attempt.json"))).mtimeMs
        return age > (input.startGraceMs ?? defaults.startGraceMs)
          ? { state: "gone", reason: "a execução não começou" }
          : { state: "compilando" }
      }
      const life = await liveness(runner.pid)
      if (life.state === "unknown") throw new Error("não foi possível saber se a execução segue")
      if (life.state === "alive" && life.started === runner.startedAt) {
        const events = await Bun.file(path.join(dir, "events.jsonl"))
          .text()
          .catch(() => "")
        return { state: events.includes('"type":"run.start"') ? "rodando" : "compilando" }
      }
      // The runner is gone (or another process took its pid): it may have written the status just before.
      return { state: "done", ending: await ending(dir, attempt, key.part, await read()) }
    },

    cancel: async (key) => {
      const dir = folder(key)
      if (await fs.exists(dir)) await Bun.write(path.join(dir, "cancel"), String(input.now()))
    },

    finish: async (key) => {
      const attempt = await json<Stored>(path.join(folder(key), "attempt.json"))
      if (attempt)
        input.workdirs.release(
          { id: attempt.workdirID, project: attempt.project, path: attempt.workdir },
          attempt.commit,
        )
    },

    cleanup: async (key) => {
      const dir = folder(key)
      const attempt = await json<Stored>(path.join(dir, "attempt.json"))
      if (attempt)
        await input.workdirs.forget({ id: attempt.workdirID, project: attempt.project, path: attempt.workdir }, key.job)
      await fs.rm(dir, { recursive: true, force: true })
      await fs.rmdir(path.dirname(dir)).catch(() => undefined)
    },
  }

  /** The commit into a working folder, the contract of that commit, and `attempt.json`, before anything starts. */
  async function write(launch: Launch, dir: string) {
    const workdir = await input.workdirs.acquire(
      launch.code.project,
      launch.code.commit,
      `${launch.job}/${launch.part}/${launch.attempt}`,
    )
    const fetched = await input.workdirs.fetch(workdir, launch.code.commit, {
      job: launch.job,
      ...(launch.repository ? { local: { repository: launch.repository } } : {}),
      ...(launch.code.inRemote && launch.code.remotes[0] ? { remote: { url: launch.code.remotes[0] } } : {}),
    })
    const given = () => input.workdirs.release(workdir)
    if (!fetched.ok) {
      given()
      throw new Error(`o código não chegou (${fetched.tried.join("; ") || "nenhuma fonte"})`)
    }
    const contract = await contractAt(input.git, workdir.path, launch.code.commit, launch.code.project)
    const test = contract.ok ? contract.contract.tests[launch.part] : undefined
    if (!contract.ok || !test) {
      given()
      throw new Error(contract.ok ? `o teste ${launch.part} não existe neste commit` : contract.problems.join("; "))
    }
    const deadlines = input.deadlines ?? defaults.deadlines
    const attempt: Stored = {
      format: 1,
      job: launch.job,
      group: `${launch.part}-${launch.attempt}`,
      attempt: launch.attempt,
      commit: launch.code.commit,
      token: input.random(),
      workdir: workdir.path,
      workdirID: workdir.id,
      project: launch.code.project,
      reused: workdir.reused === true,
      prepare: prepareCommands(launch.code.commit, contract.contract.caches),
      scrub: scrubCommands(),
      parts: [
        {
          part: launch.part,
          ...(test.build ? { build: test.build } : {}),
          ...(test.plan ? { plan: test.plan } : {}),
          run: test.run,
          args: launch.spec.args,
          ...(test.secrets ? { secrets: test.secrets } : {}),
          ...(launch.only ? { only: launch.only } : {}),
        },
      ],
      deadlines: test.deadlineMin ? { ...deadlines, runMs: test.deadlineMin * 60_000 } : deadlines,
      ...(input.timing ? { timing: input.timing } : {}),
      lowPriority: input.lowPriority === true,
    }
    await fs.mkdir(path.join(dir, "parts", launch.part, "out"), { recursive: true })
    if (launch.devices === 0)
      await Bun.write(
        path.join(dir, "parts", launch.part, "devices.json"),
        JSON.stringify({ versao: 1, aparelhos: [] }),
      )
    await Bun.write(path.join(dir, "attempt.json"), JSON.stringify(attempt, null, 2))
  }
}

/** `attempt.json` as this process writes it: the runner's fields and where its working folder is. */
type Stored = Attempt & { readonly workdirID: string; readonly project: string }
