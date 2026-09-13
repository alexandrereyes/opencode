export * as JobCausal from "./job-causal.js"

import { CausalRevert } from "@opencode/schema/causal-revert"
import { Clock, Effect, Semaphore } from "effect"
import type { SessionMessage } from "./session/message.js"
import type { SessionSchema } from "./session/schema.js"

export const Origin = CausalRevert.Origin
export type Origin = CausalRevert.Origin

export type Generation = {
  readonly id: string
  readonly generation: string
}

export type Validity = Generation & { readonly origins?: readonly Origin[] }

export type Input = {
  readonly origins?: readonly Origin[]
  readonly interruptSessionIDs?: readonly SessionSchema.ID[]
  readonly discardedSessionIDs?: readonly SessionSchema.ID[]
}

export type Plan = {
  readonly jobs: readonly Generation[]
  readonly interruptSessionIDs: readonly SessionSchema.ID[]
}

export type Candidate = Generation & {
  readonly origins: readonly Origin[]
  readonly notificationID?: SessionMessage.ID
  readonly recovery?:
    | { readonly kind: "shell"; readonly sessionID: SessionSchema.ID }
    | {
        readonly kind: "subagent"
        readonly parentSessionID: SessionSchema.ID
        readonly childSessionID: SessionSchema.ID
      }
}

export type Active = Candidate & { readonly isBackgrounded: boolean }

export interface Registry {
  readonly active: readonly Active[]
  readonly replaceOrigins: (input: Generation & { readonly origins: readonly Origin[] }) => Effect.Effect<void>
}

export interface Adapter<Info, Persisted extends Candidate & { readonly notificationID: SessionMessage.ID }> {
  readonly withRegistry: <A>(operation: (registry: Registry) => Effect.Effect<A>) => Effect.Effect<A>
  readonly pending: Effect.Effect<readonly Persisted[]>
  readonly removeNotification: (notificationID: SessionMessage.ID) => Effect.Effect<void>
  readonly writeBackground: (background: Persisted) => Effect.Effect<void>
  readonly cancel: (generation: Generation) => Effect.Effect<Info | undefined>
  readonly currentOrigins: (generation: Generation) => Effect.Effect<readonly Origin[] | undefined>
}

export function make() {
  const invalidOrigins = new Set<string>()
  const revokedOrigins = new Set<string>()
  const invalidGenerations = new Set<string>()

  const accepts = (origins: readonly Origin[]) =>
    !origins.some((origin) => [invalidOrigins, revokedOrigins].some((set) => set.has(originKey(origin))))

  const validGeneration = (generation: Generation) => !invalidGenerations.has(generationKey(generation))
  const validOrigins = (origins: readonly Origin[]) =>
    !origins.some((origin) => invalidOrigins.has(originKey(origin)))
  const persists = (generation: Generation, origins: readonly Origin[]) =>
    validGeneration(generation) && validOrigins(origins)

  const invalidateOrigins = (origins: readonly Origin[]) =>
    origins.forEach((origin) => invalidOrigins.add(originKey(origin)))

  const invalidate = (input: Input, candidates: readonly Candidate[]): Plan => {
    const discardedSessions = new Set(input.discardedSessionIDs ?? [])
    const interruptSessions = new Set([...(input.interruptSessionIDs ?? []), ...discardedSessions])
    const jobs = new Map<string, Candidate>()
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
        if (discardedSessions.has(job.recovery.parentSessionID)) discardedSessions.add(job.recovery.childSessionID)
      })
      visit()
    }
    visit()
    return {
      jobs: [...jobs.values()].map((job) => ({ id: job.id, generation: job.generation })),
      interruptSessionIDs: [...interruptSessions],
    }
  }

  return {
    accepts,
    persists,
    validGeneration,
    validOrigins,
    invalidateOrigins,
    invalidate,
    rejectStart(input: {
      readonly id: string
      readonly type: string
      readonly title?: string
      readonly started_at: number
      readonly generation: string
      readonly metadata?: Record<string, unknown>
      readonly origins: readonly Origin[]
    }) {
      return Clock.currentTimeMillis.pipe(
        Effect.map((completed_at) => ({ ...input, status: "cancelled" as const, completed_at })),
        Effect.tap((info) => Effect.sync(() => invalidGenerations.add(generationKey(info)))),
      )
    },
    revoke(origins: readonly Origin[]) {
      const revoked = new Set(origins.map(originKey))
      revoked.forEach((origin) => revokedOrigins.add(origin))
      return revoked
    },
  }
}

