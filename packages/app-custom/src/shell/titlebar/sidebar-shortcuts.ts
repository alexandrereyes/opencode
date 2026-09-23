import { onCleanup } from "solid-js"
import { createStore } from "solid-js/store"

export type ModifierHold = "idle" | "pending" | "visible" | "cancelled"

export type ModifierHoldEvent =
  | { type: "keydown"; mod: boolean; extra: boolean; key: "mod" | "digit" | "other" }
  | { type: "keyup"; mod: boolean }
  | { type: "release" }
  | { type: "elapsed" }

export const MODIFIER_HOLD_DELAY = 350

export function modifierHold(state: ModifierHold, event: ModifierHoldEvent): ModifierHold {
  if (event.type === "release") return "idle"
  if (event.type === "elapsed") return state === "pending" ? "visible" : state
  if (!event.mod) return "idle"
  if (event.type === "keyup") return state
  if (event.extra) return "cancelled"
  if (event.key === "mod") return state === "idle" ? "pending" : state
  if (event.key === "digit" && state === "visible") return state
  return "cancelled"
}

export function createModifierHold() {
  const [store, setStore] = createStore({ state: "idle" as ModifierHold })
  const timer = { id: undefined as ReturnType<typeof setTimeout> | undefined }
  const dispatch = (event: ModifierHoldEvent) => {
    const next = modifierHold(store.state, event)
    if (next !== "pending") clearTimeout(timer.id)
    if (next === "pending" && store.state !== "pending")
      timer.id = setTimeout(() => dispatch({ type: "elapsed" }), MODIFIER_HOLD_DELAY)
    setStore("state", next)
  }
  const keydown = (event: KeyboardEvent) =>
    dispatch({
      type: "keydown",
      mod: event.ctrlKey,
      extra: event.altKey || event.shiftKey || event.metaKey,
      key: event.key === "Control" ? "mod" : /^[1-9]$/.test(event.key) ? "digit" : "other",
    })
  const keyup = (event: KeyboardEvent) => dispatch({ type: "keyup", mod: event.key !== "Control" && event.ctrlKey })
  const release = () => dispatch({ type: "release" })
  window.addEventListener("keydown", keydown, true)
  window.addEventListener("keyup", keyup, true)
  window.addEventListener("blur", release)
  document.addEventListener("visibilitychange", release)
  onCleanup(() => {
    clearTimeout(timer.id)
    window.removeEventListener("keydown", keydown, true)
    window.removeEventListener("keyup", keyup, true)
    window.removeEventListener("blur", release)
    document.removeEventListener("visibilitychange", release)
  })
  return () => store.state === "visible"
}

export function sidebarShortcuts(keys: readonly string[]) {
  return new Map(keys.slice(0, 9).map((key, index) => [key, index + 1]))
}
