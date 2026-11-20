export * as BancadaDaemon from "./main.js"

import type { Database } from "bun:sqlite"
import { randomBytes, randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Option, Schema } from "effect"
import { Bancada } from "../rpc.js"
import { createCore, type Core } from "./core.js"
import { openExclusive } from "./db.js"
import { runGit } from "./git.js"
import { makeProcessLauncher } from "./launcher/process.js"
import { probe } from "./probes.js"
import { offered, parseMachineConfig } from "../machine-config.js"
import { makeBlobs } from "./blobs.js"
import { Invalid, makeRequests } from "./requests.js"
import { makeWorkdirs } from "./workdir.js"
import { migrate, NewerSchemaError } from "./schema.js"

/** Argument that makes the bundled plugin (`plugin/index.js`) run this process instead of exporting the plugin. */
export const flag = "--opencode-bancada"

/** Version of the admin API between the plugin and this process; a plugin replaces a process reporting another. */
export const adminProtocol = 1

export const limits = {
  /** How often the core advances (executions, the queue); also after every request. */
  tickMs: 1_000,
  /** How often the machine is read for the brake and the owner's presence. */
  probeMs: 5_000,
  /** How often unused working folders and expired transfers go (also once, a little after the start). */
  sweepMs: 60 * 60_000,
  firstSweepMs: 60_000,
  /** How often the process checks that its server still runs (pid and start time). */
  parentCheckMs: 2_000,
  /** The goodbye to the hub must not hold the exit. */
  farewellMs: 2_000,
}

/**
 * The server this process serves: the first that configured it. `link` is how it reaches the hub (the address of
 * `OPENCODE_SUMMARY_HUB` and the password the server presents there). Passwords live only in this process's memory:
 * never on disk, in argv, in the environment or in the log.
 */
export const Owner = Schema.Struct({
  instanceID: Schema.String.check(Schema.isMinLength(1)),
  name: Schema.String,
  hub: Schema.Boolean,
  link: Schema.optional(Schema.Struct({ target: Schema.String, password: Schema.String })),
})
export type Owner = typeof Owner.Type
const decodeOwner = Schema.decodeUnknownOption(Owner)

const Machine = Schema.Struct({ machineID: Schema.String.check(Schema.isMinLength(1)) })
const decodeMachine = Schema.decodeUnknownOption(Machine)

/** Request header naming the server (`custom.instance` instanceID) a plugin call comes from. */
export const instanceHeader = "x-bancada-instance"

/**
 * Everything that must live as long as the process: its database (whose lock is the machine's), its HTTP server and
 * its timers. A `Database` the garbage collector reaches is closed and the lock goes with it while the process still
 * runs (prova E6), so nothing of this may sit only in a local of a function that returns.
 */
const held: {
  process?: {
    db: Database
    server: ReturnType<typeof Bun.serve>
    timers: (ReturnType<typeof setInterval> | ReturnType<typeof setTimeout>)[]
    core?: Core
    requests?: ReturnType<typeof makeRequests>
  }
} = {}

/**
 * Process entry. Environment: `OPENCODE_BANCADA_STATE` (the machine's folder, required) and `OPENCODE_BANCADA_PARENT`
 * (the server's pid; the process leaves when that server is gone). Started in a session of its own: when launchd
 * ends the server's job it kills the job's process group, and this process must still say goodbye to the hub.
 * A second process on the same folder leaves at once with code 0 and one line in the log.
 */
