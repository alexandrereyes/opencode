export * as BancadaDaemon from "./main.js"

import type { Database } from "bun:sqlite"
import { randomBytes, randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Option, Schema } from "effect"
import { Bancada } from "../rpc.js"
import { CoreError, createCore, type Core } from "./core.js"
import { openExclusive } from "./db.js"
import { runGit } from "./git.js"
import { makeProcessLauncher } from "./launcher/process.js"
import { probe } from "./probes.js"
import { offered, parseMachineConfig } from "../machine-config.js"
import { makeBlobs, sha256 } from "./blobs.js"
import { makeLink, type Link } from "./link.js"
import { Invalid, makeRequests } from "./requests.js"
import { bundle, release } from "./snapshot.js"
import { identify } from "./bridge.js"
import { discover as findCapabilities, systemProbe, type Discovery } from "./capabilities.js"
import { makeDevicePool, withDevices, type DevicePool, type Driver } from "./devices/pool.js"
import { makePhones } from "./devices/physical.js"
import { androidLocal } from "./devices/android-local.js"
import { iosSimulators } from "./devices/ios.js"
import { androidDocker } from "./devices/android-docker.js"
import { dockerExecutions, makeDocker, type DockerExecutions } from "./launcher/docker.js"
import { systemShell } from "./devices/shell.js"
import { makeAndroidLifecycle, type Image } from "../../resources/adapters/android-lifecycle.js"
import { makeIosLifecycle } from "../../resources/adapters/ios-lifecycle.js"
import { iosSlim } from "../catalog/slim.js"
import type { MachineConfig } from "../machine-config.js"
import type { Part } from "../commands.js"
import type { Files } from "./transfers.js"
import { makeWorkdirs, type Workdirs } from "./workdir.js"
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
  /** A tool waiting for a request's end that stopped asking for this long: its notice goes as a message. */
  inlineMs: 60_000,
  /** A notice waits and no instance asked for events for this long: the server is woken (`OPENCODE_BANCADA_SELF`). */
  wakeMs: 30_000,
  /** How often discovery looks at what the machine has. */
  discoverMs: 10 * 60_000,
  /** How often the devices in use are checked. */
  watchMs: 10_000,
  /** How often the phones' connections are read (a Wi-Fi phone's `ip:porta` changes). */
  phonesMs: 30_000,
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
  /** The server itself (`OPENCODE_BANCADA_SELF`): woken when a notice waits and no instance of it asks for events. */
  self: Schema.optional(Schema.Struct({ url: Schema.String, password: Schema.String })),
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
    /** The link to the hub, on a machine that is not the hub and knows where it is. */
    link?: Link
    /** Reads a phone of this machine's catalog now, reconnecting it when it is by Wi-Fi. */
    phones?: (alias: string) => Promise<void>
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
  // Read once: machines that reach this one through the `mac` bridge find it by this hash (`[pontes]`).
  const hardware = machineFile.config.bridges.own ? await identify(machineFile.config.bridges.own) : undefined
  const secret = randomBytes(32).toString("base64url")
  const info = path.join(state, "bancada.json")
  const owner: { current?: Owner } = {}
  const deliveries: Deliveries = {
    leases: new Map(),
    inline: new Map(),
    polledAt: Date.now(),
    leaseMs: machineFile.config.times.noticeLeaseMs,
  }
  let stopping = false

  const stop = async (why: string) => {
    if (stopping) return
    stopping = true
    log(`stopping: ${why}`)
    // The goodbye: the hub shows "reconciliando" instead of "silenciosa" (at most 2 s).
    await held.process?.link?.stop().catch(() => undefined)
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
    const link = owner.current.link && !owner.current.hub ? owner.current.link : undefined
    const discovery = { at: 0 }
    const phones = makePhones({
      phones: () => (offering ? config.phones : []),
      adb: () => found.current?.android?.adb,
      ios: process.platform === "darwin",
      run: async (argv, timeoutMs) => {
        const done = await systemShell()
          .run(argv, { timeoutMs })
          .catch(() => undefined)
        return done ? { code: done.code, stdout: done.stdout } : undefined
      },
    })
    // The Docker mode: each execution in a sibling container (`launcher/docker.ts`).
    const executions =
      config.execution.mode === "docker"
        ? dockerExecutions({
            docker: makeDocker({ docker: Bun.which("docker") ?? "/usr/bin/docker" }),
            state,
            prefix: config.prefix,
            machineID,
            labels: config.labels,
            limits: {
              cpus: config.execution.cpus,
              memMb: config.execution.memMb,
              pids: config.execution.pids,
              low: config.execution.lowPriority,
            },
            ...(config.android.docker ? { network: config.android.docker.network } : {}),
            entrypoint: process.execPath,
          })
        : undefined
    const found: { current?: Discovery } = {}
    const pool = makeDevicePool({
      db,
      now,
      drivers: () =>
        deviceDrivers(found.current, config, state, () => owner.current?.name ?? "", pool, {
          machineID,
          ...(executions ? { executions } : {}),
        }),
      emulatorPorts: config.ports.emulator,
      docker: config.execution.mode === "docker",
      shrink: (key, devices) => current.core?.shrink(key, devices),
      simslim: () => found.current?.simslim !== undefined,
      phone: {
        find: (alias) => (offering ? config.phones : []).find((phone) => phone.alias === alias),
        serial: phones.serial,
        connected: phones.connected,
        done: (attempt) => current.core?.holds.done(attempt),
        machine: () => owner.current?.name ?? "",
      },
      log,
    })
    current.timers.push(setInterval(() => void pool.watch().catch(() => undefined), limits.watchMs))
    // The phones as connected now, every 30 s; a held one that lost its connection is reconnected (Wi-Fi, mDNS).
    const watchPhones = () => {
      const held = (current.core?.holds.here() ?? []).flatMap((row) =>
        row.kind === "fisico" ? [(JSON.parse(row.target) as { device: string }).device] : [],
      )
      const before = JSON.stringify(config.phones.map((phone) => phones.serials(phone.alias)))
      void phones
        .refresh({ reconnect: held })
        .then(() => {
          if (JSON.stringify(config.phones.map((phone) => phones.serials(phone.alias))) !== before)
            current.core?.phonesChanged()
        })
        .catch((error: unknown) => log(`reading the phones failed: ${String(error)}`))
    }
    if (offering && config.phones.length) {
      watchPhones()
      current.timers.push(setInterval(watchPhones, limits.phonesMs))
    }
    void fs
      .mkdir(path.join(state, "devices"), { recursive: true })
      .then(() => Bun.write(path.join(state, "simslim-profile.json"), JSON.stringify(iosSlim)))
    current.phones = (alias) => {
      const before = JSON.stringify(phones.serials(alias))
      return phones.refresh({ reconnect: [alias] }).then(() => {
        if (JSON.stringify(phones.serials(alias)) !== before) current.core?.phonesChanged()
      })
    }
    current.core = createCore({
      db,
      now,
      random,
      log,
      ...(offering && config.phones.length ? { phones } : {}),
      files: diskFiles(path.join(state, "transfers"), workdirs),
      ...(owner.current.hub ? { blobs } : {}),
      // The link starts with the core it serves; until then nothing calls it.
      ...(link
        ? {
            blobLink: {
              put: (input) => held.process!.link!.blobs.put(input),
              get: (input) => held.process!.link!.blobs.get(input),
            },
          }
        : {}),
      machine: {
        machineID,
        instanceID: owner.current.instanceID,
        name: owner.current.name,
        platform: process.platform === "darwin" ? "darwin" : "linux",
        hub: owner.current.hub,
        speed: config.speed,
        // The machine file's tags and secrets at once; what the machine has comes with discovery, right after.
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
        phones: offering ? config.phones : [],
        prefix: config.prefix,
        ...(hardware ? { hardware } : {}),
      },
      timings: {
        silentMs: config.times.silentMs,
        uncertainMs: config.times.uncertainMs,
        lostMs: config.times.lostMs,
        hubAwayMs: config.times.localModeMs,
        holdIdleQueuedMs: config.times.holdIdleQueuedMs,
        holdIdleMs: config.times.holdIdleMs,
        holdTotalQueuedMs: config.times.holdTotalQueuedMs,
        queuePlaceMs: config.times.queuePlaceMs,
      },
      // An offer refused for a capability published: look again (at most once a minute).
      rediscover: () => {
        if (Date.now() - discovery.at >= 60_000) discover()
      },
      // Each part with devices gets them ready while it builds (`devices/pool.ts`).
      launcher: withDevices(
        makeProcessLauncher({
          state,
          workdirs,
          git: runGit,
          now,
          random,
          deadlines: { prepareMs: config.times.prepareMs, buildMs: config.times.buildMs, runMs: config.times.runMs },
          lowPriority: config.execution.lowPriority,
          wake: advance,
          log,
          ...(executions ? { container: executions } : {}),
        }),
        pool,
        (key) => path.join(state, "attempts", key.job, key.group, "parts", key.part),
      ),
    })
    current.requests = makeRequests(current.core, runGit)
    if (link) {
      current.link = makeLink({ target: link.target, password: link.password, core: current.core, log })
      void current.link.run()
    }
    // What the machine has, found without starting anything, again every 10 min (`capabilities.ts`).
    const discover = () => {
      discovery.at = Date.now()
      if (!offering) return
      void findCapabilities(systemProbe(), config, config.phones.length ? phones.connected : undefined).then(
        (discovered) => {
          found.current = discovered
          current.core?.offer(offered(config, discovered.found))
        },
        (error: unknown) => log(`discovering what the machine has failed: ${String(error)}`),
      )
    }
    discover()
    current.timers.push(setInterval(discover, limits.discoverMs))
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
  /**
   * The machine behind the `mac` bridge, identified the first time a command or a hold needs it (`[pontes] mac`); a
   * failed attempt is tried again after 10 min. Until then a hold there goes to any Mac the hub knows.
   */
  const bridge = { tried: 0 }
  const identifyBridge = () => {
    if (Date.now() - bridge.tried < 10 * 60_000) return
    bridge.tried = Date.now()
    void identify(machineFile.config.bridges.mac).then((found) => {
      if (!found) return log("the machine behind the mac bridge could not be identified")
      held.process?.core?.bridge(found)
      bridge.tried = Number.POSITIVE_INFINITY
    })
  }
  /** One round of the core now (it runs one at a time; a call during one asks for another); what it wrote goes. */
  const advance = () =>
    void held.process?.core
      ?.tick()
      .then(() => held.process?.link?.nudge())
      .catch((error: unknown) => log(`a round of the core failed: ${String(error)}`))

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 120,
    fetch: (request) =>
      admin(request, {
        secret,
        machineID,
        owner,
        stop,
        serving,
        advance,
        requests: () => held.process?.requests,
        deliveries,
        identifyBridge,
        state,
        phones: (alias) => held.process?.phones?.(alias) ?? Promise.resolve(),
      }),
  })
  /**
   * A notice waits and no instance of the server asked for events in `wakeMs` (no Location loaded since a restart): the
   * server is woken through its own `custom.bancada/wake` (`docs/bancada.md`, "Who wakes the plugin").
   */
  const wake = () => {
    const self = owner.current?.self
    const core = held.process?.core
    if (
      !self ||
      !core ||
      Date.now() - deliveries.polledAt < limits.wakeMs ||
      core.notices().length + core.notes().length === 0
    )
      return
    deliveries.polledAt = Date.now()
    void fetch(`${self.url}/api/rpc/custom.bancada/wake`, {
      method: "POST",
      headers: {
        authorization: `Basic ${Buffer.from(`opencode:${self.password}`).toString("base64")}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ input: {} }),
      signal: AbortSignal.timeout(10_000),
    }).catch(() => log("waking the server for a notice failed"))
  }
  const timers: (ReturnType<typeof setInterval> | ReturnType<typeof setTimeout>)[] = [
    setInterval(advance, limits.tickMs),
    setInterval(wake, 10_000),
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
    readonly deliveries: Deliveries
    readonly identifyBridge: () => void
    readonly state: string
    readonly phones?: (alias: string) => Promise<void>
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
  const field = (name: string) =>
    typeof input === "object" && input !== null && name in input ? (input as Record<string, unknown>)[name] : undefined
  const requests = context.requests()
  /** The session that asks (its family, with titles for whoever waits behind it). */
  const asker = () => {
    const sessionID = field("sessionID")
    const rootSessionID = field("rootSessionID")
    if (typeof sessionID !== "string" || typeof rootSessionID !== "string") return undefined
    const title = field("sessionTitle")
    const rootTitle = field("rootTitle")
    return {
      sessionID,
      rootSessionID,
      ...(typeof title === "string" ? { sessionTitle: title } : {}),
      ...(typeof rootTitle === "string" ? { rootTitle } : {}),
    }
  }
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
    const job = typeof field("job") === "string" ? String(field("job")) : undefined
    const root = typeof field("rootSessionID") === "string" ? String(field("rootSessionID")) : undefined
    if (!job) return Response.json({ jobs: root ? core.family(root) : [] })
    // Only the tool that waits for the end says so (`inline`): its notice comes back here, not as a message, while
    // it keeps asking. Any other client's wait holds nothing.
    const waitMs = Math.min(Math.max(Number(field("waitMs") ?? 0), 0), 25_000)
    if (waitMs > 0 && field("inline") === true) context.deliveries.inline.set(job, Date.now())
    const deadline = Date.now() + waitMs
    while (Date.now() < deadline && core.status(job)?.state !== "concluido") await Bun.sleep(250)
    const view = core.status(job)
    return Response.json({ jobs: view ? [view] : [] })
  }
  if (method === "cancel") {
    const job = String(field("job") ?? "")
    const known = core.status(job)
    if (!known) return Response.json({ state: "desconhecido" })
    // The agent's tool cancels only its own family's requests (the app, the owner's, any).
    const root = field("rootSessionID")
    if (typeof root === "string" && known.rootSessionID !== root) return Response.json({ state: "outra_familia" })
    if (["recebido", "concluido", "entregue"].includes(known.state)) return Response.json({ state: known.state })
    core.cancel(job)
    context.advance()
    return Response.json({ state: "cancelado" })
  }
  // A session asks for a device (`bancada_hold`): another machine's answer is awaited up to 8 s.
  if (method === "hold") {
    const family = asker()
    const device = field("aparelho")
    const platform = field("tipo")
    const name = field("nome")
    const target =
      typeof device === "string"
        ? { kind: "fisico" as const, device }
        : (platform === "android" || platform === "ios") && typeof name === "string" && name
          ? { kind: "vaga" as const, platform: platform as "android" | "ios", name }
          : undefined
    if (!family || !target || typeof field("hold") !== "string")
      return Response.json({ error: "aparelho, or tipo and nome, are required" }, { status: 400 })
    if (field("maquina") === "mac") context.identifyBridge()
    // A phone of this machine: its connection read now (a Wi-Fi one reconnected), so the answer brings its serial.
    if (target.kind === "fisico") await context.phones?.(target.device)
    const row = core.hold({
      ...family,
      hold: String(field("hold")),
      ...(field("maquina") === "mac" ? { machine: core.bridged() } : {}),
      target,
    })
    context.advance()
    const settled = await answered(core, row ? [row.hold] : [], 8_000)
    return Response.json({ hold: settled[0] ?? null })
  }
  if (method === "release") {
    const hold = String(field("hold") ?? "")
    const row = core.holds.find(hold)
    if (!row) return Response.json({ state: "desconhecida" })
    const root = field("rootSessionID")
    if (typeof root === "string" && row.root_session_id !== root) return Response.json({ state: "outra_familia" })
    const after = core.release(hold)
    context.advance()
    return Response.json({
      state:
        row.state === "concedida" || row.state === "esperando" || row.state === "pedida"
          ? "solta"
          : (after?.state ?? row.state),
    })
  }
  if (method === "holds") {
    const root = String(field("rootSessionID") ?? "")
    return Response.json({ holds: core.holds.family(root) })
  }
  // The hook (`docs/bancada.md`, "Hook"): decided here on what the plugin read; a slot asked of another machine is
  // awaited up to 8 s.
  if (method === "hook") {
    const family = asker()
    const parts = field("parts")
    if (!family || !Array.isArray(parts))
      return Response.json({ error: "sessionID and parts are required" }, { status: 400 })
    if ((parts as Part[]).some((part) => part.where === "mac")) context.identifyBridge()
    const first = core.gate.decide(family, parts as Part[])
    if (!("pending" in first)) return Response.json(first)
    context.advance()
    await answered(core, first.pending, 8_000)
    const decision = core.gate.answer(first.pending)
    return Response.json(
      "pending" in decision
        ? {
            allow: false,
            message: "Sem vaga agora (a máquina do aparelho não respondeu a tempo). Tente de novo em instantes.",
          }
        : decision,
    )
  }
  // The plugin's instances ask for the notices to deliver; each goes to one of them, again after 30 s without `ack`.
  if (method === "events") {
    context.deliveries.polledAt = Date.now()
    const deadline = Date.now() + Math.min(Math.max(Number(field("waitMs") ?? 0), 0), 25_000)
    const due = () =>
      core.notices().filter((notice) => {
        const waiting = context.deliveries.inline.get(notice.job)
        return (
          (context.deliveries.leases.get(notice.job) ?? 0) <= Date.now() &&
          (waiting === undefined || Date.now() - waiting > limits.inlineMs)
        )
      })
    const notes = () =>
      core.notes().filter((note) => (context.deliveries.leases.get(`note:${note.key}`) ?? 0) <= Date.now())
    // What the apps show changed: at most once a second, never for an estimate alone (`docs/bancada.md`, "changed").
    const changes = () => core.changes()
    const changed = { current: changes() }
    while (Date.now() < deadline && due().length + notes().length === 0 && !changed.current) {
      await Bun.sleep(250)
      changed.current = changes()
    }
    const notices = due()
    notices.forEach((notice) => context.deliveries.leases.set(notice.job, Date.now() + context.deliveries.leaseMs))
    const ready = notes()
    ready.forEach((note) => context.deliveries.leases.set(`note:${note.key}`, Date.now() + context.deliveries.leaseMs))
    return Response.json({
      ...(changed.current ? { changed: changed.current } : {}),
      notes: ready.map((note) => ({
        key: note.key,
        sessionID: note.session_id,
        id: note.message_id,
        text: note.text,
        resume: note.resume === 1,
      })),
      notices: notices.map((notice) => ({
        job: notice.job,
        sessionID: notice.sessionID,
        id: notice.id,
        text: notice.text,
        resume: notice.resume,
      })),
    })
  }
  if (method === "session") return Response.json(core.surface.session(String(field("rootSessionID") ?? "")))
  if (method === "queue") return Response.json(core.surface.queue())
  if (method === "note.ack") {
    const key = String(field("key") ?? "")
    if (field("missing") === true) log(`the session of note ${key} no longer exists; it was dropped`)
    core.noted(key)
    context.deliveries.leases.delete(`note:${key}`)
    return Response.json({})
  }
  if (method === "notice.ack") {
    const job = String(field("job") ?? "")
    // Acceptance only (`docs/bancada.md`, "Acceptance"): with this file in the folder the process dies on the next
    // ack, between the session's message and its confirmation, once.
    const die = path.join(context.state, "teste-morre-no-ack")
    if (await Bun.file(die).exists()) {
      await fs.rm(die, { force: true })
      log(`dying before the ack of ${job}, as the acceptance asked`)
      process.exit(137)
    }
    if (field("missing") === true) log(`the session of ${job} no longer exists; its notice was dropped`)
    core.delivered(job)
    context.deliveries.leases.delete(job)
    context.deliveries.inline.delete(job)
    context.advance()
    return Response.json({})
  }
  // Another machine's calls to the hub, relayed by the plugin: a refusal goes back by name (422).
  if (method === "sync")
    return refusable(async () => {
      const output = core.sync(input)
      context.advance()
      const waitMs = typeof input === "object" && input !== null && "waitMs" in input ? Number(input.waitMs) : 0
      if (output.out.messages.length > 0 || !(waitMs > 0)) return output
      // The long poll: held until the queue writes to that machine, or its wait ends.
      const machineID = String((input as { machineID: unknown }).machineID)
      await new Promise<void>((resolve) => {
        const done = () => {
          clearTimeout(timer)
          stop()
          resolve()
        }
        const timer = setTimeout(done, Math.min(waitMs, 25_000))
        const stop = core.listen((peer) => peer === machineID && done())
      })
      return core.reply(machineID)
    })
  if (method === "blob.put") return refusable(() => core.blobPut(input))
  if (method === "blob.get") return refusable(() => core.blobGet(input))
  return new Response(null, { status: 404 })
}

/**
 * Notices on their way to the sessions (`docs/bancada.md`, "Notice"): the instance that took each, until when; the
 * tools that wait for a request's end, and when they last asked; when an instance last asked for events.
 */
type Deliveries = {
  leases: Map<string, number>
  inline: Map<string, number>
  polledAt: number
  leaseMs: number
}

/** The answer of a call between servers, or its refusal by name (`CoreError`, status 422). */
async function refusable(run: () => unknown) {
  try {
    return Response.json(await run())
  } catch (error) {
    if (!(error instanceof CoreError)) throw error
    return Response.json({ type: error.type, message: error.message, data: error.data ?? {} }, { status: 422 })
  }
}

/** The files of code transfers on this machine's disk: bundles made from the session's repository, bundles received. */
function diskFiles(root: string, workdirs: Workdirs): Files {
  const folder = () => fs.mkdir(root, { recursive: true, mode: 0o700 })
  return {
    path: (name) => path.join(root, name),
    size: (file) =>
      fs.stat(file).then(
        (stat) => stat.size,
        () => 0,
      ),
    sha256,
    read: async (file, offset, length) =>
      new Uint8Array(
        await Bun.file(file)
          .slice(offset, offset + length)
          .arrayBuffer(),
      ),
    append: async (file, data) => {
      await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 })
      await fs.appendFile(file, data, { mode: 0o600 })
    },
    remove: (file) => fs.rm(file, { force: true }),
    bundle: async (input) => {
      await folder()
      return bundle(runGit, input.repository, input.job, input.have, input.file)
    },
    have: (project) => workdirs.have(project),
    // The server's own temporary folder (`paths.tmp`): `/tmp/opencode` on Linux, `$TMPDIR/opencode` on the Mac.
    deliver: (job, part, name) => path.join(os.tmpdir(), "opencode", "bancada", job, part, name),
    copy: async (from, to) => {
      await fs.mkdir(path.dirname(to), { recursive: true })
      await fs.copyFile(from, to)
    },
    release: (repository, job) => release(runGit, repository, job),
  }
}

function taken(owner: Owner) {
  return Response.json({ owner: { instanceID: owner.instanceID, name: owner.name } }, { status: 409 })
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
    platform: process.platform,
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

/** The holds asked, once none is still waiting for another machine's first answer, or at `ms`. */
async function answered(core: Core, holds: ReadonlyArray<string>, ms: number) {
  const deadline = Date.now() + ms
  const rows = () => holds.map((hold) => core.holds.find(hold))
  while (Date.now() < deadline && rows().some((row) => row?.state === "pedida")) await Bun.sleep(100)
  return rows()
}

/**
 * The device drivers of this machine, from what discovery found: local emulators where the SDK has an emulator and
 * executions are processes (the Docker mode has its own), simulators on a Mac with Xcode.
 */
export function deviceDrivers(
  found: Discovery | undefined,
  config: MachineConfig,
  state: string,
  machine: () => string,
  pool: DevicePool,
  host: { readonly machineID: string; readonly executions?: DockerExecutions } = { machineID: "" },
): Partial<Record<"android" | "ios", Driver>> {
  const docker = config.android.docker
  if (config.execution.mode === "docker")
    return docker && host.executions
      ? {
          android: androidDocker({
            docker: makeDocker({ docker: Bun.which("docker") ?? "/usr/bin/docker" }),
            adb: found?.android?.adb ?? "adb",
            prefix: config.prefix,
            machineID: host.machineID,
            labels: config.labels,
            image: docker.image,
            network: docker.network,
            cpus: docker.cpusPerEmulator,
            memMb: docker.memMbPerEmulator,
            host: host.executions.address,
            machine,
            log,
          }),
        }
      : {}
  const shell = systemShell()
  const tools = found?.android
  const images = (found?.found.android as { imagens?: Image[] } | undefined)?.imagens ?? []
  const logs = path.join(state, "devices")
  const android = tools?.emulator
    ? androidLocal({
        lifecycle: makeAndroidLifecycle(shell, {
          ...tools,
          emulator: tools.emulator,
          avdHome: process.env.ANDROID_AVD_HOME || path.join(os.homedir(), ".android/avd"),
        }),
        prefix: config.prefix,
        images: () => images,
        port: pool.consolePort,
        logs,
        machine,
        log,
      })
    : undefined
  const profile = path.join(state, "simslim-profile.json")
  const ios =
    found?.found.ios !== undefined
      ? iosSimulators({
          lifecycle: makeIosLifecycle(shell, { ...(found.simslim ? { simslim: found.simslim } : {}) }),
          prefix: config.prefix,
          profile,
          machine,
          log,
        })
      : undefined
  return { ...(android ? { android } : {}), ...(ios ? { ios } : {}) }
}
