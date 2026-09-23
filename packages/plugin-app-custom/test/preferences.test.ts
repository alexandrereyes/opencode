import { expect, test } from "bun:test"
import { Schema } from "effect"
import { applyIntent, importProfile } from "../src/preferences"
import { Preferences } from "../src/preferences/rpc"

const profile: Preferences.Profile = {
  version: 1,
  revision: 4,
  imported: true,
  data: {
    projects: { local: { projects: [{ worktree: "/repo", expanded: true }], recentlyClosed: [] } },
    sidebarOrder: ["missing", "local:/repo"],
    pinnedSessions: ["missing-session"],
    models: { user: [], variant: {} },
    settings: {
      followUpBehavior: "steer",
      autoApprove: false,
      autoSave: true,
      tabLayout: "horizontal",
      notifications: { agent: true, permissions: true, errors: false },
    },
  },
}

test("preferences contract is versioned and typed", () => {
  expect(Schema.decodeUnknownSync(Preferences.Profile)(Schema.encodeSync(Preferences.Profile)(profile))).toEqual(
    profile,
  )
  expect(Preferences.Definition.id).toBe("custom.preferences")
  expect(Object.keys(Preferences.Definition.methods)).toEqual(["get", "import", "mutate"])
})

test("project intents preserve close history and unknown references", () => {
  const closed = Array.from({ length: 18 }, (_, index) => `/closed/${index}`).reduce(
    (current, directory) => applyIntent(current, { type: "project.close", server: "local", directory }),
    profile,
  )
  expect(closed.revision).toBe(22)
  expect(closed.data.projects.local.recentlyClosed).toHaveLength(16)
  expect(closed.data.sidebarOrder[0]).toBe("missing")
  expect(closed.data.pinnedSessions).toEqual(["missing-session"])
})

test("model and behavioral intents change only their owned preference", () => {
  const visible = applyIntent(profile, {
    type: "model.visibility",
    providerID: "anthropic",
    modelID: "claude",
    visibility: "hide",
  })
  const approved = applyIntent(visible, { type: "settings.autoApprove", value: true })
  expect(approved.data.models.user).toEqual([
    { providerID: "anthropic", modelID: "claude", visibility: "hide", favorite: undefined },
  ])
  expect(approved.data.settings.autoApprove).toBe(true)
  expect(approved.data.models).not.toHaveProperty("recent")
})

test("favorites keep their own order without changing model visibility", () => {
  const favorite = (current: Preferences.Profile, modelID: string, value: boolean) =>
    applyIntent(current, { type: "model.favorite", providerID: "openai", modelID, favorite: value })
  const added = favorite(favorite(profile, "a", true), "b", true)
  expect(added.data.models.favorites).toEqual([
    { providerID: "openai", modelID: "b" },
    { providerID: "openai", modelID: "a" },
  ])
  expect(added.data.models.user).toEqual([])

  const ordered = applyIntent(added, {
    type: "model.favorite.order",
    favorites: [
      { providerID: "openai", modelID: "a" },
      { providerID: "openai", modelID: "b" },
    ],
  })
  expect(favorite(ordered, "a", false).data.models.favorites).toEqual([{ providerID: "openai", modelID: "b" }])
})

test("provider order and default model round-trip and clear", () => {
  const ordered = applyIntent(profile, { type: "model.provider.order", order: ["openai", "anthropic"] })
  const defaulted = applyIntent(ordered, {
    type: "model.default",
    model: { providerID: "openai", modelID: "gpt", variant: "high" },
  })
  expect(defaulted.data.models.providerOrder).toEqual(["openai", "anthropic"])
  expect(defaulted.data.models.default).toEqual({ providerID: "openai", modelID: "gpt", variant: "high" })
  expect(
    Schema.decodeUnknownSync(Preferences.Profile)(Schema.encodeSync(Preferences.Profile)(defaulted)).data.models,
  ).toEqual(defaulted.data.models)

  const cleared = applyIntent(defaulted, { type: "model.default", model: null })
  expect(Schema.encodeSync(Preferences.Profile)(cleared).data.models).not.toHaveProperty("default")
})

test("tab layout is global while profiles saved before it remain valid", () => {
  const legacy = Schema.encodeSync(Preferences.Profile)(profile)
  delete (legacy.data.settings as { tabLayout?: string }).tabLayout

  expect(Schema.decodeUnknownSync(Preferences.Profile)(legacy).data.settings.tabLayout).toBeUndefined()
  expect(applyIntent(profile, { type: "settings.tabLayout", value: "vertical" }).data.settings.tabLayout).toBe(
    "vertical",
  )
})

test("one-shot import never lets an empty or stale client replace remote data", () => {
  const fresh = { ...profile, revision: 0, imported: false }
  expect(importProfile(fresh, { hasLegacyData: false, data: profile.data })).toEqual({ profile: fresh, changed: false })
  expect(importProfile(fresh, { hasLegacyData: true, data: profile.data }).profile).toMatchObject({
    revision: 1,
    imported: true,
  })
  expect(importProfile(profile, { hasLegacyData: true, data: { ...profile.data, sidebarOrder: [] } })).toEqual({
    profile,
    changed: false,
  })
})

test("concurrent one-shot imports serialize and the first non-empty import wins", async () => {
  const fresh = { ...profile, revision: 0, imported: false }
  const first = { ...profile.data, sidebarOrder: ["first"] }
  const second = { ...profile.data, sidebarOrder: ["second"] }
  const storage = { profile: fresh, update: Promise.resolve() }
  const run = (data: Preferences.Data) => {
    const result = storage.update.then(() => {
      const update = importProfile(storage.profile, { hasLegacyData: true, data })
      storage.profile = update.profile
      return update
    })
    storage.update = result.then(() => undefined)
    return result
  }

  const results = await Promise.all([run(first), run(second)])
  expect(results.map((result) => result.changed)).toEqual([true, false])
  expect(storage.profile.data.sidebarOrder).toEqual(["first"])
  expect(storage.profile.revision).toBe(1)
})

test("project move rejects invalid wire indexes and ignores out-of-range indexes", () => {
  expect(() =>
    Schema.decodeUnknownSync(Preferences.Intent)({
      type: "project.move",
      server: "local",
      directory: "/repo",
      toIndex: -1,
    }),
  ).toThrow()
  expect(() =>
    Schema.decodeUnknownSync(Preferences.Intent)({
      type: "project.move",
      server: "local",
      directory: "/repo",
      toIndex: 0.5,
    }),
  ).toThrow()
  expect(
    applyIntent(profile, { type: "project.move", server: "local", directory: "/repo", toIndex: 10 }).data.projects,
  ).toEqual(profile.data.projects)
})