export async function main() {
  const state = process.env.OPENCODE_BANCADA_STATE
  if (!state) throw new Error("OPENCODE_BANCADA_STATE is required")
  const parent = Number(process.env.OPENCODE_BANCADA_PARENT ?? 0)
  // Set only so the compiled server binary behaves as Bun; the commands this process starts must not inherit them.
  delete process.env.BUN_BE_BUN
  delete process.env.OPENCODE_BANCADA_PARENT
  await fs.mkdir(state, { recursive: true, mode: 0o700 })
  const db = openExclusive(path.join(state, "bancada.db"))
  if (!db) return log(`another Bancada process holds ${state}; leaving`)
  const newer = schema(db)
  if (newer) {
    log(newer.message)
    db.close()
    process.exit(1)
  }
  const machineID = await machine(state)
  const machineFile = await readMachineFile()
  const secret = randomBytes(32).toString("base64url")
  const info = path.join(state, "bancada.json")
  const owner: { current?: Owner } = {}
  let stopping = false

  const stop = async (why: string) => {
    if (stopping) return
    stopping = true
    log(`stopping: ${why}`)
    await farewell(machineID, owner.current)
    held.process?.timers.forEach((timer) => clearInterval(timer))
    void server.stop(true)
    const current: unknown = await Bun.file(info)
      .json()
      .catch(() => undefined)
    if (typeof current === "object" && current !== null && "pid" in current && current.pid === process.pid)
      await fs.rm(info, { force: true })
    db.close()
    process.exit(0)
  }

  /** The core starts with its owner: the machine is that server's (its id, its name, whether it is the hub). */
  const serving = () => {
    const current = held.process
    if (!current || current.core || !owner.current) return current?.core
    const now = () => Date.now()
    const random = () => randomBytes(16).toString("hex")
    const workdirs = makeWorkdirs({ db, root: path.join(state, "work"), now, random, git: runGit })
    const blobs = makeBlobs({ root: path.join(state, "blobs"), now })
    // Started more often than hourly (a deploy, a restart), a machine would never sweep without the first one.
    const sweep = () =>
      void Promise.all([workdirs.prune(), blobs.expire()]).then(
        ([folders, transfers]) =>
          folders + transfers > 0 && log(`swept ${folders} unused working folder(s), ${transfers} expired transfer(s)`),
        (error: unknown) => log(`the hourly sweep failed: ${String(error)}`),
      )
    current.timers.push(setTimeout(sweep, limits.firstSweepMs), setInterval(sweep, limits.sweepMs))
    const config = machineFile.config
    // An invalid machine file offers nothing: no budget, no capability (the problems are in the log).
    const offering = machineFile.valid
    current.core = createCore({
      db,
      now,
      random,
      log,
      machine: {
        machineID,
        instanceID: owner.current.instanceID,
        name: owner.current.name,
        platform: process.platform === "darwin" ? "darwin" : "linux",
        hub: owner.current.hub,
        speed: config.speed,
        // Discovering what the machine has (Android SDK, Xcode, phones…) comes with the devices.
        capabilities: offering ? offered(config, {}) : {},
        capacity: offering
          ? {
              memMb: config.budget.memMb,
              cpuMilli: config.budget.cpuMilli,
              builds: config.budget.builds,
              android: config.budget.maxAndroid,
              ios: config.budget.maxIos,
            }
          : { memMb: 0, cpuMilli: 0, builds: 0, android: 0, ios: 0 },
        secrets: config.execution.mode === "docker" ? [] : config.secrets,
        presence: config.budget.presence,
        brake: config.brake,
        ports: config.ports.project,
        docker: config.execution.mode === "docker",
      },
      timings: { silentMs: config.times.silentMs, uncertainMs: config.times.uncertainMs, lostMs: config.times.lostMs },
      launcher: makeProcessLauncher({
        state,
        workdirs,
        git: runGit,
        now,
        random,
        deadlines: { prepareMs: config.times.prepareMs, buildMs: config.times.buildMs, runMs: config.times.runMs },
        lowPriority: config.execution.lowPriority,
        wake: advance,
        log,
      }),
    })
    current.requests = makeRequests(current.core, runGit)
    // The machine is read off the round, every 5 s: the brake and the owner's presence.
    const reading = () =>
      void probe()
        .then((value) => held.process?.core?.observe(value))
        .catch((error: unknown) => log(`reading the machine failed: ${String(error)}`))
    reading()
    current.timers.push(setInterval(reading, limits.probeMs))
    advance()
    return current.core
  }
  /** One round of the core now (it runs one at a time; a call during one asks for another). */
  const advance = () =>
    void held.process?.core?.tick().catch((error: unknown) => log(`a round of the core failed: ${String(error)}`))

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 120,
    fetch: (request) =>
      admin(request, { secret, machineID, owner, stop, serving, advance, requests: () => held.process?.requests }),
  })
  const timers: (ReturnType<typeof setInterval> | ReturnType<typeof setTimeout>)[] = [
    setInterval(advance, limits.tickMs),
  ]
  held.process = { db, server, timers }
  await Bun.write(
    `${info}.tmp`,
    JSON.stringify({ protocol: adminProtocol, pid: process.pid, port: server.port, secret, machineID }),
    {
      mode: 0o600,
    },
  )
  await fs.chmod(`${info}.tmp`, 0o600)
  await fs.rename(`${info}.tmp`, info)
  log(`started pid=${process.pid} machine=${machineID}`)

  // A loose rejection ends a Bun process: this one follows every execution of the machine, so it logs and goes on.
  process.on("unhandledRejection", (error) => log(`unhandled rejection: ${String(error)}`))
  process.on("SIGTERM", () => void stop("SIGTERM"))
  process.on("SIGINT", () => void stop("SIGINT"))
  if (parent <= 0) return
  // When its parent dies the system gives this process another one at once: proof, without asking anything (no `ps` on
  // a loaded Mac, no language or time zone). The rule against the ppid is for telling whether another process lives.
  const check = () => {
    if (process.ppid !== parent) void stop(`server ${parent} is gone`)
  }
  check()
  timers.push(setInterval(check, limits.parentCheckMs))
}

