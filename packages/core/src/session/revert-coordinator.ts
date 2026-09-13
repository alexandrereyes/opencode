export * as SessionRevertCoordinator from "./revert-coordinator.js"

import { Effect, Option } from "effect"
import { Bus } from "../bus.js"
import { Database } from "../database/database.js"
import { Instance } from "../instance/service.js"
import type { Job } from "../job.js"
import { Snapshot } from "../snapshot.js"
import { BusyError, MessageNotFoundError, NotFoundError } from "./error.js"
import type { SessionExecution } from "./execution.js"
import { SessionInbox } from "./inbox.js"
import { SessionMessage } from "./message.js"
import { SessionRevert } from "./revert.js"
import { SessionRevertPlan } from "./revert-plan.js"
import { SessionSchema } from "./schema.js"

interface Services {
  readonly bus: Bus.Interface
  readonly database: Database.Interface
  readonly instances: Instance.Interface
  readonly execution: SessionExecution.Interface
  readonly jobs: Job.Interface
  readonly get: (sessionID: SessionSchema.ID) => Effect.Effect<SessionSchema.Info, NotFoundError>
}

export function make(services: Services) {
  const revertIntents = new Set<SessionSchema.ID>()

  const family = Effect.fnUntraced(function* (sessionIDs: readonly SessionSchema.ID[]) {
    const sessions = yield* Effect.forEach([...new Set(sessionIDs)], services.get)
    const ownerIDs = sessions.flatMap((session) => (session.revert?.parentID ? [session.revert.parentID] : []))
    const owners = yield* Effect.forEach([...new Set(ownerIDs)], services.get)
    const all = [...sessions, ...owners]
    return {
      sessions: all,
      ids: [
        ...new Set([
          ...all.map((session) => session.id),
          ...all.flatMap((session) => session.revert?.children?.map((child) => child.sessionID) ?? []),
        ]),
      ],
      owners: [
        ...new Map(
          all
            .filter((session) => session.revert && !session.revert.parentID)
            .map((session) => [session.id, session] as const),
        ).values(),
      ],
    }
  })

  const criticalFamily = <A, E, R>(
    sessionIDs: readonly SessionSchema.ID[],
    use: (current: Effect.Success<ReturnType<typeof family>>) => Effect.Effect<A, E, R>,
  ) =>
    Effect.gen(function* () {
      let locks = yield* family(sessionIDs)
      while (true) {
        const result = yield* SessionInbox.serializedAll(
          locks.ids,
          Effect.gen(function* () {
            const current = yield* family(sessionIDs)
            if (current.ids.some((id) => !locks.ids.includes(id))) return { type: "retry", family: current } as const
            return { type: "ready", value: yield* use(current) } as const
          }),
        )
        if (result.type === "ready") return result.value
        locks = result.family
      }
      return yield* Effect.die(new Error("Unreachable Session family critical state"))
    })

  const conflict = Effect.fnUntraced(function* (
    ownerID: SessionSchema.ID,
    plan: Effect.Success<ReturnType<typeof SessionRevertPlan.resolve>>,
  ) {
    const children = yield* Effect.forEach(plan.participants, (child) => services.get(child.sessionID))
    return children.find((child) => child.revert && child.revert.parentID !== ownerID)
  })

  const wakeIfReady = Effect.fnUntraced(function* (sessionID: SessionSchema.ID, resume: boolean) {
    if (!resume) return
    const session = yield* services.get(sessionID)
    if (session.revert) return
    if (revertIntents.has(sessionID)) return
    yield* services.execution.wake(sessionID)
  })

  const stage = Effect.fn("Session.revert.stage")(function* (
    sessionID: SessionSchema.ID,
    input: { messageID: SessionMessage.ID; files?: boolean },
  ): Effect.fn.Return<
    NonNullable<SessionSchema.Info["revert"]>,
    BusyError | MessageNotFoundError | NotFoundError | Snapshot.Error
  > {
    revertIntents.add(sessionID)
    return yield* Effect.gen(function* () {
      const initialSession = yield* services.get(sessionID)
      if (initialSession.revert?.parentID) return yield* new BusyError({ sessionID })
      if (yield* services.execution.isActive(sessionID)) return yield* new BusyError({ sessionID })
      const planner = yield* SessionRevertPlan.acquire(services.instances, initialSession)
      let facts = yield* SessionRevertPlan.load(
        services.database.db,
        { sessionID, messageID: input.messageID },
        { causal: Option.isSome(planner) },
      )
      let plan = yield* SessionRevertPlan.resolve(planner, facts)
      const initialConflict = yield* conflict(sessionID, plan)
      if (initialConflict) return yield* new BusyError({ sessionID: initialConflict.id })
      while (true) {
        const invalidated = yield* services.jobs.invalidateCausal({
          origins: plan.origins,
          interruptSessionIDs: plan.participants.flatMap((child) => (child.messageID ? [child.sessionID] : [])),
          discardedSessionIDs: plan.discardedSessionIDs,
        })
        if (yield* services.execution.isActive(sessionID))
          yield* services.execution
            .interrupt(sessionID, { awaitSettlement: true })
            .pipe(Effect.andThen(services.execution.awaitIdle(sessionID)))
        yield* Effect.forEach(
          invalidated.interruptSessionIDs,
          (childID) =>
            services.execution
              .interrupt(childID, { awaitSettlement: true })
              .pipe(Effect.andThen(services.execution.awaitIdle(childID))),
          { discard: true },
        )
        yield* services.jobs.cancelCausal(invalidated)
        const result = yield* SessionInbox.serializedAll(
          [sessionID, ...plan.participants.map((child) => child.sessionID)],
          Effect.gen(function* () {
            const session = yield* services.get(sessionID)
            if (session.revert?.parentID) return yield* new BusyError({ sessionID })
            const current = yield* SessionRevertPlan.load(
              services.database.db,
              {
                sessionID,
                messageID: input.messageID,
              },
              { causal: Option.isSome(planner) },
            )
            if (!SessionRevertPlan.same(current, facts)) return { type: "retry", facts: current } as const
            SessionRevertPlan.validate(current, plan)
            const planConflict = yield* conflict(sessionID, plan)
            if (planConflict) return yield* new BusyError({ sessionID: planConflict.id })
            const active = (yield* Effect.forEach(
              plan.participants.filter((child) => child.messageID),
              (child) => services.execution.isActive(child.sessionID),
            )).some(Boolean)
            if ((yield* services.execution.isActive(sessionID)) || active)
              return { type: "retry", facts: current } as const
            yield* services.jobs.revokeOrigins(plan.pendingOrigins)
            return {
              type: "ready",
              revert: yield* SessionRevert.stage({
                session,
                messageID: input.messageID,
                files: input.files,
                children: plan.participants,
              }).pipe(
                Effect.provideService(Instance.Service, services.instances),
                Effect.provideService(Database.Service, services.database),
                Effect.provideService(Bus.Service, services.bus),
              ),
            } as const
          }),
        )
        if (result.type === "ready") return result.revert
        facts = result.facts
        plan = yield* SessionRevertPlan.resolve(planner, facts)
      }
      return yield* Effect.die(new Error("Unreachable causal stage state"))
    }).pipe(Effect.ensuring(Effect.sync(() => revertIntents.delete(sessionID))))
  })

  const clear = Effect.fn("Session.revert.clear")(function* (sessionID: SessionSchema.ID) {
    const session = yield* services.get(sessionID)
    if (yield* services.execution.isActive(sessionID)) return yield* new BusyError({ sessionID })
    const cleared = yield* criticalFamily([sessionID], (current) =>
      Effect.gen(function* () {
        const target = current.sessions.find((item) => item.id === sessionID) ?? session
        const owner = current.owners[0] ?? target
        if (yield* services.execution.isActive(owner.id)) return yield* new BusyError({ sessionID: owner.id })
        yield* SessionRevert.clear(owner).pipe(
          Effect.provideService(Instance.Service, services.instances),
          Effect.provideService(Bus.Service, services.bus),
        )
        return { wake: owner.revert?.children?.length ? undefined : owner.id }
      }),
    )
    if (cleared.wake) yield* services.execution.wake(cleared.wake)
    return undefined
  })

  const commit = Effect.fn("Session.revert.commit")(function* (sessionID: SessionSchema.ID) {
    const session = yield* services.get(sessionID)
    if (yield* services.execution.isActive(sessionID)) return yield* new BusyError({ sessionID })
    return yield* criticalFamily([sessionID], (current) =>
      Effect.gen(function* () {
        const target = current.sessions.find((item) => item.id === sessionID) ?? session
        const owner = current.owners[0] ?? target
        if (yield* services.execution.isActive(owner.id)) return yield* new BusyError({ sessionID: owner.id })
        return yield* SessionRevert.commit(services.bus, owner)
      }),
    )
  })

  return { stage, clear, commit, withFamily: criticalFamily, wakeIfReady }
}
