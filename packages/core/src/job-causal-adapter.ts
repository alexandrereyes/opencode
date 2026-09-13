export * as JobCausalAdapter from "./job-causal-adapter.js"

import { Effect, SynchronizedRef } from "effect"
import { JobCausal } from "./job-causal.js"
import type { SessionMessage } from "./session/message.js"

type JobInfo = JobCausal.Generation & {
  readonly notificationID?: SessionMessage.ID
  readonly origins: readonly JobCausal.Origin[]
}

type ActiveShape<Info extends JobInfo, Recovery extends JobCausal.Candidate["recovery"]> = {
  readonly info: Omit<Info, "origins">
  readonly isBackgrounded: boolean
  readonly recovery?: Recovery
  readonly origins: Map<string, JobCausal.Origin>
}

export function make<
  Info extends JobInfo,
  Recovery extends JobCausal.Candidate["recovery"],
  Active extends ActiveShape<Info, Recovery>,
  Persisted extends JobCausal.Candidate & { readonly notificationID: SessionMessage.ID },
>(
  state: ReturnType<typeof JobCausal.make>,
  input: {
    readonly jobs: SynchronizedRef.SynchronizedRef<Map<string, Active>>
    readonly replaceOrigins: (job: Active, origins: Map<string, JobCausal.Origin>) => Active
    readonly persistBackground: (job: Active) => Effect.Effect<void>
    readonly pending: Effect.Effect<readonly Persisted[]>
    readonly removeNotification: (notificationID: SessionMessage.ID) => Effect.Effect<void>
    readonly writeBackground: (background: Persisted) => Effect.Effect<void>
    readonly cancel: (generation: JobCausal.Generation) => Effect.Effect<Info | undefined>
  },
) {
  return JobCausal.operations(state, {
    withRegistry: (operation) =>
      SynchronizedRef.modifyEffect(
        input.jobs,
        Effect.fnUntraced(function* (jobs) {
          const next = new Map(jobs)
          const value = yield* operation({
            active: [...jobs.values()].map((job) => ({
              id: job.info.id,
              generation: job.info.generation,
              origins: [...job.origins.values()],
              recovery: job.recovery,
              notificationID: job.info.notificationID,
              isBackgrounded: job.isBackgrounded,
            })),
            replaceOrigins: Effect.fnUntraced(function* (update) {
              const job = next.get(update.id)
              if (!job || job.info.generation !== update.generation) return
              const changed = input.replaceOrigins(
                job,
                new Map(update.origins.map((origin) => [JobCausal.originKey(origin), origin] as const)),
              )
              next.set(update.id, changed)
              if (changed.isBackgrounded) yield* input.persistBackground(changed)
            }),
          })
          return [value, next] as const
        }),
      ),
    pending: input.pending,
    removeNotification: input.removeNotification,
    writeBackground: input.writeBackground,
    cancel: input.cancel,
    currentOrigins: Effect.fnUntraced(function* (generation) {
      const current = (yield* SynchronizedRef.get(input.jobs)).get(generation.id)
      if (current?.info.generation !== generation.generation) return undefined
      return [...current.origins.values()]
    }),
  })
}
