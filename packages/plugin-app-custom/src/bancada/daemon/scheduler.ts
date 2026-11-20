import type { BancadaProtocol } from "../protocol.js"
import type { Wait } from "./estimate.js"
import { unmet } from "./capabilities.js"

/**
 * The queue's choice (`docs/bancada.md`, "Queue"): which waiting part goes to which machine now, with how many
 * devices, and why each other part waits. Pure: the hub gives the parts, the machines as their last pulses tell, the
 * exclusive locks taken and how to estimate; it applies what comes back.
 */

export type QueuedPart = {
  readonly job: string
  readonly part: string
  readonly spec: BancadaProtocol.PartSpec
  /** When its request entered the queue; with the request and the part's place in it, the order among equals. */
  readonly createdAt: number
  readonly index: number
  /** Bypassed 3 times: no newer part is offered to its candidates until it leaves. */
  readonly reserved: boolean
  /** The machine that refused its last offer, at which pulse: a candidate again only from a newer pulse. */
  readonly refused?: { readonly machineID: string; readonly pulse: number }
  /** Machines where a sibling of the same request is offered or accepted, not started: their group builds once. */
  readonly siblingsOn?: ReadonlyArray<string>
}

export type MachineView = {
  readonly machineID: string
  readonly name: string
  readonly state: string
  readonly braked: boolean
  readonly pulse: number
  readonly free?: BancadaProtocol.Vector
  readonly capabilities: Readonly<Record<string, unknown>>
}

export type Decision = {
  readonly offers: ReadonlyArray<{
    readonly job: string
    readonly part: string
    readonly machineID: string
    readonly proposed: number
  }>
  readonly waiting: ReadonlyArray<{
    readonly job: string
    readonly part: string
    readonly reason: BancadaProtocol.Reason
    /** From 1, among the parts that wait for a machine (not those held by a lock). */
    readonly position?: number
    /** How long until it starts, when it can be told. */
    readonly etaMs?: number
  }>
  /** Waiting parts a newer part went past on a machine they could use (once per offer). */
  readonly bypassed: ReadonlyArray<{ readonly job: string; readonly part: string; readonly times: number }>
}

/**
 * A machine as one part would find it in this decision: what is left free after the offers made to it so far, the build
 * slots the part takes there, those offers (they hold from now on) and the parts that wait for it ahead of this one.
 */
export type Line = {
  readonly free: BancadaProtocol.Vector
  readonly builds: number
  readonly offered: ReadonlyArray<{ readonly part: QueuedPart; readonly devices: number; readonly builds: number }>
  readonly waiting: ReadonlyArray<QueuedPart>
}

/** Bypasses that make a part reserved. */
export const reserveAfter = 3

