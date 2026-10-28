import { expect, test } from "bun:test"
import { Effect, Exit, Queue, Schema, Scope, Stream } from "effect"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { Push, Result } from "../src/live-activity/apns"
import { emitMs, makeHub, sharedHub, type Member } from "../src/live-activity/index"
import { devicesKey, limits, makeLifecycle, makeRegistry } from "../src/live-activity/lifecycle"
import type { LiveActivity } from "../src/live-activity/rpc"
import type { Event, Tracker } from "../src/live-activity/tracker"
import { T, created, execution, fixture, ids, minute, question, scene, session, world } from "./fixture/live-activity"

const host = "MacBook Pro"

/** One plugin storage shared by every Location's instance, as the host's KV namespace is. */
function storage() {
  const values = new Map<string, Schema.Json>()
  return {
    values,
    get: (key: string) => Effect.sync(() => values.get(key)),
    update: <A>(key: string, update: (current: Schema.Json | undefined) => readonly [Schema.Json, A]) =>
      Effect.sync(() => {
        const [next, result] = update(values.get(key))
        values.set(key, next)
        return result
      }),
  }
}

function apns(answer: (push: Push) => Result = () => ({ status: "sent" })) {
  const pushes: Push[] = []
  return {
    pushes,
    client: {
      send: (push: Push) =>
        Effect.sync(() => {
          pushes.push(push)
          return answer(push)
        }),
      close: Effect.void,
    },
  }
}

const theme = {
  background: "#120f0eff",
  surface: "#161313ff",
  border: "#2e2e2dff",
  textStrong: "#e4e0d6ff",
  text: "#c9c5baff",
  textSecondary: "#a29f94ff",
  textWeak: "#6b6861ff",
  primary: "#da7c47ff",
  success: "#83b35fff",
  warning: "#c67f13ff",
  error: "#dc6e5eff",
  accent: "#9988e5ff",
}

const iphone: LiveActivity.RegisterInput = {
  deviceID: "iphone-17",
  serverKey: "mac-principal",
  environment: "sandbox",
  theme,
  pushToStartToken: "aa11",
}

function setup(answer?: (push: Push) => Result) {
  const shared = storage()
  const registry = makeRegistry(shared)
  const fake = apns(answer)
  const lifecycle = makeLifecycle({ registry, send: fake.client.send })
  const evaluate = (tracker: Tracker, now: number) =>
    lifecycle.evaluate(tracker.derive(now, host), now).pipe(
      Effect.tap((plan) => plan.deliver),
      Effect.map((plan) => plan.wakeAt),
    )
  return { shared, registry, pushes: fake.pushes, lifecycle, evaluate }
}

it.effect("push-to-start goes out when work appears, with the push-start.json body, at most every 5 minutes", () =>
  Effect.gen(function* () {
    const { registry, pushes, evaluate } = setup()
    yield* registry.register(iphone, T - minute)
    const working = yield* scene("working")
    const calm = yield* scene("calm")
    // Work already running when the device registers is no rise from 0.
    yield* evaluate(working, T - minute)
    expect(pushes).toHaveLength(0)
    yield* evaluate(calm, T - 30_000)
    yield* evaluate(working, T)
    expect(pushes).toHaveLength(1)
    expect(pushes[0]).toMatchObject({ token: "aa11", environment: "sandbox", priority: 10 })
    expect(pushes[0]?.body).toEqual(yield* Effect.promise(() => fixture("push-start")))
    expect(pushes[0]?.expiration).toBe(Math.floor(T / 1000) + 900)
    // Still working and no activity reported yet: no second start.
    yield* evaluate(working, T + minute)
    expect(pushes).toHaveLength(1)
    // Back to zero, then work again inside the 5-minute window: the start waits for the window.
    yield* evaluate(calm, T + 2 * minute)
    expect(yield* evaluate(working, T + 3 * minute)).toBe(T + limits.startMs)
    expect(pushes).toHaveLength(1)
    yield* evaluate(working, T + limits.startMs)
    expect(pushes.map((push) => push.body)).toHaveLength(2)
  }),
)

