import { afterEach, expect, mock, test } from "bun:test"
import { createRoot } from "solid-js"
import type {
  IntegrationInfo,
  IntegrationOauthConnectOutput,
  IntegrationOauthStatusOutput,
} from "@opencode/client/promise"

const cleanups: VoidFunction[] = []
afterEach(() => cleanups.splice(0).forEach((dispose) => dispose()))
const authorization: IntegrationOauthConnectOutput["data"] = {
  attemptID: "attempt_fixture",
  mode: "auto",
  url: "https://example.test/authorize",
  instructions: "Code: ABCD",
  time: { created: 1, expires: 100_000 },
}
const methods: IntegrationInfo["methods"] = [
  {
    type: "oauth",
    id: "device",
    label: "Console",
    form: [{ type: "string", key: "workspace", hidden: true, default: "test", title: "Workspace" }],
  },
  { type: "key", label: "API key" },
]
let active: ReturnType<typeof boundary>
function boundary() {
  const connected = Promise.withResolvers<Pick<IntegrationOauthConnectOutput, "data">>()
  const status = Promise.withResolvers<Pick<IntegrationOauthStatusOutput, "data">>()
  const nextStatus = Promise.withResolvers<Pick<IntegrationOauthStatusOutput, "data">>()
  const repolled = Promise.withResolvers<void>()
  const calls = {
    opened: [] as string[],
    cancelled: [] as string[],
    connects: [] as unknown[],
    keys: [] as unknown[],
    refreshed: 0,
    completed: 0,
    polls: 0,
  }
  return {
    connected,
    status,
    nextStatus,
    repolled,
    calls,
    sdk: {
      api: {
        integration: {
          get: async () => ({ data: { id: "opencode", name: "Console", methods, connections: [] } }),
          oauth: {
            connect: (input: unknown) => {
              calls.connects.push(input)
              return connected.promise
            },
            status: () => {
              calls.polls++
              if (calls.polls === 1) return status.promise
              repolled.resolve()
              return nextStatus.promise
            },
            cancel: async (input: { attemptID: string }) => {
              calls.cancelled.push(input.attemptID)
            },
          },
          connect: {
            key: async (input: unknown) => {
              calls.keys.push(input)
            },
          },
        },
      },
    },
  }
}
mock.module("@/runtime/i18n/language", () => ({ useLanguage: () => ({ t: (key: string) => key }) }))
mock.module("@/runtime/platform/platform", () => ({
  usePlatform: () => ({ platform: "web", openExternal: (url: string) => active.calls.opened.push(url) }),
}))
mock.module("@/runtime/server/client", () => ({ useServerSDK: () => active.sdk }))
mock.module("@/runtime/server/current", () => ({
  useData: () => {
    const resource = {
      invalidate() {},
      sync: async () => {
        active.calls.refreshed++
      },
    }
    return { location: { integration: resource, provider: resource, model: resource } }
  },
}))
const { createProviderConnectionController, consoleIntegration } = await import("@/providers/connect/controller")

async function fixture(auto = true) {
  active = boundary()
  const app = createRoot((dispose) => {
    cleanups.push(dispose)
    const controller = createProviderConnectionController({
      provider: () => consoleIntegration("opencode-go"),
      keyProvider: () => "opencode-go",
      directory: () => "/fixture",
      onComplete: () => active.calls.completed++,
      autoSelect: auto ? (values) => values.findIndex((value) => value.type === "oauth") : undefined,
      pollInterval: 1,
    })
    return { controller, dispose, ...active }
  })
  await drain()
  return app
}
async function drain() {
  for (const _ of Array.from({ length: 15 })) await Promise.resolve()
}

