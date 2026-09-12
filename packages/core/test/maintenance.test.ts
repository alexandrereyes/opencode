import { expect } from "bun:test"
import { Deferred, Effect, Fiber } from "effect"
import { Maintenance } from "../src/maintenance"
import { SessionRunCoordinator } from "../src/session/run-coordinator"
import { it } from "./lib/effect"

it.live("keeps one stable identity across status and leases", () =>
  Effect.sync(() => {
    const gate = Maintenance.make()
    const identity = gate.identity
    expect(gate.identity).toBe(identity)
    expect(gate.status().identity).toBe(identity)
    const first = requireLease(gate)
    expect(first.identity).toBe(identity)
    expect(gate.cancel(first.token)).toBe(true)
    const second = requireLease(gate)
    expect(second.identity).toBe(identity)
    expect(gate.cancel(second.token)).toBe(true)
  }),
)

it.live(
  "lease and synchronous admission exclude each other",
  Effect.gen(function* () {
    const gate = Maintenance.make()
    const release = gate.enter()
    expect(release).toBeDefined()
    expect(gate.lease()).toBeUndefined()
    release?.()
    const lease = requireLease(gate)
    expect(lease).toBeDefined()
    expect(gate.enter()).toBeUndefined()
    expect(gate.cancel("wrong")).toBe(false)
    expect(gate.commit(lease.token, "wrong-process")).toBe(false)
    expect(gate.cancel(lease.token)).toBe(true)
    yield* gate.run(Effect.sync(() => expect(gate.lease()).toBeUndefined()))
    const next = requireLease(gate)
    expect(next).toBeDefined()
    gate.cancel(next.token)
  }),
)

it.live(
  "cancel resumes deferred admissions without losing cancellation",
  Effect.gen(function* () {
    const gate = Maintenance.make()
    const lease = requireLease(gate)
    const admitted = yield* Deferred.make<void>()
    const fiber = yield* gate.run(Deferred.succeed(admitted, undefined)).pipe(Effect.forkScoped)
    yield* Effect.yieldNow
    expect(yield* Deferred.isDone(admitted)).toBe(false)
    gate.cancel(lease.token)
    yield* Fiber.join(fiber)
    expect(yield* Deferred.isDone(admitted)).toBe(true)
    expect(gate.status().active).toBe(0)
    const second = requireLease(gate)
    const cancelled = yield* gate.run(Effect.die("must not run")).pipe(Effect.forkScoped)
    yield* Effect.yieldNow
    yield* Fiber.interrupt(cancelled)
    gate.cancel(second.token)
    expect(gate.status().active).toBe(0)
  }),
)

it.live(
  "expired lease releases waiters and cannot commit",
  Effect.gen(function* () {
    const gate = Maintenance.make(20)
    const lease = requireLease(gate)
    yield* gate.run(Effect.void)
    expect(gate.commit(lease.token, lease.identity)).toBe(false)
    expect(gate.status().held).toBe(false)
  }),
)

it.live(
  "committed shutdown stays closed beyond lease expiry",
  Effect.gen(function* () {
    const gate = Maintenance.make(20)
    const lease = requireLease(gate)
    expect(gate.commit(lease.token, lease.identity)).toBe(true)
    yield* Effect.sleep("30 millis")
    expect(gate.enter()).toBeUndefined()
    expect(gate.cancel(lease.token)).toBe(false)
  }),
)

it.live(
  "busy blockers and interrupted activities release with their scope",
  Effect.gen(function* () {
    const gate = Maintenance.make()
    yield* Effect.scoped(
      Effect.gen(function* () {
        yield* gate.block(() => true)
        expect(gate.lease()).toBeUndefined()
      }),
    )
    const started = yield* Deferred.make<void>()
    const fiber = yield* gate
      .run(Deferred.succeed(started, undefined).pipe(Effect.andThen(Effect.never)))
      .pipe(Effect.forkScoped)
    yield* Deferred.await(started)
    expect(gate.lease()).toBeUndefined()
    yield* Fiber.interrupt(fiber)
    const lease = requireLease(gate)
    expect(lease).toBeDefined()
    gate.cancel(lease.token)
  }),
)

it.live(
  "coordinator wake retains activity through asynchronous settlement",
  Effect.gen(function* () {
    const drained = yield* Deferred.make<void>()
    const settle = yield* Deferred.make<void>()
    const coordinator = yield* SessionRunCoordinator.make<string, never>({
      drain: () => Deferred.succeed(drained, undefined),
      settled: () => Deferred.await(settle),
    })
    yield* coordinator.wake("session")
    yield* Deferred.await(drained)
    expect(Maintenance.process.lease()).toBeUndefined()
    yield* Deferred.succeed(settle, undefined)
    yield* coordinator.awaitIdle("session")
    const lease = requireLease(Maintenance.process)
    expect(lease).toBeDefined()
    Maintenance.process.cancel(lease.token)
  }),
)

function requireLease(gate: ReturnType<typeof Maintenance.make>) {
  const lease = gate.lease()
  if (!lease) throw new Error("Expected an idle lease")
  return lease
}