it.effect(
  "no push-to-start without a token, with an activity, or after a dismissal until activeTotal returns to 0",
  () =>
    Effect.gen(function* () {
      const { registry, pushes, evaluate } = setup()
      const working = yield* scene("working")
      const calm = yield* scene("calm")
      yield* registry.register({ ...iphone, pushToStartToken: null }, T)
      yield* evaluate(calm, T - minute)
      yield* evaluate(working, T)
      expect(pushes).toHaveLength(0)
      yield* registry.register(iphone, T)
      yield* registry.activity({ deviceID: iphone.deviceID, activityID: "act-1", pushToken: "bb22" }, T)
      yield* evaluate(working, T)
      expect(pushes.every((push) => push.token === "bb22")).toBe(true)
      yield* registry.ended({ deviceID: iphone.deviceID, activityID: "act-1", reason: "dismissed" }, T)
      const count = pushes.length
      yield* evaluate(working, T + 10 * minute)
      expect(pushes).toHaveLength(count)
      yield* evaluate(calm, T + 11 * minute)
      expect((yield* registry.list(T)).at(0)?.dismissed).toBe(false)
      yield* evaluate(working, T + 12 * minute)
      expect(pushes.at(-1)).toMatchObject({ token: "aa11", priority: 10 })
      expect(pushes.at(-1)?.body).toHaveProperty("aps.event", "start")
    }),
)

it.effect("attention changes push at priority 10 with push-update.json; other changes coalesce at priority 5", () =>
  Effect.gen(function* () {
    const { registry, pushes, evaluate } = setup()
    const server = world()
    const tracker = yield* scene("one-question", server)
    const asked = server.forms.splice(0)
    yield* tracker.refreshPending(T)
    yield* registry.register(iphone, T - 2 * minute)
    yield* registry.activity({ deviceID: iphone.deviceID, activityID: "act-1", pushToken: "bb22" }, T - minute)
    // First sync of a newly registered activity: a routine update.
    yield* evaluate(tracker, T - 30_000)
    expect(pushes.map((push) => push.priority)).toEqual([5])
    expect(pushes[0]?.body).not.toHaveProperty("aps.alert")
    server.forms.push(...asked)
    yield* tracker.refreshPending(T)
    yield* evaluate(tracker, T)
    expect(pushes.map((push) => push.priority)).toEqual([5, 10])
    expect(pushes[1]?.body).toEqual(yield* Effect.promise(() => fixture("push-update")))
    // A routine change right after waits for the 10-second slot.
    yield* tracker.apply({ type: "session.text.started", created: T + 1000, data: { sessionID: ids.live } }, T + 1000)
    expect(yield* evaluate(tracker, T + 1000)).toBe(T + limits.coalesceMs)
    expect(pushes).toHaveLength(2)
    yield* evaluate(tracker, T + limits.coalesceMs)
    expect(pushes.map((push) => push.priority)).toEqual([5, 10, 5])
    // Answering the question is a removal: immediate, without an alert.
    server.forms.splice(0)
    yield* tracker.refreshPending(T + 11_000)
    yield* evaluate(tracker, T + 11_000)
    expect(pushes.map((push) => push.priority)).toEqual([5, 10, 5, 10])
    expect(pushes[3]?.body).not.toHaveProperty("aps.alert")
    // Nothing changes: a heartbeat 10 minutes after the last push, always with a fresh stale-date.
    expect(yield* evaluate(tracker, T + 12_000)).toBe(T + 11_000 + limits.heartbeatMs)
    yield* evaluate(tracker, T + 11_000 + limits.heartbeatMs)
    expect(pushes.map((push) => push.priority)).toEqual([5, 10, 5, 10, 5])
    const timestamp = Math.floor((T + 11_000 + limits.heartbeatMs) / 1000)
    expect(pushes[4]?.body).toHaveProperty("aps.timestamp", timestamp)
    expect(pushes[4]?.body).toHaveProperty(["aps", "stale-date"], timestamp + 900)
  }),
)

