import { Effect } from "effect"
import type { Client, Push } from "../live-activity/apns.js"
import type { LiveActivity } from "../live-activity/rpc.js"
import type { Devices } from "./devices.js"
import type { Stats } from "./stats.js"

/**
 * WidgetKit budgets every reload of the complication, pushed or not: Apple quotes 40 to 70 a day for a widget that is
 * looked at often. The numbers below keep pushes inside that with room for the watch's own reloads.
 */
export const limits = {
  /** Other changes wait this long after the device's previous push and go out folded into one. */
  coalesceMs: 30 * 60_000,
  /**
   * Urgent pushes are at most one a minute: sessions that finish together, or a question right after an answer,
   * go out as one push with the state at the end of that minute.
   */
  urgentSpacingMs: 60_000,
  /** Window of the daily cap. */
  dayMs: 24 * 3_600_000,
  /** Pushes per device in any 24 hours, urgent ones included (rev. 2026-10-30: 50, with unread answers urgent). */
  dailyCap: 50,
  /** Folded pushes stop here, so the last 25 of the cap stay for urgent changes. */
  coalescedCap: 25,
  expirationSeconds: 15 * 60,
}

/** What the complication draws: the ring's counts, the active total and how many need Alexandre. */
export type Key = {
  readonly active: number
  readonly attention: number
  readonly failed: number
  readonly working: number
  readonly question: number
  readonly permission: number
  readonly finished: number
}

export function key(state: LiveActivity.AgentsState | null): Key {
  if (!state) return { active: 0, attention: 0, failed: 0, working: 0, question: 0, permission: 0, finished: 0 }
  return {
    active: state.activeTotal,
    attention: state.attentionTotal,
    failed: state.counts.failed,
    working: state.counts.working,
    question: state.counts.question,
    permission: state.counts.permission,
    // The fifth arc: unread sessions, or recently finished ones from a backend without `unread`.
    finished: state.counts.unread ?? state.counts.idle,
  }
}

/**
 * A new question, permission or failure, a new unread answer (rev. 2026-10-30: what Alexandre most wants to see on
 * the wrist; it used to wait for a folded push), or the active total leaving or reaching zero.
 */
export function urgent(known: Key, next: Key) {
  return (
    next.attention > known.attention ||
    next.failed > known.failed ||
    next.finished > known.finished ||
    (known.active === 0) !== (next.active === 0)
  )
}

const same = (a: Key, b: Key) => (Object.keys(a) as (keyof Key)[]).every((name) => a[name] === b[name])

/**
 * WidgetKit pushes (`apns-push-type: widgets`) that ask the watch complication to reload. Urgent changes go at once
 * (at most one a minute, priority 10); the rest wait for one folded push per `coalesceMs` (priority 5), and nothing
 * is pushed for a state the watch already read through `/state` (`seen`). The first state after start is only
 * recorded.
 */
export function makeWidgetPush(input: {
  readonly devices: Devices
  readonly send: Client["send"]
  readonly bundleID: string
  readonly stats: Stats
}) {
  /** Per device: what the watch has (last push or `/state` read), the last push and the pushes of the last day. */
  const memo = new Map<string, { known: Key; at: number; sent: number[]; capped: boolean }>()

  const evaluate = Effect.fn("Watch.widgetPush")(function* (state: LiveActivity.AgentsState | null, now: number) {
    const next = key(state)
    const wakes: number[] = []
    const jobs: Effect.Effect<void>[] = []
    for (const device of yield* input.devices.list()) {
      const widget = device.widget
      if (!widget) continue
      const last = memo.get(device.deviceID)
      if (!last) {
        memo.set(device.deviceID, { known: next, at: -Infinity, sent: [], capped: false })
        continue
      }
      if (same(last.known, next)) continue
      last.sent = last.sent.filter((at) => now - at < limits.dayMs)
      const reason = urgent(last.known, next) ? "urgent" : "coalesced"
      const cap = reason === "urgent" ? limits.dailyCap : limits.coalescedCap
      if (last.sent.length >= cap) {
        // The slot frees when enough of the day's pushes leave the window; the watch's own reloads cover meanwhile.
        wakes.push((last.sent[last.sent.length - cap] ?? now) + limits.dayMs)
        if (!last.capped) {
          last.capped = true
          yield* input.stats.capped(device.deviceID, now)
          yield* Effect.logInfo("Watch widget push capped", {
            deviceID: device.deviceID,
            reason,
            sent: last.sent.length,
          })
        }
        continue
      }
      const spacing = reason === "urgent" ? limits.urgentSpacingMs : limits.coalesceMs
      if (now - last.at < spacing) {
        wakes.push(last.at + spacing)
        continue
      }
      const previous = { known: last.known, at: last.at }
      last.known = next
      last.at = now
      last.sent.push(now)
      last.capped = false
      // Looks again after one window, so a push that fails is retried even when nothing else changes.
      wakes.push(now + limits.coalesceMs)
      const push: Push = {
        token: widget.token,
        environment: widget.environment,
        // Priority 5 may be held and delivered in bursts by APNs; an urgent change goes at once (Apple's own widget
        // push example leaves the header out, which means 10).
        priority: reason === "urgent" ? 10 : 5,
        expiration: Math.floor(now / 1000) + limits.expirationSeconds,
        body: { aps: { "content-changed": true } },
        type: "widgets",
        bundleID: input.bundleID,
      }
      jobs.push(
        input.send(push).pipe(
          Effect.flatMap((result) => {
            if (result.status === "sent")
              return input.stats
                .pushed(device.deviceID, reason, now)
                .pipe(Effect.andThen(Effect.logInfo("Watch widget push sent", { deviceID: device.deviceID, reason })))
            if (result.status === "invalid")
              return input.devices
                .widget(device.deviceID, undefined)
                .pipe(Effect.andThen(Effect.logInfo("Watch widget token dropped", { reason: result.reason })))
            // Not delivered: the watch still has the previous state and the push does not count.
            if (same(last.known, next)) last.known = previous.known
            if (last.at === now) last.at = previous.at
            last.sent = last.sent.filter((at) => at !== now)
            return input.stats
              .failed(device.deviceID, now)
              .pipe(Effect.andThen(Effect.logWarning("Watch widget push failed", { reason: result.reason })))
          }),
        ),
      )
    }
    return {
      wakeAt: wakes.length > 0 ? Math.min(...wakes) : undefined,
      deliver: Effect.all(jobs, { concurrency: "unbounded", discard: true }),
    }
  })

  /** The watch read `state` through `/state` and cached it, so a push for that state would reload for nothing. */
  const seen = (deviceID: string, state: LiveActivity.AgentsState | null) => {
    const last = memo.get(deviceID)
    if (last) last.known = key(state)
  }

  return { evaluate, seen, memo }
}

export type WidgetPush = ReturnType<typeof makeWidgetPush>
