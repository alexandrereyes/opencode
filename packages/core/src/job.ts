export * as Job from "./job.js"

import {
  Array,
  Cause,
  Clock,
  Context,
  Deferred,
  Effect,
  Exit,
  Layer,
  Schema,
  Scope,
  Semaphore,
  SynchronizedRef,
} from "effect"
import { makeGlobalNode } from "@opencode/util/effect/app-node"
import { Identifier } from "./id/id.js"
import { KV } from "./kv.js"
import { SessionMessage } from "./session/message.js"
import { SessionSchema } from "./session/schema.js"
import { Maintenance } from "./maintenance.js"
import { CausalRevert } from "@opencode/schema/causal-revert"

export const Origin = CausalRevert.Origin
export type Origin = CausalRevert.Origin

const Background = Schema.Struct({
  id: Schema.String,
  started_at: Schema.optionalKey(Schema.Number),
  generation: Schema.optionalKey(Schema.String),
  notificationID: SessionMessage.ID,
  origins: Schema.optionalKey(Schema.Array(Origin)),
  recovery: Schema.Union([
    Schema.Struct({
      kind: Schema.Literal("shell"),
      sessionID: SessionSchema.ID,
      shellID: Schema.String,
      command: Schema.String,
    }),
    Schema.Struct({
      kind: Schema.Literal("subagent"),
      parentSessionID: SessionSchema.ID,
      childSessionID: SessionSchema.ID,
      agent: Schema.String,
      description: Schema.String,
    }),
  ]),
  status: Schema.Literals(["running", "completed", "error", "cancelled"]),
  output: Schema.optionalKey(Schema.String),
  error: Schema.optionalKey(Schema.String),
})

export type Background = typeof Background.Type
export type Recovery = Background["recovery"]
export type Status = Background["status"]

const decodeBackground = Schema.decodeUnknownResult(Background)
const backgroundPrefix = "job.background/"

export type Info = {
  id: string
  type: string
  title?: string
  status: Status
  started_at: number
  generation: string
  completed_at?: number
  output?: string
  error?: string
  metadata?: Record<string, unknown>
  notificationID?: SessionMessage.ID
  origins: readonly Origin[]
}

type Active = {
  info: Omit<Info, "origins">
  done: Deferred.Deferred<Info>
  backgrounded: Deferred.Deferred<Info>
  scope: Scope.Closeable
  blockingSessions: Map<SessionSchema.ID, number>
  isBackgrounded: boolean
  recovery?: Recovery
  origins: Map<string, Origin>
}

type State = {
  jobs: SynchronizedRef.SynchronizedRef<Map<string, Active>>
  scope: Scope.Scope
}

type FinishResult = {
  info?: Info
  done?: Deferred.Deferred<Info>
  scope?: Scope.Closeable
}

type BackgroundResult = {
  info?: Info
  backgrounded?: Deferred.Deferred<Info>
}

type StartResult =
  | { type: "existing"; info: Info }
  | { type: "started"; info: Info; scope: Scope.Closeable }
  | { type: "invalid"; info: Info }

type BlockWait = {
  done: Deferred.Deferred<Info>
  backgrounded: Deferred.Deferred<Info>
}

type BlockStart =
  | { type: "missing" }
  | { type: "finished"; info: Info }
  | { type: "backgrounded"; info: Info }
  | { type: "wait"; wait: BlockWait }

export type StartInput = {
  id?: string
  type: string
  title?: string
  metadata?: Record<string, unknown>
  recovery?: Recovery
  notificationID?: SessionMessage.ID
  origins?: readonly Origin[]
  onInvalid?: Effect.Effect<void>
  run: Effect.Effect<string, unknown>
}

export type Generation = Pick<Info, "id" | "generation">
export type Validity = Generation & { origins?: readonly Origin[] }

export type CausalInput = {
  origins?: readonly Origin[]
  interruptSessionIDs?: readonly SessionSchema.ID[]
  discardedSessionIDs?: readonly SessionSchema.ID[]
}

export type CausalPlan = {
  jobs: readonly Generation[]
  interruptSessionIDs: readonly SessionSchema.ID[]
}

export type WaitInput = {
  id: string
  generation?: string
  timeout?: number
}

export type WaitResult = {
  info?: Info
  timedOut: boolean
}

