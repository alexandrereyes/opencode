import { expect } from "bun:test"
import { Effect, Queue, Schema, Stream } from "effect"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { Push, Result } from "../src/live-activity/apns"
import { makeHub, type Member } from "../src/live-activity/index"
import { makeTracker, type Event } from "../src/live-activity/tracker"
import { devicesKey, limits, makeNotificationRegistry, makeNotifier } from "../src/notifications/index"
import type { Notifications } from "../src/notifications/rpc"
import {
  T,
  created,
  execution,
  ids,
  interrupted,
  minute,
  permission,
  question,
  session,
  shellExited,
  shellNotice,
  shellStarted,
  world,
} from "./fixture/live-activity"

const host = "MacBook Pro"

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

const iphone: Notifications.RegisterInput = {
  deviceID: "iphone-17",
  serverKey: "mac-principal",
  environment: "production",
  token: "aa11",
}

/** A tracker and notifier over an in-memory server; `step` applies events at `at` and evaluates. */
function setup(answer: (push: Push) => Result = () => ({ status: "sent" })) {
  const server = world()
  const tracker = makeTracker(server.ctx)
  const shared = storage()
  const registry = makeNotificationRegistry(shared)
  const pushes: Push[] = []
  const notifier = makeNotifier({
    registry,
    send: (push) =>
      Effect.sync(() => {
        pushes.push(push)
        return answer(push)
      }),
  })
  const step = (at: number, ...events: Event[]) =>
    Effect.gen(function* () {
      for (const event of events) yield* tracker.apply(event, at)
      const plan = yield* notifier.evaluate(tracker.derive(at, host), at)
      yield* plan.deliver
      return plan.wakeAt
    })
  const watch = (id: string) =>
    Effect.gen(function* () {
      server.watched.add(id)
      yield* tracker.apply({ type: "preferences.updated" }, T)
    })
  return { server, tracker, shared, registry, pushes, step, watch, notifier }
}

const bodyOf = (push: Push | undefined) =>
  push?.body as {
    aps: { alert: { title: string; body: string }; "thread-id": string; "interruption-level": string }
    opencode: {
      kind: string
      serverKey: string
      sessionID: string
      directory: string
      attention?: string
      requestID?: string
      outcome?: string
    }
  }

/** Runs and ends a watched root: `started` at T, its end at T + 1 min, then evaluations through the grace period. */
const finish = (outcome: "succeeded" | "failed" | "interrupted") =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.registry.register({ ...iphone, deviceID: "ipad", token: "bb22", environment: "sandbox" }, T)
    yield* f.watch(ids.live)
    yield* f.step(T, created(ids.live, T - minute), execution("started", ids.live, T))
    const end = T + minute
    const wake = yield* f.step(end, outcome === "interrupted" ? interrupted(ids.live, end) : execution(outcome, ids.live, end))
    expect(wake).toBe(end + limits.graceMs)
    expect(f.pushes).toEqual([])
    yield* f.step(end + limits.graceMs)
    return f.pushes
  })

it.effect("a watched session that ends successfully alerts every device once, with title, body and thread", () =>
  Effect.gen(function* () {
    const pushes = yield* finish("succeeded")
    expect(pushes.map((push) => [push.token, push.environment, push.type, push.priority])).toEqual([
      ["aa11", "production", "alert", 10],
      ["bb22", "sandbox", "alert", 10],
    ])
    expect(pushes[0]?.expiration).toBe(Math.floor((T + minute + limits.graceMs + limits.expirationMs) / 1000))
    expect(pushes[0]?.body).toEqual({
      aps: {
        alert: { title: "Live Activity no iOS", body: "Terminou · ios-custom" },
        sound: "default",
        "thread-id": ids.live,
        "interruption-level": "active",
      },
      opencode: {
        kind: "session.finished",
        serverKey: "mac-principal",
        sessionID: ids.live,
        directory: "/Users/alexandremartins/Worktrees/opencode2-live-activity",
        outcome: "succeeded",
      },
    })
  }),
)

