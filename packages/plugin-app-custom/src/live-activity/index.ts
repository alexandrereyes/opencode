import type { Context } from "../context.js"
import { Cause, Clock, Deferred, Effect, Exit, Queue, Scope, Semaphore, Stream } from "effect"
import os from "node:os"
import { load, type Client } from "./apns.js"
import { fit, makeLifecycle, makeRegistry, stateKey, type Lifecycle, type Storage } from "./lifecycle.js"
import { marksFrom } from "../sessions/inventory.js"
import { makeNotificationRegistry, makeNotifier, type Notifier } from "../notifications/index.js"
import { Notifications } from "../notifications/rpc.js"
import { Preferences } from "../preferences/rpc.js"
import { LiveActivity } from "./rpc.js"
import { eventTypes, makeTracker, type Event, type Tracker, type TrackerContext } from "./tracker.js"

const preferencesUpdated: Event = { type: "preferences.updated" }
const tracked = <A extends { readonly type: string }>(event: A): event is Extract<A, Event> =>
  eventTypes.has(event.type)

/** `changed` is coalesced to at most one event per this interval. */
export const emitMs = 1000

/** One Location's plugin instance as the hub sees it. */
export type Member = {
  readonly ctx: TrackerContext & { readonly storage: Storage; readonly events: Stream.Stream<Event, unknown> }
  readonly emit: (state: LiveActivity.AgentsState | null) => Effect.Effect<void, unknown>
}

export type HubOptions = {
  readonly host: Effect.Effect<string>
  readonly apns: Effect.Effect<Client | undefined>
}

type Running = {
  readonly scope: Scope.Closeable
  readonly ready: Deferred.Deferred<{ readonly host: string; readonly push: LiveActivity.Push }>
  readonly signal: Queue.Queue<void>
  readonly tracker: Tracker
  readonly registry: ReturnType<typeof makeRegistry>
  readonly notifications: ReturnType<typeof makeNotificationRegistry>
}

/**
 * Every Location runs its own plugin instance in this process, and each receives every server event. The hub keeps
 * one aggregator, one `changed` emitter and one APNs sender for all of them: the first instance starts it in a
 * process-level scope, later instances only join, and the last one to leave stops it. `changed` goes out through
 * whichever instance is still attached, so a connected app receives it once.
 */
