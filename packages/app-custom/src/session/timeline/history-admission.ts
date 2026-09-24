import { createStore } from "solid-js/store"

// TanStack Virtual defers prepend anchoring while iOS WebKit scrolls, because a
// programmatic write would cancel momentum. The rows move immediately and the
// deferred correction snaps the viewport back later. Older pages therefore wait
// outside the projection until the gesture settles and anchoring can write at once.
export function createHistoryAdmission() {
  const [state, setState] = createStore({ held: false, loaded: false })
  return {
    held: () => state.held,
    /** An older page arrived during this hold; further automatic pages wait for its admission. */
    waiting: () => state.held && state.loaded,
    hold: () => {
      if (!state.held) setState("held", true)
    },
    loaded: () => {
      if (state.held && !state.loaded) setState("loaded", true)
    },
    release: () => {
      if (state.held) setState({ held: false, loaded: false })
    },
  }
}

export type HistoryAdmission = ReturnType<typeof createHistoryAdmission>

/** Mirrors TanStack's `isIOSWebKit()`, which selects its deferred scroll-write path. */
export function defersScrollWrites() {
  if (typeof navigator === "undefined") return false
  if (/iP(hone|od|ad)/.test(navigator.userAgent)) return true
  return navigator.platform === "MacIntel" && navigator.maxTouchPoints > 0
}

/**
 * Hides messages prepended before `first`, the first message admitted so far, while held.
 * Later updates stay live. Pass an ID rather than the previous array: message
 * stores prepend in place, so a retained array reference already contains the page.
 */
export function admitMessages<T extends { id: string }>(messages: T[], first: string | undefined, held: boolean) {
  if (!held || first === undefined) return messages
  const index = messages.findIndex((message) => message.id === first)
  return index > 0 ? messages.slice(index) : messages
}
