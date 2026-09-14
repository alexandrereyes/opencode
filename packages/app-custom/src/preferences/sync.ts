import type { Preferences } from "@opencode/plugin-app-custom/preferences/rpc"

export function newerProfile(current: Preferences.Profile, incoming: Preferences.Profile) {
  if (incoming.revision < current.revision) return current
  return incoming
}