/** The admin API, on loopback, for the plugin instances of the owner server; every route needs the secret. */
async function admin(
  request: Request,
  context: {
    readonly secret: string
    readonly machineID: string
    readonly owner: { current?: Owner }
    readonly stop: (why: string) => Promise<void>
    readonly serving: () => Core | undefined
    readonly advance: () => void
    readonly requests: () => ReturnType<typeof makeRequests> | undefined
  },
) {
  if (request.headers.get("authorization") !== `Bearer ${context.secret}`) return new Response(null, { status: 401 })
  const url = new URL(request.url)
  const owner = context.owner.current
  if (request.method === "GET" && url.pathname === "/admin/health")
    return Response.json({
      protocol: adminProtocol,
      pid: process.pid,
      machineID: context.machineID,
      state: "ok",
      ...(owner ? { owner: { instanceID: owner.instanceID, name: owner.name } } : {}),
    })
  if (request.method !== "POST") return new Response(null, { status: 404 })
  if (url.pathname === "/admin/configure") {
    const next = decodeOwner(await request.json().catch(() => undefined))
    if (Option.isNone(next)) return Response.json({ error: "invalid owner" }, { status: 400 })
    if (owner && owner.instanceID !== next.value.instanceID) return taken(owner)
    if (!owner) log(`serving ${next.value.name} (${next.value.instanceID})`)
    context.owner.current = next.value
    context.serving()
    return Response.json({})
  }
  if (url.pathname === "/admin/shutdown") {
    setTimeout(() => void context.stop("asked to shut down"), 0)
    return Response.json({})
  }
  if (!url.pathname.startsWith("/admin/rpc/")) return new Response(null, { status: 404 })
  if (!owner) return Response.json({ error: "not configured" }, { status: 412 })
  if (request.headers.get(instanceHeader) !== owner.instanceID) return taken(owner)
  const method = url.pathname.slice("/admin/rpc/".length)
  const core = context.serving()
  if (!core) return Response.json({ error: "not configured" }, { status: 412 })
  if (method === "wake")
    return Response.json({
      protocol: Bancada.protocol,
      state: core.reconciling() ? "reconciling" : "ok",
    } satisfies Bancada.Wake)
  const input: unknown = await request.json().catch(() => undefined)
  const requests = context.requests()
  if (method === "submit" && requests) {
    const answer = await requests.submit(input).then(
      (submitted) => Response.json(submitted),
      (error: unknown) =>
        error instanceof Invalid
          ? Response.json({ type: "invalid", problems: error.problems }, { status: 400 })
          : Promise.reject(error),
    )
    context.advance()
    return answer
  }
  if (method === "status") {
    const job = typeof input === "object" && input !== null && "job" in input ? String(input.job) : ""
    const view = core.status(job)
    return Response.json({ jobs: view ? [view] : [] })
  }
  return new Response(null, { status: 404 })
}

function taken(owner: Owner) {
  return Response.json({ owner: { instanceID: owner.instanceID, name: owner.name } }, { status: 409 })
}

/**
 * Tells the hub this machine is restarting, so it shows "reconciliando" instead of "silenciosa". Best effort, at most
 * `limits.farewellMs`; only a server linked to a hub has one to tell.
 */
async function farewell(machineID: string, owner: Owner | undefined) {
  if (!owner?.link) return
  await fetch(`${owner.link.target}/api/rpc/custom.bancada/sync`, {
    method: "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`opencode:${owner.link.password}`).toString("base64")}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      input: {
        protocol: Bancada.protocol,
        machineID,
        instanceID: owner.instanceID,
        name: owner.name,
        ack: 0,
        messages: [],
        leaving: "restart",
        waitMs: 0,
      },
    }),
    signal: AbortSignal.timeout(limits.farewellMs),
  }).catch(() => undefined)
}

/**
 * The machine file (`OPENCODE_BANCADA_CONFIG`, else `~/.config/opencode/bancada.toml`): absent, every default; invalid,
 * its problems go to the log and the machine offers nothing (its defaults still give the times).
 */
async function readMachineFile() {
  const file = process.env.OPENCODE_BANCADA_CONFIG || path.join(os.homedir(), ".config/opencode/bancada.toml")
  const text = await Bun.file(file)
    .text()
    .catch(() => undefined)
  const host = {
    memMb: Math.round(os.totalmem() / 1_048_576),
    cores: os.availableParallelism(),
    inDocker: (await Bun.file("/.dockerenv").exists()) && (await fs.exists("/var/run/docker.sock")),
  }
  const parsed = parseMachineConfig(text, host)
  if (parsed.ok) return { valid: true, config: parsed.config }
  log(`the machine file ${file} is invalid; this machine offers nothing:\n  ${parsed.problems.join("\n  ")}`)
  const fallback = parseMachineConfig(undefined, host)
  if (!fallback.ok) throw new Error(fallback.problems.join("\n"))
  return { valid: false, config: fallback.config }
}

/** Brings the database to this release's schema; a database of a newer release is left untouched. */
function schema(db: Database) {
  try {
    migrate(db)
    return undefined
  } catch (error) {
    if (error instanceof NewerSchemaError) return error
    throw error
  }
}

/** The machine's id: drawn once and kept in `machine.json`; the database lock is already this process's. */
async function machine(state: string) {
  const file = path.join(state, "machine.json")
  const known = decodeMachine(
    await Bun.file(file)
      .json()
      .catch(() => undefined),
  )
  if (Option.isSome(known)) return known.value.machineID
  const machineID = randomUUID()
  await Bun.write(`${file}.tmp`, JSON.stringify({ machineID }), { mode: 0o600 })
  await fs.rename(`${file}.tmp`, file)
  return machineID
}

function log(line: string) {
  console.log(`${new Date().toISOString()} ${line}`)
}