it.effect("a failed run alerts with the bell or without it, collapsed per session; an interruption alerts nothing", () =>
  Effect.gen(function* () {
    const failed = yield* finish("failed")
    expect(failed.map((push) => [push.token, push.collapseID, bodyOf(push).aps.alert.body])).toEqual([
      ["aa11", `attention:${ids.live}`, "Parou com erro · ios-custom"],
      ["bb22", `attention:${ids.live}`, "Parou com erro · ios-custom"],
    ])
    expect(bodyOf(failed[0]).opencode).toEqual({
      kind: "session.attention",
      serverKey: "mac-principal",
      sessionID: ids.live,
      directory: "/Users/alexandremartins/Worktrees/opencode2-live-activity",
      attention: "failed",
    })
    expect(bodyOf(failed[0]).aps["interruption-level"]).toBe("active")
    expect(yield* finish("interrupted")).toEqual([])
    // Without the bell: the failure still alerts, a success does not.
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.step(T, created(ids.nav, T - minute), created(ids.cache, T - minute))
    yield* f.step(T + 1, execution("started", ids.nav, T + 1), execution("started", ids.cache, T + 1))
    yield* f.step(T + minute, execution("failed", ids.nav, T + minute), execution("succeeded", ids.cache, T + minute))
    yield* f.step(T + minute + limits.graceMs)
    expect(f.pushes.map((push) => [bodyOf(push).opencode.sessionID, bodyOf(push).opencode.attention])).toEqual([
      [ids.nav, "failed"],
    ])
  }),
)

it.effect("provider retries keep the run going: no alert until it really stops with an error, none if it recovers", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.step(T, created(ids.nav, T - minute), created(ids.cache, T - minute))
    yield* f.step(T + 1, execution("started", ids.nav, T + 1), execution("started", ids.cache, T + 1))
    // `session.retry.scheduled` leaves both executions running through the backoff (about 84 s for ten retries).
    for (const at of [10_000, 30_000, 60_000, 84_000]) yield* f.step(T + at)
    expect(f.pushes).toEqual([])
    yield* f.step(T + 90_000, execution("succeeded", ids.cache, T + 90_000), execution("failed", ids.nav, T + 90_000))
    yield* f.step(T + 90_000 + limits.graceMs)
    expect(f.pushes.map((push) => bodyOf(push).opencode.sessionID)).toEqual([ids.nav])
  }),
)

it.effect("a question alerts once at once, from any top-level session or its subagent; titled with the session", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.step(T, created(ids.cache, T - minute), created("ses_child_q", T - 1, ids.cache))
    const form = question("frm_1", "ses_child_q", T + 1, "Qual banco usar no cache?")
    f.server.forms.push(form)
    yield* f.step(T + 1, { type: "form.created", data: { form } })
    expect(f.pushes.map((push) => [push.collapseID, bodyOf(push).aps.alert, bodyOf(push).opencode])).toEqual([
      [
        `attention:${ids.cache}`,
        { title: "Escolher banco do cache", body: "Pergunta: Qual banco usar no cache?" },
        {
          kind: "session.attention",
          serverKey: "mac-principal",
          sessionID: ids.cache,
          directory: "/Users/alexandremartins/Dev/opencode2",
          attention: "question",
          requestID: "frm_1",
        },
      ],
    ])
    yield* f.step(T + minute)
    yield* f.step(T + 2 * minute, { type: "form.created", data: { form } })
    expect(f.pushes).toHaveLength(1)
    // Answered, it is forgotten; a new question alerts again.
    f.server.forms.length = 0
    yield* f.step(T + 3 * minute, { type: "form.replied", data: { id: "frm_1" } })
    const next = question("frm_2", ids.cache, T + 4 * minute, "E o TTL?")
    f.server.forms.push(next)
    yield* f.step(T + 4 * minute, { type: "form.created", data: { form: next } })
    expect(f.pushes.map((push) => bodyOf(push).opencode.requestID)).toEqual(["frm_1", "frm_2"])
  }),
)

it.effect("a permission alerts only if still pending after 3 s and auto-approval is off", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.step(T, created(ids.oauth, T - minute))
    const quick = permission("per_quick", ids.oauth, T + 1, "bash", ["ls"])
    f.server.permissions.push(quick)
    expect(yield* f.step(T + 1, { type: "permission.asked", data: quick })).toBe(T + 1 + limits.permissionMs)
    // Answered within the window: nothing.
    f.server.permissions.length = 0
    yield* f.step(T + 2_000, { type: "permission.replied", data: { requestID: "per_quick" } })
    yield* f.step(T + 5_000)
    expect(f.pushes).toEqual([])
    const slow = permission("per_slow", ids.oauth, T + 10_000, "bash", ["bun test --filter oauth"])
    f.server.permissions.push(slow)
    yield* f.step(T + 10_000, { type: "permission.asked", data: slow })
    yield* f.step(T + 12_000)
    expect(f.pushes).toEqual([])
    yield* f.step(T + 13_000)
    expect(f.pushes.map((push) => bodyOf(push).aps.alert.body)).toEqual(["Permissão: bash · bun test --filter oauth"])
    expect(bodyOf(f.pushes[0]).opencode).toMatchObject({ attention: "permission", requestID: "per_slow" })
    // With auto-approval on, nothing, however long it waits.
    f.server.settings.autoApprove = true
    const auto = permission("per_auto", ids.oauth, T + 20_000, "edit", ["a.ts"])
    f.server.permissions.push(auto)
    yield* f.step(T + 20_000, { type: "preferences.updated" }, { type: "permission.asked", data: auto })
    yield* f.step(T + minute)
    expect(f.pushes).toHaveLength(1)
  }),
)

