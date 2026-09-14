import { Plugin } from "@opencode/plugin/effect"
import type { RpcRegistration } from "@opencode/plugin/effect/rpc"
import { Effect, Schema } from "effect"
import { Preferences } from "./rpc.js"

const key = "preferences:profile"
const defaults: Preferences.Profile = {
  version: 1,
  revision: 0,
  imported: false,
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
const decode = Schema.decodeUnknownSync(Preferences.Profile)
const encode = Schema.encodeSync(Preferences.Profile)

export function applyIntent(profile: Preferences.Profile, intent: Preferences.Intent): Preferences.Profile {
  const data = mutableData(profile.data)
  if ("server" in intent) {
    const library = data.projects[intent.server] ?? { projects: [], recentlyClosed: [] }
    const project = library.projects.find((item) => item.worktree === intent.directory)
    if (intent.type === "project.open") {
      library.recentlyClosed = library.recentlyClosed.filter((item) => pathKey(item) !== pathKey(intent.directory))
      if (!project) library.projects.unshift({ worktree: intent.directory, expanded: true })
    }
    if (intent.type === "project.close") {
      library.projects = library.projects.filter((item) => item.worktree !== intent.directory)
      library.recentlyClosed = [
        intent.directory,
        ...library.recentlyClosed.filter((item) => pathKey(item) !== pathKey(intent.directory)),
      ].slice(0, 16)
    }
    if (intent.type === "project.remove")
      library.projects = library.projects.filter((item) => item.worktree !== intent.directory)
    if (intent.type === "project.expand" && project) project.expanded = true
    if (intent.type === "project.collapse" && project) project.expanded = false
    if (intent.type === "project.touch") library.lastProject = intent.directory
    if (intent.type === "project.move" && project && intent.toIndex < library.projects.length) {
      const from = library.projects.indexOf(project)
      if (from !== intent.toIndex) {
        library.projects.splice(from, 1)
        library.projects.splice(intent.toIndex, 0, project)
      }
    }
    data.projects[intent.server] = library
  }
  if (intent.type === "sidebar.order") data.sidebarOrder = [...intent.order]
  if (intent.type === "sidebar.pin")
    data.pinnedSessions = intent.pinned
      ? data.pinnedSessions.includes(intent.session)
        ? data.pinnedSessions
        : [...data.pinnedSessions, intent.session]
      : data.pinnedSessions.filter((item) => item !== intent.session)
  if (intent.type === "model.visibility" || intent.type === "model.favorite") {
    const index = data.models.user.findIndex(
      (item) => item.providerID === intent.providerID && item.modelID === intent.modelID,
    )
    const current = data.models.user[index]
    const next = {
      providerID: intent.providerID,
      modelID: intent.modelID,
      visibility: intent.type === "model.visibility" ? intent.visibility : (current?.visibility ?? "show"),
      favorite: intent.type === "model.favorite" ? intent.favorite : current?.favorite,
    }
    if (index === -1) data.models.user.push(next)
    else data.models.user[index] = next
  }
  if (intent.type === "model.variant") data.models.variant[`${intent.providerID}/${intent.modelID}`] = intent.variant
  if (intent.type === "settings.followUpBehavior") data.settings.followUpBehavior = intent.value
  if (intent.type === "settings.autoApprove") data.settings.autoApprove = intent.value
  if (intent.type === "settings.autoSave") data.settings.autoSave = intent.value
  if (intent.type === "settings.notification") data.settings.notifications[intent.notification] = intent.value
  return { ...profile, revision: profile.revision + 1, data }
}

export function importProfile(profile: Preferences.Profile, input: { hasLegacyData: boolean; data: Preferences.Data }) {
  if (profile.imported || profile.revision > 0 || !input.hasLegacyData) return { profile, changed: false as const }
  return {
    profile: { ...profile, revision: profile.revision + 1, imported: true, data: input.data },
    changed: true as const,
  }
}

export const registerPreferences = Effect.fn("Preferences.register")(function* (ctx: Plugin.Context) {
  yield* ctx.storage.adoptLegacy(key)
  yield* ctx.storage.update(key, (current) => [encode(decode(current ?? defaults)), undefined])
  const registration: RpcRegistration<typeof Preferences.Definition> = yield* ctx.rpc
    .register(Preferences.Definition, {
      get: () => ctx.storage.get(key).pipe(Effect.map((value) => decode(value ?? defaults))),
      import: (input) =>
        Effect.gen(function* () {
          const result = yield* ctx.storage.update(key, (current) => {
            const existing = decode(current ?? defaults)
            const result = importProfile(existing, input)
            return [encode(result.profile), result]
          })
          if (result.changed)
            yield* registration.events.emit("updated", { revision: result.profile.revision }).pipe(Effect.orDie)
          return result.profile
        }),
      mutate: (intent) =>
        Effect.gen(function* () {
          const profile = yield* ctx.storage.update(key, (current) => {
            const next = { ...applyIntent(decode(current ?? defaults), intent), imported: true }
            return [encode(next), next]
          })
          yield* registration.events.emit("updated", { revision: profile.revision }).pipe(Effect.orDie)
          return profile
        }),
    })
    .pipe(Effect.orDie)
})

function pathKey(path: string) {
  const value = path[1] === ":" || path.startsWith("\\\\") ? path.replaceAll("\\", "/") : path
  const trimmed = value.replace(/\/+$/, "")
  if (!trimmed && value.startsWith("/")) return "/"
  if (/^[a-zA-Z]:$/.test(trimmed)) return `${trimmed}/`
  return trimmed
}

function mutableData(data: Preferences.Data) {
  return {
    projects: Object.fromEntries(
      Object.entries(data.projects).map(([server, library]) => [
        server,
        {
          projects: library.projects.map((project) => ({ ...project })),
          recentlyClosed: [...library.recentlyClosed],
          lastProject: library.lastProject,
        },
      ]),
    ),
    sidebarOrder: [...data.sidebarOrder],
    pinnedSessions: [...data.pinnedSessions],
    models: { user: data.models.user.map((model) => ({ ...model })), variant: { ...data.models.variant } },
    settings: { ...data.settings, notifications: { ...data.settings.notifications } },
  }
}
