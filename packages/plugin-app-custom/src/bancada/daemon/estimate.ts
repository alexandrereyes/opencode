/**
 * How long a part would take on a machine (`docs/bancada.md`, "Estimate"): `ends = wait + duration`. Pure: the hub
 * gives the history and what each machine runs.
 */

/** One past execution of a project's test on a machine. */
export type Sample = {
  readonly buildMs: number
  readonly runMs: number
  readonly devices: number
  /** Scenarios it ran, when it said. */
  readonly scenarios?: number
}

export const defaults = {
  /** Without any history. */
  durationMs: 5 * 60_000,
  /** A machine the owner called slow, without history of its own. */
  slow: 2.5,
  /** Samples kept per project, test and machine. */
  kept: 10,
}

/**
 * The duration of a part here: the median run of the last executions of that project and test on this machine, plus
 * the median build (none when a sibling part of the same request is already here: its build serves both). With the
 * planned scenarios known and history that counted them, time per scenario × scenarios ÷ devices. Without history
 * here, the other machines' median (× 2.5 on a slow machine); without any, 5 minutes (× 2.5 on a slow machine).
 */
export function duration(input: {
  readonly here: ReadonlyArray<Sample>
  readonly elsewhere: ReadonlyArray<Sample>
  readonly slow: boolean
  readonly devices: number
  readonly planned?: number
  readonly built: boolean
}) {
  const factor = input.slow ? defaults.slow : 1
  const history = input.here.length > 0 ? input.here : input.elsewhere
  if (history.length === 0) return defaults.durationMs * factor
  const counted = history.filter((sample) => sample.scenarios !== undefined && sample.scenarios > 0)
  const run =
    input.planned !== undefined && counted.length > 0
      ? (median(counted.map((sample) => (sample.runMs * Math.max(1, sample.devices)) / sample.scenarios!)) *
          input.planned) /
        Math.max(1, input.devices)
      : median(history.map((sample) => sample.runMs))
  const build = input.built ? 0 : median(history.map((sample) => sample.buildMs))
  return Math.round((run + build) * (input.here.length > 0 ? 1 : factor))
}

/** What a machine runs now, as the hub knows it: when each attempt should end and what it holds until then. */
export type Running = { readonly endsAt: number; readonly devices: number; readonly building: boolean }

/** A part that waits for the same machine ahead of this one: what it will take there, and for how long. */
export type Ahead = { readonly devices: number; readonly builds: number; readonly durationMs: number }

/**
 * How long a part waits for a machine and why. `now`: it fits now. `queue`: it fits when what the queue runs or holds
 * ahead there ends (the instant the count found). `budget`: nothing of that frees enough (a light slot, the owner's
 * presence, memory taken from outside): it fits only when the machine's state changes. `brake`: the machine is at its
 * limit. `never`: it needs more than the machine ever has.
 */
export type Wait = { readonly ms: number; readonly by: "now" | "queue" | "budget" | "brake" | "never" }

/**
 * The wait (`docs/bancada.md`, "Estimate"): none when it fits now and the brake is open (5 minutes, unknown, while it
 * is closed). Otherwise what the machine runs ends in the order of its estimated end, and each part waiting ahead there
 * takes its turn as soon as it fits, and holds what it took for its own duration; this one starts when enough is left
 * for it. A part ahead that nothing frees enough for keeps its place without taking anything.
 */
export function wait(input: {
  readonly now: number
  readonly free: { readonly builds: number; readonly devices: number }
  readonly ceiling: number
  readonly min: number
  /** Build slots it takes: 1, or none without build or where its group already holds one. */
  readonly builds: number
  readonly braked: boolean
  readonly running: ReadonlyArray<Running>
  readonly ahead: ReadonlyArray<Ahead>
}): Wait {
  if (input.min > input.ceiling) return { ms: Number.POSITIVE_INFINITY, by: "never" }
  // A brake reopens after good readings, not when attempts end: how long is unknown.
  if (input.braked)
    return { ms: defaults.durationMs + input.ahead.reduce((sum, item) => sum + item.durationMs, 0), by: "brake" }
  if (input.free.builds >= input.builds && input.free.devices >= input.min) return { ms: 0, by: "now" }
  const state = {
    builds: input.free.builds,
    devices: input.free.devices,
    at: input.now,
    ending: input.running.toSorted((a, b) => a.endsAt - b.endsAt),
  }
  // Ends what runs, in order, until `need` fits; false when nothing left frees enough.
  const free = (need: { readonly devices: number; readonly builds: number }) => {
    while (state.builds < need.builds || state.devices < need.devices) {
      const next = state.ending.shift()
      if (!next) return false
      state.builds += next.building ? 1 : 0
      state.devices += next.devices
      state.at = Math.max(state.at, next.endsAt)
    }
    return true
  }
  for (const item of input.ahead) {
    const before = { ...state, ending: [...state.ending] }
    if (!free(item)) {
      Object.assign(state, before)
      continue
    }
    state.builds -= item.builds
    state.devices -= item.devices
    state.ending = [
      ...state.ending,
      { endsAt: state.at + item.durationMs, devices: item.devices, building: item.builds > 0 },
    ].toSorted((a, b) => a.endsAt - b.endsAt)
  }
  // Nothing it runs would free enough: it fits only when the machine's state changes (a brake, a hold).
  if (!free({ devices: input.min, builds: input.builds }))
    return { ms: state.at - input.now + defaults.durationMs, by: "budget" }
  return { ms: state.at - input.now, by: "queue" }
}

function median(values: ReadonlyArray<number>) {
  const sorted = values.toSorted((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2
}
