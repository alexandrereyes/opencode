import type { Accessor } from "solid-js"

export function ensureSessionKey(key: string, touch: (key: string) => void, seed: (key: string) => void) {
  touch(key)
  seed(key)
  return key
}

export function createSessionKeyReader(sessionKey: string | Accessor<string>, ensure: (key: string) => void) {
  const key = typeof sessionKey === "function" ? sessionKey : () => sessionKey
  return () => {
    const value = key()
    ensure(value)
    return value
  }
}

export function pruneSessionKeys(input: {
  keep?: string
  max: number
  used: Map<string, number>
  view: string[]
  tabs: string[]
}) {
  if (!input.keep) return []

  const keys = new Set<string>([...input.view, ...input.tabs])
  if (keys.size <= input.max) return []

  const score = (key: string) => {
    if (key === input.keep) return Number.MAX_SAFE_INTEGER
    return input.used.get(key) ?? 0
  }

  return Array.from(keys)
    .sort((a, b) => score(b) - score(a))
    .slice(input.max)
}

/**
 * Follows the routed Session's layout key. A key that changes for the same Session means it moved to another
 * Location; the returned previous key is the state to carry. Until layout storage loads, the first key is kept, so a
 * move before then copies from it once storage is ready instead of writing over unloaded state.
 */
export function createSessionMoveTracker() {
  const last = { id: undefined as string | undefined, key: undefined as string | undefined }
  return (input: { id?: string; key: string; ready: boolean }) => {
    if (!input.id) return
    if (last.id !== input.id) {
      last.id = input.id
      last.key = input.key
      return
    }
    if (!input.ready || last.key === input.key) return
    const from = last.key
    last.key = input.key
    return from
  }
}
