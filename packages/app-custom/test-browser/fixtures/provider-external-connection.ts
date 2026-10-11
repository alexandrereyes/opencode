import { afterEach, expect, mock, test } from "bun:test"
import { createRoot } from "solid-js"
import type { IntegrationInfo } from "@opencode/client/promise"

const cleanups: VoidFunction[] = []
afterEach(() => cleanups.splice(0).forEach((dispose) => dispose()))
const profile: IntegrationInfo["methods"][number] = {
  id: "aws-profile",
  type: "external",
  label: "AWS profile (SSO or named profile)",
  form: [
    {
      type: "string",
      key: "profile",
      title: "AWS profile",
      required: true,
      custom: true,
      options: [{ value: "default", label: "default" }],
    },
    { type: "string", key: "partition", hidden: true, default: "aws", title: "Partition" },
  ],
}
const cli: IntegrationInfo["methods"][number] = { id: "azure-cli", type: "external", label: "Azure CLI" }
let active: ReturnType<typeof boundary>
function boundary(methods: IntegrationInfo["methods"]) {
  const saved = Promise.withResolvers<void>()
  const calls = {
    external: [] as unknown[],
    oauth: 0,
    refreshed: 0,
    completed: 0,
  }
  return {
    saved,
    calls,
    sdk: {
      api: {
        integration: {
          get: async () => ({ data: { id: "amazon-bedrock", name: "Amazon Bedrock", methods, connections: [] } }),
          oauth: {
            connect: async () => {
              calls.oauth++
              throw new Error("OAuth must not start for an external method")
            },
            cancel: async () => undefined,
          },
          connect: {
            external: (input: unknown) => {
              calls.external.push(input)
              return saved.promise
            },
          },
        },
      },
    },
  }
}
mock.module("@/runtime/i18n/language", () => ({ useLanguage: () => ({ t: (key: string) => key }) }))
mock.module("@/runtime/platform/platform", () => ({
  usePlatform: () => ({ platform: "web", openExternal: () => undefined }),
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
const { createProviderConnectionController } = await import("@/providers/connect/controller")

async function fixture(methods: IntegrationInfo["methods"]) {
  active = boundary(methods)
  const app = createRoot((dispose) => {
    cleanups.push(dispose)
    const controller = createProviderConnectionController({
      provider: () => "amazon-bedrock",
      directory: () => "/fixture",
      onComplete: () => active.calls.completed++,
    })
    return { controller, dispose, ...active }
  })
  await drain()
  return app
}
async function drain() {
  for (const _ of Array.from({ length: 15 })) await Promise.resolve()
}

test("lists external methods next to key and OAuth methods", async () => {
  const app = await fixture([{ type: "key", label: "Bedrock API key" }, profile])
  expect(app.controller.methods().map((method) => method.type)).toEqual(["key", "external"])
  expect(app.controller.busy()).toBe(false)
  expect(app.controller.methodIndex()).toBeUndefined()
})

test("an external method with visible fields asks for its form first", async () => {
  const app = await fixture([{ type: "key", label: "Bedrock API key" }, profile])
  await app.controller.auth.select(1)
  expect(app.controller.auth.state()).toBe("form")
  expect(app.calls.external).toEqual([])
})

test("saves the external answer with hidden defaults, stays busy while refreshing and completes", async () => {
  const app = await fixture([{ type: "key", label: "Bedrock API key" }, profile])
  void app.controller.auth.select(1, { profile: "sso-dev" })
  await drain()
  expect(app.calls.external).toEqual([
    {
      integrationID: "amazon-bedrock",
      methodID: "aws-profile",
      answer: { partition: "aws", profile: "sso-dev" },
      location: { directory: "/fixture" },
    },
  ])
  expect(app.controller.auth.state()).toBe("pending")
  expect(app.controller.busy()).toBe(true)
  expect(app.controller.authorization()).toBeUndefined()
  app.saved.resolve()
  await drain()
  expect(app.calls.refreshed).toBe(3)
  expect(app.controller.auth.state()).toBe("ready")
  expect(app.calls.completed).toBe(1)
  expect(app.calls.oauth).toBe(0)
})

test("a single external method without a form saves immediately without an answer", async () => {
  const app = await fixture([cli])
  expect(app.calls.external).toEqual([
    { integrationID: "amazon-bedrock", methodID: "azure-cli", answer: undefined, location: { directory: "/fixture" } },
  ])
  expect(app.controller.busy()).toBe(true)
  app.saved.resolve()
  await drain()
  expect(app.calls.completed).toBe(1)
})

test("a rejected external connection shows the server message and does not complete", async () => {
  const app = await fixture([cli])
  app.saved.reject(new Error("Please run 'az login' to setup account."))
  await drain()
  expect(app.controller.auth.state()).toBe("error")
  expect(app.controller.auth.error()).toBe("Please run 'az login' to setup account.")
  expect(app.controller.busy()).toBe(false)
  expect(app.calls.completed).toBe(0)
  expect(app.calls.refreshed).toBe(0)
})

test("closing while an external connection is saving ignores its late result", async () => {
  const app = await fixture([cli])
  app.dispose()
  app.saved.resolve()
  await drain()
  expect(app.calls.refreshed).toBe(0)
  expect(app.calls.completed).toBe(0)
})

test("going back while an external connection is saving ignores its late result", async () => {
  const app = await fixture([{ type: "key", label: "Bedrock API key" }, profile])
  void app.controller.auth.select(1, { profile: "default" })
  await drain()
  app.controller.auth.reset()
  app.saved.resolve()
  await drain()
  expect(app.controller.methodIndex()).toBeUndefined()
  expect(app.calls.refreshed).toBe(0)
  expect(app.calls.completed).toBe(0)
})
