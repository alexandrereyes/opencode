import type { BrowserHandoffs } from "./rpc.js"

export const limits = {
  /** A call that can hand off counts as waiting once it has run this long, like a permission's alert delay. */
  graceMs: 3_000,
}

/** A browse call that can hand off, from its start; `waiting` once it outlived the grace period. */
export type Entry = BrowserHandoffs.Handoff & {
  waiting: boolean
  /** The Location instance that saw it start: only that one settles it and announces its changes. */
  readonly owner: object
  /** The call's input as `execute.before` received it, which `execute.after` passes back unchanged. */
  readonly input: unknown
}

/**
 * Every Location runs its own plugin instance in this process; a tool call fires the hooks of its own Location only.
 * The registry is process-wide so Sessões, the session family and the Live Activity hub, which read across
 * Locations, see every waiting call.
 */
export function makeRegistry() {
  const entries = new Map<string, Entry>()
  const listeners = new Set<() => void>()
  const notify = () => {
    for (const listener of listeners) listener()
  }
  return {
    add: (entry: Entry) => {
      entries.set(entry.id, entry)
    },
    /** Marks a call as waiting; false when it already ended. */
    reveal: (id: string) => {
      const entry = entries.get(id)
      if (!entry || entry.waiting) return false
      entry.waiting = true
      notify()
      return true
    },
    /** Removes the entries `match` selects; the removed ones that were waiting are returned. */
    remove: (match: (entry: Entry) => boolean) => {
      const removed = [...entries.values()].filter(match)
      for (const entry of removed) entries.delete(entry.id)
      const waiting = removed.filter((entry) => entry.waiting)
      if (waiting.length > 0) notify()
      return waiting
    },
    /** The calls waiting now, oldest first. */
    waiting: (): readonly Entry[] =>
      [...entries.values()].filter((entry) => entry.waiting).toSorted((a, b) => a.since - b.since),
    has: (match: (entry: Entry) => boolean) => [...entries.values()].some(match),
    /** Called on every change of the waiting list (the Live Activity hub wakes on it). */
    listen: (listener: () => void) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}

export type Registry = ReturnType<typeof makeRegistry>

/** The waiting calls as the RPC, Sessões and the session family return them. */
export const wire = (entry: Entry): BrowserHandoffs.Handoff => ({
  id: entry.id,
  sessionID: entry.sessionID,
  callID: entry.callID,
  messageID: entry.messageID,
  message: entry.message,
  since: entry.since,
})

declare global {
  var opencodeCustomBrowserHandoffs: Registry | undefined
}

/** Not module scope: the plugin loader evaluates this module again for every Location (see `sharedHub`). */
export function sharedRegistry() {
  globalThis.opencodeCustomBrowserHandoffs ??= makeRegistry()
  return globalThis.opencodeCustomBrowserHandoffs
}