export type BlockInput = {
  id: string
  sessionID: SessionSchema.ID
}

export type BlockResult = { type: "finished"; info: Info } | { type: "backgrounded"; info: Info }

export type BackgroundAllInput = {
  sessionID: SessionSchema.ID
  type?: string
}

export interface Interface {
  readonly get: (id: string) => Effect.Effect<Info | undefined>
  readonly start: (input: StartInput) => Effect.Effect<Info>
  readonly wait: (input: WaitInput) => Effect.Effect<WaitResult>
  readonly block: (input: BlockInput) => Effect.Effect<BlockResult | undefined>
  readonly background: (id: string) => Effect.Effect<Info | undefined>
  readonly backgroundAll: (input: BackgroundAllInput) => Effect.Effect<Info[]>
  readonly cancel: (id: string) => Effect.Effect<Info | undefined>
  readonly invalidateCausal: (input: CausalInput) => Effect.Effect<CausalPlan>
  readonly revokeOrigins: (origins: readonly Origin[]) => Effect.Effect<void>
  readonly cancelCausal: (plan: CausalPlan) => Effect.Effect<Info[]>
  readonly isValid: (generation: Validity) => Effect.Effect<boolean>
  readonly guard: <A, E, R>(generation: Validity, effect: Effect.Effect<A, E, R>) => Effect.Effect<A | undefined, E, R>
  readonly pendingBackground: Effect.Effect<readonly Background[]>
  readonly completeBackground: (notificationID: SessionMessage.ID) => Effect.Effect<void>
}

export class Service extends Context.Service<Service, Interface>()("@opencode/Job") {}

function snapshot(job: Active): Info {
  return {
    ...job.info,
    origins: [...job.origins.values()],
    ...(job.info.metadata ? { metadata: { ...job.info.metadata } } : {}),
  }
}

function originKey(origin: Origin) {
  return `${origin.parentSessionID}\u0000${origin.messageID}\u0000${origin.toolCallID}`
}

function generationKey(generation: Generation) {
  return `${generation.id}\u0000${generation.generation}`
}

function owningSession(recovery: Recovery) {
  return recovery.kind === "shell" ? recovery.sessionID : recovery.parentSessionID
}

function errorText(error: unknown) {
  if (error instanceof Error) return error.message
  return String(error)
}

function incrementSession(input: Map<SessionSchema.ID, number>, sessionID: SessionSchema.ID) {
  return new Map(input).set(sessionID, (input.get(sessionID) ?? 0) + 1)
}

function decrementSession(input: Map<SessionSchema.ID, number>, sessionID: SessionSchema.ID) {
  const count = input.get(sessionID)
  if (count === undefined) return input
  const next = new Map(input)
  if (count <= 1) next.delete(sessionID)
  else next.set(sessionID, count - 1)
  return next
}

/**
 * Makes one scoped, process-local registry. Explicitly recoverable background
 * work also owns a durable notification marker until its notification is admitted.
 */
