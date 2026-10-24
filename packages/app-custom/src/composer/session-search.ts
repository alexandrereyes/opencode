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
        Promise.all(caseVariants(query).map((variant) => input.list(variant, current.signal).catch(() => []))).then(
          (lists) =>
            lists.length === 1
              ? lists[0]
              : [...new Map(lists.flat().map((session) => [session.id, session] as const)).values()].toSorted(
                  (a, b) => b.time.updated - a.time.updated,
                ),
        ),
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

// The server matches titles with SQLite LIKE, which ignores case only for ASCII letters. When the query
// has other cased letters (Ã, Í, Ç…), also ask with them lowered, uppercased and capitalized, so
// "SESSÃO" finds "Sessão" and "índice" finds "Índice". Accents are matched as typed.
export function caseVariants(query: string) {
  if (![...query].some((char) => char > "\u007f" && char.toLowerCase() !== char.toUpperCase())) return [query]
  const lower = query.toLocaleLowerCase()
  return [...new Set([query, lower, query.toLocaleUpperCase(), lower.charAt(0).toLocaleUpperCase() + lower.slice(1)])]
}
