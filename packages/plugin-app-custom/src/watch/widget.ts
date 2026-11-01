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
  /**
   * At most one push a minute: a question answered and another asked in the same minute go out as one push with the
   * kinds at the end of that minute, or as none when they end where the watch already is.
   */
  spacingMs: 60_000,
  /** Every push looks again this long after, so one that APNs did not take is retried without a new change. */
  retryMs: 5 * 60_000,
  /** Window of the daily cap. */
  dayMs: 24 * 3_600_000,
  /** Pushes per device in any 24 hours. */
  dailyCap: 50,
  expirationSeconds: 15 * 60,
}

/**
 * What the complication draws (rev. 2026-11-01): which kinds of priority attention wait, never how many. Working
 * sessions, unread answers, finished ones, Progresso and the totals stay in the Painel and the Live Activity, so they
 * never push it. Mirrors `WatchAttention` (OpenCodeKit).
 */
export type Key = {
  readonly question: boolean
  readonly permission: boolean
  readonly failed: boolean
}

export function key(state: LiveActivity.AgentsState | null): Key {
  return {
    question: (state?.counts.question ?? 0) > 0,
    permission: (state?.counts.permission ?? 0) > 0,
    failed: (state?.counts.failed ?? 0) > 0,
  }
}

const same = (a: Key, b: Key) => a.question === b.question && a.permission === b.permission && a.failed === b.failed

/**
 * WidgetKit pushes (`apns-push-type: widgets`) that ask the watch complication to reload. Only a kind appearing or
 * clearing pushes (rev. 2026-11-01): at once, at most one a minute, priority 10, so an alert resolved on another
 * device leaves the wrist as fast as it arrived. Nothing is pushed for a state the watch already read through
 * `/state` (`seen`). The first state after start is only recorded.
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
      if (last.sent.length >= limits.dailyCap) {
        // The slot frees when the day's oldest push leaves the window; the watch's own reloads cover meanwhile.
        wakes.push((last.sent[last.sent.length - limits.dailyCap] ?? now) + limits.dayMs)
        if (!last.capped) {
          last.capped = true
          yield* input.stats.capped(device.deviceID, now)
          yield* Effect.logInfo("Watch widget push capped", { deviceID: device.deviceID, sent: last.sent.length })
        }
        continue
      }
      if (now - last.at < limits.spacingMs) {
        wakes.push(last.at + limits.spacingMs)
        continue
      }
      const previous = { known: last.known, at: last.at }
      last.known = next
      last.at = now
      last.sent.push(now)
      last.capped = false
      wakes.push(now + limits.retryMs)
      const push: Push = {
        token: widget.token,
        environment: widget.environment,
        // APNs may hold priority 5 and deliver it in bursts; Apple's own widget push example leaves the header out,
        // which means 10.
        priority: 10,
        expiration: Math.floor(now / 1000) + limits.expirationSeconds,
        body: { aps: { "content-changed": true } },
        type: "widgets",
        bundleID: input.bundleID,
      }
      jobs.push(
        input.send(push).pipe(
          Effect.flatMap((result) => {
            // Every push is an attention change; `coalesced` stays in the stats contract, always 0 since 2026-11-01.
            if (result.status === "sent")
              return input.stats
                .pushed(device.deviceID, "urgent", now)
                .pipe(
                  Effect.andThen(Effect.logInfo("Watch widget push sent", { deviceID: device.deviceID, key: next })),
                )
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
