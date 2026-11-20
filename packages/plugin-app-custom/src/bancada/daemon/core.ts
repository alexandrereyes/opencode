export * as BancadaCore from "./core.js"

import type { Database } from "bun:sqlite"
import { Result, Schema } from "effect"
import { BancadaProtocol } from "../protocol.js"
import { makeCoordinator } from "./coordinator.js"
import { defaults, type BrakeConfig, type Range } from "../machine-config.js"
import type { Reading } from "./brake.js"
import { makeExecutor, type Launcher } from "./executor.js"
import { makeMessages } from "./messages.js"
import { makeOrigin, type NewJob } from "./origin.js"
import { migrate } from "./schema.js"

/** This machine as the core sees it. `hub`: the queue of every machine runs here too. */
export interface Machine {
  readonly machineID: string
  readonly instanceID: string
  readonly name: string
  readonly platform: "darwin" | "linux"
  readonly hub: boolean
  readonly speed: "normal" | "lento"
  readonly capabilities: Readonly<Record<string, unknown>>
  /** The budget: memory, CPU and builds, and the ceilings of emulators and simulators. */
  readonly capacity: BancadaProtocol.Vector
  /** From the machine file; the machine file's defaults when absent (tests, the simulation). */
  readonly secrets?: ReadonlyArray<string>
  readonly presence?: { readonly idleMs: number; readonly factor: number }
  readonly brake?: BrakeConfig
  readonly ports?: Range
  readonly docker?: boolean
}

/**
 * Everything the core touches outside its database. It never reads a clock or sets a timer of its own: time comes
 * from `now` and progress from `tick`, so the simulation runs it on virtual time (`docs/bancada.md`, "Core").
 */
export interface Ports {
  readonly db: Database
  readonly now: () => number
  /** A fresh random id (128 bits). */
  readonly random: () => string
  readonly machine: Machine
  readonly launcher: Launcher
  /** A line for the process's log: what an operator must be able to read later (never secrets). */
  readonly log: (line: string) => void
  /** Shorter times for tests; production uses `defaults`. */
  readonly timings?: Partial<typeof timings>
}

/** The times of the protocol (`docs/bancada.md`, "State machine"). */
export const timings = {
  /** A machine that has not called for this long is silent. */
  silentMs: 45_000,
  /** Silent for this long, a machine is away: parts only it can run wait for it by name. */
  uncertainMs: 3 * 60_000,
  /** A part uncertain for this long is lost (it runs again elsewhere only when safe). */
  lostMs: 15 * 60_000,
  /** A machine still reconciling after this long counts as silent for what it runs. */
  reconcilingMs: 5 * 60_000,
  /** An offer received and unanswered for this long is withdrawn. */
  replyMs: 30_000,
  /** A delivered request's tombstone stays this long. */
  tombstoneMs: 7 * 24 * 60 * 60_000,
  /** A request the hub acknowledged and never registered closes at its origin after this long. */
  unregisteredMs: 60_000,
}

export class CoreError extends Error {
  constructor(
    readonly type: "not_hub" | "protocol_mismatch" | "invalid",
    message: string,
    readonly data?: Readonly<Record<string, unknown>>,
  ) {
    super(message)
  }
}

/** The hub, as a peer of a machine's messages; every machine is a peer of the hub by its `machineID`. */
const hub = "hub"

const decodeInput = Schema.decodeUnknownResult(BancadaProtocol.SyncInput)
const decodeOutput = Schema.decodeUnknownResult(BancadaProtocol.SyncOutput)

/**
 * The Bancada of one machine: its origin (this server's requests), its executor (what runs here) and, on the hub, the
 * queue of every machine. The roles talk only through messages, also on the hub, where the machine's link to the queue
 * is a loop in this process instead of HTTP.
 */