it.effect("after a restart, requests already pending and runs already over do not alert again", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    f.server.add(session(ids.cache, { time: { created: T - 3_600_000, updated: T - minute } }))
    f.server.active.add(ids.cache)
    f.server.forms.push(question("frm_old", ids.cache, T - minute, "Já perguntada"))
    yield* f.tracker.rebuild(T)
    yield* f.step(T)
    yield* f.step(T + minute)
    expect(f.pushes).toEqual([])
    expect([...f.notifier.requests]).toEqual(["frm_old"])
    // Work this process sees still counts.
    yield* f.step(T + 2 * minute, execution("failed", ids.cache, T + 2 * minute))
    yield* f.step(T + 2 * minute + limits.graceMs)
    expect(f.pushes.map((push) => bodyOf(push).opencode.attention)).toEqual(["failed"])
  }),
)

it.effect("a run that starts and fails between two evaluations still alerts once", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.watch(ids.nav)
    yield* f.step(T, created(ids.nav, T - minute))
    // A model that cannot be resolved fails at once: both events land before the hub evaluates again.
    yield* f.step(T + 1, execution("started", ids.nav, T + 1), execution("failed", ids.nav, T + 2))
    yield* f.step(T + 1 + limits.graceMs)
    expect(f.pushes.map((push) => bodyOf(push).opencode.attention)).toEqual(["failed"])
    yield* f.step(T + minute)
    expect(f.pushes).toHaveLength(1)
  }),
)

it.effect("sessions without the bell, or that never worked in this process, alert nothing", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.step(T, created(ids.nav, T - minute), execution("started", ids.nav, T))
    yield* f.step(T + minute, execution("succeeded", ids.nav, T + minute))
    yield* f.step(T + 2 * minute)
    // Turning the bell on after the end is not a finish either.
    yield* f.watch(ids.nav)
    yield* f.step(T + 3 * minute)
    yield* f.step(T + 4 * minute)
    expect(f.pushes).toEqual([])
    // Turning it on while it works, then off before the end, alerts nothing; on again, the next end alerts.
    yield* f.step(T + 5 * minute, execution("started", ids.nav, T + 5 * minute))
    f.server.watched.delete(ids.nav)
    yield* f.step(T + 6 * minute, { type: "preferences.updated" }, execution("succeeded", ids.nav, T + 6 * minute))
    yield* f.step(T + 7 * minute)
    expect(f.pushes).toEqual([])
    yield* f.watch(ids.nav)
    yield* f.step(T + 8 * minute, execution("started", ids.nav, T + 8 * minute))
    yield* f.step(T + 9 * minute, execution("succeeded", ids.nav, T + 9 * minute))
    yield* f.step(T + 10 * minute)
    expect(f.pushes).toHaveLength(1)
  }),
)

it.effect("subagents and background shells keep the family working; a wake inside the grace period is not an end", () =>
  Effect.gen(function* () {
    const f = setup()
    yield* f.registry.register(iphone, T)
    yield* f.watch(ids.live)
    const child = "ses_child_notify"
    yield* f.step(
      T,
      created(ids.live, T - minute),
      execution("started", ids.live, T),
      created(child, T + 1, ids.live),
      execution("started", child, T + 2),
      shellStarted(ids.live, "sh_1", T + 3, "bun test"),
    )
    // The root answers while its subagent and background shell still run.
    yield* f.step(T + minute, execution("succeeded", ids.live, T + minute))
    yield* f.step(T + 2 * minute)
    yield* f.step(T + 3 * minute, execution("succeeded", child, T + 3 * minute))
    yield* f.step(T + 4 * minute)
    expect(f.pushes).toEqual([])
    // The shell ends and its notice wakes the root two seconds later: still the same piece of work.
    yield* f.step(T + 5 * minute, shellExited("sh_1", T + 5 * minute))
    yield* f.step(
      T + 5 * minute + 2_000,
      shellNotice(ids.live, "sh_1", T + 5 * minute + 2_000),
      execution("started", ids.live, T + 5 * minute + 2_000),
    )
    yield* f.step(T + 5 * minute + limits.graceMs + 1)
    expect(f.pushes).toEqual([])
    yield* f.step(T + 6 * minute, execution("succeeded", ids.live, T + 6 * minute))
    yield* f.step(T + 6 * minute + limits.graceMs)
    expect(f.pushes).toHaveLength(1)
    // Nothing more until it works again.
    yield* f.step(T + 7 * minute)
    expect(f.pushes).toHaveLength(1)
  }),
)

