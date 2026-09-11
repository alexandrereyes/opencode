import { createStore } from "solid-js/store"
import type { SessionNavigationInfo } from "@opencode/client/promise"

/** One epoch-ms clock across servers, independent of render and message clocks. */
export function createRecentClock(now = Date.now) {
  const clock = { last: 0 }
  return {
    seed: (rank: number) => {
      clock.last = Math.max(clock.last, rank)
    },
    next: () => (clock.last = Math.max(clock.last + 1, now())),
  }
}

export function createRecentOrder(clock: ReturnType<typeof createRecentClock>) {
  const [ranks, setRanks] = createStore<Record<string, number>>({})
  const phases = new Map<string, boolean>()
  const remove = (id: string) => {
    phases.delete(id)
    setRanks(id, undefined!)
  }
  const seed = (row: SessionNavigationInfo, refresh = false) => {
    const session = row.session
    if (session.time.archived) return remove(session.id)
    const baseline = session.time.updated || session.time.created
    const rank = ranks[session.id]
    if (rank !== undefined && (!refresh || rank >= baseline)) return
    clock.seed(baseline)
    setRanks(session.id, baseline)
  }
  const activity = (active: Set<string>, observed: Set<string>) => {
    const known = new Set([...Object.keys(ranks), ...phases.keys(), ...active])
    const changed = [...known].filter((id) => {
      // Events received while fetching supersede the snapshot, just as in Client data.
      if (observed.has(id)) return false
      const previous = phases.get(id)
      phases.set(id, active.has(id))
      return previous !== undefined && previous !== active.has(id)
    })
    // A snapshot cannot recover the order of missed transitions. Tie by session key.
    if (!changed.length) return changed
    const rank = clock.next()
    changed.forEach((id) => setRanks(id, rank))
    return changed
  }
  return {
    ranks,
    seed,
    remove,
    activity,
    observe(id: string, active: boolean) {
      const previous = phases.get(id)
      phases.set(id, active)
      if (previous === active || (previous === undefined && !active)) return
      setRanks(id, clock.next())
    },
    snapshot(rows: SessionNavigationInfo[], active: Set<string>, observed: Set<string>, promoted: string[] = []) {
      const known = new Set(rows.map((row) => row.session.id))
      new Set([...Object.keys(ranks), ...phases.keys()]).forEach((id) => {
        if (!known.has(id) && !observed.has(id)) remove(id)
      })
      rows.forEach((row) => {
        if (!observed.has(row.session.id)) seed(row, true)
      })
      activity(active, observed)
      // Keep the early activity batch tied if navigation raises one of its baselines.
      // Later live transitions retain their own rank, rather than being promoted again.
      const cohort = promoted.filter((id) => !observed.has(id) && ranks[id] !== undefined)
      if (!cohort.length) return
      const rank = Math.max(...cohort.map((id) => ranks[id]))
      cohort.forEach((id) => setRanks(id, rank))
    },
  }
}
