import { expect, test } from "bun:test"
import type { NativeApps } from "@opencode/plugin-app-custom/native-apps/rpc"
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
    app.requests[0]?.request.reject(new Error("network unavailable"))
    await settled(app.loading)
    expect(app.apps()).toBeUndefined()

    app.setState("status", "connected")
    expect(app.requests).toHaveLength(1)
    app.setState("status", "reconnecting")
    expect(app.requests).toHaveLength(1)
    app.setState("status", "connected")
    expect(app.requests).toHaveLength(2)
    app.requests[1]?.request.resolve({ os: "macos", apps: ["finder", "rider"] })
    await settled(app.loading)
    expect(app.apps()).toEqual({ os: "macos", apps: ["finder", "rider"] })

    // Successful discovery also refreshes on a later connection, without remounting.
    app.setState("status", "reconnecting")
    expect(app.apps()).toBeUndefined()
    app.setState("status", "connected")
    expect(app.apps()).toBeUndefined()
    expect(app.requests).toHaveLength(3)
    app.requests[2]?.request.resolve({ os: "macos", apps: ["rider"] })
    await settled(app.loading)
    expect(app.apps()).toEqual({ os: "macos", apps: ["rider"] })
  } finally {
    app.dispose()
  }
})

test("refreshes for server and Location changes and ignores previous requests that resolve later", async () => {
  const app = fixture("web", true)
  try {
    app.setState("status", "connected")
    expect(app.requests[0]?.location).toBe("/repo")
    app.setState("location", "/other")
    expect(app.requests[1]?.location).toBe("/other")
    app.setState("server", "other-server")
    expect(app.requests[2]?.location).toBe("/other")

    app.requests[2]?.request.resolve({ os: "macos", apps: ["rider"] })
    await settled(app.loading)
    app.requests[0]?.request.resolve({ os: "macos", apps: ["vscode"] })
    app.requests[1]?.request.resolve({ os: "macos", apps: ["finder"] })
    await Promise.resolve()
    expect(app.apps()).toEqual({ os: "macos", apps: ["rider"] })
  } finally {
    app.dispose()
  }
})

test("hides resolved availability while a new context is pending or unavailable", async () => {
  const app = fixture("web", true)
  try {
    app.setState("status", "connected")
    app.requests[0]?.request.resolve({ os: "macos", apps: ["vscode"] })
    await settled(app.loading)
    expect(app.apps()).toEqual({ os: "macos", apps: ["vscode"] })

    app.setState("location", "/other")
    expect(app.apps()).toBeUndefined()
    app.requests[1]?.request.reject(new Error("plugin unavailable"))
    await settled(app.loading)
    expect(app.apps()).toBeUndefined()
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
    const [state, setState] = createStore<{
      status: ServerConnectionStatus
      server: string
      location: string
    }>({ status: "connecting", server: "local", location: "/repo" })
    const requests: Array<{
      location: string
      request: ReturnType<typeof Promise.withResolvers<NativeApps.Availability>>
    }> = []
    const availability = createNativeAppAvailability({
      platform: () => platform,
      local: () => local,
      server: () => state.server,
      location: () => state.location,
      status: () => state.status,
      list: (location) => {
        const request = Promise.withResolvers<NativeApps.Availability>()
        requests.push({ location, request })
        return request.promise
      },
    })
    return { apps: availability.value, loading: availability.loading, requests, setState, dispose }
  })
}

function settled(loading: () => boolean) {
  return new Promise<void>((resolve) => {
    createRoot((dispose) => {
      createEffect(() => {
        if (loading()) return
        dispose()
        resolve()
      })
    })
  })
}
