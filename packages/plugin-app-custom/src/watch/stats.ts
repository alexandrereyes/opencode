import { Effect } from "effect"

/** Who read `/watch/v1/state`: the app in front, its background refresh, or the complication reloading. */
export type Client = "app" | "background" | "widget" | "unknown"

type Usage = {
  state: Record<Client, number>
  pushes: { urgent: number; coalesced: number; failed: number }
  /** Times a push had to wait for the daily cap. */
  capped: number
}

const hourMs = 3_600_000
/** Hours kept per device, and the span `day` sums. */
const keep = 48
const dayHours = 24

const empty = (): Usage => ({
  state: { app: 0, background: 0, widget: 0, unknown: 0 },
  pushes: { urgent: 0, coalesced: 0, failed: 0 },
  capped: 0,
})

export function reader(header: string | null): Client {
  return header === "app" || header === "background" || header === "widget" ? header : "unknown"
}

/**
 * In-memory counters per watch and hour, to check the WidgetKit budget: every `widget` read is one complication
 * reload. Read through `custom.watch` → `stats`; each finished hour is also logged once ("Watch hourly usage").
 * Restarting the server starts them over.
 */
export function makeStats() {
  const devices = new Map<string, Map<number, Usage>>()

  const bucket = (deviceID: string, now: number) => {
    const hours = devices.get(deviceID) ?? new Map<number, Usage>()
    devices.set(deviceID, hours)
    const hour = Math.floor(now / hourMs) * hourMs
    const current = hours.get(hour)
    if (current) return { usage: current, closed: undefined }
    // A new hour closes the previous one: return it for the log, and forget hours beyond what is kept.
    const closed = [...hours.entries()].at(-1)
    for (const old of hours.keys()) if (old <= hour - keep * hourMs) hours.delete(old)
    const usage = empty()
    hours.set(hour, usage)
    return { usage, closed }
  }

  const log = (deviceID: string, closed: readonly [number, Usage] | undefined) =>
    closed
      ? Effect.logInfo("Watch hourly usage", {
          deviceID,
          hour: new Date(closed[0]).toISOString(),
          ...closed[1].state,
          urgent: closed[1].pushes.urgent,
          coalesced: closed[1].pushes.coalesced,
          failed: closed[1].pushes.failed,
          capped: closed[1].capped,
        })
      : Effect.void

  /** Counts into the hour of `now`; the first count of a new hour logs the previous one. */
  const count = (deviceID: string, now: number, apply: (usage: Usage) => void) =>
    Effect.suspend(() => {
      const found = bucket(deviceID, now)
      apply(found.usage)
      return log(deviceID, found.closed)
    })

  return {
    state: (deviceID: string, from: Client, now: number) =>
      count(deviceID, now, (usage) => {
        usage.state[from] += 1
      }),
    pushed: (deviceID: string, reason: "urgent" | "coalesced", now: number) =>
      count(deviceID, now, (usage) => {
        usage.pushes[reason] += 1
      }),
    failed: (deviceID: string, now: number) =>
      count(deviceID, now, (usage) => {
        usage.pushes.failed += 1
      }),
    capped: (deviceID: string, now: number) =>
      count(deviceID, now, (usage) => {
        usage.capped += 1
      }),
    /** The last 24 hours per device, plus each of its hours with any activity (newest first). */
    snapshot: (now: number) => ({
      devices: [...devices.entries()].map(([deviceID, hours]) => {
        const recent = [...hours.entries()].filter(([hour]) => hour > now - dayHours * hourMs).toReversed()
        return {
          deviceID,
          day: recent.reduce((total, [, usage]) => add(total, usage), empty()),
          hours: recent.map(([hour, usage]) => ({ hour, ...usage })),
        }
      }),
    }),
  }
}

export type Stats = ReturnType<typeof makeStats>

function add(total: Usage, usage: Usage): Usage {
  return {
    state: {
      app: total.state.app + usage.state.app,
      background: total.state.background + usage.state.background,
      widget: total.state.widget + usage.state.widget,
      unknown: total.state.unknown + usage.state.unknown,
    },
    pushes: {
      urgent: total.pushes.urgent + usage.pushes.urgent,
      coalesced: total.pushes.coalesced + usage.pushes.coalesced,
      failed: total.pushes.failed + usage.pushes.failed,
    },
    capped: total.capped + usage.capped,
  }
}