test("starts shared Console OAuth with hidden defaults, opens browser, polls and refreshes on completion", async () => {
  const app = await fixture()
  expect(app.controller.busy()).toBe(true)
  expect(app.calls.connects).toEqual([
    {
      integrationID: "opencode",
      methodID: "device",
      answer: { workspace: "test" },
      location: { directory: "/fixture" },
    },
  ])
  app.connected.resolve({ data: authorization })
  await drain()
  expect(app.calls.opened).toEqual([authorization.url])
  expect(app.calls.polls).toBe(1)
  expect(app.controller.authorization()).toEqual(authorization)
  app.controller.auth.open()
  expect(app.calls.opened).toHaveLength(2)
  app.status.resolve({ data: { status: "complete", time: authorization.time } })
  await drain()
  expect(app.calls.refreshed).toBe(3)
  expect(app.calls.completed).toBe(1)
  app.dispose()
  expect(app.calls.cancelled).toEqual([])
})

test("multiple methods show selection instead of a permanent spinner", async () => {
  const app = await fixture(false)
  expect(app.controller.busy()).toBe(false)
  expect(app.controller.methodIndex()).toBeUndefined()
  expect(app.calls.connects).toEqual([])
})

test("pending authorization is polled again until completion", async () => {
  const app = await fixture()
  app.connected.resolve({ data: authorization })
  app.status.resolve({ data: { status: "pending", time: authorization.time } })
  await app.repolled.promise
  expect(app.calls.polls).toBe(2)
  expect(app.calls.completed).toBe(0)
  app.nextStatus.resolve({ data: { status: "complete", time: authorization.time } })
  await drain()
  expect(app.calls.completed).toBe(1)
})

test("server rejection exposes its message and does not complete", async () => {
  const app = await fixture()
  app.connected.resolve({ data: authorization })
  app.status.resolve({ data: { status: "failed", message: "Authorization denied", time: authorization.time } })
  await drain()
  expect(app.controller.auth.error()).toBe("Authorization denied")
  expect(app.calls.completed).toBe(0)
})

test("closing cancels an active attempt and ignores late status completion", async () => {
  const app = await fixture()
  app.connected.resolve({ data: authorization })
  await drain()
  app.dispose()
  app.status.resolve({ data: { status: "complete", time: authorization.time } })
  await drain()
  expect(app.calls.cancelled).toEqual([authorization.attemptID])
  expect(app.calls.completed).toBe(0)
})

test("closing while starting cancels the late attempt without opening the browser", async () => {
  const app = await fixture()
  app.dispose()
  app.connected.resolve({ data: authorization })
  await drain()
  expect(app.calls.cancelled).toEqual([authorization.attemptID])
  expect(app.calls.opened).toEqual([])
})

test("switching to a Go service-account key cancels OAuth and preserves the key integration", async () => {
  const app = await fixture()
  app.connected.resolve({ data: authorization })
  await drain()
  await app.controller.auth.select(1)
  expect(app.calls.cancelled).toEqual([authorization.attemptID])
  await app.controller.auth.connectKey("fixture-not-a-real-key")
  expect(app.calls.keys).toEqual([
    { integrationID: "opencode-go", location: { directory: "/fixture" }, key: "fixture-not-a-real-key" },
  ])
})

test("start failure is visible and retry starts another request", async () => {
  const app = await fixture()
  app.connected.reject(new Error("Authorization unavailable"))
  await drain()
  expect(app.controller.auth.error()).toBe("Authorization unavailable")
  expect(app.controller.busy()).toBe(false)
  app.controller.auth.retry()
  await drain()
  expect(app.calls.connects).toHaveLength(2)
})

test("polling failure cancels the still-open attempt and exposes the error", async () => {
  const app = await fixture()
  app.connected.resolve({ data: authorization })
  await drain()
  app.status.reject(new Error("Connection lost"))
  await drain()
  expect(app.controller.auth.error()).toBe("Connection lost")
  expect(app.calls.cancelled).toEqual([authorization.attemptID])
})

test("expired authorization gets an actionable error", async () => {
  const app = await fixture()
  app.connected.resolve({ data: authorization })
  await drain()
  app.status.resolve({ data: { status: "expired", time: authorization.time } })
  await drain()
  expect(app.controller.auth.error()).toBe("provider.connect.oauth.expired")
})
