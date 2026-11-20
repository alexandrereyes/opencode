import type { BancadaProtocol } from "../protocol.js"

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

/** Bypasses that make a part reserved. */
export const reserveAfter = 3

export function schedule(input: {
  readonly parts: ReadonlyArray<QueuedPart>
  readonly machines: ReadonlyArray<MachineView>
  /** Exclusive locks held now (by parts offered or running). */
  readonly locks: ReadonlySet<string>
  /** How long until the part could start on the machine (`estimate.ts`, `wait`). */
  readonly wait: (part: QueuedPart, machine: MachineView) => number
  /** How long the part would take there once started (`estimate.ts`, `duration`). */
  readonly duration: (part: QueuedPart, machine: MachineView) => number
}): Decision {
  const room = new Map(
    input.machines.flatMap((machine) => (machine.free ? [[machine.machineID, { ...machine.free }]] : [])),
  )
  const locks = new Set(input.locks)
  const capable = (part: QueuedPart, machine: MachineView) =>
    needs(part.spec).every((need) => need in machine.capabilities)
  const candidates = (part: QueuedPart) =>
    input.machines.filter(
      (machine) =>
        machine.state === "ok" &&
        machine.free !== undefined &&
        capable(part, machine) &&
        !(part.refused?.machineID === machine.machineID && machine.pulse <= part.refused.pulse),
    )
  const ends = (part: QueuedPart, machine: MachineView) => input.wait(part, machine) + input.duration(part, machine)
  const best = (part: QueuedPart, among: ReadonlyArray<MachineView>) =>
    among
      .map((machine) => ({ machine, ends: ends(part, machine), wait: input.wait(part, machine) }))
      .toSorted(
        (a, b) =>
          a.ends - b.ends ||
          (room.get(b.machine.machineID)?.memMb ?? 0) - (room.get(a.machine.machineID)?.memMb ?? 0) ||
          a.machine.machineID.localeCompare(b.machine.machineID),
      )[0]
  const fits = (part: QueuedPart, machine: MachineView) => {
    const free = room.get(machine.machineID)
    if (!free || machine.braked || free.builds < 1) return false
    return part.spec.platform === "none" || free[part.spec.platform] >= part.spec.devices.min
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
      waiting.push({
        part,
        reason: choice.machine.braked
          ? { code: "freio", text: "máquina no limite" }
          : { code: "orcamento", text: onlyMacs(part) ? "aguardando um Mac" : "aguardando folga" },
        ...(Number.isFinite(choice.wait) ? { etaMs: choice.wait } : {}),
        ranked: true,
      })
      continue
    }
    const proposed = grant(part, choice.machine)
    const free = room.get(choice.machine.machineID)!
    room.set(choice.machine.machineID, {
      ...free,
      builds: free.builds - 1,
      ...(part.spec.platform === "none" ? {} : { [part.spec.platform]: free[part.spec.platform] - proposed }),
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
    const platform = part.spec.platform
    if (platform === "none") return 0
    const free = room.get(machine.machineID)![platform]
    const others = order.filter(
      (other) =>
        other !== part &&
        !offered.has(other) &&
        other.spec.platform === platform &&
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

/** What a part needs from a machine: its capabilities, and the policy of its secrets. */
export function needs(spec: BancadaProtocol.PartSpec) {
  return [...spec.needs, ...(spec.secrets ? [`segredos:${spec.secrets}`] : [])]
}

/** Negative when `a` entered the queue before `b`. */
function older(a: QueuedPart, b: QueuedPart) {
  return a.createdAt - b.createdAt || a.job.localeCompare(b.job) || a.index - b.index
}

function onlyMacs(part: QueuedPart) {
  return part.spec.platform === "ios"
}

/** `abacato:servidor-dev` as `servidor-dev`. */
function short(lock: string) {
  return lock.slice(lock.lastIndexOf(":") + 1)
}

/** What no machine offers, for "nenhuma máquina oferece …". */
function missing(part: QueuedPart, machines: ReadonlyArray<MachineView>) {
  const absent = needs(part.spec).filter((need) => !machines.some((machine) => need in machine.capabilities))
  return (absent.length ? absent : needs(part.spec)).join(", ") || "o que a parte precisa"
}
