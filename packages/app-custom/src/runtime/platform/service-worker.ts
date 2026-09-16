export function registerServiceWorker() {
  void navigator.serviceWorker.register("/sw.js")
}

export function canRefreshApplication() {
  return "serviceWorker" in navigator
}

export async function refreshApplication() {
  await Promise.all([
    ...(await navigator.serviceWorker.getRegistrations()).map((registration) => registration.unregister()),
    ...(await caches.keys()).map((name) => caches.delete(name)),
  ])
  window.location.reload()
}
