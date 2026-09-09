export * as Maintenance from "./maintenance.js"

import { Effect } from "effect"

/** A process-local admission barrier. Acquiring it and admitting work never yield. */
export function make(duration = 60_000) {
  const activities = new Set<object>()
  const blockers = new Set<() => boolean>()
  const waiting = new Set<() => void>()
  const state: {
    lease?: { token: string; expires: number }
    timer?: ReturnType<typeof setTimeout>
    committed: boolean
  } = { committed: false }
  const identity = crypto.randomUUID()

  const open = () => {
    if (state.timer) clearTimeout(state.timer)
    state.timer = undefined
    state.lease = undefined
    waiting.forEach((resume) => resume())
    waiting.clear()
  }
  const expire = () => {
    if (!state.committed && state.lease && state.lease.expires <= Date.now()) open()
  }
  const enter = () => {
    expire()
    if (state.lease) return undefined
    const activity = {}
    activities.add(activity)
    return () => {
      activities.delete(activity)
    }
  }
  const acquire: Effect.Effect<() => void> = Effect.suspend(() => {
    const release = enter()
    if (release) return Effect.succeed(release)
    return Effect.callback<void>((resume) => {
      const wake = () => resume(Effect.void)
      expire()
      if (!state.lease) {
        wake()
        return
      }
      waiting.add(wake)
      return Effect.sync(() => {
        waiting.delete(wake)
      })
    }).pipe(Effect.andThen(acquire))
  })
  const run = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
    Effect.uninterruptibleMask((restore) =>
      Effect.acquireUseRelease(
        restore(acquire),
        () => restore(effect),
        (release) => Effect.sync(release),
      ),
    )

  return {
    identity,
    run,
    enter,
    /** Register conservative synchronous blockers (for example, every open terminal). */
    block: (busy: () => boolean) =>
      Effect.acquireRelease(
        Effect.sync(() => {
          blockers.add(busy)
        }),
        () =>
          Effect.sync(() => {
            blockers.delete(busy)
          }),
      ),
    status: () => {
      expire()
      return { identity, active: activities.size, held: !!state.lease, committed: state.committed }
    },
    lease: () => {
      expire()
      if (state.lease || activities.size || [...blockers].some((busy) => busy())) return undefined
      state.lease = { token: crypto.randomUUID(), expires: Date.now() + duration }
      state.timer = setTimeout(expire, duration)
      state.timer.unref?.()
      return { identity, ...state.lease }
    },
    cancel: (token: string) => {
      expire()
      if (state.committed || state.lease?.token !== token) return false
      open()
      return true
    },
    /** Caller must trigger shutdown synchronously after this succeeds, never signal a saved PID later. */
    commit: (token: string, expected: string) => {
      expire()
      if (state.committed || identity !== expected || state.lease?.token !== token) return false
      state.committed = true
      if (state.timer) clearTimeout(state.timer)
      return true
    },
  }
}

// Execution ownership is process-local, including multiple embedded runtimes in one process.
export const process = make()
