import type { Context } from "../context.js"
import { Cause, Clock, Deferred, Effect, Exit, Queue, Scope, Semaphore, Stream } from "effect"
import os from "node:os"
import { load, type Client } from "./apns.js"
import { identity } from "../instance/index.js"
import { fit, makeLifecycle, makeRegistry, stateKey, type Device, type Lifecycle, type Storage } from "./lifecycle.js"
import { linkSettings, makePeers, serveSummary, type LinkSettings, type Peers, type Read } from "./link.js"
import { marksFrom } from "../sessions/inventory.js"
import { makeNotificationRegistry, makeNotifier, type Notifier } from "../notifications/index.js"
import { Notifications } from "../notifications/rpc.js"
import { Preferences } from "../preferences/rpc.js"
import { tool } from "../progress/todos.js"
import { sharedRegistry, type Registry } from "../browser-handoff/registry.js"
import { LiveActivity } from "./rpc.js"
import { eventTypes, makeTracker, type Derived, type Event, type Tracker, type TrackerContext } from "./tracker.js"
import { join as joinSummaries, summary } from "./unified.js"

const preferencesUpdated: Event = { type: "preferences.updated" }
const tracked = <A extends { readonly type: string }>(event: A): event is Extract<A, Event> =>
  eventTypes.has(event.type)

/** `changed` is coalesced to at most one event per this interval. */
export const emitMs = 1000

/** One Location's plugin instance as the hub sees it. */
export type Member = {
  readonly ctx: Omit<TrackerContext, "todo"> & {
    readonly storage: Storage
    readonly events: Stream.Stream<Event, unknown>
  }
  /** `unified`: the joined state, only on a server that reads its peers' summaries (`docs/unified-summary.md`). */
  readonly emit: (
    state: LiveActivity.AgentsState | null,
    unified?: LiveActivity.AgentsState,
  ) => Effect.Effect<void, unknown>
  /** Its Location directory and whether `todowrite` is in that Location's tools (`experimental.todo`). */
  readonly todo?: { readonly directory: string; readonly enabled: Effect.Effect<boolean> }
}

export type HubOptions = {
  readonly host: Effect.Effect<string>
  readonly apns: Effect.Effect<Client | undefined>
  /** Browse handoffs waiting on Alexandre (`docs/browser-handoff.md`). */
  readonly handoffs?: Pick<Registry, "waiting" | "listen">
  /**
   * The link between servers (`docs/unified-summary.md`): the socket this one publishes its own summary on, and the
   * peers whose summaries it joins into the "Todos" activity. Without it, one Live Activity per server, as always.
   */
  readonly link?: LinkSettings & { readonly read?: Read }
}

type Running = {
  readonly scope: Scope.Closeable
  readonly ready: Deferred.Deferred<Ready>
  readonly signal: Queue.Queue<void>
  readonly tracker: Tracker
  readonly registry: ReturnType<typeof makeRegistry>
  readonly notifications: ReturnType<typeof makeNotificationRegistry>
  /** Present on a server that joins its peers' summaries: it writes the "Todos" scope's activities. */
  readonly peers?: Peers
}

type Ready = { readonly host: string; readonly push: LiveActivity.Push; readonly instanceID: string }

