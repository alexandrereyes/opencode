import { createEffect, on, onCleanup } from "solid-js"
import { createStore } from "solid-js/store"
import type { SessionLifecycleResult } from "@/session/lifecycle-actions"
import { readSessionTabsRemovedDetail, SESSION_TABS_REMOVED_EVENT } from "./session-events"
import { sessionKey, type SidebarSession } from "./sidebar-model"

export function createSidebarSelection(input: {
  rows: () => SidebarSession[]
  view: () => string
  pending: () => boolean
}) {
  const [state, setState] = createStore({ mode: false, keys: [] as string[], anchor: undefined as string | undefined })
  const clear = () => setState({ mode: false, keys: [], anchor: undefined })
  createEffect(on(input.view, clear))
  createEffect(() => {
    const visible = new Set(input.rows().map((row) => row.key))
    const keys = state.keys.filter((key) => visible.has(key))
    if (keys.length !== state.keys.length) setState("keys", keys)
    if (state.anchor && !visible.has(state.anchor)) setState("anchor", undefined)
  })
  const removed = (event: Event) => {
    const detail = readSessionTabsRemovedDetail(event)
    if (!detail) return
    const keys = new Set(detail.sessionIDs.map((id) => sessionKey(detail.server, id)))
    setState("keys", (current) => current.filter((key) => !keys.has(key)))
    if (state.anchor && keys.has(state.anchor)) setState("anchor", undefined)
  }
  window.addEventListener(SESSION_TABS_REMOVED_EVENT, removed)
  onCleanup(() => window.removeEventListener(SESSION_TABS_REMOVED_EVENT, removed))
  return {
    state,
    clear,
    start: () => setState("mode", true),
    selected: () => input.rows().filter((row) => state.keys.includes(row.key)),
    all: () => {
      if (!input.pending()) setState({ mode: true, keys: input.rows().map((row) => row.key) })
    },
    complete: (result: SessionLifecycleResult) => {
      const succeeded = new Set(result.succeeded.map((item) => sessionKey(item.server, item.session.id)))
      setState("keys", (keys) => keys.filter((key) => !succeeded.has(key)))
      if (!state.keys.length) clear()
    },
    activate: (key: string, event: MouseEvent | KeyboardEvent) => {
      if (!state.mode && !event.metaKey && !event.ctrlKey && !event.shiftKey) return false
      event.preventDefault()
      if (input.pending()) return true
      const keys = input.rows().map((row) => row.key)
      if (!keys.includes(key)) return true
      const anchor = state.anchor ? keys.indexOf(state.anchor) : -1
      const index = keys.indexOf(key)
      setState({
        mode: true,
        keys:
          event.shiftKey && anchor >= 0
            ? [...new Set([...state.keys, ...keys.slice(Math.min(anchor, index), Math.max(anchor, index) + 1)])]
            : state.keys.includes(key)
              ? state.keys.filter((item) => item !== key)
              : [...state.keys, key],
        anchor: event.shiftKey && anchor >= 0 ? state.anchor : key,
      })
      return true
    },
    escape: (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.isComposing || !state.mode || input.pending()) return
      event.preventDefault()
      event.stopPropagation()
      clear()
    },
  }
}
