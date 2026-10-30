import type { Context } from "../context.js"
import { optional } from "@opencode/schema/schema"
import { Effect, Option, Schema } from "effect"
import type { Client, Push, Result } from "./apns.js"
import { LiveActivity } from "./rpc.js"
import { clip, type Derived } from "./tracker.js"

export const limits = {
  /** Registrations without `register` for this long are dropped. */
  forgetMs: 30 * 86_400_000,
  startMs: 5 * 60_000,
  coalesceMs: 10_000,
  heartbeatMs: 10 * 60_000,
  /** `activeTotal` and `counts.failed` must stay 0 this long before the activity ends. */
  endMs: 10 * 60_000,
  staleMs: 15 * 60_000,
  /** ActivityKit ends a Live Activity after 8 hours; a little earlier counts, as clocks and reports drift. */
  activityMs: 8 * 3_600_000 - 15 * 60_000,
  bodyBytes: 4096,
}

export const devicesKey = "live-activity:devices"

const Device = Schema.Struct({
  deviceID: Schema.String,
  serverKey: Schema.String,
  environment: LiveActivity.Environment,
  theme: Schema.Record(Schema.String, Schema.String),
  pushToStartToken: optional(Schema.String),
  registeredAt: Schema.Number,
  /** The user dismissed the last activity; no push-to-start until `activeTotal` returns to 0. */
  dismissed: Schema.Boolean,
  startPushedAt: optional(Schema.Number),
  /** `registeredAt` is when this server first heard of the activity, kept across token re-reports. */
  activity: optional(
    Schema.Struct({ activityID: Schema.String, pushToken: Schema.String, registeredAt: Schema.Number }),
  ),
  /** The activity whose token APNs refused (it expired): clearing its card later is no dismissal. */
  expired: optional(Schema.String),
  /** The last activity ended without the user refusing it: push-to-start may start a new one while work goes on. */
  rearm: optional(Schema.Boolean),
})
export type Device = typeof Device.Type
const Devices = Schema.Array(Device)
const decodeDevices = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Devices)(value ?? []), () => [])
const encodeDevices = Schema.encodeSync(Devices)

export type Storage = Pick<Context["storage"], "get" | "update">

