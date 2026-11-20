export * as BancadaCore from "./core.js"

import type { Database } from "bun:sqlite"
import { Result, Schema } from "effect"
import { BancadaProtocol } from "../protocol.js"
import { makeAlerts } from "./alerts.js"
import { makeCoordinator } from "./coordinator.js"
import { defaults, type BrakeConfig, type Range } from "../machine-config.js"
import type { Reading } from "./brake.js"
import { makeExecutor, type Launcher } from "./executor.js"
import { makeMessages } from "./messages.js"
import { makeOrigin, type NewJob } from "./origin.js"
import { needs } from "./scheduler.js"
import type { Blobs } from "./blobs.js"
import { makeTransfers, type BlobLink, type Files } from "./transfers.js"
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
  /** The files of code transfers (bundles sent and received); without them no code travels through the hub. */
  readonly files?: Files
  /** The hub's `blob.put` and `blob.get` through the link; the hub uses its own. */
  readonly blobLink?: BlobLink
  /** The hub's store of transfers. */
  readonly blobs?: Blobs
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
  /** A part waiting this long for a machine that nobody offers raises an alert. */
  noMachineMs: 10 * 60_000,
  /** This long without a call to the hub that went through, a machine serves its own new requests alone. */
  hubAwayMs: 45_000,
  /** A transfer of code lives this long on the hub; an executor that waited longer asks again. */
  transferMs: 60 * 60_000,
}

export class CoreError extends Error {
  constructor(
    readonly type: "not_hub" | "protocol_mismatch" | "invalid" | "machine_taken",
    message: string,
    readonly data?: Readonly<Record<string, unknown>>,
  ) {
    super(message)
  }
}

/** The hub, as a peer of a machine's messages; every machine is a peer of the hub by its `machineID`. */
const hub = "hub"
/**
 * This machine's own queue, as a peer of its origin and executor while the hub is out (`docs/bancada.md`, "Hub out"):
 * the same queue the hub runs, over this machine alone, for the requests of its own sessions.
 */
const local = "local"

/** Why the link to the hub refused, as it tells the core; a refusal by version or schema puts the machine alone. */
export type Refusal = {
  /** `unreadable`: this machine could not read the hub's answer (the hub is of another release). */
  readonly type: "protocol_mismatch" | "invalid" | "unreadable" | "not_hub" | "machine_taken" | "unauthorized"
  readonly message: string
}

const decodeInput = Schema.decodeUnknownResult(BancadaProtocol.SyncInputEnvelope)
/** A message's body, decoded alone when it is applied: one that does not decode throws, and goes to `dead_letter`. */
const fromMachine = Schema.decodeUnknownSync(BancadaProtocol.FromMachine)
const fromHub = Schema.decodeUnknownSync(BancadaProtocol.FromHub)
const decodePut = Schema.decodeUnknownResult(BancadaProtocol.BlobPut)
const decodeGet = Schema.decodeUnknownResult(BancadaProtocol.BlobGet)
const decodeOutput = Schema.decodeUnknownResult(BancadaProtocol.SyncOutputEnvelope)

/**
 * The Bancada of one machine: its origin (this server's requests), its executor (what runs here) and, on the hub, the
 * queue of every machine. The roles talk only through messages, also on the hub, where the machine's link to the queue
 * is a loop in this process instead of HTTP.
 */