export function createCore(ports: Ports) {
  const db = ports.db
  migrate(db)
  const self = ports.machine
  const messages = makeMessages(db, ports.random, ports.now, ports.log)
  const toHub = (body: BancadaProtocol.FromMachine) => messages.send(hub, body)
  const times = { ...timings, ...ports.timings }
  const origin = makeOrigin({
    db,
    now: ports.now,
    identity: { instanceID: self.instanceID, machineID: self.machineID, name: self.name },
    send: toHub,
    unregisteredMs: times.unregisteredMs,
    log: ports.log,
  })
  const executor = makeExecutor({
    db,
    now: ports.now,
    random: ports.random,
    machineID: self.machineID,
    limits: {
      capacity: self.capacity,
      capabilities: self.capabilities,
      secrets: self.secrets ?? [],
      presence: self.presence ?? defaults.presence,
      brake: self.brake ?? defaults.brake,
      ports: self.ports ?? defaults.ports.project,
      docker: self.docker ?? false,
    },
    launcher: ports.launcher,
    send: toHub,
    repository: origin.repository,
    // A task of an attempt ended: its result should not wait for the next second.
    wake: () => void tick(),
  })
  const coordinator = self.hub
    ? makeCoordinator({
        db,
        now: ports.now,
        times,
        startedAt: ports.now(),
        log: ports.log,
        send: (machineID, body) => messages.send(machineID, body),
        acknowledged: (machineID) => messages.acknowledged(machineID),
      })
    : undefined

  const meta = db.query<{ value: string }, [string]>("SELECT value FROM meta WHERE key = ?")
  const setMeta = (key: string, value: string) =>
    db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value])

  /** Tells the hub who this machine is, when that changed or when the hub may have forgotten it (`force`). */
  const hello = (force: boolean) => {
    const body: BancadaProtocol.FromMachine = {
      type: "hello",
      platform: self.platform,
      capabilities: { ...self.capabilities },
      speed: self.speed,
    }
    const text = JSON.stringify(body)
    if (!force && meta.get("hello")?.value === text) return
    db.transaction(() => {
      toHub(body)
      setMeta("hello", text)
    })()
  }
  hello(false)

  /** A message of the hub, inside the transaction that applies it. */
  const fromHub = (message: BancadaProtocol.FromHub) => {
    if (message.type === "offer") return executor.offer(message)
    if (message.type === "attempt.cancel") return executor.cancel(message)
    if (message.type === "cleanup") return executor.cleanup(message)
    if (message.type === "submit.ack" || message.type === "job.update" || message.type === "result")
      return origin.apply(message)
  }

  const outgoing = (waitMs = 0): BancadaProtocol.SyncInput =>
    db.transaction(() => {
      const seq = Number(meta.get("pulse_seq")?.value ?? 0) + 1
      setMeta("pulse_seq", String(seq))
      return {
        protocol: BancadaProtocol.version,
        machineID: self.machineID,
        instanceID: self.instanceID,
        name: self.name,
        out: messages.outgoing<BancadaProtocol.FromMachine>(hub),
        ack: messages.ack(hub),
        pulse: {
          seq,
          state: executor.reconciling() ? "reconciling" : "ok",
          free: executor.free(),
          brake: executor.braked(),
          presence: executor.present(),
          running: executor.running(),
        },
        waitMs,
      } satisfies BancadaProtocol.SyncInput
    })()

  const incoming = (raw: unknown) => {
    const output = decodeOutput(raw)
    if (Result.isFailure(output)) throw new CoreError("invalid", output.failure.message)
    if (output.success.protocol !== BancadaProtocol.version)
      throw new CoreError("protocol_mismatch", "the hub speaks another protocol", {
        expected: BancadaProtocol.version,
      })
    messages.acked(hub, output.success.ack)
    // A hub that changed stream (another database) may have forgotten this machine and its requests.
    if (messages.receive(hub, output.success.out, (body) => fromHub(body as BancadaProtocol.FromHub)) === "changed") {
      hello(true)
      db.transaction(() => origin.resubmit())()
    }
  }

  /** The hub's side of `custom.bancada/sync`: applies what the machine sent and answers with what waits for it. */
  const sync = (raw: unknown): BancadaProtocol.SyncOutput => {
    if (!coordinator) throw new CoreError("not_hub", "this server does not keep the queue")
    const decoded = decodeInput(raw)
    if (Result.isFailure(decoded)) throw new CoreError("invalid", decoded.failure.message)
    const input = decoded.success
    if (input.protocol !== BancadaProtocol.version)
      throw new CoreError("protocol_mismatch", "this hub speaks another protocol", {
        expected: BancadaProtocol.version,
      })
    db.transaction(() => coordinator.seen(input))()
    messages.receive(input.machineID, input.out, (body) =>
      coordinator.apply(input.machineID, body as BancadaProtocol.FromMachine),
    )
    messages.acked(input.machineID, input.ack)
    db.transaction(() => coordinator.schedule())()
    return {
      protocol: BancadaProtocol.version,
      out: messages.outgoing<BancadaProtocol.FromHub>(input.machineID),
      ack: messages.ack(input.machineID),
    }
  }

  /** On the hub this machine reaches the queue in this process, until neither side has anything new. */
  const loop = () => {
    for (const _ of Array.from({ length: 8 })) {
      const input = outgoing()
      const output = sync(input)
      incoming(output)
      if (input.out.messages.length === 0 && output.out.messages.length === 0) return
    }
  }

  /** One round: executions starting and ending, then the queue (and, on the hub, this machine's loop to it). */
  const round = async () => {
    await executor.tick()
    db.transaction(() => {
      origin.unregistered(messages.acknowledged(hub))
      origin.forget(times.tombstoneMs)
    })()
    if (!coordinator) return
    db.transaction(() => {
      coordinator.watch()
      coordinator.schedule()
    })()
    loop()
  }
  /**
   * One `tick` at a time: a call while one runs joins it and asks for one more round at its end. Two rounds waiting on
   * the same execution would both see it end and report it twice.
   */
  const ticking: { current?: Promise<void>; again: boolean } = { again: false }
  const tick = () => {
    if (ticking.current) {
      ticking.again = true
      return ticking.current
    }
    ticking.current = (async () => {
      do {
        ticking.again = false
        await round()
      } while (ticking.again)
    })().finally(() => {
      ticking.current = undefined
    })
    return ticking.current
  }

  return {
    submit: (request: NewJob) => origin.submit(request),
    /** The session cancels a request of this origin. */
    cancel: (job: string) => origin.cancel(job),
    /** Whether this machine is still reading again what it started before a restart. */
    reconciling: executor.reconciling,
    /** A reading of the machine for the brake and the owner's presence; the brake's changes go to the log. */
    observe: (reading: Reading) => {
      const brake = executor.observe(reading)
      if (brake.changed) ports.log(brake.closed ? `brake closed: ${brake.reasons.join("; ")}` : "brake open")
      return brake
    },
    status: origin.status,
    notices: origin.notices,
    delivered: origin.delivered,
    outgoing,
    incoming,
    sync,
    /** Advances what depends on time or on the outside: executions starting and ending, the queue. */
    tick,
  }
}

export type Core = ReturnType<typeof createCore>
