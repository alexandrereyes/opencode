import { expect, test } from "bun:test"
import type { Preferences } from "@opencode/plugin-app-custom/preferences/rpc"
import { newerProfile } from "./sync"

function profile(revision: number): Preferences.Profile {
  return {
    version: 1,
    revision,
    imported: true,
    data: {
      projects: {},
      sidebarOrder: [],
      pinnedSessions: [],
      models: { user: [], variant: {} },
      settings: {
        followUpBehavior: "steer",
        autoApprove: false,
        autoSave: true,
        notifications: { agent: true, permissions: true, errors: false },
      },
    },
  }
}

test("monotonic reconciliation rejects an older response", () => {
  const current = profile(8)
  expect(newerProfile(current, profile(7))).toBe(current)
  expect(newerProfile(current, profile(9)).revision).toBe(9)
})