export const make = Effect.gen(function* () {
  const kv = yield* KV.Service
  const activeScopes = new Set<Scope.Closeable>()
  const invalidOrigins = new Set<string>()
  const revokedOrigins = new Set<string>()
  const invalidGenerations = new Set<string>()
  const notificationLock = Semaphore.makeUnsafe(1)
  yield* Maintenance.process.block(() => activeScopes.size > 0)
  const state: State = {
    jobs: yield* SynchronizedRef.make(new Map()),
    scope: yield* Scope.Scope,
  }

  const persistBackground = Effect.fnUntraced(function* (job: Active) {
    if (!job.recovery || !job.info.notificationID) return
    if (
      invalidGenerations.has(generationKey(job.info)) ||
      [...job.origins.values()].some((origin) => invalidOrigins.has(originKey(origin)))
    ) {
      yield* kv.remove(`${backgroundPrefix}${job.info.notificationID}`)
      return
    }
    yield* kv.set(`${backgroundPrefix}${job.info.notificationID}`, {
      id: job.info.id,
      started_at: job.info.started_at,
      generation: job.info.generation,
      notificationID: job.info.notificationID,
      origins: [...job.origins.values()],
      recovery: job.recovery,
      status: job.info.status,
      ...(job.info.output !== undefined ? { output: job.info.output } : {}),
      ...(job.info.error !== undefined ? { error: job.info.error } : {}),
    })
  })

  const settle = Effect.fnUntraced(function* (id: string, scope: Scope.Closeable, exit: Exit.Exit<string, unknown>) {
    const completed_at = yield* Clock.currentTimeMillis
    const result = yield* SynchronizedRef.modifyEffect(
      state.jobs,
      Effect.fnUntraced(function* (jobs): Effect.fn.Return<readonly [FinishResult, Map<string, Active>]> {
        const job = jobs.get(id)
        if (!job) return [{}, jobs]
        if (job.scope !== scope) return [{}, jobs]
        if (job.info.status !== "running") return [{ info: snapshot(job) }, jobs]
        const status: Exclude<Status, "running"> = Exit.isSuccess(exit)
          ? "completed"
          : Cause.hasInterruptsOnly(exit.cause)
            ? "cancelled"
            : "error"
        const next = {
          ...job,
          blockingSessions: new Map<SessionSchema.ID, number>(),
          info: {
            ...job.info,
            status,
            completed_at,
            ...(Exit.isSuccess(exit) ? { output: exit.value } : {}),
            ...(Exit.isFailure(exit) ? { error: errorText(Cause.squash(exit.cause)) } : {}),
          },
        }
        if (status !== "cancelled") yield* persistBackground(next)
        return [{ info: snapshot(next), done: job.done, scope: job.scope }, new Map(jobs).set(id, next)]
      }),
    )
    if (result.info && result.done) yield* Deferred.succeed(result.done, result.info)
    if (result.scope) {
      const scope = result.scope
      yield* Scope.close(scope, Exit.void).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            activeScopes.delete(scope)
          }),
        ),
        Effect.forkIn(state.scope, { startImmediately: true }),
      )
    }
    return result.info
  })

  const get: Interface["get"] = Effect.fn("Job.get")(function* (id) {
    const job = (yield* SynchronizedRef.get(state.jobs)).get(id)
    if (!job) return undefined
    return snapshot(job)
  })

  const start: Interface["start"] = Effect.fnUntraced(function* (input) {
    return yield* Effect.uninterruptibleMask((restore) =>
      Effect.gen(function* () {
        const id = input.id ?? Identifier.ascending("job")
        const started_at = yield* Clock.currentTimeMillis
        const generation = Identifier.create("jobgen", "ascending")
        const done = yield* Deferred.make<Info>()
        const backgrounded = yield* Deferred.make<Info>()
        const result = yield* SynchronizedRef.modifyEffect(
          state.jobs,
          Effect.fnUntraced(function* (jobs): Effect.fn.Return<readonly [StartResult, Map<string, Active>]> {
            const origins = input.origins ?? []
            const existing = jobs.get(id)
            if (origins.some((origin) => [invalidOrigins, revokedOrigins].some((set) => set.has(originKey(origin))))) {
              const completed_at = yield* Clock.currentTimeMillis
              const info = {
                id,
                type: input.type,
                title: input.title,
                status: "cancelled" as const,
                started_at,
                generation,
                completed_at,
                metadata: input.metadata,
                origins,
              }
              invalidGenerations.add(generationKey(info))
              return [{ type: "invalid", info }, jobs]
            }
            if (existing?.info.status === "running") {
              const next = {
                ...existing,
                origins: new Map([
                  ...existing.origins,
                  ...origins.map((origin) => [originKey(origin), origin] as const),
                ]),
              }
              if (next.origins.size === existing.origins.size)
                return [{ type: "existing", info: snapshot(existing) }, jobs]
              if (next.isBackgrounded) yield* persistBackground(next)
              return [{ type: "existing", info: snapshot(next) }, new Map(jobs).set(id, next)]
            }
            const scope = yield* Scope.fork(state.scope, "parallel")
            activeScopes.add(scope)
            const job = {
              info: {
                id,
                type: input.type,
                title: input.title,
                status: "running" as const,
                started_at,
                generation,
                metadata: input.metadata,
                ...(input.notificationID ? { notificationID: input.notificationID } : {}),
              },
              done,
              backgrounded,
              scope,
              blockingSessions: new Map<SessionSchema.ID, number>(),
              isBackgrounded: false,
              recovery: input.recovery,
              origins: new Map(origins.map((origin) => [originKey(origin), origin] as const)),
            }
            return [{ type: "started", info: snapshot(job), scope }, new Map(jobs).set(id, job)]
          }),
        )
        if (result.type === "invalid") {
          if (input.onInvalid) yield* input.onInvalid
          return result.info
        }
        if (result.type === "started")
          yield* restore(input.run).pipe(
            Effect.exit,
            Effect.flatMap((exit) => settle(id, result.scope, exit)),
            Effect.asVoid,
            Maintenance.process.run,
            Effect.forkIn(result.scope, { startImmediately: true }),
          )
        return result.info
      }),
    )
  })

  const wait: Interface["wait"] = Effect.fn("Job.wait")(function* (input) {
    const job = (yield* SynchronizedRef.get(state.jobs)).get(input.id)
    if (!job) return { timedOut: false }
    if (input.generation !== undefined && job.info.generation !== input.generation) return { timedOut: false }
    if (job.info.status !== "running") return { info: snapshot(job), timedOut: false }
    if (input.timeout === undefined) return { info: yield* Deferred.await(job.done), timedOut: false }
    if (input.timeout <= 0) return { info: snapshot(job), timedOut: true }
    const info = yield* Deferred.await(job.done).pipe(Effect.timeoutOption(input.timeout))
    if (info._tag === "Some") return { info: info.value, timedOut: false }
    return { info: snapshot(job), timedOut: true }
  })

  const removeBlock = Effect.fnUntraced(function* (input: BlockInput) {
    yield* SynchronizedRef.update(state.jobs, (jobs) => {
      const job = jobs.get(input.id)
      if (!job || job.info.status !== "running" || job.isBackgrounded) return jobs
      return new Map(jobs).set(input.id, {
        ...job,
        blockingSessions: decrementSession(job.blockingSessions, input.sessionID),
      })
    })
  })

  const block: Interface["block"] = Effect.fnUntraced(function* (input) {
    const result = yield* SynchronizedRef.modify(state.jobs, (jobs): readonly [BlockStart, Map<string, Active>] => {
      const job = jobs.get(input.id)
      if (!job) return [{ type: "missing" }, jobs]
      if (job.info.status !== "running") return [{ type: "finished", info: snapshot(job) }, jobs]
      if (job.isBackgrounded) return [{ type: "backgrounded", info: snapshot(job) }, jobs]
      return [
        { type: "wait", wait: { done: job.done, backgrounded: job.backgrounded } },
        new Map(jobs).set(input.id, {
          ...job,
          blockingSessions: incrementSession(job.blockingSessions, input.sessionID),
        }),
      ]
    })
    if (result.type === "missing") return undefined
    if (result.type === "finished") return { type: "finished", info: result.info }
    if (result.type === "backgrounded") return { type: "backgrounded", info: result.info }
    return yield* Effect.raceFirst(
      Deferred.await(result.wait.done).pipe(Effect.map((info) => ({ type: "finished" as const, info }))),
      Deferred.await(result.wait.backgrounded).pipe(Effect.map((info) => ({ type: "backgrounded" as const, info }))),
    ).pipe(Effect.ensuring(removeBlock(input)))
  })

  const markBackground = Effect.fnUntraced(function* (job: Active) {
    const next = {
      ...job,
      isBackgrounded: true,
      blockingSessions: new Map<SessionSchema.ID, number>(),
      info: {
        ...job.info,
        ...(job.recovery ? { notificationID: job.info.notificationID ?? SessionMessage.ID.create() } : {}),
      },
    }
    yield* persistBackground(next)
    return next
  })

  const background: Interface["background"] = Effect.fn("Job.background")(function* (id) {
    const result = yield* SynchronizedRef.modifyEffect(
      state.jobs,
      Effect.fnUntraced(function* (jobs): Effect.fn.Return<readonly [BackgroundResult, Map<string, Active>]> {
        const job = jobs.get(id)
        // Recoverable work may finish before the caller backgrounds it.
        if (!job || (job.info.status !== "running" && !job.recovery)) return [{}, jobs]
        if (job.isBackgrounded) return [{ info: snapshot(job) }, jobs]
        const next = yield* markBackground(job)
        return [{ info: snapshot(next), backgrounded: job.backgrounded }, new Map(jobs).set(id, next)]
      }),
    )
    if (result.info && result.backgrounded) yield* Deferred.succeed(result.backgrounded, result.info)
    return result.info
  })

  const backgroundAll: Interface["backgroundAll"] = Effect.fn("Job.backgroundAll")(function* (input) {
    const result = yield* SynchronizedRef.modifyEffect(
      state.jobs,
      Effect.fnUntraced(function* (jobs): Effect.fn.Return<
        readonly [Required<BackgroundResult>[], Map<string, Active>]
      > {
        const results: Required<BackgroundResult>[] = []
        const next = new Map(jobs)
        for (const [id, job] of jobs) {
          if (job.info.status !== "running") continue
          if (job.isBackgrounded) continue
          if (input.type !== undefined && job.info.type !== input.type) continue
          if (!job.blockingSessions.has(input.sessionID)) continue
          const updated = yield* markBackground(job)
          results.push({ info: snapshot(updated), backgrounded: job.backgrounded })
          next.set(id, updated)
        }
        return [results, next]
      }),
    )
    yield* Effect.forEach(result, (item) => Deferred.succeed(item.backgrounded, item.info), { discard: true })
    return result.map((item) => item.info)
  })

  const cancelGeneration = Effect.fnUntraced(function* (id: string, expected?: string) {
    const completed_at = yield* Clock.currentTimeMillis
    const result = yield* SynchronizedRef.modifyEffect(
      state.jobs,
      Effect.fnUntraced(function* (jobs): Effect.fn.Return<readonly [FinishResult, Map<string, Active>]> {
        const job = jobs.get(id)
        if (!job) return [{}, jobs]
        if (expected !== undefined && job.info.generation !== expected) return [{}, jobs]
        if (job.info.status !== "running") return [{ info: snapshot(job) }, jobs]
        const next = {
          ...job,
          blockingSessions: new Map<SessionSchema.ID, number>(),
          info: {
            ...job.info,
            status: "cancelled" as const,
            completed_at,
          },
        }
        yield* persistBackground(next)
        return [{ info: snapshot(next), done: job.done, scope: job.scope }, new Map(jobs).set(id, next)]
      }),
    )
    if (result.info && result.done) yield* Deferred.succeed(result.done, result.info)
    if (result.scope) {
      const scope = result.scope
      yield* Scope.close(scope, Exit.void).pipe(
        Effect.ensuring(
          Effect.sync(() => {
            activeScopes.delete(scope)
          }),
        ),
      )
    }
    return result.info
  })

  const cancel: Interface["cancel"] = Effect.fn("Job.cancel")((id) => cancelGeneration(id))

  const invalidateCausal: Interface["invalidateCausal"] = Effect.fn("Job.invalidateCausal")(function* (input) {
    return yield* notificationLock.withPermit(
      Effect.gen(function* () {
        const selected = yield* SynchronizedRef.modifyEffect(
          state.jobs,
          Effect.fnUntraced(function* (active) {
            input.origins?.forEach((origin) => invalidOrigins.add(originKey(origin)))
            const persisted = yield* pendingBackground
            const candidates = [
              ...[...active.values()].map((job) => ({
                id: job.info.id,
                generation: job.info.generation,
                origins: [...job.origins.values()],
                recovery: job.recovery,
                notificationID: job.info.notificationID,
              })),
              ...persisted.map((job) => ({
                id: job.id,
                generation: job.generation ?? job.notificationID,
                origins: job.origins ?? [],
                recovery: job.recovery,
                notificationID: job.notificationID,
              })),
            ]
            const discardedSessions = new Set(input.discardedSessionIDs ?? [])
            const interruptSessions = new Set([...(input.interruptSessionIDs ?? []), ...discardedSessions])
            const jobs = new Map<string, (typeof candidates)[number]>()
            const visit = (): void => {
              const found = candidates.filter((job) => {
                if (jobs.has(generationKey(job))) return false
                if (job.origins.some((origin) => invalidOrigins.has(originKey(origin)))) return true
                return job.recovery ? discardedSessions.has(owningSession(job.recovery)) : false
              })
              if (found.length === 0) return
              found.forEach((job) => {
                jobs.set(generationKey(job), job)
                invalidGenerations.add(generationKey(job))
                if (job.recovery?.kind !== "subagent") return
                interruptSessions.add(job.recovery.childSessionID)
                if (discardedSessions.has(job.recovery.parentSessionID))
                  discardedSessions.add(job.recovery.childSessionID)
              })
              visit()
            }
            visit()
            yield* Effect.forEach(
              [...jobs.values()].flatMap((job) => (job.notificationID ? [job.notificationID] : [])),
              (notificationID) => kv.remove(`${backgroundPrefix}${notificationID}`),
              { discard: true },
            )
            return [
              {
                jobs: [...jobs.values()].map((job) => ({ id: job.id, generation: job.generation })),
                interruptSessionIDs: [...interruptSessions],
              },
              active,
            ] as const
          }),
        )
        return selected
      }),
    )
  })

  const revokeOrigins: Interface["revokeOrigins"] = Effect.fn("Job.revokeOrigins")(function* (origins) {
    const revoked = new Set(origins.map(originKey))
    yield* SynchronizedRef.modifyEffect(
      state.jobs,
      Effect.fnUntraced(function* (jobs) {
        revoked.forEach((origin) => revokedOrigins.add(origin))
        const next = new Map(jobs)
        yield* Effect.forEach(
          [...jobs.entries()],
          Effect.fnUntraced(function* ([id, job]) {
            const retained = [...job.origins].filter(([key]) => !revoked.has(key))
            if (retained.length === job.origins.size) return
            const updated = { ...job, origins: new Map(retained) }
            next.set(id, updated)
            if (updated.isBackgrounded) yield* persistBackground(updated)
          }),
          { discard: true },
        )
        const activeNotifications = new Set(
          [...next.values()].flatMap((job) => (job.info.notificationID ? [job.info.notificationID] : [])),
        )
        yield* Effect.forEach(
          (yield* pendingBackground).filter((job) => !activeNotifications.has(job.notificationID)),
          (job) =>
            kv.set(`${backgroundPrefix}${job.notificationID}`, {
              ...job,
              origins: (job.origins ?? []).filter((origin) => !revoked.has(originKey(origin))),
            }),
          { discard: true },
        )
        return [undefined, next] as const
      }),
    )
  })

  const cancelCausal: Interface["cancelCausal"] = Effect.fn("Job.cancelCausal")(function* (plan) {
    return yield* Effect.forEach(plan.jobs, (generation) => cancelGeneration(generation.id, generation.generation), {
      concurrency: "unbounded",
    }).pipe(Effect.map((results) => results.filter((info): info is Info => info !== undefined)))
  })

  const valid = Effect.fnUntraced(function* (generation: Validity) {
    if (invalidGenerations.has(generationKey(generation))) return false
    const current = (yield* SynchronizedRef.get(state.jobs)).get(generation.id)
    const origins =
      current?.info.generation === generation.generation ? [...current.origins.values()] : generation.origins
    return !origins?.some((origin) => invalidOrigins.has(originKey(origin)))
  })

  const isValid: Interface["isValid"] = Effect.fn("Job.isValid")(valid)

  const guard: Interface["guard"] = (generation, effect) =>
    notificationLock.withPermit(
      valid(generation).pipe(Effect.flatMap((valid) => (valid ? effect : Effect.succeed(undefined)))),
    )

  const pendingBackground: Interface["pendingBackground"] = Effect.gen(function* () {
    const recovered: Background[] = []
    let after: string | undefined
    do {
      const page = yield* kv.scan({ prefix: backgroundPrefix, after })
      recovered.push(...Array.filterMap(page.entries, (entry) => decodeBackground(entry.value)))
      after = page.next
    } while (after)
    return recovered
  }).pipe(Effect.withSpan("Job.pendingBackground"))

  const completeBackground: Interface["completeBackground"] = Effect.fn("Job.completeBackground")((notificationID) =>
    SynchronizedRef.modifyEffect(state.jobs, (jobs) =>
      kv.remove(`${backgroundPrefix}${notificationID}`).pipe(Effect.as([undefined, jobs] as const)),
    ),
  )

  return Service.of({
    get,
    start: (input) => Maintenance.process.run(start(input)),
    wait,
    block,
    background,
    backgroundAll,
    cancel,
    invalidateCausal,
    revokeOrigins,
    cancelCausal,
    isValid,
    guard,
    pendingBackground,
    completeBackground,
  })
})

const layer = Layer.effect(Service, make)

export const node = makeGlobalNode({ service: Service, layer, deps: [KV.node] })
