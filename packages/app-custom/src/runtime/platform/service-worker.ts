export function registerServiceWorker() {
  let controlled = !!navigator.serviceWorker.controller
  let reloading = false
  let registration: ServiceWorkerRegistration | undefined
  let pending: Promise<void> | undefined
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    // A first install already loaded the current release from the network.
    if (!controlled) {
      controlled = true
      return
    }
    if (reloading) return
    reloading = true
    window.location.reload()
  })

  const update = () => {
    if (pending) return pending
    pending = (async () => {
      if (registration) return void (await registration.update())
      registration = await navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" })
    })()
      .catch(() => undefined)
      .finally(() => {
        pending = undefined
      })
    return pending
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void update()
  })
  window.addEventListener("pageshow", () => void update())
  if (document.readyState === "complete") return void update()
  window.addEventListener("load", () => void update(), { once: true })
}
