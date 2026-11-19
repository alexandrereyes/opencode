export * as BancadaDaemon from "./main.js"

import type { Database } from "bun:sqlite"
import { randomBytes, randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import path from "node:path"
import { Option, Schema } from "effect"
import { Bancada } from "../rpc.js"
import { openExclusive } from "./db.js"
import { startTime } from "./launcher/process.js"

/** Argument that makes the bundled plugin (`plugin/index.js`) run this process instead of exporting the plugin. */
export const flag = "--opencode-bancada"

/** Version of the admin API between the plugin and this process; a plugin replaces a process reporting another. */
export const adminProtocol = 1

export const limits = {
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
  process?: { db: Database; server: ReturnType<typeof Bun.serve>; timers: ReturnType<typeof setInterval>[] }
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
  const machineID = await machine(state)
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

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 120,
    fetch: (request) => admin(request, { secret, machineID, owner, stop }),
  })
  await Bun.write(
    `${info}.tmp`,
    JSON.stringify({ protocol: adminProtocol, pid: process.pid, port: server.port, secret, machineID }),
    {
      mode: 0o600,
    },
  )
  await fs.chmod(`${info}.tmp`, 0o600)
  await fs.rename(`${info}.tmp`, info)
  const timers: ReturnType<typeof setInterval>[] = []
  held.process = { db, server, timers }
  log(`started pid=${process.pid} machine=${machineID}`)

  process.on("SIGTERM", () => void stop("SIGTERM"))
  process.on("SIGINT", () => void stop("SIGINT"))
  if (parent <= 0) return
  const born = await startTime(parent)
  if (!born) return void stop(`server ${parent} was already gone`)
  timers.push(
    setInterval(async () => {
      if ((await startTime(parent)) !== born) void stop(`server ${parent} is gone`)
    }, limits.parentCheckMs),
  )
}

/** The admin API, on loopback, for the plugin instances of the owner server; every route needs the secret. */
async function admin(
  request: Request,
  context: {
    readonly secret: string
    readonly machineID: string
    readonly owner: { current?: Owner }
    readonly stop: (why: string) => Promise<void>
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
    return Response.json({})
  }
  if (url.pathname === "/admin/shutdown") {
    setTimeout(() => void context.stop("asked to shut down"), 0)
    return Response.json({})
  }
  // Diagnostics: a full collection, to check that the machine's lock survives it (prova E6).
  if (url.pathname === "/admin/gc") {
    Bun.gc(true)
    return Response.json({})
  }
  if (!url.pathname.startsWith("/admin/rpc/")) return new Response(null, { status: 404 })
  if (!owner) return Response.json({ error: "not configured" }, { status: 412 })
  if (request.headers.get(instanceHeader) !== owner.instanceID) return taken(owner)
  const method = url.pathname.slice("/admin/rpc/".length)
  if (method === "wake") return Response.json({ protocol: Bancada.protocol, state: "ok" } satisfies Bancada.Wake)
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
