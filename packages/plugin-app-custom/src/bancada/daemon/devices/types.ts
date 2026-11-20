import { deviceCosts } from "../../catalog/costs.js"
import type { BancadaProtocol } from "../../protocol.js"
import type { Range } from "../../machine-config.js"

/** The kinds of devices the Bancada hands to a project (`docs/bancada.md`, "Devices"). */
export type DeviceKind = "android-emulador" | "android-docker" | "ios-simulador" | "android-fisico" | "ios-fisico"

/** How a device starts: trimmed of what tests never use, or as it comes. */
export type Profile = "enxuto" | "estoque"

/** A device of the `device` table, as a driver sees it. */
export type DeviceRow = {
  readonly id: string
  readonly kind: DeviceKind
  readonly profile: Profile
  readonly native: string
  readonly serial?: string
  readonly consolePort?: number
  readonly adbPort?: number
  readonly pid?: number
}

/** What goes in `devices.json` for one device (keys in Portuguese: it is the project's file). */
export type DeviceView = Readonly<Record<string, unknown>>

/** The ports of one granted device: the project's block of 20. */
export type PortSlot = Range

/**
 * One kind of device on this machine (`docs/bancada.md`, "Devices"). A driver touches only what the Bancada created
 * (the machine's prefix and a row of `device`), and proves a device's identity before stopping it.
 */
export interface DeviceDriver {
  readonly kind: DeviceKind
  /** Whether this machine can have a device of this spec, with its profile and default cost. */
  readonly fits: (spec: BancadaProtocol.DeviceSpec) =>
    | { readonly ok: true; readonly profile: Profile; readonly cost: { memMb: number; cpuMilli: number } }
    | {
        readonly ok: false
        readonly why: string
      }
  /** Makes sure the device exists (creates it when needed). Idempotent. */
  readonly ensure: (device: DeviceRow) => Promise<void>
  /** Starts it from its clean state, ready for the project: what goes in `devices.json`. */
  readonly ready: (device: DeviceRow, slot: PortSlot) => Promise<DeviceView>
  readonly health: (device: DeviceRow) => Promise<"ok" | "morto" | "mudo">
  /** Gives it back clean: stopped, or cleaned and kept warm. */
  readonly giveBack: (device: DeviceRow, keepWarm: boolean) => Promise<void>
  readonly destroy: (device: DeviceRow) => Promise<void>
  /** What exists right now, for reconciliation. */
  readonly actual: () => Promise<
    ReadonlyArray<{
      readonly native: string
      readonly running: boolean
      readonly serial?: string
      readonly pid?: number
    }>
  >
}

/**
 * The device a part would get here and its cost subject (`<kind>:<profile>`): an emulator of the machine (or a
 * container's, with `[android.docker]`), or a simulator, trimmed when the part accepts it and the machine can (`simslim`
 * for iOS). `undefined` for a part without devices.
 */
export function deviceFor(
  platform: BancadaProtocol.Platform,
  spec: BancadaProtocol.DeviceSpec,
  input: { readonly docker: boolean; readonly simslim: boolean },
) {
  if (platform === "none") return undefined
  const trimmed = spec.slim === "exige" || (spec.slim !== "recusa" && (platform === "android" || input.simslim))
  const profile: Profile = trimmed ? "enxuto" : "estoque"
  const kind: DeviceKind = platform === "ios" ? "ios-simulador" : input.docker ? "android-docker" : "android-emulador"
  const cost = kind === "ios-simulador" ? deviceCosts[`ios-simulador:${profile}`] : deviceCosts[kind]
  return { kind, profile, subject: `${kind}:${profile}`, cost }
}