it.effect("a new failed session alerts; the end comes after 10 calm minutes with push-end.json", () =>
  Effect.gen(function* () {
    const { registry, pushes, evaluate } = setup()
    const tracker = yield* scene("working")
    yield* registry.register(iphone, T - 2 * minute)
    yield* registry.activity({ deviceID: iphone.deviceID, activityID: "act-1", pushToken: "bb22" }, T - minute)
    yield* evaluate(tracker, T - 30_000)
    yield* tracker.apply(execution("failed", ids.deploy, T), T)
    yield* evaluate(tracker, T)
    expect(pushes.at(-1)).toMatchObject({ priority: 10 })
    expect(pushes.at(-1)?.body).toHaveProperty("aps.alert", {
      title: "Sessão parou com erro",
      body: "Deploy no Swarm · core-infra",
    })
    const { registry: endRegistry, pushes: endPushes, evaluate: endEvaluate } = setup()
    const calm = yield* scene("calm")
    yield* endRegistry.register(iphone, T - 2 * minute)
    yield* endRegistry.activity({ deviceID: iphone.deviceID, activityID: "act-2", pushToken: "cc33" }, T - minute)
    yield* endEvaluate(calm, T)
    expect(yield* endEvaluate(calm, T + minute)).toBe(T + limits.endMs)
    const before = endPushes.length
    yield* endEvaluate(calm, T + limits.endMs)
    expect(endPushes).toHaveLength(before + 1)
    expect(endPushes.at(-1)).toMatchObject({ token: "cc33", priority: 10 })
    expect(endPushes.at(-1)?.body).toEqual(yield* Effect.promise(() => fixture("push-end")))
    expect((yield* endRegistry.list(T)).at(0)?.activity).toBeUndefined()
    // The ended card leaves the screen at once, so the next push-to-start never sits next to it.
    const ended = Math.floor((T + limits.endMs) / 1000)
    expect(endPushes.at(-1)?.body).toHaveProperty(["aps", "dismissal-date"], ended)
    yield* endEvaluate(yield* scene("working"), T + limits.endMs + minute)
    expect(endPushes.at(-1)).toMatchObject({ token: "aa11", priority: 10 })
    expect(endPushes.at(-1)?.body).toHaveProperty("aps.event", "start")
  }),
)

it.effect("APNs invalid tokens are dropped; other failures retry on the next slot", () =>
  Effect.gen(function* () {
    const failing = setup((push) =>
      push.token === "bb22" ? { status: "invalid", reason: "Unregistered" } : { status: "sent" },
    )
    const working = yield* scene("working")
    yield* failing.registry.register(iphone, T)
    yield* failing.registry.activity({ deviceID: iphone.deviceID, activityID: "act-1", pushToken: "bb22" }, T)
    yield* failing.evaluate(working, T + limits.coalesceMs)
    expect((yield* failing.registry.list(T)).at(0)).toMatchObject({ pushToStartToken: "aa11" })
    expect((yield* failing.registry.list(T)).at(0)?.activity).toBeUndefined()

    const start = setup(() => ({ status: "invalid", reason: "BadDeviceToken" }))
    yield* start.registry.register(iphone, T)
    yield* start.evaluate(yield* scene("calm"), T - minute)
    yield* start.evaluate(working, T)
    expect((yield* start.registry.list(T)).at(0)?.pushToStartToken).toBeUndefined()

    const answers: Result[] = [{ status: "failed", reason: "TooManyRequests" }, { status: "sent" }]
    const retry = setup(() => answers.shift() ?? { status: "sent" })
    yield* retry.registry.register(iphone, T)
    yield* retry.registry.activity({ deviceID: iphone.deviceID, activityID: "act-1", pushToken: "bb22" }, T)
    yield* retry.evaluate(working, T + limits.coalesceMs)
    expect(yield* retry.evaluate(working, T + limits.coalesceMs + 1)).toBe(T + 2 * limits.coalesceMs)
    yield* retry.evaluate(working, T + 2 * limits.coalesceMs)
    expect(retry.pushes).toHaveLength(2)
    expect((yield* retry.registry.list(T)).at(0)?.activity?.pushToken).toBe("bb22")
  }),
)

