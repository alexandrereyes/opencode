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
  /** While something works. Parked (nothing working), there is no heartbeat (rev. 2026-11-08). */
  heartbeatMs: 10 * 60_000,
  staleMs: 15 * 60_000,
  /**
   * The `stale-date` of a parked state (nothing working, rev. 2026-11-08): the whole life of an activity, so the calm
   * card never turns stale while iOS keeps it, without routine pushes to refresh it.
   */
  parkedStaleMs: 8 * 3_600_000,
  /** ActivityKit ends a Live Activity 8 hours after it starts: past this since its registration, it is gone. */
  lifeMs: 8 * 3_600_000,
  /** The same limit, a little earlier, for reports and refused tokens, as clocks and reports drift. */
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
    /** Past `lifeMs`, ActivityKit has ended the activity: push-to-start may start a new one while work goes on. */
    expire: (deviceID: string, activityID: string, now: number) =>
      edit(now, deviceID, (device) => {
        if (device.activity?.activityID !== activityID) return device
        const { activity: _, ...rest } = device
        return { ...rest, expired: activityID, rearm: true }
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
     * Drops a token APNs reported invalid: the push-to-start token, or the activity it updates. An activity token dies
     * with its activity. Near its 8 hours, ActivityKit ended it: push-to-start is rearmed for work still going. Earlier
     * (rev. 2026-11-08: an activity no longer ends when work stops, and the app reports its own ends), the user
     * dismissed it while the app was not running: like a reported swipe, no push-to-start until `activeTotal` returns
     * to 0 and rises again.
     */
    drop: (deviceID: string, token: string, now: number) =>
      edit(now, deviceID, (device) => {
        const { activity, pushToStartToken, ...rest } = device
        const lost = activity !== undefined && activity.pushToken === token
        const expired = lost && now - activity.registeredAt >= limits.activityMs
        return {
          ...rest,
          ...(pushToStartToken && pushToStartToken !== token ? { pushToStartToken } : {}),
          ...(activity && !lost ? { activity } : {}),
          ...(expired ? { expired: activity.activityID, rearm: true } : {}),
          ...(lost && !expired ? { dismissed: true } : {}),
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
  /** `parked`: the last push carried a parked state, with its long `stale-date`. */
  const activities = new Map<
    string,
    { lastPushAt: number; sent: string; marks: ReadonlySet<string>; parked: boolean }
  >()
  // Push-to-start needs a rise of activeTotal from 0 observed after the device's last start push or activity.
  const seen = { zeroAt: -Infinity, activity: new Map<string, number>(), retry: new Set<string>() }

  const evaluate = Effect.fn("LiveActivity.evaluate")(function* (derived: Derived, now: number) {
    const state = derived.state
    // Nothing works (rev. 2026-11-08): the activity stays, parked, with no heartbeat and no routine update.
    const parked = isParked(state)
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
    for (const listed of yield* input.registry.list(now)) {
      let device = listed
      // ActivityKit has ended it (8 hours): a new one may start at once while work goes on.
      if (device.activity && now - device.activity.registeredAt >= limits.lifeMs) {
        const { activity: gone, ...rest } = device
        yield* input.registry.expire(device.deviceID, gone.activityID, now)
        activities.delete(gone.activityID)
        device = { ...rest, expired: gone.activityID, rearm: true }
      }
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
              alert: { title: "MyAgents", body: summary(state) },
            }),
            (result) => (result.status === "failed" ? Effect.sync(() => seen.retry.add(device.deviceID)) : Effect.void),
          ),
        )
        continue
      }
      // An activity that covered active work spends that rise; one that ended while calm leaves the device armed.
      if (state.activeTotal > 0) seen.activity.set(device.deviceID, now)
      wakes.push(activity.registeredAt + limits.lifeMs)
      const memo = activities.get(activity.activityID) ?? {
        lastPushAt: activity.registeredAt,
        sent: "",
        marks,
        parked: false,
      }
      activities.set(activity.activityID, memo)
      const since = now - memo.lastPushAt
      const added = [...marks].filter((mark) => !memo.marks.has(mark))
      const urgent = added.length > 0 || [...memo.marks].some((mark) => !marks.has(mark))
      // Parked, one push carries the parked state (its long stale-date); after it, only what needs Alexandre.
      const due = parked
        ? urgent || (!memo.parked && since >= limits.coalesceMs)
        : urgent || (key !== memo.sent && since >= limits.coalesceMs) || since >= limits.heartbeatMs
      if (!due) {
        if (!parked) wakes.push(memo.lastPushAt + (key === memo.sent ? limits.heartbeatMs : limits.coalesceMs))
        else if (!memo.parked) wakes.push(memo.lastPushAt + limits.coalesceMs)
        continue
      }
      memo.lastPushAt = now
      memo.sent = key
      memo.marks = marks
      memo.parked = parked
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
                  memo.parked = false
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
  readonly event: "start" | "update"
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
      // Orders this app's activities (one per server) by importance; below voice (100) and dictation (75).
      "relevance-score": relevance(input.state),
      "content-state": input.state,
      "stale-date": timestamp + (isParked(input.state) ? limits.parkedStaleMs : limits.staleMs) / 1000,
      ...(input.attributes ? { "attributes-type": "AgentsActivityAttributes", attributes: input.attributes } : {}),
      ...(input.alert ? { alert: input.alert } : {}),
      ...(input.event === "start" ? { "input-push-token": 1 } : {}),
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

/**
 * The activity's `relevance-score` (rev. 2026-11-10): iOS shows the highest first on the Lock Screen and in the
 * Dynamic Island, so with one activity per server the one that needs Alexandre comes first. The same scale on every
 * server, from the state the card shows; the app computes it the same way (`OpenCodeKit.AgentsState.relevance`).
 */
export const relevanceScores = { attention: 70, unread: 60, working: 50, idle: 40 } as const

export function relevance(state: LiveActivity.AgentsState) {
  const counts = state.counts
  if (counts.question + counts.permission + (counts.browser ?? 0) + counts.failed > 0) return relevanceScores.attention
  if ((counts.unread ?? 0) > 0) return relevanceScores.unread
  if (counts.working > 0) return relevanceScores.working
  return relevanceScores.idle
}

/** Nothing works: the activity shows the calm state until iOS ends it or the user dismisses it (rev. 2026-11-08). */
export function isParked(state: LiveActivity.AgentsState) {
  return state.counts.working === 0
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