/** Device registrations, kept in plugin storage so every Location's instance shares them. */
export function makeRegistry(storage: Storage) {
  const change = (now: number, update: (devices: readonly Device[]) => readonly Device[]) =>
    storage.update(devicesKey, (current) => [
      encodeDevices(update(decodeDevices(current).filter((device) => now - device.registeredAt < limits.forgetMs))),
      undefined,
    ])
  const edit = (now: number, deviceID: string, update: (device: Device) => Device | undefined) =>
    change(now, (devices) =>
      devices.flatMap((device) => {
        if (device.deviceID !== deviceID) return [device]
        const next = update(device)
        return next ? [next] : []
      }),
    )

  return {
    list: (now: number) =>
      storage
        .get(devicesKey)
        .pipe(
          Effect.map((value) => decodeDevices(value).filter((device) => now - device.registeredAt < limits.forgetMs)),
        ),
    register: (input: LiveActivity.RegisterInput, now: number) =>
      change(now, (devices) => {
        const previous = devices.find((device) => device.deviceID === input.deviceID)
        return [
          ...devices.filter((device) => device.deviceID !== input.deviceID),
          {
            deviceID: input.deviceID,
            serverKey: input.serverKey,
            environment: input.environment,
            theme: input.theme,
            ...(input.pushToStartToken ? { pushToStartToken: input.pushToStartToken } : {}),
            registeredAt: now,
            dismissed: previous?.dismissed ?? false,
            ...(previous?.startPushedAt === undefined ? {} : { startPushedAt: previous.startPushedAt }),
            ...(previous?.activity ? { activity: previous.activity } : {}),
          },
        ]
      }),
    activity: (input: LiveActivity.ActivityInput, now: number) =>
      edit(now, input.deviceID, (device) => ({
        ...device,
        activity: {
          activityID: input.activityID,
          pushToken: input.pushToken,
          registeredAt: device.activity?.activityID === input.activityID ? device.activity.registeredAt : now,
        },
      })),
    ended: (input: LiveActivity.EndedInput, now: number) =>
      edit(now, input.deviceID, (device) => {
        // A duplicate the app ended while a newer activity stays registered changes nothing.
        if (device.activity && device.activity.activityID !== input.activityID) return device
        // After 8 hours ActivityKit ends the activity itself; the card the user then clears reports "dismissed"
        // too, but that is no refusal of new activities.
        const expired =
          device.expired === input.activityID ||
          (device.activity !== undefined && now - device.activity.registeredAt >= limits.activityMs)
        const refused = input.reason === "dismissed" && !expired
        const { activity: _, expired: __, rearm: ___, ...rest } = device
        return { ...rest, dismissed: device.dismissed || refused, ...(refused ? {} : { rearm: true }) }
      }),
    unregister: (deviceID: string, now: number) => edit(now, deviceID, () => undefined),
    started: (deviceID: string, now: number) =>
      edit(now, deviceID, (device) => {
        const { rearm: _, ...rest } = device
        return { ...rest, startPushedAt: now }
      }),
    rearm: (now: number) =>
      change(now, (devices) =>
        devices.some((device) => device.dismissed)
          ? devices.map((device) => ({ ...device, dismissed: false }))
          : devices,
      ),
    /**
     * Drops a token APNs reported invalid: the push-to-start token, or the activity it updates. An activity token
     * dies with its activity (ActivityKit ends one after 8 hours), so push-to-start is rearmed for work still going.
     */
    drop: (deviceID: string, token: string, now: number) =>
      edit(now, deviceID, (device) => {
        const { activity, pushToStartToken, ...rest } = device
        const lost = activity !== undefined && activity.pushToken === token
        return {
          ...rest,
          ...(pushToStartToken && pushToStartToken !== token ? { pushToStartToken } : {}),
          ...(activity && !lost ? { activity } : {}),
          ...(lost ? { expired: activity.activityID, rearm: true } : {}),
        }
      }),
  }
}

export type Registry = ReturnType<typeof makeRegistry>

/**
 * Start, update and end decisions for every registered device. `evaluate` runs whenever the state may have changed or
 * a deadline it returned passes; it returns the pushes to deliver separately so APNs never delays the caller.
 */