export function schedule(input: {
  readonly parts: ReadonlyArray<QueuedPart>
  readonly machines: ReadonlyArray<MachineView>
  /** Exclusive locks held now (by parts offered or running). */
  readonly locks: ReadonlySet<string>
  /** How long until the part could start on the machine, and why (`estimate.ts`, `wait`). */
  readonly wait: (part: QueuedPart, machine: MachineView, line: Line) => Wait
  /** How long the part would take there once started (`estimate.ts`, `duration`). */
  readonly duration: (part: QueuedPart, machine: MachineView) => number
}): Decision {
  const room = new Map(
    input.machines.flatMap((machine) => (machine.free ? [[machine.machineID, { ...machine.free }]] : [])),
  )
  const locks = new Set(input.locks)
  const capable = (part: QueuedPart, machine: MachineView) =>
    needs(part.spec).every((need) => need in machine.capabilities) &&
    unmet(part.spec, machine.capabilities) === undefined
  const candidates = (part: QueuedPart) =>
    input.machines.filter(
      (machine) =>
        machine.state === "ok" &&
        machine.free !== undefined &&
        capable(part, machine) &&
        !(part.refused?.machineID === machine.machineID && machine.pulse <= part.refused.pulse),
    )
  /** Siblings offered in this decision, by request and machine: a group takes one build slot. */
  const grouped = new Set<string>()
  /** The build slots a part takes on a machine: none without `build`, or where its group already holds one. */
  const builds = (part: QueuedPart, machine: MachineView) =>
    !part.spec.build || part.siblingsOn?.includes(machine.machineID) || grouped.has(`${part.job}@${machine.machineID}`)
      ? 0
      : 1
  /** What was offered to each machine in this decision, and which parts wait for it, in order. */
  const offeredOn = new Map<string, Line["offered"][number][]>()
  const waitingOn = new Map<string, QueuedPart[]>()
  const best = (part: QueuedPart, among: ReadonlyArray<MachineView>) =>
    among
      .map((machine) => {
        const wait = input.wait(part, machine, {
          free: room.get(machine.machineID)!,
          builds: builds(part, machine),
          offered: offeredOn.get(machine.machineID) ?? [],
          waiting: waitingOn.get(machine.machineID) ?? [],
        })
        return { machine, ends: wait.ms + input.duration(part, machine), wait }
      })
      .toSorted(
        (a, b) =>
          a.ends - b.ends ||
          (room.get(b.machine.machineID)?.memMb ?? 0) - (room.get(a.machine.machineID)?.memMb ?? 0) ||
          a.machine.machineID.localeCompare(b.machine.machineID),
      )[0]
  const fits = (part: QueuedPart, machine: MachineView) => {
    const free = room.get(machine.machineID)
    if (!free || machine.braked || free.builds < builds(part, machine)) return false
    const platform = seat(part.spec)
    return platform === "none" || free[platform] >= part.spec.devices.min
  }

  // Reserved parts first, oldest first; then the soonest to end, then the oldest.
  const order = input.parts
    .map((part) => ({ part, soonest: best(part, candidates(part))?.ends ?? Number.POSITIVE_INFINITY }))
    .toSorted(
      (a, b) =>
        Number(b.part.reserved) - Number(a.part.reserved) ||
        (a.part.reserved ? older(a.part, b.part) : a.soonest - b.soonest || older(a.part, b.part)),
    )
    .map((item) => item.part)

  /** Machines a waiting reserved part holds, per platform: no newer part of that platform goes there. */
  const held = new Map<string, QueuedPart>()
  const blocked = (part: QueuedPart, machine: MachineView) => {
    const holder = held.get(`${machine.machineID}:${part.spec.platform}`)
    return holder !== undefined && holder !== part && older(holder, part) < 0
  }
  const offered = new Set<QueuedPart>()
  const offers: Array<Decision["offers"][number] & { readonly at: QueuedPart }> = []
  const waiting: Array<{ part: QueuedPart; reason: BancadaProtocol.Reason; etaMs?: number; ranked: boolean }> = []

  for (const part of order) {
    const lock = part.spec.exclusive.find((name) => locks.has(name))
    if (lock) {
      waiting.push({
        part,
        reason: { code: "trava", detail: lock, text: `aguardando trava ${short(lock)}` },
        ranked: false,
      })
      continue
    }
    const all = candidates(part)
    if (all.length === 0) {
      const away = input.machines.find((machine) => capable(part, machine))
      waiting.push({
        part,
        reason: away
          ? { code: "maquina_fora", detail: away.name, text: `aguardando ${away.name} voltar` }
          : { code: "sem_maquina", text: `nenhuma máquina oferece ${missing(part, input.machines)}` },
        ranked: true,
      })
      continue
    }
    const choice = best(
      part,
      all.filter((machine) => !blocked(part, machine)),
    )
    if (!choice) {
      waiting.push({ part, reason: { code: "fila", text: "na fila" }, ranked: true })
      continue
    }
    if (!fits(part, choice.machine)) {
      if (part.reserved) all.forEach((machine) => held.set(`${machine.machineID}:${part.spec.platform}`, part))
      waitingOn.set(choice.machine.machineID, [...(waitingOn.get(choice.machine.machineID) ?? []), part])
      waiting.push({
        part,
        reason: why(part, choice.machine, choice.wait),
        ...(Number.isFinite(choice.wait.ms) ? { etaMs: choice.wait.ms } : {}),
        ranked: true,
      })
      continue
    }
    const proposed = grant(part, choice.machine)
    const free = room.get(choice.machine.machineID)!
    const taken = builds(part, choice.machine)
    grouped.add(`${part.job}@${choice.machine.machineID}`)
    offeredOn.set(choice.machine.machineID, [
      ...(offeredOn.get(choice.machine.machineID) ?? []),
      { part, devices: proposed, builds: taken },
    ])
    room.set(choice.machine.machineID, {
      ...free,
      builds: free.builds - taken,
      ...((platform) => (platform === "none" ? {} : { [platform]: free[platform] - proposed }))(seat(part.spec)),
    })
    part.spec.exclusive.forEach((name) => locks.add(name))
    offered.add(part)
    offers.push({ job: part.job, part: part.part, machineID: choice.machine.machineID, proposed, at: part })
  }

  /**
   * Elastic grant: everything up to the part's maximum when nobody else waits for that kind of device on that
   * machine; otherwise a fair share of what is free, between its minimum and maximum.
   */
  function grant(part: QueuedPart, machine: MachineView) {
    const platform = seat(part.spec)
    if (platform === "none") return 0
    const free = room.get(machine.machineID)![platform]
    const others = order.filter(
      (other) =>
        other !== part &&
        !offered.has(other) &&
        seat(other.spec) === platform &&
        candidates(other).some((candidate) => candidate.machineID === machine.machineID),
    ).length
    const share = others === 0 ? part.spec.devices.max : Math.floor(free / (1 + others))
    return Math.min(free, Math.max(part.spec.devices.min, Math.min(part.spec.devices.max, share)))
  }

  const bypassed = waiting.flatMap((wait) => {
    const times = offers.filter(
      (offer) =>
        older(wait.part, offer.at) < 0 &&
        candidates(wait.part).some((machine) => machine.machineID === offer.machineID),
    ).length
    return wait.ranked && times > 0 ? [{ job: wait.part.job, part: wait.part.part, times }] : []
  })
  const ranked = waiting.filter((wait) => wait.ranked)
  return {
    offers: offers.map((offer) => ({
      job: offer.job,
      part: offer.part,
      machineID: offer.machineID,
      proposed: offer.proposed,
    })),
    waiting: waiting.map((wait) => ({
      job: wait.part.job,
      part: wait.part.part,
      reason: wait.reason,
      ...(wait.ranked ? { position: ranked.indexOf(wait) + 1 } : {}),
      ...(wait.etaMs === undefined ? {} : { etaMs: wait.etaMs }),
    })),
    bypassed,
  }
}