export function operations<Info, Persisted extends Candidate & { readonly notificationID: SessionMessage.ID }>(
  state: ReturnType<typeof make>,
  adapter: Adapter<Info, Persisted>,
) {
  const notificationLock = Semaphore.makeUnsafe(1)
  const invalidateCausal = (input: Input) =>
    notificationLock.withPermit(
      adapter.withRegistry((registry) =>
        Effect.gen(function* () {
          // Linearization point: registrations with these origins are rejected before the durable scan can yield.
          state.invalidateOrigins(input.origins ?? [])
          const candidates = [...registry.active, ...(yield* adapter.pending)]
          const plan = state.invalidate(input, candidates)
          const selected = new Set(plan.jobs.map(generationKey))
          yield* Effect.forEach(
            candidates.flatMap((job) =>
              selected.has(generationKey(job)) && job.notificationID ? [job.notificationID] : [],
            ),
            adapter.removeNotification,
            { discard: true },
          )
          return plan
        }),
      ),
    )

  const revokeOrigins = (origins: readonly Origin[]) =>
    adapter.withRegistry((registry) =>
      Effect.gen(function* () {
        // Linearization point remains inside the registry lock, before active or durable origins are rewritten.
        const revoked = state.revoke(origins)
        yield* Effect.forEach(
          registry.active,
          (job) => {
            const retained = job.origins.filter((origin) => !revoked.has(originKey(origin)))
            if (retained.length === job.origins.length) return Effect.void
            return registry.replaceOrigins({ ...job, origins: retained })
          },
          { discard: true },
        )
        const activeNotifications = new Set(
          registry.active.flatMap((job) => (job.notificationID ? [job.notificationID] : [])),
        )
        yield* Effect.forEach(
          (yield* adapter.pending).filter((job) => !activeNotifications.has(job.notificationID)),
          (job) =>
            adapter.writeBackground({
              ...job,
              origins: job.origins.filter((origin) => !revoked.has(originKey(origin))),
            }),
          { discard: true },
        )
      }),
    )

  const cancelCausal = (plan: Plan) =>
    Effect.forEach(plan.jobs, adapter.cancel, { concurrency: "unbounded" }).pipe(
      Effect.map((results) => results.filter((info): info is Info => info !== undefined)),
    )

  const isValid = Effect.fnUntraced(function* (generation: Validity) {
    if (!state.validGeneration(generation)) return false
    return state.validOrigins((yield* adapter.currentOrigins(generation)) ?? generation.origins ?? [])
  })

  return {
    invalidateCausal,
    revokeOrigins,
    cancelCausal,
    isValid,
    guard: <A, E, R>(generation: Validity, effect: Effect.Effect<A, E, R>) =>
      notificationLock.withPermit(
        isValid(generation).pipe(Effect.flatMap((valid) => (valid ? effect : Effect.succeed(undefined)))),
      ),
  }
}

export function originKey(origin: Origin) {
  return `${origin.parentSessionID}\u0000${origin.messageID}\u0000${origin.toolCallID}`
}

export function generationKey(generation: Generation) {
  return `${generation.id}\u0000${generation.generation}`
}

function owningSession(recovery: NonNullable<Candidate["recovery"]>) {
  return recovery.kind === "shell" ? recovery.sessionID : recovery.parentSessionID
}
