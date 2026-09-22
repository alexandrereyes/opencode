export const retentionMs = 15 * 60_000
export const entryLimit = 6_000

type Details = Record<string, string | number | boolean | undefined>
type Entry = { at: number; type: string; data: Details }

// A fixed-size buffer: recording must stay cheap even during an event storm.
export function createPerformanceHistory(now = Date.now, limit = entryLimit) {
  const entries: Entry[] = []
  let cursor = 0
  let overwritten = 0
  return {
    record(type: string, data: Details = {}) {
      if (entries.length === limit) overwritten++
      entries[cursor] = { at: now(), type, data }
      cursor = (cursor + 1) % limit
    },
    snapshot() {
      const ordered = entries.length === limit ? [...entries.slice(cursor), ...entries.slice(0, cursor)] : [...entries]
      return {
        retentionMs,
        entryLimit: limit,
        overwritten,
        entries: ordered.filter((entry) => entry.at >= now() - retentionMs),
      }
    },
  }
}

export const performanceHistory = createPerformanceHistory()

// Never retain hosts, query strings, filesystem paths, credentials or payloads.
export function requestLabel(url: string) {
  const parts = new URL(url).pathname.split("/").filter(Boolean)
  if (parts[0] !== "api") return "other"
  return parts
    .map((part, index) => {
      if (index === 0) return part
      if (index === 1 && /^[a-z-]+$/.test(part)) return part
      return ":param"
    })
    .join("/")
}

const events = new Map<string, number>()
export function countPerformanceEvent(type: string) {
  events.set(type, (events.get(type) ?? 0) + 1)
}

export function flushPerformanceEvents() {
  if (!events.size) return
  performanceHistory.record("events", Object.fromEntries(events))
  events.clear()
}

export function exportPerformanceHistory(version?: string) {
  flushPerformanceEvents()
  const data = {
    schema: 1,
    exportedAt: new Date().toISOString(),
    version,
    clock: "Unix milliseconds; durations in milliseconds",
    notes:
      "Local page lifetime only. Headers timing excludes response body. Paint markers are animation-frame opportunities, not GPU completion. No conversation content is collected.",
    ...performanceHistory.snapshot(),
  }
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }))
  const anchor = document.createElement("a")
  anchor.href = url
  anchor.download = `opencode-performance-${Date.now()}.json`
  document.body.appendChild(anchor)
  anchor.click()
  anchor.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1_000)
}

export function createNavigationDiagnostics(history = performanceHistory, now = performance.now.bind(performance)) {
  let sequence = 0
  let pending: { id: number; session: string; at: number } | undefined
  return {
    click(session: string, inputDelay: number) {
      pending = { id: ++sequence, session, at: now() }
      history.record("navigation.click", { id: pending.id, session, inputDelay })
    },
    route(session?: string) {
      if (!session) pending = undefined
      if (session && pending?.session !== session) pending = { id: ++sequence, session, at: now() }
      history.record("navigation.route", {
        session,
        id: pending?.id,
        elapsedMs: pending ? now() - pending.at : undefined,
      })
    },
    ready(session: string) {
      const navigation = pending?.session === session ? pending : undefined
      history.record("session.data-ready", {
        session,
        id: navigation?.id,
        elapsedMs: navigation ? now() - navigation.at : undefined,
      })
      return (visible: boolean) => {
        if (navigation && navigation !== pending) return
        history.record("session.paint-opportunity", {
          session,
          id: navigation?.id,
          elapsedMs: navigation ? now() - navigation.at : undefined,
          visible,
        })
      }
    },
  }
}

export const navigationDiagnostics = createNavigationDiagnostics()