export function makeHub(options: HubOptions) {
  const members: Member[] = []
  const runtime = { current: undefined as Running | undefined }
  const lock = Semaphore.makeUnsafe(1)

  const start = Effect.fn("LiveActivity.start")(function* (member: Member) {
    const scope = yield* Scope.make()
    const running: Running = {
      scope,
      ready: yield* Deferred.make<{ readonly host: string; readonly push: LiveActivity.Push }>(),
      signal: yield* Queue.sliding<void>(1),
      tracker: makeTracker(member.ctx),
      registry: makeRegistry(member.ctx.storage),
      notifications: makeNotificationRegistry(member.ctx.storage),
    }
    runtime.current = running
    // Subscribe before rebuilding so nothing published meanwhile is lost; events wait for the rebuild.
    yield* member.ctx.events.pipe(
      Stream.runForEach((event) =>
        Deferred.await(running.ready).pipe(
          Effect.andThen(Clock.currentTimeMillis),
          Effect.flatMap((now) => running.tracker.apply(event, now)),
          Effect.catchCause((cause) => Effect.logWarning("Live Activity could not apply an event", { cause })),
          Effect.andThen(Queue.offer(running.signal, undefined)),
        ),
      ),
      Effect.catchCause((cause) => Effect.logWarning("Live Activity event subscription failed", { cause })),
      Effect.forkIn(scope, { startImmediately: true }),
    )
    yield* Effect.gen(function* () {
      const host = yield* options.host
      const client = yield* options.apns
      if (client) yield* Scope.addFinalizer(scope, client.close)
      yield* running.tracker
        .rebuild(yield* Clock.currentTimeMillis)
        .pipe(Effect.catchCause((cause) => Effect.logWarning("Live Activity rebuild failed", { cause })))
      const push: LiveActivity.Push = client ? "configured" : "unconfigured"
      yield* Deferred.succeed(running.ready, { host, push })
      yield* loop(
        running,
        host,
        client
          ? {
              lifecycle: makeLifecycle({ registry: running.registry, send: client.send }),
              notifier: makeNotifier({
                registry: running.notifications,
                activities: running.registry,
                send: client.send,
              }),
            }
          : undefined,
      )
    }).pipe(Effect.forkIn(scope, { startImmediately: true }))
  })

  const loop = (
    running: Running,
    host: string,
    push: { readonly lifecycle: Lifecycle; readonly notifier: Notifier } | undefined,
  ) => {
    // The app learns the boot state through `snapshot`; `changed` reports differences from then on.
    const emitted = { key: "null", at: -Infinity }
    return Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      running.tracker.prune(now)
      const derived = running.tracker.derive(now, host)
      const state = visible(derived.state, now)
      const key = state ? stateKey(state) : "null"
      const wakes = derived.wakeAt === undefined ? [] : [derived.wakeAt]
      if (key !== emitted.key && now - emitted.at < emitMs) wakes.push(emitted.at + emitMs)
      if (key !== emitted.key && now - emitted.at >= emitMs) {
        emitted.key = key
        emitted.at = now
        yield* (members[0]?.emit(state) ?? Effect.void).pipe(
          Effect.catchCause((cause) => Effect.logWarning("Live Activity changed event failed", { cause })),
        )
      }
      if (push) {
        const plan = yield* push.lifecycle.evaluate(derived, now)
        if (plan.wakeAt !== undefined) wakes.push(plan.wakeAt)
        yield* plan.deliver.pipe(
          Effect.catchCause((cause) => Effect.logWarning("Live Activity push delivery failed", { cause })),
          Effect.forkIn(running.scope),
        )
        const alerts = yield* push.notifier.evaluate(derived, now, state)
        if (alerts.wakeAt !== undefined) wakes.push(alerts.wakeAt)
        yield* alerts.deliver.pipe(
          Effect.catchCause((cause) => Effect.logWarning("Session notification delivery failed", { cause })),
          Effect.forkIn(running.scope),
        )
      }
      const wait = Queue.take(running.signal)
      yield* wakes.length === 0 ? wait : wait.pipe(Effect.timeoutOption(Math.max(Math.min(...wakes) - now, 1)))
    }).pipe(
      Effect.catchCause((cause) =>
        Cause.hasInterruptsOnly(cause)
          ? Effect.failCause(cause)
          : Effect.logWarning("Live Activity update failed", { cause }).pipe(
              Effect.andThen(Queue.take(running.signal).pipe(Effect.timeoutOption(emitMs))),
            ),
      ),
      Effect.forever,
    )
  }

  const current = Effect.suspend(() =>
    runtime.current ? Effect.succeed(runtime.current) : Effect.die(new Error("Live Activity is not running")),
  )

  /**
   * The state with the host name and each attention session's oldest pending request, for other surfaces of the
   * same hub (the watch gateway). The request IDs never enter the Live Activity state or pushes. Unlike `snapshot`,
   * `state` stays while only unread answers wait (rev. 2026-10-29), so the watch counts what Sessões counts.
   */
  const view = Effect.gen(function* () {
    const running = yield* current
    const ready = yield* Deferred.await(running.ready)
    const now = yield* Clock.currentTimeMillis
    const derived = running.tracker.derive(now, ready.host)
    return {
      state: visible(derived.state, now, true),
      live: visible(derived.state, now),
      host: ready.host,
      requests: derived.requests,
    }
  })

  const change = <A>(run: (running: Running, now: number) => Effect.Effect<A>) =>
    Effect.gen(function* () {
      const running = yield* current
      const result = yield* run(running, yield* Clock.currentTimeMillis)
      yield* Queue.offer(running.signal, undefined)
      return result
    })

  const handlers = {
    register: (input: LiveActivity.RegisterInput) =>
      change((running, now) =>
        running.registry.register(input, now).pipe(
          Effect.andThen(Deferred.await(running.ready)),
          Effect.map((ready) => ({ push: ready.push })),
        ),
      ),
    activity: (input: LiveActivity.ActivityInput) =>
      change((running, now) => running.registry.activity(input, now).pipe(Effect.as({}))),
    ended: (input: LiveActivity.EndedInput) =>
      change((running, now) => running.registry.ended(input, now).pipe(Effect.as({}))),
    unregister: (input: { readonly deviceID: string }) =>
      change((running, now) => running.registry.unregister(input.deviceID, now).pipe(Effect.as({}))),
    snapshot: () => view.pipe(Effect.map((result) => ({ state: result.live }))),
  }

  const notifications = {
    register: (input: Notifications.RegisterInput) =>
      change((running, now) =>
        running.notifications.register(input, now).pipe(
          Effect.andThen(Deferred.await(running.ready)),
          Effect.map((ready) => ({ push: ready.push })),
        ),
      ),
    unregister: (input: { readonly deviceID: string }) =>
      change((running, now) => running.notifications.unregister(input.deviceID, now).pipe(Effect.as({}))),
  }

  const attach = (member: Member) =>
    lock.withPermit(
      Effect.gen(function* () {
        members.push(member)
        if (!runtime.current) yield* start(member)
      }),
    )

  const detach = (member: Member) =>
    lock.withPermit(
      Effect.gen(function* () {
        const index = members.indexOf(member)
        if (index >= 0) members.splice(index, 1)
        const running = runtime.current
        if (members.length > 0 || !running) return
        runtime.current = undefined
        yield* Scope.close(running.scope, Exit.void)
      }),
    )

  /** Joins the hub for the lifetime of the calling scope. */
  const join = (member: Member) => Effect.acquireRelease(attach(member), () => detach(member))

  return { join, handlers, notifications, view, members, runtime }
}