it.effect("registrations: idempotent register, stale duplicates ignored, unregister and 30-day expiry", () =>
  Effect.gen(function* () {
    const shared = storage()
    const registry = makeRegistry(shared)
    yield* registry.register(iphone, T)
    yield* registry.activity({ deviceID: iphone.deviceID, activityID: "act-2", pushToken: "bb22" }, T)
    yield* registry.register({ ...iphone, pushToStartToken: "dd44" }, T + minute)
    expect(yield* registry.list(T + minute)).toEqual([
      {
        ...iphone,
        pushToStartToken: "dd44",
        registeredAt: T + minute,
        dismissed: false,
        activity: { activityID: "act-2", pushToken: "bb22", registeredAt: T },
      },
    ])
    yield* registry.ended({ deviceID: iphone.deviceID, activityID: "act-1", reason: "dismissed" }, T + minute)
    expect((yield* registry.list(T + minute)).at(0)).toMatchObject({
      dismissed: false,
      activity: { activityID: "act-2" },
    })
    yield* registry.register({ ...iphone, deviceID: "ipad" }, T + minute)
    yield* registry.unregister("ipad", T + minute)
    expect((yield* registry.list(T + minute)).map((device) => device.deviceID)).toEqual([iphone.deviceID])
    expect(yield* registry.list(T + minute + limits.forgetMs)).toEqual([])
    yield* registry.register({ ...iphone, deviceID: "ipad" }, T + minute + limits.forgetMs)
    expect(shared.values.get(devicesKey)).toHaveLength(1)
  }),
)

const settle = Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1)))
const settled = Effect.gen(function* () {
  for (let round = 0; round < 5; round++) yield* settle
})

function member(server: ReturnType<typeof world>, shared: ReturnType<typeof storage>, queue: Queue.Queue<Event>) {
  const emitted: (LiveActivity.AgentsState | null)[] = []
  const value: Member = {
    ctx: { ...server.ctx, storage: shared, events: Stream.fromQueue(queue) },
    emit: (state) => Effect.sync(() => void emitted.push(state)),
  }
  return { value, emitted }
}

it.effect("unconfigured hub stores registrations, answers snapshot and emits changed without pushing", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const server = world()
    const shared = storage()
    const queue = yield* Queue.unbounded<Event>()
    const hub = makeHub({ host: Effect.succeed(host), apns: Effect.succeed(undefined) })
    const node = member(server, shared, queue)
    yield* hub.join(node.value)
    expect(yield* hub.handlers.register(iphone)).toEqual({ push: "unconfigured" })
    expect(yield* hub.handlers.activity({ deviceID: iphone.deviceID, activityID: "a", pushToken: "bb22" })).toEqual({})
    expect(shared.values.get(devicesKey)).toHaveLength(1)
    expect(yield* hub.handlers.snapshot()).toEqual({ state: null })
    yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
    yield* settled
    const snapshot = yield* hub.handlers.snapshot()
    expect(snapshot.state).toMatchObject({ host, activeTotal: 1, focus: { sessionID: ids.live } })
    expect(node.emitted).toEqual([snapshot.state])
    expect(yield* hub.handlers.ended({ deviceID: iphone.deviceID, activityID: "a", reason: "ended" })).toEqual({})
    expect(yield* hub.handlers.unregister({ deviceID: iphone.deviceID })).toEqual({})
    expect(shared.values.get(devicesKey)).toEqual([])
  }),
)

