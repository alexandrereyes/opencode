import { Effect, Option, Schema } from "effect"
import type { Client, Push } from "../live-activity/apns.js"
import type { Storage } from "../live-activity/lifecycle.js"
import { LiveActivity } from "../live-activity/rpc.js"
import type { Derived, Root } from "../live-activity/tracker.js"
import type { Notifications } from "./rpc.js"

export const limits = {
  /** Registrations without `register` for this long are dropped. */
  forgetMs: 30 * 86_400_000,
  /**
   * A family must stay quiet this long before it counts as finished: a background shell or subagent that ends wakes
   * its parent a moment later, and that gap is not the end of the work.
   */
  graceMs: 5_000,
  /** A permission must still be pending this long: auto-approval or a quick answer settles most of them. */
  permissionMs: 3_000,
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

/** One system notification: a bell session's success, or attention any top-level session needs. */
export type Alert =
  | { readonly kind: "finished"; readonly ref: Root["ref"] }
  | { readonly kind: "failed"; readonly ref: Root["ref"] }
  | {
      readonly kind: "question" | "permission"
      readonly ref: Root["ref"]
      readonly requestID: string
      readonly text?: string
    }

/**
 * Session alerts, one per registered device:
 * - a question, at once, and a permission still pending after `permissionMs` with auto-approval off, once per
 *   request; requests already pending when this process starts count as notified;
 * - a top-level session whose family (its own execution, subagents and background shells) stopped for good after
 *   its own run failed. Provider retries keep the execution running, so only the final failure counts;
 * - with "Avisar ao terminar", the same stop after a success, when the work is newer than the bell.
 * Only work this process saw counts. A user or shutdown interruption alerts nothing.
 */
export function makeNotifier(input: { readonly registry: NotificationRegistry; readonly send: Client["send"] }) {
  const state = { primedAt: undefined as number | undefined }
  /**
   * Per top-level family: `handled`, the `workedAt` already reported (or present when first seen idle); `pending` and
   * `quietSince`, the work being confirmed as finished and since when it has been quiet.
   */
  const families = new Map<string, { handled?: number; pending?: number; quietSince?: number }>()
  /** Bell sessions → their `workedAt` when the bell was first seen: only newer work finishes "for" the bell. */
  const bells = new Map<string, number | undefined>()
  /** Requests already notified (or pending at startup), forgotten once they leave the pending list. */
  const requests = new Set<string>()

  const evaluate = Effect.fn("Notifications.evaluate")(function* (
    derived: Pick<Derived, "roots" | "pending" | "autoApprove">,
    now: number,
  ) {
    const priming = state.primedAt === undefined
    const primedAt = state.primedAt ?? now
    state.primedAt = primedAt
    for (const id of families.keys()) if (!derived.roots.has(id)) families.delete(id)
    for (const id of bells.keys()) if (!derived.roots.get(id)?.watched) bells.delete(id)
    const wakes: number[] = []
    const alerts: Alert[] = []
    for (const [id, root] of derived.roots) {
      if (root.watched && !bells.has(id)) bells.set(id, root.workedAt)
      // Work seen after startup is new even when the family is first seen idle (it started and ended in between).
      const memo =
        families.get(id) ??
        (root.working ? {} : priming || (root.workedAt ?? 0) <= primedAt ? { handled: root.workedAt } : {})
      families.set(id, memo)
      if (root.working) {
        memo.pending = undefined
        memo.quietSince = undefined
        continue
      }
      if (root.workedAt === undefined || root.workedAt === memo.handled) continue
      // Newer work than the quiet period being confirmed restarts it.
      if (memo.pending !== root.workedAt || memo.quietSince === undefined) {
        memo.pending = root.workedAt
        memo.quietSince = now
      }
      if (now - memo.quietSince < limits.graceMs) {
        wakes.push(memo.quietSince + limits.graceMs)
        continue
      }
      memo.handled = root.workedAt
      memo.pending = undefined
      memo.quietSince = undefined
      if (root.outcome === "failed") alerts.push({ kind: "failed", ref: root.ref })
      if (root.outcome === "succeeded" && root.watched && bells.get(id) !== root.workedAt)
        alerts.push({ kind: "finished", ref: root.ref })
    }
    const pending = new Set(derived.pending.map((request) => request.id))
    for (const id of requests) if (!pending.has(id)) requests.delete(id)
    for (const request of derived.pending) {
      if (requests.has(request.id)) continue
      if (priming) {
        requests.add(request.id)
        continue
      }
      if (request.kind === "permission") {
        if (derived.autoApprove) continue
        if (now - request.since < limits.permissionMs) {
          wakes.push(request.since + limits.permissionMs)
          continue
        }
      }
      requests.add(request.id)
      alerts.push({
        kind: request.kind,
        ref: request.ref,
        requestID: request.id,
        ...(request.text ? { text: request.text } : {}),
      })
    }
    const devices = alerts.length > 0 ? yield* input.registry.list(now) : []
    const jobs = alerts.flatMap((alert) =>
      devices.map((device) =>
        input.send(push(device, alert, now)).pipe(
          Effect.flatMap((result) => {
            if (result.status === "sent")
              return Effect.logInfo("Session notification sent", {
                sessionID: alert.ref.sessionID,
                kind: alert.kind,
                environment: device.environment,
              })
            if (result.status === "invalid")
              return input.registry
                .drop(device.deviceID, device.token, now)
                .pipe(Effect.andThen(Effect.logInfo("Session notification token dropped", { reason: result.reason })))
            return Effect.logWarning("Session notification failed", { reason: result.reason })
          }),
        ),
      ),
    )
    return {
      wakeAt: wakes.length > 0 ? Math.min(...wakes) : undefined,
      deliver: Effect.all(jobs, { concurrency: "unbounded", discard: true }),
    }
  })

  return { evaluate, families, requests }
}

export type Notifier = ReturnType<typeof makeNotifier>

/**
 * The APNs alert body; `opencode` carries what the app needs to decide presentation and open the session (and the
 * request). `active` lets the iPhone's Focus decide; nothing is time-sensitive.
 */
export function body(alert: Alert, serverKey: string) {
  const target = { serverKey, sessionID: alert.ref.sessionID, directory: alert.ref.directory }
  return {
    aps: {
      alert: { title: alert.ref.title, body: text(alert) },
      sound: "default",
      "thread-id": alert.ref.sessionID,
      "interruption-level": "active",
    },
    opencode:
      alert.kind === "finished"
        ? { kind: "session.finished", ...target, outcome: "succeeded" }
        : {
            kind: "session.attention",
            ...target,
            attention: alert.kind,
            ...("requestID" in alert ? { requestID: alert.requestID } : {}),
          },
  }
}

function text(alert: Alert) {
  if (alert.kind === "finished") return `Terminou · ${alert.ref.project}`
  if (alert.kind === "failed") return `Parou com erro · ${alert.ref.project}`
  if (alert.kind === "question") return `Pergunta: ${alert.text ?? "responda na sessão"}`
  return `Permissão: ${alert.text ?? "aprove ou negue na sessão"}`
}

function push(device: Device, alert: Alert, now: number): Push {
  return {
    token: device.token,
    environment: device.environment,
    priority: 10,
    expiration: Math.floor((now + limits.expirationMs) / 1000),
    type: "alert",
    // A newer request or failure of the same session replaces the older one in the Notification Center.
    ...(alert.kind === "finished" ? {} : { collapseID: `attention:${alert.ref.sessionID}` }),
    body: body(alert, device.serverKey),
  }
}
