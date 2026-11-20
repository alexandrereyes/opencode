export * as BancadaCore from "./core.js"

import type { Database } from "bun:sqlite"
import { Result, Schema } from "effect"
import { BancadaProtocol } from "../protocol.js"
import { makeAlerts } from "./alerts.js"
import { makeCoordinator } from "./coordinator.js"
import { defaults, type BrakeConfig, type Phone, type Range } from "../machine-config.js"
import type { Reading } from "./brake.js"
import { makeExecutor, type Launcher } from "./executor.js"
import { makeMessages } from "./messages.js"
import { makeOrigin, type NewJob } from "./origin.js"
import { needs } from "./scheduler.js"
import { unmet } from "./capabilities.js"
import { BancadaNotice } from "../notice.js"
import { SessionMessage } from "@opencode/schema/session-message"
import { makeHolds, makeMirror, type Target } from "./holds.js"
import { makeGate } from "./gate.js"
import { makeChanges, makeSurface, server } from "./surface.js"
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
  /** The phones of the machine file's catalog (`[[fisico]]`). */
  readonly phones?: ReadonlyArray<Phone>
  /** Its hardware identity (`resources/machine.ts`), for machines that reach it through the `mac` bridge. */
  readonly hardware?: string
  /** The names of the devices the Bancada makes here start with it (the machine file's `prefixo`). */
  readonly prefix?: string
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
  /** An offer was refused for a capability this machine published: discovery should look again. */
  readonly rediscover?: () => void
  /** This machine's phones as connected now (`devices/physical.ts`). */
  readonly phones?: {
    readonly serial: (alias: string) => string | undefined
    readonly serials: (alias: string) => ReadonlyArray<string>
    readonly connected: (alias: string) => boolean
  }
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
  /** Holds (`docs/bancada.md`, "Holds"): the machine file's `[tempos]` of `device-lease`. */
  holdIdleQueuedMs: 10 * 60_000,
  holdIdleMs: 60 * 60_000,
  holdTotalQueuedMs: 30 * 60_000,
  queuePlaceMs: 15 * 60_000,
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
  /** What this machine offers: the machine file's at the start, then what discovery finds (`capabilities.ts`). */
  const offered = { current: self.capabilities }
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
      parts.every(
        (spec) =>
          spec.exclusive.length === 0 &&
          needs(spec).every((need) => need in offered.current) &&
          unmet(spec, offered.current) === undefined,
      )
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
      capabilities: () => offered.current,
      secrets: self.secrets ?? [],
      presence: self.presence ?? defaults.presence,
      brake: self.brake ?? defaults.brake,
      ports: self.ports ?? defaults.ports.project,
      docker: self.docker ?? false,
    },
    launcher: ports.launcher,
    ...(ports.rediscover ? { missed: ports.rediscover } : {}),
    phone: { take: (want) => holds.take(want), drop: (hold) => holds.drop(hold) },
    send: (body) => messages.send("job" in body ? peerOf(body.job) : hub, body),
    repository: origin.repository,
    // A task of an attempt ended: its result should not wait for the next second.
    wake: () => void tick(),
    keepMs: times.tombstoneMs,
    slots: () => holds.waiting(),
    ...(transfers.enabled()
      ? { code: { ask: transfers.ask, spoiled: transfers.spoiled, state: transfers.code, forget: transfers.forget } }
      : {}),
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
    hub: self.hub,
    alerts,
    random: ports.random,
  })
  /** What this server's sessions hold (here or elsewhere), and the holds this machine decides. */
  const mirror = makeMirror({ db, now: ports.now, messageID: () => SessionMessage.ID.create(), answerMs: 8_000 })
  const holds = makeHolds({
    db,
    now: ports.now,
    machineID: self.machineID,
    phones: () => self.phones ?? [],
    ...(ports.phones ? { serial: ports.phones.serial, connected: ports.phones.connected } : {}),
    times: {
      idleQueuedMs: times.holdIdleQueuedMs,
      idleMs: times.holdIdleMs,
      totalQueuedMs: times.holdTotalQueuedMs,
      placeMs: times.queuePlaceMs,
    },
    reserve: (platform) => executor.reserveSlot(platform),
    release: (lease) => executor.releaseLease(lease),
    // A session of this server: its mirror at once; another machine's: through the hub.
    answer: (row, answer) =>
      row.origin_machine === self.machineID
        ? mirror.answer(answer, self.name)
        : void messages.send(hub, { type: "hold.state", ...answer }),
  })
  /** A session of this server, as a hold's origin. */
  const originOf = (request: {
    readonly sessionID: string
    readonly rootSessionID: string
    readonly sessionTitle?: string
    readonly rootTitle?: string
  }): BancadaProtocol.Origin => ({
    instanceID: self.instanceID,
    machineID: self.machineID,
    name: self.name,
    sessionID: request.sessionID,
    rootSessionID: request.rootSessionID,
    ...(request.sessionTitle ? { sessionTitle: request.sessionTitle } : {}),
    ...(request.rootTitle ? { rootTitle: request.rootTitle } : {}),
  })
  /** Renewals already sent to another machine, by hold: at most one a minute. */
  const touched = new Map<string, number>()

  /** The machines and phones the hub said (`catalog`), with this machine's own phones. */
  const catalog = () => {
    const said: Omit<typeof BancadaProtocol.Catalog.Type, "type"> = JSON.parse(
      meta.get("catalog")?.value ?? '{"machines":[],"phones":[]}',
    )
    const own = (self.phones ?? []).map((phone) => ({
      alias: phone.alias,
      id: phone.id,
      platform: phone.platform,
      policy: phone.policy,
      serials: [...(ports.phones?.serials(phone.alias) ?? [])],
      machineID: self.machineID,
    }))
    return {
      machines: said.machines,
      phones: [...own, ...said.phones.filter((phone) => phone.machineID !== self.machineID)],
    }
  }
  /** The machine behind the `mac` bridge: this one, one of the catalog by its hardware, or `mac` (the hub picks a Mac). */
  const bridged = () => {
    const hardware = meta.get("bridge")?.value
    if (!hardware) return "mac"
    if (hardware === self.hardware) return self.machineID
    return catalog().machines.find((item) => item.hardware === hardware)?.machineID ?? "mac"
  }
  /**
   * A session asks for a device (`docs/bancada.md`, "Holds"): decided here when it is this machine's (a light slot
   * by default; a phone of this catalog), else by the machine that has it, through the hub (`machine`: a machine id,
   * or `mac` for the Mac). With the hub out, another machine's device is refused: "o hub está fora".
   */
  const askHold = (request: {
    readonly hold: string
    readonly sessionID: string
    readonly rootSessionID: string
    readonly sessionTitle?: string
    readonly rootTitle?: string
    readonly machine?: string
    readonly target: Target
  }) => {
    const target = request.target
    // The family holds it, or waits for it, already: the same hold (asking again keeps a place in the queue).
    const same = mirror
      .family(request.rootSessionID)
      .find((row) => JSON.stringify(JSON.parse(row.target)) === JSON.stringify(target))
    if (same) {
      if (same.machine_id === self.machineID) holds.ask(same.hold, { ...originOf(request) }, self.machineID, target)
      else if (!link.away)
        messages.send(hub, {
          type: "hold.request",
          hold: same.hold,
          origin: originOf(request),
          machineID: same.machine_id,
          target,
        })
      return mirror.find(same.hold)
    }
    const local =
      request.machine === undefined
        ? target.kind === "vaga" || (self.phones ?? []).some((phone) => phone.alias === target.device)
        : request.machine === self.machineID
    const origin = originOf(request)
    db.transaction(() => {
      mirror.asked({
        hold: request.hold,
        sessionID: request.sessionID,
        rootSessionID: request.rootSessionID,
        machineID: local ? self.machineID : (request.machine ?? ""),
        target,
      })
      if (local) return holds.ask(request.hold, origin, self.machineID, target)
      if (link.away)
        return mirror.answer(
          { hold: request.hold, state: "negada", reason: { code: "aguardando_hub", text: "o hub está fora" } },
          "",
        )
      messages.send(hub, {
        type: "hold.request",
        hold: request.hold,
        origin,
        machineID: request.machine ?? "",
        target,
      })
    })()
    return mirror.find(request.hold)
  }

  /** Use of a held device by its family (the hook saw it): renewed; one renewal a minute travels to another machine. */
  const touchHold = (hold: string) => {
    const row = mirror.find(hold)
    if (!row || row.state !== "concedida") return
    if (row.machine_id === self.machineID) return void holds.renew(hold, ports.now())
    if (ports.now() - (touched.get(hold) ?? 0) < 60_000) return
    touched.set(hold, ports.now())
    messages.send(hub, { type: "hold.touch", hold, at: ports.now() })
  }

  const testPorts = db.query<{ start: number; end: number }, []>(
    "SELECT d.port_start AS start, d.port_end AS end FROM lease_device d JOIN lease l ON l.id = d.lease_id WHERE l.state = 'active'",
  )
  const gate = makeGate({
    machineID: self.machineID,
    prefix: self.prefix ?? "bancada-",
    phones: () => catalog().phones,
    family: mirror.family,
    granted: mirror.granted,
    here: holds.held,
    ports: () => testPorts.all(),
    bridge: bridged,
    hold: askHold,
    touch: touchHold,
    find: mirror.find,
    id: () => BancadaProtocol.holdID(ports.random()),
  })

  /** What the apps read (`surface.ts`). */
  const surface = makeSurface({
    db,
    now: ports.now,
    self: () => ({ machineID: self.machineID, instanceID: self.instanceID, name: self.name }),
    hubState: () =>
      self.hub ? "ok" : link.refused?.type === "protocol_mismatch" ? "incompatible" : link.away ? "unavailable" : "ok",
    isHub: self.hub,
    holds: mirror.family,
    phone: (alias) => {
      const found = catalog().phones.find((phone) => phone.alias === alias)
      const own = (self.phones ?? []).find((phone) => phone.alias === alias)
      return found ? { name: own?.name ?? found.alias, id: found.id, platform: found.platform } : undefined
    },
    machine: (machineID) => {
      if (machineID === self.machineID) return server(self.instanceID, self.name)
      const found = catalog().machines.find((item) => item.machineID === machineID)
      return found?.instanceID ? server(found.instanceID, found.name) : undefined
    },
    alerts: () => alerts.active(),
  })

  const changes = makeChanges({
    now: ports.now,
    queue: surface.queue,
    session: surface.session,
    // The families with a request not delivered or a hold asked: whose `session` the apps may be showing.
    roots: () =>
      db
        .query<{ root: string }, []>(
          "SELECT root_session_id AS root FROM job WHERE state <> 'entregue' UNION SELECT root_session_id FROM grant_mirror WHERE state IN ('pedida', 'esperando', 'concedida')",
        )
        .all()
        .map((row) => row.root),
    alerts: () => alerts.active(),
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
      capabilities: { ...offered.current },
      speed: self.speed,
      ...(self.phones?.length
        ? {
            phones: self.phones.map((phone) => {
              const serials = (ports.phones?.serials(phone.alias) ?? []).filter((serial) => serial !== phone.id)
              return {
                alias: phone.alias,
                id: phone.id,
                platform: phone.platform,
                policy: phone.policy,
                ...(serials.length ? { serials: [...serials] } : {}),
              }
            }),
          }
        : {}),
      ...(self.hardware ? { hardware: self.hardware } : {}),
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
    if (message.type === "evidence.request") return transfers.evidence(message)
    if (message.type === "hold.ask")
      return holds.ask(message.hold, message.origin, message.origin.machineID, message.target)
    if (message.type === "hold.renew") return holds.renew(message.hold, message.at)
    if (message.type === "catalog") return setMeta("catalog", JSON.stringify(message))
    if (message.type === "hold.drop") return holds.drop(message.hold)
    if (message.type === "hold.grant")
      return mirror.answer(
        { hold: message.hold, state: "concedida", device: message.device, expiresAt: message.expiresAt },
        message.device.maquina ?? "",
      )
    if (message.type === "hold.deny")
      return mirror.answer(
        {
          hold: message.hold,
          state: message.position === undefined ? "negada" : "esperando",
          reason: message.reason,
          ...(message.position === undefined ? {} : { position: message.position }),
          ...(message.expiresAt === undefined ? {} : { expiresAt: message.expiresAt }),
        },
        message.machine ?? "",
      )
    if (message.type === "hold.expire")
      return mirror.answer(
        {
          hold: message.hold,
          state: message.reason ? "vencida" : "solta",
          ...(message.reason ? { reason: { code: "orcamento", text: message.reason } } : {}),
        },
        "",
      )
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
          kept: executor.kept(),
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

  /**
   * Requests whose result arrived get their notice (`docs/bancada.md`, "Notice"): at once when there is no evidence to
   * bring; otherwise once the evidence is where the session can read it (a task off the round, tried again in 5 s while
   * some is on its way). More than 20 failures: the whole list goes to `falhas.json` beside the evidence.
   */
  const noticing = new Map<string, number>()
  const notify = () =>
    origin.received().forEach((item) => {
      const failures = item.parts.flatMap((part) =>
        (part.outcome?.scenarios ?? [])
          .filter((scenario) => scenario.result === "falhou")
          .map((scenario) => ({ part: part.part, ...scenario })),
      )
      const long = failures.length > BancadaNotice.limits.failures && ports.files !== undefined
      if (!long && !item.parts.some((part) => part.evidence?.length)) return origin.notify(item.job, {})
      if ((noticing.get(item.job) ?? 0) > ports.now()) return
      noticing.set(item.job, Number.POSITIVE_INFINITY)
      void (async () => {
        const delivered = await transfers.collect(item.job, item.parts, item.receivedAt)
        const list = long ? ports.files!.deliver(item.job, ".", "falhas.json") : undefined
        if (list) {
          await ports.files!.remove(list)
          await ports.files!.append(list, new TextEncoder().encode(JSON.stringify(failures, null, 2)))
        }
        origin.notify(item.job, delivered, list)
      })().then(
        () => {
          noticing.delete(item.job)
          void tick()
        },
        () => noticing.set(item.job, ports.now() + 5_000),
      )
    })

  /** One round: executions starting and ending, then the queue (and, on the hub, this machine's loop to it). */
  const round = async () => {
    await executor.tick()
    transfers.tick()
    holds.tick()
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
    // After the loop: a result this machine's own queue just gave gets its notice in the same round.
    notify()
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
    /** An exception for the apps (`alerts.ts`): raised once until cleared. */
    alert: (id: string, kind: string, text: string) => alerts.raise(id, kind, text),
    /** An attempt uses fewer devices than granted (its plan): the rest goes back. */
    shrink: executor.shrink,
    /** Whether running devices nobody uses still fit in the budget. */
    warmFits: executor.warmFits,
    /** A reading of the machine for the brake and the owner's presence; the brake's changes go to the log. */
    observe: (reading: Reading) => {
      const brake = executor.observe(reading)
      if (brake.changed) ports.log(brake.closed ? `brake closed: ${brake.reasons.join("; ")}` : "brake open")
      return brake
    },
    status: origin.status,
    /** The requests of a session's family not delivered yet. */
    family: origin.family,
    hold: askHold,
    /** The session lets a hold go. */
    release: (hold: string) =>
      db.transaction(() => {
        const row = mirror.find(hold)
        if (!row || !["pedida", "esperando", "concedida"].includes(row.state)) return row
        if (row.machine_id === self.machineID) holds.drop(hold)
        else messages.send(hub, { type: "hold.release", hold })
        mirror.answer({ hold, state: "solta" }, "")
        return mirror.find(hold)
      })(),
    touch: touchHold,
    /** The hook's decision on a shell command's parts (`gate.ts`). */
    gate,
    /**
     * The machine behind the `mac` bridge, by the hardware identity its command printed (`[pontes]`): resolved
     * against the hub's catalog from then on.
     */
    bridge: (hardware: string) => setMeta("bridge", hardware),
    /** The phones' serials changed (a Wi-Fi phone came back on another `ip:porta`): the hub hears it in the hello. */
    phonesChanged: () => hello(false),
    /** What discovery found (with the machine file's tags and secrets): published to the queues when it changed. */
    offer: (capabilities: Readonly<Record<string, unknown>>) => {
      offered.current = capabilities
      hello(false)
    },
    bridged,
    /** The machines and phones the hub said (`catalog`), with this machine's own phones. */
    catalog,
    /** The holds of a session's family; every hold in force, for the hook; the holds this machine decides. */
    holds: {
      family: mirror.family,
      granted: mirror.granted,
      find: mirror.find,
      here: holds.held,
      decided: holds.find,
      done: holds.done,
    },
    /** Notes for the sessions (a hold came out, one expired), and their delivery. */
    notes: mirror.notes,
    noted: mirror.noted,
    notices: origin.notices,
    /** The session received the notice of a request: once; the hub may clean up, and nothing of its code stays. */
    delivered: (job: string) => {
      const repository = origin.repository(job)
      origin.delivered(job)
      transfers.sent(job)
      // The ref that held the frozen commit in the session's repository goes (`docs/bancada.md`, "Frozen code").
      if (repository && ports.files)
        void ports.files
          .release(repository, job)
          .catch((error: unknown) => ports.log(`could not remove refs/bancada/${job}: ${String(error)}`))
    },
    /** The alerts up now. */
    alerts: alerts.active,
    /** The apps' views: a family's devices and waits, and the queue. */
    surface,
    /** What the apps should reload now, if anything (`surface.ts`, `makeChanges`). */
    changes,
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
