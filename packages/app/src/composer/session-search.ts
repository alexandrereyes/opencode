import type { SessionInfo } from "@opencode/client/promise"
import { looksLikeSessionID } from "@/session/search"

export function createSessionSearch(input: {
  list: (query: string, signal: AbortSignal) => Promise<SessionInfo[]>
  get: (sessionID: string, signal: AbortSignal) => Promise<SessionInfo>
  current: () => string | undefined
  debounce?: number
}) {
  let abort: AbortController | undefined
  return {
    async load(query: string) {
      abort?.abort()
      const current = new AbortController()
      abort = current
      const debounce = input.debounce ?? 100
      if (query && debounce > 0) {
        await new Promise<void>((resolve) => {
          const timer = setTimeout(resolve, debounce)
          current.signal.addEventListener(
            "abort",
            () => {
              clearTimeout(timer)
              resolve()
            },
            { once: true },
          )
        })
      }
      if (current.signal.aborted) return []
      const [listed, exact] = await Promise.all([
        input.list(query, current.signal).catch(() => []),
        looksLikeSessionID(query)
          ? input
              .get(query, current.signal)
              .then((session) => [session])
              .catch(() => [])
          : Promise.resolve([]),
      ])
      if (current.signal.aborted) return []
      const active = input.current()
      return [...new Map([...exact, ...listed].map((session) => [session.id, session] as const)).values()].filter(
        (session) => session.id !== active && !session.parentID && !session.time.archived,
      )
    },
    dispose() {
      abort?.abort()
    },
  }
}
