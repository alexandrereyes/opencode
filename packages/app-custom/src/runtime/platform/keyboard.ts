import { onCleanup, onMount } from "solid-js"

export function KeyboardInsets() {
  onMount(() => {
    const viewport = window.visualViewport
    if (!viewport) return
    const root = document.documentElement
    const sync = () => {
      const active = document.activeElement
      const editing =
        active instanceof HTMLElement &&
        (active.isContentEditable || active.matches("input:not([readonly]), textarea:not([readonly])"))
      // iOS retains the home-indicator inset above its keyboard. Ignore pinch zoom
      // and small viewport changes from browser chrome, not just editor focus.
      const keyboard = editing && root.clientHeight - viewport.height * viewport.scale > 100
      if (keyboard) root.style.setProperty("--safe-area-inset-bottom", "0px")
      if (!keyboard) root.style.removeProperty("--safe-area-inset-bottom")
    }
    // iOS blurs the editor on the synthetic mousedown of a tap and hit-tests the
    // mouseup and click again at the same point. Restoring the inset
    // synchronously moves the bottom controls away from the finger, so the tap
    // only dismisses the keyboard. Defer it past the click.
    let timer: ReturnType<typeof setTimeout> | undefined
    const blur = () => {
      clearTimeout(timer)
      timer = setTimeout(sync)
    }
    sync()
    viewport.addEventListener("resize", sync)
    window.addEventListener("resize", sync)
    document.addEventListener("focusin", sync)
    document.addEventListener("focusout", blur)
    onCleanup(() => {
      clearTimeout(timer)
      viewport.removeEventListener("resize", sync)
      window.removeEventListener("resize", sync)
      document.removeEventListener("focusin", sync)
      document.removeEventListener("focusout", blur)
      root.style.removeProperty("--safe-area-inset-bottom")
    })
  })
  return null
}