export type Hub = ReturnType<typeof makeHub>

/**
 * `null` while nothing is working, waiting or failed (nor, with `unread`, any answer unread); otherwise the state
 * trimmed to fit an update push. Unread answers never keep a Live Activity alive.
 */
function visible(state: LiveActivity.AgentsState, now: number, unread = false) {
  if (state.activeTotal === 0 && state.counts.failed === 0 && !(unread && (state.counts.unread ?? 0) > 0)) return null
  return fit({ event: "update", state, now })
}

/** macOS ComputerName (e.g. "MacBook Pro"), falling back to the host name. */
const computerName = Effect.tryPromise(async () => {
  const child = Bun.spawn(["/usr/sbin/scutil", "--get", "ComputerName"], {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
  })
  const name = (await new Response(child.stdout).text()).trim()
  if ((await child.exited) !== 0 || !name) throw new Error("ComputerName is unavailable")
  return name
}).pipe(Effect.orElseSucceed(() => os.hostname().replace(/\.local$/, "")))

declare global {
  var opencodeCustomLiveActivityHub: Hub | undefined
}

/**
 * The process-wide hub. Not module scope: the plugin loader evaluates this module again for every Location (it
 * clears the module cache per load), so only a global slot is shared by all Location instances. The first
 * evaluation's code serves the process until it restarts.
 */
export function sharedHub() {
  globalThis.opencodeCustomLiveActivityHub ??= makeHub({ host: computerName, apns: load() })
  return globalThis.opencodeCustomLiveActivityHub
}

export const registerLiveActivity = Effect.fn("LiveActivity.register")(function* (ctx: Context) {
  const hub = sharedHub()
  const registration = yield* ctx.rpc.register(LiveActivity.Definition, hub.handlers).pipe(Effect.orDie)
  yield* ctx.rpc.register(Notifications.Definition, hub.notifications).pipe(Effect.orDie)
  yield* hub.join({
    ctx: {
      session: ctx.session,
      message: ctx.message,
      request: ctx.request,
      storage: ctx.storage,
      marks: () =>
        ctx
          .rpc(Preferences.Definition)
          .get({})
          .pipe(
            Effect.map((profile) => ({
              notify: marksFrom(profile).notify,
              autoApprove: profile.data.settings.autoApprove,
              master: profile.data.masterSessions?.local,
            })),
            Effect.orElseSucceed(() => ({ notify: [], autoApprove: false })),
          ),
      events: ctx.event.subscribe().pipe(
        // A preferences change ("Avisar ao terminar") arrives as an RPC event; the tracker only needs to know it happened.
        Stream.map((event) =>
          event.type === "rpc.custom.preferences.updated" ? preferencesUpdated : tracked(event) ? event : undefined,
        ),
        Stream.filter((event) => event !== undefined),
      ),
    },
    emit: (state) => registration.events.emit("changed", { state }),
  })
})