/** The devices of the "Todos" scope, which get the joined state where there is one. */
const everywhere = (device: Device) => device.scope === "all"

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
    const signal = yield* Queue.sliding<void>(1)
    const running: Running = {
      scope,
      ready: yield* Deferred.make<Ready>(),
      signal,
      // A session's Location answers for its own config; one with no loaded instance cannot be executing.
      tracker: makeTracker({
        ...member.ctx,
        todo: (directory) =>
          members.find((item) => item.todo?.directory === directory)?.todo?.enabled ?? Effect.succeed(false),
        handoffs: () => options.handoffs?.waiting() ?? [],
      }),
      registry: makeRegistry(member.ctx.storage),
      notifications: makeNotificationRegistry(member.ctx.storage),
      ...(options.link && options.link.peers.length > 0
        ? {
            peers: makePeers({
              sockets: options.link.peers,
              storage: member.ctx.storage,
              ...(options.link.read ? { read: options.link.read } : {}),
              changed: () => Queue.offerUnsafe(signal, undefined),
            }),
          }
        : {}),
    }
    runtime.current = running
    // A handoff starting to wait or ending changes the state without a server event of its own.
    if (options.handoffs) {
      const stop = options.handoffs.listen(() => Queue.offerUnsafe(running.signal, undefined))
      yield* Scope.addFinalizer(scope, Effect.sync(stop))
    }
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
      const instanceID = options.link?.serve || running.peers ? (yield* identity(member.ctx.storage)).instanceID : ""
      yield* Deferred.succeed(running.ready, { host, push, instanceID })
      // Always this server's own state, never the joined one: two servers reading each other cannot loop.
      if (options.link?.serve)
        yield* serveSummary({
          socket: options.link.serve,
          read: () => summary({ instanceID, name: host }, running.tracker.derive(Date.now(), host)),
        }).pipe(
          Scope.provide(scope),
          Effect.catchCause((cause) => Effect.logWarning("Unified summary could not be served", { cause })),
          Effect.forkIn(scope, { startImmediately: true }),
        )
      if (running.peers) yield* running.peers.run.pipe(Effect.forkIn(scope, { startImmediately: true }))
      yield* loop(
        running,
        { host, push, instanceID },
        client
          ? {
              // With peers, the "Todos" scope's devices follow the joined state and the others this server's own.
              lifecycle: makeLifecycle({
                registry: running.registry,
                send: client.send,
                ...(running.peers ? { only: (device: Device) => !everywhere(device) } : {}),
              }),
              ...(running.peers
                ? { unified: makeLifecycle({ registry: running.registry, send: client.send, only: everywhere }) }
                : {}),
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

  /** This server's state joined with its peers' fresh summaries; nothing on a server that reads no peer. */
  const joined = (running: Running, ready: Ready, derived: Derived, now: number) => {
    if (!running.peers) return undefined
    const read = running.peers.current(now)
    const result = joinSummaries({
      self: summary({ instanceID: ready.instanceID, name: ready.host }, derived),
      peers: read.peers,
    })
    return { ...result, card: fit({ event: "update", state: result.state, now }), wakeAt: read.wakeAt }
  }

  const loop = (
    running: Running,
    ready: Ready,
    push: { readonly lifecycle: Lifecycle; readonly unified?: Lifecycle; readonly notifier: Notifier } | undefined,
  ) => {
    const host = ready.host
    // The app learns the boot state through `snapshot`; `changed` reports differences from then on (the first pass
    // only records it: since rev. 2026-11-08 an idle boot state is a state too, not `null`).
    const emitted = { key: undefined as string | undefined, at: -Infinity }
    return Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      yield* running.tracker.refreshHandoffs()
      running.tracker.prune(now)
      const derived = running.tracker.derive(now, host)
      const state = visible(derived.state, now)
      const all = joined(running, ready, derived, now)
      const key = (state ? stateKey(state) : "null") + (all ? stateKey(all.card) : "")
      emitted.key ??= key
      const wakes = derived.wakeAt === undefined ? [] : [derived.wakeAt]
      // A peer that stops answering leaves the joined state when its last summary turns stale.
      if (all?.wakeAt !== undefined) wakes.push(all.wakeAt)
      if (key !== emitted.key && now - emitted.at < emitMs) wakes.push(emitted.at + emitMs)
      if (key !== emitted.key && now - emitted.at >= emitMs) {
        emitted.key = key
        emitted.at = now
        yield* (members[0]?.emit(state, all?.card) ?? Effect.void).pipe(
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
        if (push.unified && all) {
          const plan = yield* push.unified.evaluate(all, now)
          if (plan.wakeAt !== undefined) wakes.push(plan.wakeAt)
          yield* plan.deliver.pipe(
            Effect.catchCause((cause) => Effect.logWarning("Unified Live Activity push delivery failed", { cause })),
            Effect.forkIn(running.scope),
          )
        }
        const alerts = yield* push.notifier.evaluate(derived, now, state, all?.card)
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
   * Its lists are complete: the watch's scrolling dashboard is not constrained by an APNs payload (rev. 2026-11-05).
   */
  const view = Effect.gen(function* () {
    const running = yield* current
    const ready = yield* Deferred.await(running.ready)
    const now = yield* Clock.currentTimeMillis
    const derived = running.tracker.derive(now, ready.host)
    const all = joined(running, ready, derived, now)
    return {
      state: visible({ ...derived.state, ...derived.dashboard }, now, "watch"),
      live: visible(derived.state, now),
      ...(all ? { unified: all.card } : {}),
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
          // Confirmed only where the joined state exists; elsewhere the registration gets this server's own.
          Effect.map((ready) => ({
            push: ready.push,
            ...(input.scope === "all" && running.peers ? { scope: "all" as const } : {}),
          })),
        ),
      ),
    activity: (input: LiveActivity.ActivityInput) =>
      change((running, now) => running.registry.activity(input, now).pipe(Effect.as({}))),
    ended: (input: LiveActivity.EndedInput) =>
      change((running, now) => running.registry.ended(input, now).pipe(Effect.as({}))),
    unregister: (input: { readonly deviceID: string }) =>
      change((running, now) => running.registry.unregister(input.deviceID, now).pipe(Effect.as({}))),
    snapshot: () =>
      view.pipe(
        Effect.map((result) => ({ state: result.live, ...(result.unified ? { unified: result.unified } : {}) })),
      ),
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

  /** A session's Progresso while it shows (`docs/progress.md`); none before the hub has started. */
  const progress = (sessionID: string) => runtime.current?.tracker.progress(sessionID)

  return { join, handlers, notifications, view, members, runtime, progress }
}

export type Hub = ReturnType<typeof makeHub>

/**
 * Activity states are trimmed to fit an update push; the watch keeps the full HTTP lists. The activity always gets the
 * state (rev. 2026-11-08): with nothing working it stays on screen, parked, and the app no longer ends it; it starts
 * one only while something works, waits or failed. The watch gets `null` while nothing is working, waiting or failed
 * and no answer is unread.
 */
function visible(state: LiveActivity.AgentsState, now: number, surface: "activity" | "watch" = "activity") {
  if (surface === "watch" && state.activeTotal === 0 && state.counts.failed === 0 && (state.counts.unread ?? 0) === 0)
    return null
  return surface === "watch" ? state : fit({ event: "update", state, now })
}

/**
 * The card's `host`: `OPENCODE_HOST_NAME` when the deployment names the server (rev. 2026-11-10: a container's host
 * name is its ID, `3d30be133570`), else macOS ComputerName (e.g. "MacBook Pro"), else the host name.
 */
export const hostName = (configured = process.env.OPENCODE_HOST_NAME) =>
  configured?.trim() ? Effect.succeed(configured.trim().slice(0, 40)) : computerName

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
  globalThis.opencodeCustomLiveActivityHub ??= makeHub({
    host: hostName(),
    apns: load(),
    handoffs: sharedRegistry(),
    link: linkSettings(),
  })
  return globalThis.opencodeCustomLiveActivityHub
}

export const registerLiveActivity = Effect.fn("LiveActivity.register")(function* (ctx: Context) {
  const hub = sharedHub()
  const registration = yield* ctx.rpc.register(LiveActivity.Definition, hub.handlers).pipe(Effect.orDie)
  yield* ctx.rpc.register(Notifications.Definition, hub.notifications).pipe(Effect.orDie)
  yield* hub.join({
    ctx: {
      session: ctx.session,
      background: ctx.job.background,
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
    emit: (state, unified) => registration.events.emit("changed", { state, ...(unified ? { unified } : {}) }),
    todo: {
      directory: ctx.location.directory,
      enabled: ctx.tool.list().pipe(Effect.map((tools) => tools.some((item) => item.id === tool))),
    },
  })
})
