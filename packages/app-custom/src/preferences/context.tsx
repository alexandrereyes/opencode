import { Preferences } from "@opencode/plugin-app-custom/preferences/rpc"
import { createSimpleContext } from "@opencode/ui-custom/context"
import { createEffect, on, onCleanup, type JSX } from "solid-js"
import { createStore, reconcile } from "solid-js/store"
import { createServerSdkContext } from "@/runtime/server/client"
import { ServerConnection } from "@/runtime/server/registry"
import { ServerScope } from "@/runtime/server/scope"
import {
  canMutatePreferences,
  completePreferenceMigration,
  createPreferenceIntentQueue,
  initialPreferenceBootstrap,
  receivePreferenceProfile,
} from "./bootstrap"

type LegacySource = {
  raw: Promise<string | null> | string | null
  read: () => Partial<Preferences.Data>
}

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
      tabLayout: "vertical",
      notifications: { agent: true, permissions: true, errors: false },
    },
  },
}

export const { use: usePreferences, provider: PreferencesProvider } = createSimpleContext({
  name: "Preferences",
  gate: false,
  init: (props: { authority?: ServerConnection.Any; children?: JSX.Element }) => {
    const [state, setState] = createStore(initialPreferenceBootstrap(defaults, !!props.authority))
    const sources = new Map<string, LegacySource>()
    const sdk = props.authority
      ? createServerSdkContext(props.authority, ServerScope.fromServerKey(ServerConnection.key(props.authority)))
      : undefined
    const client = sdk?.api.rpc(Preferences.Definition)
    let importStarted = false

    const apply = (profile: Preferences.Profile) => {
      const next = receivePreferenceProfile(state, profile)
      if (next === state) return
      setState(reconcile(next))
      if (next.phase === "canonical") void intents.drain()
    }
    const send = async (intent: Preferences.Intent) => {
      const result = await client?.mutate(intent)
      if (result) apply(result)
    }
    const intents = createPreferenceIntentQueue({
      ready: () => canMutatePreferences(state, !!props.authority),
      send,
    })
    const refresh = () =>
      client
        ?.get({})
        .then((profile) => {
          apply(profile)
          void importLegacy()
        })
        .catch(() => undefined)
    const importLegacy = async () => {
      if (!client || importStarted || sources.size < 4) return
      importStarted = true
      const entries = [...sources.values()]
      const raws = await Promise.all(entries.map((source) => source.raw)).catch(() => undefined)
      if (!raws) {
        importStarted = false
        return
      }
      const hasLegacyData = raws.some((raw) => raw !== null)
      const data = mutableData(defaults.data)
      entries
        .map((source) => source.read())
        .forEach((piece) => {
          if (piece.projects) data.projects = mutableData({ ...defaults.data, projects: piece.projects }).projects
          if (piece.sidebarOrder) data.sidebarOrder = [...piece.sidebarOrder]
          if (piece.pinnedSessions) data.pinnedSessions = [...piece.pinnedSessions]
          if (piece.models) data.models = mutableData({ ...defaults.data, models: piece.models }).models
          if (piece.settings) data.settings = { ...piece.settings, notifications: { ...piece.settings.notifications } }
        })
      await client
        .import({ hasLegacyData, data })
        .then((profile) => {
          setState(reconcile(completePreferenceMigration(state, profile)))
          void intents.drain()
        })
        .catch(() => {
          importStarted = false
        })
    }

    if (sdk) {
      createEffect(on(() => `${sdk.connection.status()}:${sdk.connection.epoch()}`, refresh))
      onCleanup(
        client!.events.on("updated", (event) => {
          if (event.data.revision <= state.profile.revision) return
          void refresh()
        }),
      )
      const focus = () => void refresh()
      if (typeof window !== "undefined") {
        window.addEventListener("focus", focus)
        onCleanup(() => window.removeEventListener("focus", focus))
      }
    }

    return {
      profile: () => state.profile,
      phase: () => state.phase,
      canonical: () => state.phase === "canonical",
      legacy(id: string, source: LegacySource) {
        sources.set(id, source)
        void importLegacy()
      },
      async mutate(intent: Preferences.Intent) {
        if (!client) return
        intents.enqueue(intent)
      },
      refresh,
    }
  },
})

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
