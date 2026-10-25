import type { Resources } from "../rpc.js"
import { adapter as androidEmulator } from "./android-emulator.js"
import { adapter as chrome } from "./chrome.js"
import { adapter as iosSimulator } from "./ios-simulator.js"
import type { Adapter } from "./types.js"

/** The hub's adapters, one per kind. Each lives in its own file so kinds evolve independently. */
export const adapters: Readonly<Record<Resources.Kind, Adapter>> = {
  "ios-simulator": iosSimulator,
  "android-emulator": androidEmulator,
  chrome,
}