export function createCore(ports: Ports) {
  const db = ports.db
  migrate(db)
  const self = ports.machine
  const times = { ...timings, ...ports.timings }
  const alerts = makeAlerts(db, ports.now, ports.log)
  const messages = makeMessages(db, ports.random, ports.now, ports.log, (peer, seq, error) =>
    alerts.raise(
      `dead_letter:${peer}/${seq}`,
      "mensagem",
      `uma mensagem de ${peer === hub ? "o hub" : peer} não pôde ser aplicada e foi guardada à parte: ${error}`,
    ),
  )
  /** Calls waiting for a message to a machine (the hub's long poll): woken when one is written. */
  const listeners = new Set<(peer: string) => void>()
  /**
   * The link to the hub, as the link tells it: when a call last went through, and a refusal that puts this machine
   * alone at once (another protocol, a schema the hub cannot read). In memory: a restart counts from its start.
   */
  const link: { okAt: number; refused?: Refusal; away: boolean } = { okAt: ports.now(), away: false }
  const away = () =>
    !self.hub &&
    (link.refused?.type === "protocol_mismatch" ||
      link.refused?.type === "invalid" ||
      link.refused?.type === "unreadable" ||
      ports.now() - link.okAt >= times.hubAwayMs)
  const origin = makeOrigin({
    db,
    now: ports.now,
    identity: { instanceID: self.instanceID, machineID: self.machineID, name: self.name },
    send: (body, scope) => messages.send(scope === "local" ? local : hub, body),
    scope: (parts) =>
      link.away &&
      parts.every((spec) => spec.exclusive.length === 0 && needs(spec).every((need) => need in self.capabilities))
        ? "local"
        : "hub",
    away: () => link.away,
    unregisteredMs: times.unregisteredMs,
    log: ports.log,
    alerts,
  })
  /** A message about a request goes to the queue that has it: the hub's, or this machine's own (`local`). */
  const peerOf = (job: string) => (origin.scope(job) === "local" ? local : hub)
  const transfers = makeTransfers({
    db,
    now: ports.now,
    transferMs: times.transferMs,
    self: { machineID: self.machineID, instanceID: self.instanceID },
    ...(ports.files ? { files: ports.files } : {}),
    // On the hub its own store answers, in this process (a copy on the same disk, no HTTP).
    ...(self.hub
      ? { link: { put: (input) => transfers.put(input), get: (input) => transfers.get(input) } satisfies BlobLink }
      : ports.blobLink
        ? { link: ports.blobLink }
        : {}),
    ...(self.hub && ports.blobs ? { blobs: ports.blobs } : {}),
    send: (body) => messages.send(hub, body),
    repository: origin.repository,
    alerts,
    log: ports.log,
    wake: () => void tick(),
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
    send: (body) => messages.send("job" in body ? peerOf(body.job) : hub, body),
    repository: origin.repository,
    // A task of an attempt ended: its result should not wait for the next second.
    wake: () => void tick(),
    ...(transfers.enabled() ? { code: { ask: transfers.ask, state: transfers.code, forget: transfers.forget } } : {}),
  })
  /** The queue: every machine's on the hub; elsewhere, this machine's own, for its requests while the hub is out. */
  const queue = makeCoordinator({
    db,
    now: ports.now,
    times,
    startedAt: ports.now(),
    log: ports.log,
    send: (machineID, body) => {
      const seq = messages.send(machineID, body)
      listeners.forEach((listener) => listener(machineID))
      return seq
    },
    acknowledged: (machineID) => messages.acknowledged(machineID),
    alerts,
    random: ports.random,
  })
  /** How this machine reaches the queue in this process: as the hub's own machine, or its own queue. */
  const queuePeer = self.hub ? hub : local

  const meta = db.query<{ value: string }, [string]>("SELECT value FROM meta WHERE key = ?")
  const setMeta = (key: string, value: string) =>
    db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [key, value])

  /**
   * Tells the queues who this machine is, when that changed or when the hub may have forgotten it (`force`): the hub,
   * and on a machine that is not the hub its own queue, which schedules on what this machine offers.
   */
  const hello = (force: boolean) => {
    const body: BancadaProtocol.FromMachine = {
      type: "hello",
      platform: self.platform,
      capabilities: { ...self.capabilities },
      speed: self.speed,
    }
    const text = JSON.stringify(body)
    const peers = self.hub ? [hub] : [hub, local]
    db.transaction(() =>
      peers.forEach((peer) => {
        if (!force && meta.get(`hello:${peer}`)?.value === text) return
        messages.send(peer, body)
        setMeta(`hello:${peer}`, text)
      }),
    )()
  }
  hello(false)

  /** A message of a queue, inside the transaction that applies it. */
  const fromQueue = (message: BancadaProtocol.FromHub) => {
    if (message.type === "offer") return executor.offer(message)
    if (message.type === "attempt.cancel") return executor.cancel(message)
    if (message.type === "cleanup") return executor.cleanup(message)
    if (message.type === "code.request") return transfers.request(message)
    if (message.type === "code.source") return transfers.source(message)
    if (message.type === "submit.ack" || message.type === "job.update" || message.type === "result")
      return origin.apply(message)
  }

  /** This machine's call to a queue: what it has for it, what it applied of it, and its pulse. */
  const call = (peer: string, waitMs: number, leaving?: "restart" | "stop"): BancadaProtocol.SyncInput =>
    db.transaction(() => {
      const seq = Number(meta.get("pulse_seq")?.value ?? 0) + 1
      setMeta("pulse_seq", String(seq))
      return {
        protocol: BancadaProtocol.version,
        machineID: self.machineID,
        instanceID: self.instanceID,
        name: self.name,
        out: messages.outgoing<BancadaProtocol.FromMachine>(peer),
        ack: messages.ack(peer),
        pulse: {
          seq,
          state: executor.reconciling() ? "reconciling" : "ok",
          free: executor.free(),
          brake: executor.braked(),
          presence: executor.present(),
          running: executor.running(),
        },
        ...(leaving ? { leaving } : {}),
        waitMs,
      } satisfies BancadaProtocol.SyncInput
    })()

  /** This machine's call to the hub; `leaving` when the process stops (the hub shows "reconciliando"). */
  const outgoing = (waitMs = 0, leaving?: "restart" | "stop") => call(hub, waitMs, leaving)

  /**
   * The hub's answer: a call that went through (the machine is not alone). Its `protocol` is read before anything else
   * (rule 11): another version is a refusal by name. Returns how many of the hub's messages it carried.
   */
  const incoming = (raw: unknown) => {
    const protocol = protocolOf(raw)
    if (protocol !== undefined && protocol !== BancadaProtocol.version) {
      refused({ type: "protocol_mismatch", message: `o hub fala o protocolo ${protocol}` })
      throw new CoreError("protocol_mismatch", "the hub speaks another protocol", {
        expected: BancadaProtocol.version,
      })
    }
    const output = decodeOutput(raw)
    if (Result.isFailure(output)) throw new CoreError("invalid", output.failure.message)
    link.okAt = ports.now()
    link.refused = undefined
    messages.acked(hub, output.success.ack)
    // A hub that changed stream (another database) may have forgotten this machine and its requests.
    if (messages.receive(hub, output.success.out, (body) => fromQueue(fromHub(body))) === "changed") {
      hello(true)
      db.transaction(() => origin.resubmit())()
    }
    return output.success.out.messages.length
  }

  /**
   * The hub refused this machine's call (`docs/bancada.md`, "sync"): another protocol or a call it could not read puts
   * the machine alone at once; every refusal raises an alert, which the next call that goes through clears.
   */
  const refused = (refusal: Refusal) => {
    link.refused = refusal
    alerts.raise(`hub:${refusal.type}`, "hub", refusalText(refusal))
  }

  /** The queue's side of a call: applies what the machine sent and answers with what waits for it. */
  const serve = (input: BancadaProtocol.SyncInputEnvelope): BancadaProtocol.SyncOutput => {
    db.transaction(() => queue.seen(input))()
    messages.receive(input.machineID, input.out, (body) => queue.apply(input.machineID, fromMachine(body)))
    messages.acked(input.machineID, input.ack)
    db.transaction(() => queue.schedule())()
    return reply(input.machineID)
  }
  const reply = (machineID: string): BancadaProtocol.SyncOutput => ({
    protocol: BancadaProtocol.version,
    out: messages.outgoing<BancadaProtocol.FromHub>(machineID),
    ack: messages.ack(machineID),
  })

  /** The hub's side of `custom.bancada/sync`: applies what the machine sent and answers with what waits for it. */
  const sync = (raw: unknown): BancadaProtocol.SyncOutput => {
    if (!self.hub) throw new CoreError("not_hub", "this server does not keep the queue")
    version(raw)
    const decoded = decodeInput(raw)
    if (Result.isFailure(decoded)) throw new CoreError("invalid", decoded.failure.message)
    const input = decoded.success
    const taken = queue.taken(input)
    if (taken)
      throw new CoreError("machine_taken", `the machine ${input.machineID} is ${taken.name}'s`, {
        instanceID: taken.instanceID,
        name: taken.name,
      })
    return serve(input)
  }

  /** A blob call the hub decoded: only the hub takes them, in its protocol. */
  const decodeBlob = <A>(raw: unknown, decode: (raw: unknown) => Result.Result<A, { readonly message: string }>) => {
    if (!self.hub) throw new CoreError("not_hub", "this server does not keep the queue")
    version(raw)
    const decoded = decode(raw)
    if (Result.isFailure(decoded)) throw new CoreError("invalid", decoded.failure.message)
    return decoded.success
  }

  /** This machine reaches its queue in this process, until neither side has anything new. */
  const loop = () => {
    for (const _ of Array.from({ length: 8 })) {
      const input = call(queuePeer, 0)
      const output = serve(input)
      messages.acked(queuePeer, output.ack)
      messages.receive(queuePeer, output.out, (body) => fromQueue(fromHub(body)))
      if (input.out.messages.length === 0 && output.out.messages.length === 0) return
    }
  }

  /** Whether this machine is alone now; the change goes to the log and to an alert. */
  const follow = () => {
    const now = away()
    if (now === link.away) return
    link.away = now
    if (now) {
      ports.log("the hub is out: serving this machine's own new requests alone")
      return alerts.raise(
        "hub:fora",
        "hub",
        "o hub não responde: esta máquina atende sozinha os pedidos novos das próprias sessões",
      )
    }
    ports.log("the hub is back")
    alerts
      .active()
      .filter((alert) => alert.kind === "hub")
      .forEach((alert) => alerts.clear(alert.id))
  }

  /** One round: executions starting and ending, then the queue (and, on the hub, this machine's loop to it). */
  const round = async () => {
    await executor.tick()
    transfers.tick()
    follow()
    db.transaction(() => {
      origin.unregistered((scope) => messages.acknowledged(scope === "local" ? local : hub))
      origin.forget(times.tombstoneMs)
    })()
    db.transaction(() => {
      queue.watch()
      queue.schedule()
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
    /** The session received the notice of a request: once; the hub may clean up, and nothing of its code stays. */
    delivered: (job: string) => {
      origin.delivered(job)
      transfers.sent(job)
    },
    /** The alerts up now. */
    alerts: alerts.active,
    /** The hub as this machine sees it: reachable, or out since when and why (`queue.hub`). */
    hub: () =>
      self.hub
        ? { state: "hub" as const }
        : link.away
          ? {
              state: "unavailable" as const,
              since: link.okAt,
              ...(link.refused ? { reason: refusalText(link.refused) } : {}),
            }
          : { state: "ok" as const },
    outgoing,
    incoming,
    refused,
    /** What this machine wrote to the hub and what the hub acknowledged of it (the link's nudge). */
    queued: () => ({ written: messages.written(hub), acked: messages.acknowledged(hub) }),
    sync,
    /** What waits for a machine now (the hub's answer to a long poll that waited). */
    reply,
    /** The hub's `custom.bancada/blob.put`. */
    blobPut: (raw: unknown) => transfers.put(decodeBlob(raw, decodePut)),
    /** The hub's `custom.bancada/blob.get`. */
    blobGet: (raw: unknown) => transfers.get(decodeBlob(raw, decodeGet)),
    /** Calls `listener` with the machine whenever the queue writes to one; returns how to stop. */
    listen: (listener: (peer: string) => void) => {
      listeners.add(listener)
      return () => void listeners.delete(listener)
    },
    /** Advances what depends on time or on the outside: executions starting and ending, the queue. */
    tick,
  }
}

export type Core = ReturnType<typeof createCore>

/**
 * A call of another protocol version is refused by name before anything else of it is read: its shape may have
 * changed too, and "invalid" would hide why.
 */
function version(raw: unknown) {
  const protocol = protocolOf(raw)
  if (protocol !== undefined && protocol !== BancadaProtocol.version)
    throw new CoreError("protocol_mismatch", `this hub speaks protocol ${BancadaProtocol.version}, not ${protocol}`, {
      expected: BancadaProtocol.version,
    })
}

function protocolOf(raw: unknown) {
  const protocol = typeof raw === "object" && raw !== null && "protocol" in raw ? raw.protocol : undefined
  return typeof protocol === "number" ? protocol : undefined
}

function refusalText(refusal: Refusal) {
  if (refusal.type === "protocol_mismatch") return "o hub fala outra versão do protocolo da Bancada"
  if (refusal.type === "invalid") return `o hub não entendeu a chamada desta máquina: ${refusal.message}`
  if (refusal.type === "unreadable") return `esta máquina não entendeu a resposta do hub: ${refusal.message}`
  if (refusal.type === "not_hub") return "o servidor configurado como hub não é o hub"
  if (refusal.type === "machine_taken")
    return `o hub já tem esta máquina registrada por outro servidor: ${refusal.message}`
  return "o hub recusou a senha desta máquina"
}
