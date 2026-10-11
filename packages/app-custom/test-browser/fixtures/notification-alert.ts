import { expect, mock, test } from "bun:test"
import { createRoot } from "solid-js"
import type { Data } from "@opencode/client/solid"
import type { ServerSDK } from "@/runtime/server/client"
import type { ServerConnection } from "@/runtime/server/registry"
import { ServerScope } from "@/runtime/server/scope"
import type { Tab } from "@/shell/tabs/tabs"

const server = "local\nhttp://localhost:4096" as ServerConnection.Key
const session = { id: "session-1", title: "Test session", location: { directory: "/project" } }
const alerts: string[] = []
const tabs: { store: Tab[] } = { store: [] }
const { sessionIDHasOpenTab } = await import("@/shell/tabs/tabs")

mock.module("@/runtime/platform/platform", () => ({
  usePlatform: () => ({
    platform: "web",
    notify: async (title: string) => {
      alerts.push(title)
    },
  }),
}))
mock.module("@/settings/model", () => ({
  useSettings: () => ({
    sounds: { agentEnabled: () => false, errorsEnabled: () => false },
    notifications: { agent: () => true, errors: () => true },
  }),
}))
mock.module("@/runtime/i18n/language", () => ({ useLanguage: () => ({ t: (key: string) => key }) }))
mock.module("@/shell/tabs/tabs", () => ({ useTabs: () => tabs, sessionIDHasOpenTab }))
const { createServerNotificationState } = await import("@/shell/notifications/notification")

test.each([
  ["session.execution.succeeded", "notification.session.responseReady.title"],
  ["session.execution.failed", "notification.session.error.title"],
] as const)("system alert for %s requires an open session tab", async (type, title) => {
  alerts.length = 0
  tabs.store = [{ type: "session", server, sessionId: "another-session" }]
  const listeners: ((event: unknown) => void)[] = []
  const root = createRoot((dispose) => ({
    dispose,
    state: createServerNotificationState({
      key: server,
      sdk: {
        // Notification history persists per server scope; keep each case separate.
        scope: ServerScope.fromServerKey(`${server}-${type}` as ServerConnection.Key),
        event: {
          listen: (fn: (event: unknown) => void) => {
            listeners.push(fn)
            return () => {}
          },
        },
      } as unknown as ServerSDK,
      data: { session: { get: () => session } } as unknown as Data,
      coordinator: {
        sound: async () => {},
        system: async (_id: string, fn: () => Promise<void>) => fn(),
      } as unknown as Parameters<typeof createServerNotificationState>[0]["coordinator"],
    }),
  }))
  const emit = (id: string) =>
    listeners.forEach((listener) =>
      listener({
        type,
        id,
        created: Date.now(),
        data: { sessionID: session.id, error: { type: "api", message: "failed", status: 500 } },
      }),
    )

  emit("event-1")
  await new Promise((resolve) => setTimeout(resolve, 0))
  // The notification history still records sessions without an open tab.
  expect(root.state.session.all(session.id)).toHaveLength(1)
  expect(alerts).toEqual([])

  tabs.store = [{ type: "session", server, sessionId: session.id }]
  emit("event-2")
  await new Promise((resolve) => setTimeout(resolve, 0))
  expect(root.state.session.all(session.id)).toHaveLength(2)
  expect(alerts).toEqual([title])
  root.dispose()
})
