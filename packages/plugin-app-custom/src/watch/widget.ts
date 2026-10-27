import { Effect } from "effect"
import type { Client, Push } from "../live-activity/apns.js"
import type { LiveActivity } from "../live-activity/rpc.js"
import type { Devices } from "./devices.js"

export const limits = {
  /** At most one WidgetKit push per device in this window, unless attention or failures increase. */
  spacingMs: 2 * 60_000,
  expirationSeconds: 15 * 60,
}

type Key = { readonly active: number; readonly attention: number; readonly failed: number }

/**
 * WidgetKit pushes (`apns-push-type: widgets`) that ask the watch complication to reload its timeline when
 * `activeTotal`, `attentionTotal` or `counts.failed` change. The first state seen after start is only recorded.
 */
export function makeWidgetPush(input: {
  readonly devices: Devices
  readonly send: Client["send"]
  readonly bundleID: string
}) {
  const memo = new Map<string, { sent: Key; at: number }>()

  const evaluate = Effect.fn("Watch.widgetPush")(function* (state: LiveActivity.AgentsState | null, now: number) {
    const key: Key = state
      ? { active: state.activeTotal, attention: state.attentionTotal, failed: state.counts.failed }
      : { active: 0, attention: 0, failed: 0 }
    const wakes: number[] = []
    const jobs: Effect.Effect<void>[] = []
    for (const device of yield* input.devices.list()) {
      const widget = device.widget
      if (!widget) continue
      const last = memo.get(device.deviceID)
      if (!last) {
        memo.set(device.deviceID, { sent: key, at: -Infinity })
        continue
      }
      if (last.sent.active === key.active && last.sent.attention === key.attention && last.sent.failed === key.failed)
        continue
      const rising = key.attention > last.sent.attention || key.failed > last.sent.failed
      if (!rising && now - last.at < limits.spacingMs) {
        wakes.push(last.at + limits.spacingMs)
        continue
      }
      memo.set(device.deviceID, { sent: key, at: now })
      const push: Push = {
        token: widget.token,
        environment: widget.environment,
        priority: 5,
        expiration: Math.floor(now / 1000) + limits.expirationSeconds,
        body: { aps: { "content-changed": true } },
        type: "widgets",
        bundleID: input.bundleID,
      }
      jobs.push(
        input.send(push).pipe(
          Effect.flatMap((result) => {
            if (result.status === "sent") return Effect.logInfo("Watch widget push sent", { deviceID: device.deviceID })
            if (result.status === "invalid")
              return input.devices
                .widget(device.deviceID, undefined)
                .pipe(Effect.andThen(Effect.logInfo("Watch widget token dropped", { reason: result.reason })))
            // Retried at the next change or slot.
            memo.set(device.deviceID, { sent: last.sent, at: now })
            return Effect.logWarning("Watch widget push failed", { reason: result.reason })
          }),
        ),
      )
    }
    return {
      wakeAt: wakes.length > 0 ? Math.min(...wakes) : undefined,
      deliver: Effect.all(jobs, { concurrency: "unbounded", discard: true }),
    }
  })

  return { evaluate, memo }
}

export type WidgetPush = ReturnType<typeof makeWidgetPush>
