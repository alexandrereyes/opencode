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

/**
 * How long a part waits on a machine before it fits: none when it fits now and the brake is open (5 minutes, unknown,
 * while it is closed). Otherwise the
 * machine's attempts end in the order of their estimated end until a build and `min` devices are free; plus what the
 * parts already held for that machine ahead of this one take. Infinity when it would never fit.
 */
export function wait(input: {
  readonly now: number
  readonly free: { readonly builds: number; readonly devices: number }
  readonly ceiling: number
  readonly min: number
  readonly braked: boolean
  readonly running: ReadonlyArray<Running>
  readonly ahead: ReadonlyArray<number>
}) {
  const queued = input.ahead.reduce((sum, ms) => sum + ms, 0)
  if (input.min > input.ceiling) return Number.POSITIVE_INFINITY
  // A brake reopens after good readings, not when attempts end: how long is unknown.
  if (input.braked) return defaults.durationMs + queued
  if (input.free.builds >= 1 && input.free.devices >= input.min && queued === 0) return 0
  const ordered = input.running.toSorted((a, b) => a.endsAt - b.endsAt)
  const freed = ordered.reduce<{ builds: number; devices: number; at: number } | undefined>(
    (state, attempt) => {
      if (!state || (state.builds >= 1 && state.devices >= input.min)) return state
      return {
        builds: state.builds + (attempt.building ? 1 : 0),
        devices: state.devices + attempt.devices,
        at: Math.max(state.at, attempt.endsAt),
      }
    },
    { builds: input.free.builds, devices: input.free.devices, at: input.now },
  )
  // Nothing it runs would free enough: it fits only when the machine's state changes (a brake, a hold).
  const fits = freed && freed.builds >= 1 && freed.devices >= input.min
  return (fits ? Math.max(0, freed.at - input.now) : defaults.durationMs) + queued
}

function median(values: ReadonlyArray<number>) {
  const sorted = values.toSorted((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2
}
