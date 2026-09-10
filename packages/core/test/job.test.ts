import { describe, expect } from "bun:test"
import { Job } from "@opencode/core/job"
import { KV } from "@opencode/core/kv"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Deferred, Effect, Exit, Fiber, Scope } from "effect"
import { SessionSchema } from "@opencode/core/session/schema"
import { SessionMessage } from "@opencode/core/session/message"
import { SessionInbox } from "@opencode/core/session/inbox"
import { SubagentCompletion } from "@opencode/core/session/subagent-completion"
import { testEffect } from "./lib/effect"
import { Maintenance } from "../src/maintenance"

const it = testEffect(AppNodeBuilder.build(LayerNode.group([Job.node, KV.node])))

describe("Job", () => {
  it.live("tracks process-local work through explicit observation", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const latch = yield* Deferred.make<void>()
      const job = yield* jobs.start({
        type: "test",
        metadata: { durable: false },
        run: Deferred.await(latch).pipe(Effect.as("done")),
      })

      expect(job).toMatchObject({ type: "test", status: "running", metadata: { durable: false } })
      expect(Maintenance.process.lease()).toBeUndefined()
      expect(yield* jobs.wait({ id: job.id, timeout: 0 })).toMatchObject({
        timedOut: true,
        info: { status: "running" },
      })

      yield* Deferred.succeed(latch, undefined)
      expect(yield* jobs.wait({ id: job.id })).toMatchObject({
        timedOut: false,
        info: { status: "completed", output: "done" },
      })
    }),
  )

  it.live("publishes jobs before starting immediately settling work", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service

      yield* Effect.forEach(Array.from({ length: 100 }), (_, index) => {
        const id = `job_immediate_start_${index}`
        return Effect.gen(function* () {
          const job = yield* jobs.start({
            id,
            type: "test",
            run: jobs
              .get(id)
              .pipe(
                Effect.flatMap((info) =>
                  info?.status === "running"
                    ? Effect.succeed(`done-${index}`)
                    : Effect.fail("job started before publish"),
                ),
              ),
          })

          expect(yield* jobs.wait({ id: job.id })).toMatchObject({
            timedOut: false,
            info: { status: "completed", output: `done-${index}` },
          })
        })
      })
    }),
  )

  it.live("reuses running work when started again with the same ID", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const output = yield* Deferred.make<string>()
      const job = yield* jobs.start({ id: "job_reused", type: "test", run: Deferred.await(output) })

      expect(
        yield* jobs.start({ id: job.id, type: "duplicate", run: Effect.die("Duplicate work must not run") }),
      ).toEqual(job)

      yield* Deferred.succeed(output, "original output")
      expect((yield* jobs.wait({ id: job.id })).info).toMatchObject({
        type: "test",
        status: "completed",
        output: "original output",
      })
    }),
  )

  it.live("ignores an obsolete callback after a cancellation waiter starts a same-ID replacement", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const callback = yield* Deferred.make<() => void>()
      const output = yield* Deferred.make<string>()
      const finalized = yield* Deferred.make<void>()
      const job = yield* jobs.start({
        id: "job_replaced",
        type: "test",
        run: Effect.callback<string>((resume) => {
          Deferred.doneUnsafe(
            callback,
            Effect.succeed(() => resume(Effect.succeed("obsolete output"))),
          )
        }),
      })
      const complete = yield* Deferred.await(callback)
      // Cancellation wakes waiters before closing the old scope, allowing the old callback to race replacement.
      const replacement = yield* jobs.wait({ id: job.id }).pipe(
        Effect.tap((result) => Effect.sync(() => expect(result.info?.status).toBe("cancelled"))),
        Effect.andThen(
          jobs.start({
            id: job.id,
            type: "replacement",
            run: Deferred.await(output).pipe(Effect.ensuring(Deferred.succeed(finalized, undefined))),
          }),
        ),
        Effect.andThen(Effect.sync(complete)),
        Effect.forkChild({ startImmediately: true }),
      )

      yield* jobs.cancel(job.id)
      yield* Fiber.join(replacement)
      expect(yield* jobs.get(job.id)).toMatchObject({ type: "replacement", status: "running" })
      expect(yield* Deferred.isDone(finalized)).toBe(false)

      yield* Deferred.succeed(output, "replacement output")
      expect((yield* jobs.wait({ id: job.id })).info).toMatchObject({
        type: "replacement",
        status: "completed",
        output: "replacement output",
      })
      expect(yield* Deferred.isDone(finalized)).toBe(true)
    }),
  )

  it.live("returns finished from a blocking wait when completion wins", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const latch = yield* Deferred.make<void>()
      const job = yield* jobs.start({ type: "test", run: Deferred.await(latch).pipe(Effect.as("done")) })
      const waiting = yield* jobs
        .block({ id: job.id, sessionID: SessionSchema.ID.make("ses_parent") })
        .pipe(Effect.forkIn(yield* Scope.Scope, { startImmediately: true }))

      yield* Deferred.succeed(latch, undefined)

      expect(yield* Fiber.join(waiting)).toMatchObject({
        type: "finished",
        info: { status: "completed", output: "done" },
      })
      expect(yield* jobs.background(job.id)).toBeUndefined()
    }),
  )

  it.live("returns backgrounded from a blocking wait when background wins", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const latch = yield* Deferred.make<void>()
      const job = yield* jobs.start({ type: "test", run: Deferred.await(latch).pipe(Effect.as("done")) })
      const waiting = yield* jobs
        .block({ id: job.id, sessionID: SessionSchema.ID.make("ses_parent") })
        .pipe(Effect.forkIn(yield* Scope.Scope, { startImmediately: true }))

      expect(yield* jobs.background(job.id)).toMatchObject({ id: job.id, status: "running" })
      expect(yield* Fiber.join(waiting)).toMatchObject({
        type: "backgrounded",
        info: { id: job.id, status: "running" },
      })

      yield* Deferred.succeed(latch, undefined)
      expect(yield* jobs.wait({ id: job.id })).toMatchObject({
        timedOut: false,
        info: { status: "completed", output: "done" },
      })
    }),
  )

  it.live("backgrounds only jobs actively blocking a session", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const parent = SessionSchema.ID.make("ses_parent")
      const other = SessionSchema.ID.make("ses_other")
      const latch = yield* Deferred.make<void>()
      const first = yield* jobs.start({
        id: "job_first",
        type: "test",
        run: Deferred.await(latch).pipe(Effect.as("first")),
      })
      const second = yield* jobs.start({
        id: "job_second",
        type: "test",
        run: Deferred.await(latch).pipe(Effect.as("second")),
      })
      const third = yield* jobs.start({
        id: "job_third",
        type: "other",
        run: Deferred.await(latch).pipe(Effect.as("third")),
      })
      const scope = yield* Scope.Scope
      const firstWait = yield* jobs
        .block({ id: first.id, sessionID: parent })
        .pipe(Effect.forkIn(scope, { startImmediately: true }))
      const secondWait = yield* jobs
        .block({ id: second.id, sessionID: other })
        .pipe(Effect.forkIn(scope, { startImmediately: true }))
      const thirdWait = yield* jobs
        .block({ id: third.id, sessionID: parent })
        .pipe(Effect.forkIn(scope, { startImmediately: true }))

      expect(yield* jobs.backgroundAll({ sessionID: parent, type: "test" })).toMatchObject([{ id: first.id }])
      expect(yield* Fiber.join(firstWait)).toMatchObject({ type: "backgrounded", info: { id: first.id } })

      yield* Deferred.succeed(latch, undefined)
      expect(yield* Fiber.join(secondWait)).toMatchObject({ type: "finished", info: { id: second.id } })
      expect(yield* Fiber.join(thirdWait)).toMatchObject({ type: "finished", info: { id: third.id } })
    }),
  )

  it.live("retains background ownership and terminal output until notification acknowledgment", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const latch = yield* Deferred.make<void>()
      const recovery = {
        kind: "shell" as const,
        sessionID: SessionSchema.ID.make("ses_background_shell"),
        shellID: "shell_background",
        command: "echo done",
      }
      const job = yield* jobs.start({ type: "shell", recovery, run: Deferred.await(latch).pipe(Effect.as("done")) })

      expect((yield* jobs.pendingBackground).find((item) => item.id === job.id)).toBeUndefined()
      const background = yield* jobs.background(job.id)

      const running = (yield* jobs.pendingBackground).find((item) => item.id === job.id)
      expect(running).toMatchObject({ id: job.id, recovery, status: "running" })
      expect(running?.notificationID).toStartWith("msg_")
      expect(background?.notificationID).toBe(running?.notificationID)

      yield* Deferred.succeed(latch, undefined)
      yield* jobs.wait({ id: job.id })

      const completed = (yield* jobs.pendingBackground).find((item) => item.id === job.id)
      expect(completed).toMatchObject({
        id: job.id,
        notificationID: running?.notificationID,
        recovery,
        status: "completed",
        output: "done",
      })
      if (!completed) return yield* Effect.die("background marker missing")

      yield* jobs.completeBackground(completed.notificationID)
      expect((yield* jobs.pendingBackground).find((item) => item.id === job.id)).toBeUndefined()
    }),
  )

  it.live("persists backgroundAll ownership before releasing a blocked subagent", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const parentSessionID = SessionSchema.ID.make("ses_background_parent")
      const latch = yield* Deferred.make<void>()
      const recovery = {
        kind: "subagent" as const,
        parentSessionID,
        childSessionID: SessionSchema.ID.make("ses_background_child"),
        agent: "explore",
        description: "Explore background recovery",
      }
      const job = yield* jobs.start({ type: "subagent", recovery, run: Deferred.await(latch).pipe(Effect.as("done")) })
      const waiting = yield* jobs
        .block({ id: job.id, sessionID: parentSessionID })
        .pipe(Effect.forkIn(yield* Scope.Scope, { startImmediately: true }))

      yield* jobs.backgroundAll({ sessionID: parentSessionID })
      expect(yield* Fiber.join(waiting)).toMatchObject({ type: "backgrounded", info: { id: job.id } })

      const marker = (yield* jobs.pendingBackground).find((item) => item.id === job.id)
      expect(marker).toMatchObject({ id: job.id, recovery, status: "running" })
      if (!marker) return yield* Effect.die("background marker missing")

      yield* jobs.cancel(job.id)
      expect((yield* jobs.pendingBackground).find((item) => item.id === job.id)).toMatchObject({
        notificationID: marker.notificationID,
        status: "cancelled",
      })
      yield* jobs.completeBackground(marker.notificationID)
    }),
  )

  it.live("retains terminal errors for recovery until notification acknowledgment", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const latch = yield* Deferred.make<void>()
      const job = yield* jobs.start({
        type: "shell",
        recovery: {
          kind: "shell",
          sessionID: SessionSchema.ID.make("ses_background_error"),
          shellID: "shell_error",
          command: "exit 1",
        },
        run: Deferred.await(latch).pipe(Effect.andThen(Effect.fail(new Error("shell failed")))),
      })

      yield* jobs.background(job.id)
      yield* Deferred.succeed(latch, undefined)
      yield* jobs.wait({ id: job.id })

      const marker = (yield* jobs.pendingBackground).find((item) => item.id === job.id)
      expect(marker).toMatchObject({ id: job.id, status: "error", error: "shell failed" })
      if (!marker) return yield* Effect.die("background marker missing")
      yield* jobs.completeBackground(marker.notificationID)
    }),
  )

  it.live("durably backgrounds recoverable work that has already failed", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const job = yield* jobs.start({
        type: "shell",
        recovery: {
          kind: "shell",
          sessionID: SessionSchema.ID.make("ses_immediate_error"),
          shellID: "shell_immediate_error",
          command: "exit 1",
        },
        run: Effect.fail(new Error("shell failed")),
      })
      expect((yield* jobs.wait({ id: job.id })).info?.status).toBe("error")

      const background = yield* jobs.background(job.id)
      expect(background?.notificationID).toStartWith("msg_")
      expect(yield* jobs.pendingBackground).toMatchObject([
        { id: job.id, notificationID: background?.notificationID, status: "error", error: "shell failed" },
      ])
    }),
  )

  it.live("recovers a background marker after its process-local registry closes", () =>
    Effect.gen(function* () {
      const scope = yield* Scope.make()
      const previous = yield* Job.make.pipe(Scope.provide(scope))
      const job = yield* previous.start({
        type: "shell",
        recovery: {
          kind: "shell",
          sessionID: SessionSchema.ID.make("ses_background_restart"),
          shellID: "shell_restart",
          command: "sleep 60",
        },
        run: Effect.never,
      })
      yield* previous.background(job.id)
      yield* Scope.close(scope, Exit.void)

      const current = yield* Job.make
      const marker = (yield* current.pendingBackground).find((item) => item.id === job.id)
      expect(marker).toMatchObject({ id: job.id, status: "running" })
      if (!marker) return yield* Effect.die("background marker missing")
      yield* current.completeBackground(marker.notificationID)
    }),
  )

  it.live("preserves running background ownership when its work is interrupted", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const interrupted = yield* Deferred.make<void>()
      const job = yield* jobs.start({
        type: "subagent",
        recovery: {
          kind: "subagent",
          parentSessionID: SessionSchema.ID.make("ses_interrupted_parent"),
          childSessionID: SessionSchema.ID.make("ses_interrupted_child"),
          agent: "explore",
          description: "Continue after shutdown",
        },
        run: Deferred.await(interrupted).pipe(Effect.andThen(Effect.interrupt)),
      })
      yield* jobs.background(job.id)
      yield* Deferred.succeed(interrupted, undefined)
      yield* jobs.wait({ id: job.id })

      const marker = (yield* jobs.pendingBackground).find((item) => item.id === job.id)
      expect(marker).toMatchObject({ id: job.id, status: "running" })
      if (!marker) return yield* Effect.die("background marker missing")
      yield* jobs.completeBackground(marker.notificationID)
    }),
  )

  it.live("interrupts live work without promising settlement after the owning process-local scope closes", () =>
    Effect.gen(function* () {
      const scope = yield* Scope.make()
      const interrupted = yield* Deferred.make<void>()
      const jobs = yield* Job.make.pipe(Scope.provide(scope))
      const job = yield* jobs.start({
        type: "test",
        run: Effect.never.pipe(Effect.ensuring(Deferred.succeed(interrupted, undefined))),
      })

      yield* Scope.close(scope, Exit.void)

      yield* Deferred.await(interrupted).pipe(Effect.timeout("1 second"))
      // The abandoned in-memory registry is not a durable observation channel.
      expect((yield* jobs.get(job.id))?.status).toBe("running")
    }),
  )

  it.live("interrupts a reused child while preserving its earlier worker and cancelling its later worker", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const root = SessionSchema.ID.make("ses_causal_root")
      const child = SessionSchema.ID.make("ses_causal_child")
      const original = {
        parentSessionID: root,
        messageID: SessionMessage.ID.make("msg_causal_original"),
        toolCallID: "call-original",
      }
      const reverted = {
        parentSessionID: root,
        messageID: SessionMessage.ID.make("msg_causal_reverted"),
        toolCallID: "call-reverted",
      }
      const childRecovery = {
        kind: "subagent" as const,
        parentSessionID: root,
        childSessionID: child,
        agent: "explore",
        description: "existing child",
      }
      const childJob = yield* jobs.start({
        id: child,
        type: "subagent",
        origins: [original],
        recovery: childRecovery,
        run: Effect.never,
      })
      const joined = yield* jobs.start({ id: child, type: "subagent", origins: [reverted], run: Effect.never })
      expect(joined.origins).toEqual([original, reverted])

      const earlierWorkerOrigin = {
        parentSessionID: child,
        messageID: SessionMessage.ID.make("msg_causal_worker_before"),
        toolCallID: "call-worker-before",
      }
      const laterWorkerOrigin = {
        parentSessionID: child,
        messageID: SessionMessage.ID.make("msg_causal_worker_after"),
        toolCallID: "call-worker-after",
      }
      const earlierWorker = yield* jobs.start({
        id: "shell_causal_before",
        type: "shell",
        origins: [earlierWorkerOrigin],
        recovery: { kind: "shell", sessionID: child, shellID: "shell_causal_before", command: "preserve" },
        run: Effect.never,
      })
      const laterWorker = yield* jobs.start({
        id: "shell_causal_after",
        type: "shell",
        origins: [laterWorkerOrigin],
        recovery: { kind: "shell", sessionID: child, shellID: "shell_causal_after", command: "cancel" },
        run: Effect.never,
      })
      const unrelated = yield* jobs.start({
        id: "shell_causal_unrelated",
        type: "shell",
        origins: [original],
        recovery: { kind: "shell", sessionID: root, shellID: "shell_causal_unrelated", command: "preserve" },
        run: Effect.never,
      })
      yield* Effect.forEach([childJob.id, earlierWorker.id, laterWorker.id, unrelated.id], jobs.background, {
        discard: true,
      })

      const plan = yield* jobs.invalidateCausal({ origins: [reverted, laterWorkerOrigin] })
      expect(new Set(plan.jobs.map((job) => job.id))).toEqual(new Set([child, laterWorker.id]))
      expect(plan.interruptSessionIDs).toEqual([child])
      expect(yield* jobs.isValid(childJob)).toBe(false)
      expect(yield* jobs.isValid(earlierWorker)).toBe(true)
      expect(yield* jobs.isValid(laterWorker)).toBe(false)
      expect(yield* jobs.isValid(unrelated)).toBe(true)

      expect((yield* jobs.cancelCausal(plan)).map((job) => job.id).toSorted()).toEqual(
        [child, laterWorker.id].toSorted(),
      )
      const cancelledChild = yield* jobs.get(child)
      if (!cancelledChild) return yield* Effect.die("cancelled child missing")
      yield* SubagentCompletion.deliver(
        { synthetic: () => Effect.die("invalid completion must not be admitted") },
        jobs,
        { ...cancelledChild, recovery: childRecovery },
      )
      expect((yield* jobs.get(earlierWorker.id))?.status).toBe("running")
      expect((yield* jobs.get(unrelated.id))?.status).toBe("running")
      expect(new Set((yield* jobs.pendingBackground).map((job) => job.id))).toEqual(
        new Set([earlierWorker.id, unrelated.id]),
      )
      yield* Effect.forEach([earlierWorker.id, unrelated.id], jobs.cancel, { discard: true })
      yield* Effect.forEach(yield* jobs.pendingBackground, (job) => jobs.completeBackground(job.notificationID), {
        discard: true,
      })
      const restarted = yield* Job.make
      expect(yield* restarted.pendingBackground).toEqual([])
    }),
  )

  it.live("rejects a late invalid join without contaminating its replacement generation", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const origin = {
        parentSessionID: SessionSchema.ID.make("ses_generation_parent"),
        messageID: SessionMessage.ID.make("msg_generation_old"),
        toolCallID: "call-generation-old",
      }
      const old = yield* jobs.start({ id: "job_generation", type: "test", origins: [origin], run: Effect.never })
      const plan = yield* jobs.invalidateCausal({ origins: [origin] })
      yield* jobs.cancel(old.id)
      const replacementOrigin = {
        parentSessionID: origin.parentSessionID,
        messageID: SessionMessage.ID.make("msg_generation_new"),
        toolCallID: "call-generation-new",
      }
      const replacement = yield* jobs.start({
        id: old.id,
        type: "test",
        origins: [replacementOrigin],
        run: Effect.never,
      })
      const cleaned = yield* Deferred.make<void>()
      const rejected = yield* jobs.start({
        id: old.id,
        type: "late-invalid",
        origins: [origin],
        onInvalid: Deferred.succeed(cleaned, undefined),
        run: Effect.die("late invalid work must not run"),
      })

      expect(replacement.generation).not.toBe(old.generation)
      expect(rejected.status).toBe("cancelled")
      expect(yield* Deferred.isDone(cleaned)).toBe(true)
      expect(yield* jobs.wait({ id: old.id, generation: old.generation })).toEqual({ timedOut: false })
      expect(yield* jobs.cancelCausal(plan)).toEqual([])
      expect(yield* jobs.get(replacement.id)).toMatchObject({
        generation: replacement.generation,
        status: "running",
        origins: [replacementOrigin],
      })
      yield* jobs.cancel(replacement.id)
    }),
  )

  it.live("allows a discarded child session to start a later valid generation", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const parent = SessionSchema.ID.make("ses_discard_reuse_parent")
      const child = SessionSchema.ID.make("ses_discard_reuse_child")
      const discardedOrigin = {
        parentSessionID: parent,
        messageID: SessionMessage.ID.make("msg_discard_reuse_old"),
        toolCallID: "call-discard-reuse-old",
      }
      const old = yield* jobs.start({
        id: child,
        type: "subagent",
        origins: [discardedOrigin],
        recovery: {
          kind: "subagent",
          parentSessionID: parent,
          childSessionID: child,
          agent: "explore",
          description: "old generation",
        },
        run: Effect.never,
      })
      const plan = yield* jobs.invalidateCausal({
        origins: [discardedOrigin],
        discardedSessionIDs: [child],
      })
      yield* jobs.cancelCausal(plan)
      const validOrigin = {
        parentSessionID: parent,
        messageID: SessionMessage.ID.make("msg_discard_reuse_new"),
        toolCallID: "call-discard-reuse-new",
      }
      const replacement = yield* jobs.start({
        id: child,
        type: "subagent",
        origins: [validOrigin],
        recovery: {
          kind: "subagent",
          parentSessionID: parent,
          childSessionID: child,
          agent: "explore",
          description: "new generation",
        },
        run: Effect.never,
      })
      const shell = yield* jobs.start({
        id: "shell_discard_reuse_new",
        type: "shell",
        origins: [
          {
            parentSessionID: child,
            messageID: SessionMessage.ID.make("msg_discard_reuse_shell"),
            toolCallID: "call-discard-reuse-shell",
          },
        ],
        recovery: {
          kind: "shell",
          sessionID: child,
          shellID: "shell_discard_reuse_new",
          command: "new shell",
        },
        run: Effect.never,
      })

      expect(old.generation).not.toBe(replacement.generation)
      expect(replacement.status).toBe("running")
      expect(shell.status).toBe("running")
      yield* Effect.forEach([replacement.id, shell.id], jobs.cancel, { discard: true })
    }),
  )

  it.live("revokes multiple pending origins without invalidating the shared earlier generation", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const parent = SessionSchema.ID.make("ses_pending_origins_parent")
      const origin = (name: string) => ({
        parentSessionID: parent,
        messageID: SessionMessage.ID.make(`msg_pending_${name}`),
        toolCallID: `call-pending-${name}`,
      })
      const earlier = origin("earlier")
      const queued = origin("queued")
      const steered = origin("steered")
      const completed = yield* Deferred.make<string>()
      const job = yield* jobs.start({
        id: "job_pending_origins",
        type: "subagent",
        origins: [earlier],
        recovery: {
          kind: "subagent",
          parentSessionID: parent,
          childSessionID: SessionSchema.ID.make("ses_pending_origins_child"),
          agent: "explore",
          description: "pending origins",
        },
        run: Deferred.await(completed),
      })
      yield* jobs.start({ id: job.id, type: "subagent", origins: [queued], run: Effect.never })
      const stale = yield* jobs.start({ id: job.id, type: "subagent", origins: [steered], run: Effect.never })
      yield* jobs.background(job.id)
      yield* Deferred.succeed(completed, "earlier result")
      const oldResult = (yield* jobs.wait({ id: job.id, generation: job.generation })).info
      if (!oldResult) return yield* Effect.die("completed shared generation missing")

      yield* jobs.revokeOrigins([queued, steered])
      expect(yield* jobs.get(job.id)).toMatchObject({
        generation: job.generation,
        status: "completed",
        origins: [earlier],
      })
      expect((yield* jobs.pendingBackground)[0]?.origins).toEqual([earlier])
      const replacementOrigin = origin("replacement")
      const replacement = yield* jobs.start({
        id: job.id,
        type: "subagent",
        origins: [replacementOrigin],
        run: Effect.never,
      })
      expect(yield* jobs.isValid(stale)).toBe(true)
      expect(yield* jobs.guard(oldResult, Effect.succeed("admitted earlier result"))).toBe("admitted earlier result")

      const cleaned = yield* Deferred.make<void>()
      expect(
        yield* jobs.start({
          id: job.id,
          type: "late pending retry",
          origins: [queued],
          onInvalid: Deferred.succeed(cleaned, undefined),
          run: Effect.die("revoked pending work must not join"),
        }),
      ).toMatchObject({ status: "cancelled", origins: [queued] })
      expect(yield* Deferred.isDone(cleaned)).toBe(true)
      expect(yield* jobs.get(job.id)).toMatchObject({
        generation: replacement.generation,
        status: "running",
        origins: [replacementOrigin],
      })
      yield* jobs.cancel(replacement.id)
      yield* Effect.forEach(yield* jobs.pendingBackground, (marker) => jobs.completeBackground(marker.notificationID), {
        discard: true,
      })
    }),
  )

  it.live("revokes pending origins under the real inbox family lock without notification lock inversion", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const sessionID = SessionSchema.ID.make("ses_revoke_lock_order")
      const origin = {
        parentSessionID: sessionID,
        messageID: SessionMessage.ID.make("msg_revoke_lock_order"),
        toolCallID: "call-revoke-lock-order",
      }
      const job = yield* jobs.start({ id: "job_revoke_lock_order", type: "test", origins: [origin], run: Effect.never })
      const familyEntered = yield* Deferred.make<void>()
      const releaseRevoke = yield* Deferred.make<void>()
      const revoking = yield* SessionInbox.serialized(
        sessionID,
        Deferred.succeed(familyEntered, undefined).pipe(
          Effect.andThen(Deferred.await(releaseRevoke)),
          Effect.andThen(jobs.revokeOrigins([origin])),
        ),
      ).pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Deferred.await(familyEntered)
      const notification = yield* jobs
        .guard(job, SessionInbox.serialized(sessionID, Effect.succeed("admitted")))
        .pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Effect.yieldNow

      yield* Deferred.succeed(releaseRevoke, undefined)
      yield* Fiber.join(revoking)
      expect(yield* Fiber.join(notification)).toBe("admitted")
      expect((yield* jobs.get(job.id))?.origins).toEqual([])
      yield* jobs.cancel(job.id)
    }),
  )

  it.live("rejects and cleans up work registered while causal invalidation scans durable jobs", () =>
    Effect.gen(function* () {
      const kv = yield* KV.Service
      const scanCaptured = yield* Deferred.make<void>()
      const releaseScan = yield* Deferred.make<void>()
      const jobs = yield* Job.make.pipe(
        Effect.provideService(
          KV.Service,
          KV.Service.of({
            ...kv,
            scan: (options) =>
              kv.scan(options).pipe(
                Effect.tap(() => Deferred.succeed(scanCaptured, undefined)),
                Effect.tap(() => Deferred.await(releaseScan)),
              ),
          }),
        ),
      )
      const origin = {
        parentSessionID: SessionSchema.ID.make("ses_late_registration"),
        messageID: SessionMessage.ID.make("msg_late_registration"),
        toolCallID: "call-late-registration",
      }
      const invalidation = yield* jobs
        .invalidateCausal({ origins: [origin] })
        .pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Deferred.await(scanCaptured)

      const cleaned = yield* Deferred.make<void>()
      const registration = yield* jobs
        .start({
          id: "shell_late_registration",
          type: "shell",
          origins: [origin],
          recovery: {
            kind: "shell",
            sessionID: origin.parentSessionID,
            shellID: "shell_late_registration",
            command: "late",
          },
          onInvalid: Deferred.succeed(cleaned, undefined),
          run: Effect.die("invalid work must not start"),
        })
        .pipe(
          Effect.tap((job) => jobs.background(job.id)),
          Effect.forkScoped({ startImmediately: true }),
        )
      yield* Deferred.succeed(releaseScan, undefined)

      expect((yield* Fiber.join(invalidation)).jobs).toEqual([])
      const rejected = yield* Fiber.join(registration)
      expect(rejected.status).toBe("cancelled")
      expect(yield* Deferred.isDone(cleaned)).toBe(true)
      expect(yield* jobs.isValid(rejected)).toBe(false)
      expect(yield* jobs.pendingBackground).toEqual([])
      const rebuilt = yield* Job.make
      expect(yield* rebuilt.pendingBackground).toEqual([])
    }),
  )

  it.live("checks a causal generation inside the cancellation mutex", () =>
    Effect.gen(function* () {
      const kv = yield* KV.Service
      const persistEntered = yield* Deferred.make<void>()
      const releasePersist = yield* Deferred.make<void>()
      let pausePersist = false
      const jobs = yield* Job.make.pipe(
        Effect.provideService(
          KV.Service,
          KV.Service.of({
            ...kv,
            set: (key, value) =>
              kv.set(key, value).pipe(
                Effect.tap(() => (pausePersist ? Deferred.succeed(persistEntered, undefined) : Effect.void)),
                Effect.tap(() => (pausePersist ? Deferred.await(releasePersist) : Effect.void)),
              ),
          }),
        ),
      )
      const origin = {
        parentSessionID: SessionSchema.ID.make("ses_cancel_mutex"),
        messageID: SessionMessage.ID.make("msg_cancel_mutex"),
        toolCallID: "call-cancel-mutex",
      }
      const first = yield* jobs.start({ id: "job_cancel_mutex", type: "test", origins: [origin], run: Effect.never })
      const plan = yield* jobs.invalidateCausal({ origins: [origin] })
      yield* jobs.cancel(first.id)

      const holder = yield* jobs.start({
        id: "job_cancel_mutex_holder",
        type: "shell",
        recovery: {
          kind: "shell",
          sessionID: origin.parentSessionID,
          shellID: "job_cancel_mutex_holder",
          command: "hold persist",
        },
        run: Effect.never,
      })
      pausePersist = true
      const backgrounding = yield* jobs.background(holder.id).pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Deferred.await(persistEntered)
      const replacement = yield* jobs
        .start({ id: first.id, type: "replacement", run: Effect.never })
        .pipe(Effect.forkScoped({ startImmediately: true }))
      const cancelling = yield* jobs.cancelCausal(plan).pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Deferred.succeed(releasePersist, undefined)
      yield* Fiber.join(backgrounding)

      const next = yield* Fiber.join(replacement)
      expect(yield* Fiber.join(cancelling)).toEqual([])
      expect(next.generation).not.toBe(first.generation)
      expect((yield* jobs.get(next.id))?.status).toBe("running")
      yield* Effect.forEach([next.id, holder.id], jobs.cancel, { discard: true })
      yield* Effect.forEach(yield* jobs.pendingBackground, (job) => jobs.completeBackground(job.notificationID), {
        discard: true,
      })
    }),
  )

  it.live("serializes notification admission with causal invalidation without blocking settlement", () =>
    Effect.gen(function* () {
      const jobs = yield* Job.Service
      const origin = {
        parentSessionID: SessionSchema.ID.make("ses_notification_guard"),
        messageID: SessionMessage.ID.make("msg_notification_guard"),
        toolCallID: "call-notification-guard",
      }
      const releaseWork = yield* Deferred.make<void>()
      const job = yield* jobs.start({
        id: "job_notification_guard",
        type: "test",
        origins: [origin],
        run: Deferred.await(releaseWork).pipe(Effect.as("done")),
      })
      const admissionStarted = yield* Deferred.make<void>()
      const releaseAdmission = yield* Deferred.make<void>()
      const admission = yield* jobs
        .guard(
          job,
          Deferred.succeed(admissionStarted, undefined).pipe(
            Effect.andThen(Deferred.await(releaseAdmission)),
            Effect.as("admitted"),
          ),
        )
        .pipe(Effect.forkScoped({ startImmediately: true }))
      yield* Deferred.await(admissionStarted)
      const independent = yield* jobs.start({ id: "job_notification_independent", type: "test", run: Effect.never })
      expect(independent.status).toBe("running")
      const invalidation = yield* jobs
        .invalidateCausal({ origins: [origin] })
        .pipe(Effect.forkScoped({ startImmediately: true }))

      yield* Deferred.succeed(releaseWork, undefined)
      expect((yield* jobs.wait({ id: job.id })).info?.status).toBe("completed")
      expect(invalidation.pollUnsafe()).toBeUndefined()
      yield* Deferred.succeed(releaseAdmission, undefined)
      expect(yield* Fiber.join(admission)).toBe("admitted")
      expect((yield* Fiber.join(invalidation)).jobs).toMatchObject([{ id: job.id }])
      yield* jobs.cancel(independent.id)
    }),
  )

  it.live("never resurrects a marker when origin revocation races invalidation or acknowledgement", () =>
    Effect.gen(function* () {
      const kv = yield* KV.Service
      yield* Effect.forEach(
        ["invalidate", "acknowledge"] as const,
        Effect.fnUntraced(function* (mode) {
          const origin = {
            parentSessionID: SessionSchema.ID.make(`ses_marker_race_${mode}`),
            messageID: SessionMessage.ID.make(`msg_marker_race_${mode}`),
            toolCallID: `call-marker-race-${mode}`,
          }
          const sourceScope = yield* Scope.make()
          const source = yield* Job.make.pipe(Scope.provide(sourceScope))
          const sourceJob = yield* source.start({
            id: `job_marker_race_${mode}`,
            type: "shell",
            origins: [origin],
            recovery: {
              kind: "shell",
              sessionID: origin.parentSessionID,
              shellID: `shell_marker_race_${mode}`,
              command: mode,
            },
            run: Effect.never,
          })
          yield* source.background(sourceJob.id)
          const marker = (yield* source.pendingBackground)[0]
          if (!marker) return yield* Effect.die("background marker missing")
          yield* Scope.close(sourceScope, Exit.void)

          const scanCaptured = yield* Deferred.make<void>()
          const releaseScan = yield* Deferred.make<void>()
          const removeEntered = yield* Deferred.make<void>()
          const releaseRemove = yield* Deferred.make<void>()
          let scans = 0
          const jobs = yield* Job.make.pipe(
            Effect.provideService(
              KV.Service,
              KV.Service.of({
                ...kv,
                scan: (options) =>
                  Effect.gen(function* () {
                    const result = yield* kv.scan(options)
                    scans++
                    if ((mode === "invalidate" && scans === 2) || (mode === "acknowledge" && scans === 1)) {
                      yield* Deferred.succeed(scanCaptured, undefined)
                      yield* Deferred.await(releaseScan)
                    }
                    return result
                  }),
                remove: (key) =>
                  mode === "invalidate"
                    ? Deferred.succeed(removeEntered, undefined).pipe(
                        Effect.andThen(Deferred.await(releaseRemove)),
                        Effect.andThen(kv.remove(key)),
                      )
                    : kv.remove(key),
              }),
            ),
          )

          if (mode === "invalidate") {
            const invalidating = yield* jobs
              .invalidateCausal({ origins: [origin] })
              .pipe(Effect.forkScoped({ startImmediately: true }))
            yield* Deferred.await(removeEntered)
            const revoking = yield* jobs.revokeOrigins([origin]).pipe(Effect.forkScoped({ startImmediately: true }))
            yield* Effect.yieldNow
            expect(yield* Deferred.isDone(scanCaptured)).toBe(false)
            yield* Deferred.succeed(releaseRemove, undefined)
            yield* Fiber.join(invalidating)
            yield* Deferred.await(scanCaptured)
            yield* Deferred.succeed(releaseScan, undefined)
            yield* Fiber.join(revoking)
          } else {
            const revoking = yield* jobs.revokeOrigins([origin]).pipe(Effect.forkScoped({ startImmediately: true }))
            yield* Deferred.await(scanCaptured)
            const acknowledging = yield* jobs
              .completeBackground(marker.notificationID)
              .pipe(Effect.forkScoped({ startImmediately: true }))
            yield* Effect.yieldNow
            expect(acknowledging.pollUnsafe()).toBeUndefined()
            yield* Deferred.succeed(releaseScan, undefined)
            yield* Fiber.join(revoking)
            yield* Fiber.join(acknowledging)
          }

          const rebuilt = yield* Job.make
          expect(
            (yield* rebuilt.pendingBackground).find((job) => job.notificationID === marker.notificationID),
          ).toBeUndefined()
        }),
        { discard: true },
      )
    }),
  )
})
