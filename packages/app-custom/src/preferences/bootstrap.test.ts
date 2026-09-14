import { expect, test } from "bun:test"
import type { Preferences } from "@opencode/plugin-app-custom/preferences/rpc"
import {
  canMutatePreferences,
  completePreferenceMigration,
  createPreferenceIntentQueue,
  initialPreferenceBootstrap,
  preferenceAutoApprove,
  preferenceValue,
  receivePreferenceProfile,
} from "./bootstrap"

function profile(input: { revision?: number; imported?: boolean; order?: string[]; pins?: string[] } = {}) {
  return {
    version: 1,
    revision: input.revision ?? 0,
    imported: input.imported ?? false,
    data: {
      projects: {},
      sidebarOrder: input.order ?? [],
      pinnedSessions: input.pins ?? [],
      models: { user: [], variant: {} },
      settings: {
        followUpBehavior: "steer",
        autoApprove: true,
        autoSave: true,
        notifications: { agent: true, permissions: true, errors: false },
      },
    },
  } satisfies Preferences.Profile
}

test("an empty remote GET keeps legacy order and pins authoritative until import finishes", () => {
  const legacy = { order: ["server:/repo"], pins: ["server:session"] }
  const fetched = receivePreferenceProfile(initialPreferenceBootstrap(profile(), true), profile())

  expect(fetched.phase).toBe("migration")
  expect(preferenceValue(fetched, legacy.order, fetched.profile.data.sidebarOrder)).toEqual(legacy.order)
  expect(preferenceValue(fetched, legacy.pins, fetched.profile.data.pinnedSessions)).toEqual(legacy.pins)
  expect(canMutatePreferences(fetched, true)).toBe(false)
  expect(preferenceAutoApprove(fetched, true)).toBe(false)

  const imported = completePreferenceMigration(fetched, profile({ revision: 1, imported: true, ...legacy }))
  expect(imported.phase).toBe("canonical")
  expect(canMutatePreferences(imported, true)).toBe(true)
  expect(preferenceValue(imported, [], imported.profile.data.sidebarOrder)).toEqual(legacy.order)
})

test("failed import remains retryable and no-authority mode remains local", () => {
  const migration = receivePreferenceProfile(initialPreferenceBootstrap(profile(), true), profile())
  expect(receivePreferenceProfile(migration, profile()).phase).toBe("migration")
  expect(canMutatePreferences(migration, true)).toBe(false)
  expect(completePreferenceMigration(migration, profile()).phase).toBe("canonical")

  const local = initialPreferenceBootstrap(profile(), false)
  expect(local.phase).toBe("local")
  expect(canMutatePreferences(local, false)).toBe(false)
  expect(preferenceValue(local, ["legacy"], [])).toEqual(["legacy"])
  expect(preferenceAutoApprove(local, true)).toBe(true)
})

test("bootstrap intents drain once in order only after preferences become canonical", async () => {
  const state = { ready: false }
  const sent: string[] = []
  const queue = createPreferenceIntentQueue({
    ready: () => state.ready,
    send: async (intent) => {
      sent.push(intent.type)
    },
  })

  queue.enqueue({ type: "project.open", server: "local", directory: "/repo" })
  queue.enqueue({ type: "sidebar.pin", session: "local:session", pinned: true })
  queue.enqueue({ type: "project.close", server: "local", directory: "/repo" })
  await Promise.resolve()
  expect(sent).toEqual([])
  expect(queue.size()).toBe(3)

  state.ready = true
  await queue.drain()
  expect(sent).toEqual(["project.open", "sidebar.pin", "project.close"])
  expect(queue.size()).toBe(0)
})

test("canonical draining is serial and drops a failed attempt without retrying forever", async () => {
  const sent: string[] = []
  const active = { value: 0, maximum: 0 }
  const state = { ready: false }
  const queue = createPreferenceIntentQueue({
    ready: () => state.ready,
    send: async (intent) => {
      active.value++
      active.maximum = Math.max(active.maximum, active.value)
      sent.push(intent.type)
      await Promise.resolve()
      active.value--
      if (intent.type === "sidebar.pin") throw new Error("disconnected")
    },
  })

  queue.enqueue({ type: "project.open", server: "local", directory: "/repo" })
  queue.enqueue({ type: "sidebar.pin", session: "local:session", pinned: true })
  queue.enqueue({ type: "project.close", server: "local", directory: "/repo" })
  state.ready = true
  await queue.drain()

  expect(active.maximum).toBe(1)
  expect(sent).toEqual(["project.open", "sidebar.pin", "project.close"])
  expect(queue.size()).toBe(0)
})
