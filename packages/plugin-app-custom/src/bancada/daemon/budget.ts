import type { BancadaProtocol } from "../protocol.js"

/**
 * The machine's budget (`docs/bancada.md`, "Budget"): memory, CPU and builds, plus how many emulators and simulators
 * its ceilings allow. An attempt reserves its peak at admission: its build, its devices and what the test takes beside
 * them, all at once; the build's share goes back when the build ends. Pure: the executor gives the numbers.
 */

/** Memory in MB and CPU in thousandths of a core. */
export type Cost = { readonly memMb: number; readonly cpuMilli: number }

export const zero: Cost = { memMb: 0, cpuMilli: 0 }

/** Samples kept per subject; fewer than `trusted` and the default cost holds. */
export const samples = { kept: 20, trusted: 3 }

/** The p90 of what this machine measured, once it has `samples.trusted` samples; the default before. */
export function measured(values: ReadonlyArray<Cost>, fallback: Cost): Cost {
  if (values.length < samples.trusted) return fallback
  const p90 = (numbers: number[]) => numbers.toSorted((a, b) => a - b)[Math.ceil(numbers.length * 0.9) - 1]!
  return { memMb: p90(values.map((value) => value.memMb)), cpuMilli: p90(values.map((value) => value.cpuMilli)) }
}

export function add(...costs: ReadonlyArray<Cost>): Cost {
  return costs.reduce((sum, cost) => ({ memMb: sum.memMb + cost.memMb, cpuMilli: sum.cpuMilli + cost.cpuMilli }), zero)
}

export function times(cost: Cost, n: number): Cost {
  return { memMb: cost.memMb * n, cpuMilli: cost.cpuMilli * n }
}

/**
 * What new admissions may still use: the budget minus every live reservation. While the owner uses the Mac, memory
 * and CPU count only `presence` of the budget (live reservations stay whole).
 */
export function room(capacity: BancadaProtocol.Vector, used: BancadaProtocol.Vector, presence = 1) {
  return {
    memMb: Math.floor(capacity.memMb * presence) - used.memMb,
    cpuMilli: Math.floor(capacity.cpuMilli * presence) - used.cpuMilli,
    builds: capacity.builds - used.builds,
    android: capacity.android - used.android,
    ios: capacity.ios - used.ios,
  } satisfies BancadaProtocol.Vector
}

/**
 * The most devices between `min` and `proposed` an attempt can reserve now, with its build and its extra; undefined
 * when not even `min` fits (or the build slot it needs is not free).
 */
export function largestFit(input: {
  readonly room: BancadaProtocol.Vector
  /** Build slots it takes: 1, or none for a test without build or one whose group already holds one. */
  readonly builds?: number
  readonly platform: BancadaProtocol.Platform
  readonly min: number
  readonly proposed: number
  readonly build: Cost
  readonly device: Cost
  readonly extra: (devices: number) => Cost
}) {
  if (input.room.builds < (input.builds ?? 1)) return undefined
  const fits = (n: number) => {
    if (input.platform !== "none" && n > input.room[input.platform]) return false
    const peak = add(input.build, times(input.device, n), input.extra(n))
    return peak.memMb <= input.room.memMb && peak.cpuMilli <= input.room.cpuMilli
  }
  const counts = input.platform === "none" ? [0] : range(input.proposed, input.min)
  return counts.find(fits)
}

/**
 * The pulse's free vector, which the hub never offers beyond: as many builds as fit together now, and as many devices
 * of each kind as fit beside one build within the ceilings.
 */
export function free(
  room: BancadaProtocol.Vector,
  build: Cost,
  devices: { readonly android: Cost; readonly ios: Cost },
): BancadaProtocol.Vector {
  const left = { memMb: room.memMb - build.memMb, cpuMilli: room.cpuMilli - build.cpuMilli }
  const building = room.builds >= 1 && left.memMb >= 0 && left.cpuMilli >= 0
  const count = (cost: Cost, ceiling: number) =>
    building
      ? Math.max(0, Math.min(ceiling, Math.floor(left.memMb / cost.memMb), Math.floor(left.cpuMilli / cost.cpuMilli)))
      : 0
  // As many builds as fit together, not only as the budget counts: the hub offers one per build.
  const builds = Math.min(room.builds, Math.floor(room.memMb / build.memMb), Math.floor(room.cpuMilli / build.cpuMilli))
  return {
    memMb: Math.max(0, room.memMb),
    cpuMilli: Math.max(0, room.cpuMilli),
    builds: building ? builds : 0,
    android: count(devices.android, room.android),
    ios: count(devices.ios, room.ios),
  }
}

function range(from: number, to: number) {
  return Array.from({ length: Math.max(0, from - to + 1) }, (_, index) => from - index)
}