export function makeLifecycle(input: { readonly registry: Registry; readonly send: Client["send"] }) {
  const activities = new Map<string, { lastPushAt: number; sent: string; marks: ReadonlySet<string> }>()
  // Push-to-start needs a rise of activeTotal from 0 observed after the device's last start push or activity.
  const seen = { zeroAt: -Infinity, activity: new Map<string, number>(), retry: new Set<string>() }
  const calm = { since: undefined as number | undefined }

  const evaluate = Effect.fn("LiveActivity.evaluate")(function* (derived: Derived, now: number) {
    const state = derived.state
    const quiet = state.activeTotal === 0 && state.counts.failed === 0
    calm.since = quiet ? (calm.since ?? now) : undefined
    if (state.activeTotal === 0) {
      seen.zeroAt = now
      yield* input.registry.rearm(now)
    }
    const key = stateKey(state)
    const marks = new Set(derived.marks.keys())
    const wakes: number[] = []
    const jobs: Effect.Effect<void>[] = []
    const deliver = (
      device: Device,
      event: BodyInput["event"],
      request: Push,
      after: (result: Result) => Effect.Effect<void>,
    ) =>
      input.send(request).pipe(
        Effect.tap((result) => {
          if (result.status === "sent")
            return Effect.logInfo("Live Activity push sent", {
              event,
              priority: request.priority,
              environment: request.environment,
            })
          if (result.status === "invalid")
            return input.registry
              .drop(device.deviceID, request.token, now)
              .pipe(Effect.andThen(Effect.logInfo("Live Activity token dropped", { event, reason: result.reason })))
          return Effect.logWarning("Live Activity push failed", {
            event,
            priority: request.priority,
            reason: result.reason,
          })
        }),
        Effect.flatMap(after),
      )
    for (const device of yield* input.registry.list(now)) {
      const activity = device.activity
      if (!activity) {
        const last = device.startPushedAt ?? -Infinity
        const armed =
          seen.zeroAt > Math.max(last, seen.activity.get(device.deviceID) ?? -Infinity) ||
          seen.retry.has(device.deviceID) ||
          device.rearm === true
        if (state.activeTotal === 0 || !device.pushToStartToken || device.dismissed || !armed) continue
        if (now - last < limits.startMs) {
          wakes.push(last + limits.startMs)
          continue
        }
        seen.retry.delete(device.deviceID)
        yield* input.registry.started(device.deviceID, now)
        wakes.push(now + limits.startMs)
        jobs.push(
          deliver(
            device,
            "start",
            push(device.pushToStartToken, device.environment, 10, {
              event: "start",
              state,
              now,
              attributes: { serverKey: device.serverKey, theme: device.theme },
              alert: { title: "OpenCode", body: summary(state) },
            }),
            (result) => (result.status === "failed" ? Effect.sync(() => seen.retry.add(device.deviceID)) : Effect.void),
          ),
        )
        continue
      }
      // An activity that covered active work spends that rise; one that ended while calm leaves the device armed.
      if (state.activeTotal > 0) seen.activity.set(device.deviceID, now)
      const memo = activities.get(activity.activityID) ?? {
        lastPushAt: activity.registeredAt,
        sent: "",
        marks,
      }
      activities.set(activity.activityID, memo)
      const since = now - memo.lastPushAt
      if (quiet && calm.since !== undefined) {
        const endAt = Math.max(calm.since + limits.endMs, memo.lastPushAt + limits.coalesceMs)
        if (now < endAt) {
          wakes.push(endAt)
        } else {
          memo.lastPushAt = now
          wakes.push(now + limits.coalesceMs)
          jobs.push(
            deliver(
              device,
              "end",
              push(activity.pushToken, device.environment, 10, { event: "end", state, now }),
              (result) =>
                // Delivered or dropped, the activity is over for the backend; a failed end is retried.
                result.status === "failed"
                  ? Effect.void
                  : input.registry
                      .ended({ deviceID: device.deviceID, activityID: activity.activityID, reason: "ended" }, now)
                      .pipe(Effect.andThen(Effect.sync(() => activities.delete(activity.activityID)))),
            ),
          )
          continue
        }
      }
      const added = [...marks].filter((mark) => !memo.marks.has(mark))
      const urgent = added.length > 0 || [...memo.marks].some((mark) => !marks.has(mark))
      const due = urgent || (key !== memo.sent && since >= limits.coalesceMs) || since >= limits.heartbeatMs
      if (!due) {
        wakes.push(memo.lastPushAt + (key === memo.sent ? limits.heartbeatMs : limits.coalesceMs))
        continue
      }
      memo.lastPushAt = now
      memo.sent = key
      memo.marks = marks
      wakes.push(now + limits.coalesceMs)
      jobs.push(
        deliver(
          device,
          "update",
          // Urgent but silent: the session alerts (`notifications/index.ts`) buzz once per question, permission or
          // failure, through this activity when it is live.
          push(activity.pushToken, device.environment, urgent ? 10 : 5, { event: "update", state, now }),
          (result) =>
            result.status === "failed"
              ? Effect.sync(() => {
                  memo.sent = ""
                })
              : Effect.void,
        ),
      )
    }
    return {
      wakeAt: wakes.length > 0 ? Math.min(...wakes) : undefined,
      deliver: Effect.all(jobs, { concurrency: "unbounded", discard: true }),
    }
  })

  return { evaluate, activities }
}

export type Lifecycle = ReturnType<typeof makeLifecycle>

export type BodyInput = {
  readonly event: "start" | "update" | "end"
  readonly state: LiveActivity.AgentsState
  readonly now: number
  readonly attributes?: LiveActivity.Attributes
  readonly alert?: { readonly title: string; readonly body: string }
}

