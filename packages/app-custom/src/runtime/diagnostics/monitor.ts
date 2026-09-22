import { createEffect, onCleanup, onMount } from "solid-js"
import { useLocation } from "@solidjs/router"
import { flushPerformanceEvents, navigationDiagnostics, performanceHistory } from "./performance"

export function sessionFromPath(path: string) {
  return /\/session\/(ses_[a-zA-Z0-9]+)(?:\/|$)/.exec(path)?.[1]
}

export function usePerformanceMonitor() {
  const location = useLocation()
  createEffect(() => {
    navigationDiagnostics.route(sessionFromPath(location.pathname))
  })
  onMount(() => {
    let previous = performance.now()
    const tick = setInterval(() => {
      const at = performance.now()
      const delay = at - previous - 250
      previous = at
      if (document.visibilityState === "visible" && delay > 100) {
        performanceHistory.record("main-thread.delay", { duration: Math.round(delay) })
      }
    }, 250)
    const aggregate = setInterval(flushPerformanceEvents, 5_000)
    const visibility = () => {
      previous = performance.now()
      performanceHistory.record("visibility", { visible: document.visibilityState === "visible" })
      flushPerformanceEvents()
    }
    const click = (event: MouseEvent) => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      const anchor = event.composedPath().find((item): item is HTMLAnchorElement => item instanceof HTMLAnchorElement)
      if (!anchor || anchor.origin !== window.location.origin) return
      const session = sessionFromPath(anchor.pathname)
      if (!session) return
      navigationDiagnostics.click(session, Math.max(0, Math.round(performance.now() - event.timeStamp)))
    }
    performanceHistory.record("monitor.started", { visible: document.visibilityState === "visible" })
    document.addEventListener("click", click, true)
    document.addEventListener("visibilitychange", visibility)
    onCleanup(() => {
      clearInterval(tick)
      clearInterval(aggregate)
      document.removeEventListener("click", click, true)
      document.removeEventListener("visibilitychange", visibility)
      flushPerformanceEvents()
    })
  })
}

export function recordSessionReady(session: string) {
  const paint = navigationDiagnostics.ready(session)
  let frame = requestAnimationFrame(() => {
    frame = requestAnimationFrame(() => {
      paint(document.visibilityState === "visible")
    })
  })
  return () => cancelAnimationFrame(frame)
}