/**
 * The kind of device a part takes from a machine's budget: a phone takes none (it is reserved apart, `holds.ts`), so a
 * phone's test never waits for room for an emulator.
 */
export function seat(spec: BancadaProtocol.PartSpec): BancadaProtocol.Platform {
  return spec.needs.some((need) => need === "android-fisico" || need === "ios-fisico") ? "none" : spec.platform
}

/** What a part needs from a machine: its capabilities, and the policy of its secrets. */
export function needs(spec: BancadaProtocol.PartSpec) {
  return [...spec.needs, ...(spec.secrets ? [`segredos:${spec.secrets}`] : [])]
}

/** Negative when `a` entered the queue before `b`. */
function older(a: QueuedPart, b: QueuedPart) {
  return a.createdAt - b.createdAt || a.job.localeCompare(b.job) || a.index - b.index
}

/**
 * Why a part waits for the machine it would end soonest on (`docs/bancada.md`, "Queue"): the queue explains it when what
 * runs or waits ahead there frees enough (`fila`, the common case); otherwise it waits for room (`orcamento`). A part
 * only Macs serve (iOS) waits for a Mac.
 */
function why(part: QueuedPart, machine: MachineView, wait: Wait): BancadaProtocol.Reason {
  if (machine.braked) return { code: "freio", text: "máquina no limite" }
  if (part.spec.platform === "ios") return { code: "orcamento", text: "aguardando um Mac" }
  if (wait.by === "queue" || wait.by === "now") return { code: "fila", text: "na fila" }
  return { code: "orcamento", text: "aguardando folga" }
}

/** `abacato:servidor-dev` as `servidor-dev`. */
function short(lock: string) {
  return lock.slice(lock.lastIndexOf(":") + 1)
}

/** What no machine offers, for "nenhuma máquina oferece …". */
function missing(part: QueuedPart, machines: ReadonlyArray<MachineView>) {
  const absent = needs(part.spec).filter((need) => !machines.some((machine) => need in machine.capabilities))
  if (absent.length) return absent.join(", ")
  // Every need is offered somewhere, but not with this device (an image, a runtime, a model, a phone).
  const short = machines
    .filter((machine) => needs(part.spec).every((need) => need in machine.capabilities))
    .map((machine) => unmet(part.spec, machine.capabilities))
    .find((text) => text !== undefined)
  return short ?? (needs(part.spec).join(", ") || "o que a parte precisa")
}