it.effect("registrations: one token per install, more than one device, unregister, expiry and invalid tokens", () =>
  Effect.gen(function* () {
    const f = setup((push) =>
      push.token === "dead" ? { status: "invalid", reason: "Unregistered" } : { status: "failed", reason: "busy" },
    )
    yield* f.registry.register(iphone, T)
    yield* f.registry.register({ ...iphone, token: "cc33" }, T + 1)
    yield* f.registry.register({ ...iphone, deviceID: "ipad", token: "dead" }, T + 2)
    // A reinstall reports the same token under a new device ID: the old install's entry goes.
    yield* f.registry.register({ ...iphone, deviceID: "iphone-reinstalled", token: "cc33" }, T + 3)
    expect((yield* f.registry.list(T + 3)).map((device) => [device.deviceID, device.token])).toEqual([
      ["ipad", "dead"],
      ["iphone-reinstalled", "cc33"],
    ])
    yield* f.watch(ids.live)
    yield* f.step(T, created(ids.live, T - minute), execution("started", ids.live, T))
    yield* f.step(T + minute, execution("succeeded", ids.live, T + minute))
    yield* f.step(T + minute + limits.graceMs)
    expect(f.pushes.map((push) => push.token).toSorted()).toEqual(["cc33", "dead"])
    // The invalid token is dropped; a transient failure keeps its device.
    expect((yield* f.registry.list(T + 2 * minute)).map((device) => device.deviceID)).toEqual(["iphone-reinstalled"])
    yield* f.registry.unregister("iphone-reinstalled", T + 2 * minute)
    expect(f.shared.values.get(devicesKey)).toEqual([])
    yield* f.registry.register(iphone, T)
    expect(yield* f.registry.list(T + limits.forgetMs)).toEqual([])
  }),
)

const settle = Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1)))
const settled = Effect.gen(function* () {
  for (let round = 0; round < 5; round++) yield* settle
})

it.effect("the hub registers devices through custom.notifications and alerts from live events", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const server = world()
    const shared = storage()
    const queue = yield* Queue.unbounded<Event>()
    const pushes: Push[] = []
    const hub = makeHub({
      host: Effect.succeed(host),
      apns: Effect.succeed({
        send: (push: Push) => Effect.sync((): Result => (pushes.push(push), { status: "sent" })),
        close: Effect.void,
      }),
    })
    const member: Member = { ctx: { ...server.ctx, storage: shared, events: Stream.fromQueue(queue) }, emit: () => Effect.void }
    yield* hub.join(member)
    expect(yield* hub.notifications.register(iphone)).toEqual({ push: "configured" })
    server.watched.add(ids.live)
    yield* Queue.offerAll(queue, [
      { type: "preferences.updated" },
      created(ids.live, T),
      execution("started", ids.live, T),
      created(ids.nav, T),
      execution("started", ids.nav, T),
    ])
    yield* settled
    yield* TestClock.adjust(minute)
    yield* Queue.offerAll(queue, [
      execution("succeeded", ids.live, T + minute),
      execution("succeeded", ids.nav, T + minute),
    ])
    yield* settled
    expect(pushes.filter((push) => push.type === "alert")).toEqual([])
    yield* TestClock.adjust(limits.graceMs)
    yield* settled
    const alerts = pushes.filter((push) => push.type === "alert")
    expect(alerts.map((push) => [push.token, (push.body as { opencode: { sessionID: string } }).opencode.sessionID])).toEqual([
      ["aa11", ids.live],
    ])
    expect(yield* hub.notifications.unregister({ deviceID: iphone.deviceID })).toEqual({})
    expect(shared.values.get(devicesKey)).toEqual([])
  }),
)

it.effect("without APNs credentials the hub still stores registrations and reports push unconfigured", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const server = world()
    const shared = storage()
    const hub = makeHub({ host: Effect.succeed(host), apns: Effect.succeed(undefined) })
    yield* hub.join({
      ctx: { ...server.ctx, storage: shared, events: Stream.fromQueue(yield* Queue.unbounded<Event>()) },
      emit: () => Effect.void,
    })
    expect(yield* hub.notifications.register(iphone)).toEqual({ push: "unconfigured" })
    expect(shared.values.get(devicesKey)).toHaveLength(1)
  }),
)
