import { Effect, Option, Schema } from "effect"
import type { Client, Push } from "../live-activity/apns.js"
import type { Storage } from "../live-activity/lifecycle.js"
import { LiveActivity } from "../live-activity/rpc.js"
import type { Watch } from "../live-activity/tracker.js"
import type { Notifications } from "./rpc.js"

export const limits = {
  /** Registrations without `register` for this long are dropped. */
  forgetMs: 30 * 86_400_000,
  /**
   * A family must stay quiet this long before it counts as finished: a background shell or subagent that ends wakes
   * its parent a moment later, and that gap is not the end of the work.
   */
  graceMs: 5_000,
  /** APNs keeps an undelivered alert for this long. */
  expirationMs: 24 * 3_600_000,
}

export const devicesKey = "notifications:devices"

const Device = Schema.Struct({
  deviceID: Schema.String,
  serverKey: Schema.String,
  environment: LiveActivity.Environment,
  token: Schema.String,
  registeredAt: Schema.Number,
})
export type Device = typeof Device.Type
const Devices = Schema.Array(Device)
const decodeDevices = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Devices)(value ?? []), () => [])
const encodeDevices = Schema.encodeSync(Devices)

/** One APNs device token per app install, kept in plugin storage so every Location's instance shares them. */
export function makeNotificationRegistry(storage: Storage) {
  const change = (now: number, update: (devices: readonly Device[]) => readonly Device[]) =>
    storage.update(devicesKey, (current) => [
      encodeDevices(update(decodeDevices(current).filter((device) => now - device.registeredAt < limits.forgetMs))),
      undefined,
    ])
  return {
    list: (now: number) =>
      storage
        .get(devicesKey)
        .pipe(
          Effect.map((value) => decodeDevices(value).filter((device) => now - device.registeredAt < limits.forgetMs)),
        ),
    register: (input: Notifications.RegisterInput, now: number) =>
      change(now, (devices) => [
        // A token belongs to one install; another device ID reporting it replaced that install.
        ...devices.filter((device) => device.deviceID !== input.deviceID && device.token !== input.token),
        { ...input, registeredAt: now },
      ]),
    unregister: (deviceID: string, now: number) =>
      change(now, (devices) => devices.filter((device) => device.deviceID !== deviceID)),
    /** Drops a token APNs reported invalid, unless the device registered a new one meanwhile. */
    drop: (deviceID: string, token: string, now: number) =>
      change(now, (devices) => devices.filter((device) => device.deviceID !== deviceID || device.token !== token)),
  }
}

export type NotificationRegistry = ReturnType<typeof makeNotificationRegistry>

/**
 * "Avisar ao terminar": one alert per registered device when a watched top-level session's family (its own
 * execution, subagents and background shells) stops working for good. Only work this process saw counts, and only
 * work newer than the bell (a run that ended before it was turned on is not reported). A user or shutdown
 * interruption alerts nothing.
 */
export function makeNotifier(input: { readonly registry: NotificationRegistry; readonly send: Client["send"] }) {
  /**
   * Per watched family: `handled`, the `workedAt` already reported (or present when first seen idle); `pending` and
   * `quietSince`, the work being confirmed as finished and since when it has been quiet.
   */
  const families = new Map<string, { handled?: number; pending?: number; quietSince?: number }>()

  const evaluate = Effect.fn("Notifications.evaluate")(function* (
    watched: ReadonlyMap<string, Watch>,
    now: number,
  ) {
    for (const id of families.keys()) if (!watched.has(id)) families.delete(id)
    const wakes: number[] = []
    const finished: (Watch & { readonly outcome: "succeeded" | "failed" })[] = []
    for (const [id, watch] of watched) {
      const memo = families.get(id) ?? (watch.working ? {} : { handled: watch.workedAt })
      families.set(id, memo)
      if (watch.working) {
        memo.pending = undefined
        memo.quietSince = undefined
        continue
      }
      if (watch.workedAt === undefined || watch.workedAt === memo.handled) continue
      // Newer work than the quiet period being confirmed restarts it.
      if (memo.pending !== watch.workedAt || memo.quietSince === undefined) {
        memo.pending = watch.workedAt
        memo.quietSince = now
      }
      if (now - memo.quietSince < limits.graceMs) {
        wakes.push(memo.quietSince + limits.graceMs)
        continue
      }
      memo.handled = watch.workedAt
      memo.pending = undefined
      memo.quietSince = undefined
      if (watch.outcome === "succeeded" || watch.outcome === "failed") finished.push({ ...watch, outcome: watch.outcome })
    }
    const devices = finished.length > 0 ? yield* input.registry.list(now) : []
    const jobs = finished.flatMap((watch) =>
      devices.map((device) => {
        const request = push(device, watch, now)
        return input.send(request).pipe(
          Effect.flatMap((result) => {
            if (result.status === "sent")
              return Effect.logInfo("Session notification sent", {
                sessionID: watch.ref.sessionID,
                outcome: watch.outcome,
                environment: device.environment,
              })
            if (result.status === "invalid")
              return input.registry
                .drop(device.deviceID, device.token, now)
                .pipe(Effect.andThen(Effect.logInfo("Session notification token dropped", { reason: result.reason })))
            return Effect.logWarning("Session notification failed", { reason: result.reason })
          }),
        )
      }),
    )
    return {
      wakeAt: wakes.length > 0 ? Math.min(...wakes) : undefined,
      deliver: Effect.all(jobs, { concurrency: "unbounded", discard: true }),
    }
  })

  return { evaluate, families }
}

export type Notifier = ReturnType<typeof makeNotifier>

/** The APNs alert body; `opencode` carries what the app needs to decide presentation and open the session. */
export function body(watch: Watch & { readonly outcome: "succeeded" | "failed" }, serverKey: string) {
  return {
    aps: {
      alert: {
        title: watch.ref.title,
        body: `${watch.outcome === "failed" ? "Terminou com erro" : "Terminou"} · ${watch.ref.project}`,
      },
      sound: "default",
      "thread-id": watch.ref.sessionID,
    },
    opencode: {
      kind: "session.finished",
      serverKey,
      sessionID: watch.ref.sessionID,
      directory: watch.ref.directory,
      outcome: watch.outcome,
    },
  }
}

function push(device: Device, watch: Watch & { readonly outcome: "succeeded" | "failed" }, now: number): Push {
  return {
    token: device.token,
    environment: device.environment,
    priority: 10,
    expiration: Math.floor((now + limits.expirationMs) / 1000),
    type: "alert",
    body: body(watch, device.serverKey),
  }
}