/** The complete APNs body, keys in the order of the contract fixtures. Times in `aps` are epoch seconds. */
export function body(input: BodyInput) {
  const timestamp = Math.floor(input.now / 1000)
  return {
    aps: {
      timestamp,
      event: input.event,
      // Below voice (100), including push-to-start and background updates. Match OpenCodeKit.LiveActivityRelevance.
      "relevance-score": 50,
      "content-state": input.state,
      "stale-date": timestamp + limits.staleMs / 1000,
      ...(input.attributes ? { "attributes-type": "AgentsActivityAttributes", attributes: input.attributes } : {}),
      ...(input.alert ? { alert: input.alert } : {}),
      ...(input.event === "start" ? { "input-push-token": 1 } : {}),
      // An ended card leaves the screen at once, so it never lingers next to the next activity.
      ...(input.event === "end" ? { "dismissal-date": timestamp } : {}),
    },
  }
}

/** Trims the state, in the contract's order, until the whole body fits in 4096 bytes. */
export function fit(input: BodyInput) {
  const size = (state: LiveActivity.AgentsState) => Buffer.byteLength(JSON.stringify(body({ ...input, state })), "utf8")
  const titles =
    (max: number) =>
    (state: LiveActivity.AgentsState): LiveActivity.AgentsState => ({
      ...state,
      ...(state.focus ? { focus: { ...state.focus, title: clip(state.focus.title, max) } } : {}),
      attention: state.attention.map((item) => ({ ...item, title: clip(item.title, max) })),
      sessions: state.sessions.map((item) => ({ ...item, title: clip(item.title, max) })),
      ...(state.needs ? { needs: state.needs.map((item) => ({ ...item, title: clip(item.title, max) })) } : {}),
    })
  const steps: ((state: LiveActivity.AgentsState) => LiveActivity.AgentsState)[] = [
    ...input.state.attention
      .map((_, index) => (state: LiveActivity.AgentsState) => ({
        ...state,
        attention: state.attention.map((item, position) => {
          if (position !== index) return item
          const { text: _, ...rest } = item
          return rest
        }),
      }))
      .toReversed(),
    // The rows' "Agora: …" goes before any row; the focus keeps its own.
    (state: LiveActivity.AgentsState) => ({
      ...state,
      sessions: state.sessions.map((item) => {
        if (!item.progress?.current) return item
        const { current: _, ...progress } = item.progress
        return { ...item, progress }
      }),
    }),
    // The card and the island show two of them.
    (state: LiveActivity.AgentsState) => (state.needs ? { ...state, needs: state.needs.slice(0, 2) } : state),
    (state: LiveActivity.AgentsState) => ({ ...state, sessions: state.sessions.slice(0, 3) }),
    (state: LiveActivity.AgentsState) => ({ ...state, attention: state.attention.slice(0, 2) }),
    ...[48, 32, 20, 12, 6].map(titles),
  ]
  return steps.reduce((state, step) => (size(state) <= limits.bodyBytes ? state : step(state)), input.state)
}

export function push(token: string, environment: LiveActivity.Environment, priority: 5 | 10, input: BodyInput): Push {
  const payload = body({ ...input, state: fit(input) })
  return { token, environment, priority, expiration: payload.aps["stale-date"], body: payload }
}

/** Push-to-start alert text, e.g. "2 sessões trabalhando". */
export function summary(state: LiveActivity.AgentsState) {
  const part = (count: number, one: string, many: string) =>
    count === 0 ? [] : [`${count} ${count === 1 ? one : many}`]
  return [
    ...part(state.counts.working, "sessão trabalhando", "sessões trabalhando"),
    ...part(state.counts.question, "pergunta pendente", "perguntas pendentes"),
    ...part(state.counts.permission, "permissão pendente", "permissões pendentes"),
  ].join(" · ")
}

/** Identity of a state for change detection: everything but `updatedAt`. */
export function stateKey(state: LiveActivity.AgentsState) {
  return JSON.stringify({ ...state, updatedAt: 0 })
}