it.effect(
  "one aggregator for every member: changed once per change, at most once a second, from a remaining member",
  () =>
    Effect.gen(function* () {
      yield* TestClock.setTime(T)
      const server = world()
      const shared = storage()
      const queue = yield* Queue.unbounded<Event>()
      const fake = apns()
      const hub = makeHub({ host: Effect.succeed(host), apns: Effect.succeed(fake.client) })
      const first = member(server, shared, queue)
      const second = member(server, shared, queue)
      const firstScope = yield* Scope.make()
      const secondScope = yield* Scope.make()
      yield* hub.join(first.value).pipe(Scope.provide(firstScope))
      yield* hub.join(second.value).pipe(Scope.provide(secondScope))
      expect(yield* hub.handlers.register(iphone)).toEqual({ push: "configured" })
      yield* Queue.offerAll(queue, [created(ids.live, T), execution("started", ids.live, T)])
      yield* settled
      expect(first.emitted.map((state) => state?.activeTotal)).toEqual([1])
      expect(second.emitted).toEqual([])
      // The single sender pushed one start for the device.
      expect(fake.pushes.map((push) => push.token)).toEqual(["aa11"])
      // A second change inside the same second waits for the next slot.
      yield* Queue.offerAll(queue, [created(ids.cache, T), execution("started", ids.cache, T)])
      yield* settled
      expect(first.emitted).toHaveLength(1)
      yield* TestClock.adjust(emitMs)
      yield* settled
      expect(first.emitted.map((state) => state?.activeTotal)).toEqual([1, 2])
      // The first member leaves; the same aggregator keeps its state and emits through the second.
      yield* Scope.close(firstScope, Exit.void)
      yield* Queue.offer(queue, execution("succeeded", ids.cache, T + emitMs))
      yield* settled
      yield* TestClock.adjust(emitMs)
      yield* settled
      expect(first.emitted).toHaveLength(2)
      expect(second.emitted.map((state) => state?.counts)).toEqual([
        { working: 1, question: 0, permission: 0, failed: 0, idle: 1, unread: 1 },
      ])
      expect(hub.runtime.current).toBeDefined()
      yield* Scope.close(secondScope, Exit.void)
      expect(hub.runtime.current).toBeUndefined()
      expect(hub.members).toEqual([])
    }),
)

it.effect("a starting hub rebuilds running sessions and pending requests before answering", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const server = world()
    server.add(session(ids.live, { time: { created: T - 3_600_000, updated: T - minute } }))
    server.active.add(ids.live)
    server.prompts.set(ids.live, T - 5 * minute)
    server.add(session(ids.cache, { time: { created: T - 3_600_000, updated: T - minute } }))
    server.active.add(ids.cache)
    server.forms.push(question("frm_1", ids.cache, T - 2 * minute, "Qual banco usar no cache?"))
    const hub = makeHub({ host: Effect.succeed(host), apns: Effect.succeed(undefined) })
    yield* hub.join(member(server, storage(), yield* Queue.unbounded<Event>()).value)
    const state = (yield* hub.handlers.snapshot()).state
    expect(state?.counts).toEqual({ working: 1, question: 1, permission: 0, failed: 0, idle: 0, unread: 0 })
    expect(state?.focus).toMatchObject({ sessionID: ids.live, startedAt: T - 5 * minute })
    expect(state?.attention[0]).toMatchObject({ sessionID: ids.cache, text: "Qual banco usar no cache?" })
  }),
)

test("every evaluation of the plugin module, one per Location, shares one process-wide hub", async () => {
  // The plugin loader clears the module cache for each Location; a query string evaluates the module again here.
  const specifier = "../src/live-activity/index.ts"
  const other: { sharedHub: typeof sharedHub } = await import(`${specifier}?location=second`)
  try {
    expect(other.sharedHub).not.toBe(sharedHub)
    expect(other.sharedHub()).toBe(sharedHub())
  } finally {
    globalThis.opencodeCustomLiveActivityHub = undefined
  }
})
