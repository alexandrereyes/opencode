import type { Preferences } from "@opencode/plugin-app-custom/preferences/rpc"
import { newerProfile } from "./sync"

export type PreferencePhase = "local" | "fetching" | "migration" | "canonical"

export type PreferenceBootstrap = {
  phase: PreferencePhase
  profile: Preferences.Profile
}

export function initialPreferenceBootstrap(profile: Preferences.Profile, authority: boolean): PreferenceBootstrap {
  return { profile, phase: authority ? "fetching" : "local" }
}

export function receivePreferenceProfile(
  state: PreferenceBootstrap,
  profile: Preferences.Profile,
): PreferenceBootstrap {
  const next = newerProfile(state.profile, profile)
  if (next === state.profile) return state
  if (state.phase === "canonical") return { profile: next, phase: "canonical" }
  return { profile: next, phase: profile.imported ? "canonical" : "migration" }
}

export function completePreferenceMigration(
  state: PreferenceBootstrap,
  profile: Preferences.Profile,
): PreferenceBootstrap {
  return { profile: newerProfile(state.profile, profile), phase: "canonical" }
}

export function canonicalPreferences(state: PreferenceBootstrap) {
  return state.phase === "canonical"
}

export function canMutatePreferences(state: PreferenceBootstrap, authority: boolean) {
  return authority && canonicalPreferences(state)
}

export function preferenceValue<T>(state: PreferenceBootstrap, local: T, remote: T) {
  return canonicalPreferences(state) ? remote : local
}

export function preferenceAutoApprove(state: PreferenceBootstrap, local: boolean) {
  if (state.phase === "local") return local
  if (!canonicalPreferences(state)) return false
  return state.profile.data.settings.autoApprove
}

export function createPreferenceIntentQueue(input: {
  ready: () => boolean
  send: (intent: Preferences.Intent) => Promise<void>
}) {
  const pending: Preferences.Intent[] = []
  let draining = false

  const drain = async () => {
    if (draining || !input.ready()) return
    draining = true
    const next = async (): Promise<void> => {
      if (!input.ready()) {
        draining = false
        return
      }
      const intent = pending.shift()
      if (!intent) {
        draining = false
        return
      }
      await input.send(intent).catch(() => undefined)
      return next()
    }
    await next()
  }

  return {
    enqueue(intent: Preferences.Intent) {
      pending.push(intent)
      void drain()
    },
    drain,
    size: () => pending.length,
  }
}
