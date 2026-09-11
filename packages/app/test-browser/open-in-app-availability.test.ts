import { expect, test } from "bun:test"
import type { NativeApp } from "@opencode/schema/native-app"
import { createEffect, createRoot } from "solid-js"
import { createStore } from "solid-js/store"
import type { Platform } from "@/runtime/platform/platform"
import type { ServerConnectionStatus } from "@/runtime/server/client"
import { createNativeAppAvailability } from "@/session/files/open-in-app-availability"

test("local web discovery waits for connection and recovers from a failed request after reconnecting", async () => {
  const app = fixture("web", true)
  try {
    expect(app.requests).toHaveLength(0)
    expect(app.apps()).toBeUndefined()

    app.setState("status", "connected")
    expect(app.requests).toHaveLength(1)
    app.requests[0]?.reject(new Error("network unavailable"))
    await settled(app.apps)
    expect(app.apps()).toBeUndefined()

    app.setState("status", "connected")
    expect(app.requests).toHaveLength(1)
    app.setState("status", "reconnecting")
    expect(app.requests).toHaveLength(1)
    app.setState("status", "connected")
    expect(app.requests).toHaveLength(2)
    app.requests[1]?.resolve({ os: "macos", apps: ["finder", "rider"] })
    await settled(app.apps)
    expect(app.apps()).toEqual({ os: "macos", apps: ["finder", "rider"] })

    // Successful discovery also refreshes on a later connection, without remounting.
    app.setState("status", "reconnecting")
    app.setState("status", "connected")
    expect(app.requests).toHaveLength(3)
    app.requests[2]?.resolve({ os: "macos", apps: ["rider"] })
    await settled(app.apps)
    expect(app.apps()).toEqual({ os: "macos", apps: ["rider"] })
  } finally {
    app.dispose()
  }
})

test.each([
  ["desktop", true],
  ["desktop", false],
  ["web", false],
] as const)("does not request native apps for %s with local=%s, including reconnections", (platform, local) => {
  const app = fixture(platform, local)
  try {
    app.setState("status", "connected")
    app.setState("status", "reconnecting")
    app.setState("status", "connected")
    expect(app.requests).toHaveLength(0)
    expect(app.apps()).toBeUndefined()
  } finally {
    app.dispose()
  }
})

function fixture(platform: Platform["platform"], local: boolean) {
  return createRoot((dispose) => {
    const [state, setState] = createStore<{ status: ServerConnectionStatus }>({ status: "connecting" })
    const requests: ReturnType<typeof Promise.withResolvers<NativeApp.Availability>>[] = []
    const apps = createNativeAppAvailability({
      platform: () => platform,
      local: () => local,
      status: () => state.status,
      list: () => {
        const request = Promise.withResolvers<NativeApp.Availability>()
        requests.push(request)
        return request.promise
      },
    })
    return { apps, requests, setState, dispose }
  })
}

function settled(apps: ReturnType<typeof createNativeAppAvailability>) {
  return new Promise<void>((resolve) => {
    createRoot((dispose) => {
      createEffect(() => {
        if (apps.loading) return
        dispose()
        resolve()
      })
    })
  })
}
