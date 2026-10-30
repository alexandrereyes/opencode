import { sameResource } from "./hub/hub.js"
import type { Resources } from "./rpc.js"

/**
 * A resource a shell command refers to. iOS references may carry only a simulator name, resolved against
 * `simctl list` before registration; everything else is complete enough for the hub, whose probe fills the rest.
 */
export type Reference =
  | { readonly kind: "ios-simulator"; readonly udid?: string; readonly name?: string }
  | { readonly kind: "android-emulator"; readonly serial?: string; readonly avd?: string }
  | { readonly kind: "chrome"; readonly session: string; readonly workspace?: string; readonly cdp?: string }

const uuid = /\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b/gi
const exactUUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i
const simulatorTools = /\b(simctl|xcodebuild|agent-device|axe|idb|serve-sim|maestro)\b/
const emulatorTools = /(^|[\s;&|(/])(adb|emulator|android-emulator|agent-device|maestro|serve-emu)(\s|$)/
/** `simctl` subcommands whose first operand is the device. */
const deviceCommands =
  "boot|bootstatus|spawn|launch|terminate|install|uninstall|io|openurl|addmedia|privacy|push|status_bar|ui|keychain|getenv|location|pbcopy|pbpaste|listapps|appinfo|get_app_container|clone|rename"
const quoted = String.raw`("([^"]+)"|'([^']+)'|([^\s;&|)'"]+))`

/** Resources named by a shell command (and, for `simctl create`, its output). Commands that end one are ignored. */
export function references(command: string, output = "", workdir?: string): Reference[] {
  return dedupe([...simulators(command, output), ...emulators(command), ...browsers(command, workdir)])
}

function simulators(command: string, output: string): Reference[] {
  if (!simulatorTools.test(command)) return []
  if (/\bsimctl\s+(delete|erase|shutdown)\b/.test(command)) return []
  const created = /\bsimctl\s+create\b/.test(command) ? [...output.matchAll(uuid)].map((match) => match[0]) : []
  const udids = [...[...command.matchAll(uuid)].map((match) => match[0]), ...created].map((value) =>
    value.toUpperCase(),
  )
  const names = [
    ...matches(
      command,
      new RegExp(String.raw`\bsimctl\s+(?:${deviceCommands})\s+(?:-[\w-]+(?:=\S+)?\s+)*${quoted}`, "g"),
    ),
    ...matches(command, new RegExp(String.raw`--device[= ]${quoted}`, "g")),
    ...[...command.matchAll(/platform=iOS Simulator[^'"\n]*?\bname=([^,'"\n]+)/g)].map((match) => match[1]!.trim()),
  ].filter((name) => !exactUUID.test(name) && name !== "booted")
  return [
    ...udids.map((udid) => ({ kind: "ios-simulator" as const, udid })),
    ...names.map((name) => ({ kind: "ios-simulator" as const, name })),
  ]
}

function emulators(command: string): Reference[] {
  if (!emulatorTools.test(command)) return []
  const serials = [...command.matchAll(/\bemulator-(\d{4,5})\b/g)].map((match) => `emulator-${match[1]}`)
  const avds = [
    ...matches(
      command,
      new RegExp(String.raw`(?:^|[\s;&|(/])(?:emulator|android-emulator)\s+(?:[^;&|]*?\s)?-avd\s+${quoted}`, "g"),
    ),
    ...[...command.matchAll(/(?:^|[\s;&|(/])emulator\s+@([\w.-]+)/g)].map((match) => match[1]!),
  ]
  return [
    ...serials.map((serial) => ({ kind: "android-emulator" as const, serial })),
    ...avds.map((avd) => ({ kind: "android-emulator" as const, avd })),
  ]
}

function browsers(command: string, workdir: string | undefined): Reference[] {
  const invocations = [
    ...command.matchAll(/(?:^|[\s;&|(])((?:PLAYWRIGHT_CLI_SESSION=\S+\s+)?playwright-cli\b[^;&|\n]*)/g),
  ]
  return invocations.flatMap((match) => {
    const invocation = match[1]!
    const verb = invocation
      .replace(/^PLAYWRIGHT_CLI_SESSION=\S+\s+/, "")
      .split(/\s+/)
      .slice(1)
      .find((word) => !word.startsWith("-"))
    if (
      !verb ||
      ["list", "close-all", "kill-all", "install", "install-browser", "close", "detach", "delete-data"].includes(verb)
    )
      return []
    if (/\s--(help|version)\b/.test(invocation)) return []
    const named = /(?:\s-s[= ]|\s--session[= ]|PLAYWRIGHT_CLI_SESSION=)(?:"([^"]+)"|'([^']+)'|([^\s"']+))/.exec(
      invocation,
    )
    const session = named ? (named[1] ?? named[2] ?? named[3])! : "default"
    const port = /(?:--remote-debugging-port[= ]|--cdp[= ]https?:\/\/(?:127\.0\.0\.1|localhost):)(\d{2,5})/.exec(
      invocation,
    )?.[1]
    return [
      {
        kind: "chrome" as const,
        session,
        ...(workdir ? { workspace: workdir } : {}),
        ...(port ? { cdp: `http://127.0.0.1:${port}` } : {}),
      },
    ]
  })
}

function matches(command: string, pattern: RegExp) {
  return [...command.matchAll(pattern)].map((match) => (match[2] ?? match[3] ?? match[4] ?? "").trim()).filter(Boolean)
}

function dedupe(list: Reference[]) {
  const seen = new Set<string>()
  return list.filter((item) => {
    const key = JSON.stringify(item)
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

/**
 * The registered resources a command names, matched against the hub's registry alone (no `simctl`), so a command is
 * marked in use before it runs without delaying it. A simulator name counts only when exactly one live registered
 * simulator has it; unknown resources wait for the command's result to register them.
 */
export function known(list: readonly Reference[], resources: readonly Resources.Resource[]) {
  const live = resources.filter((resource) => resource.state !== "gone")
  return live.filter((resource) =>
    list.some((reference) => {
      const meta = resource.meta
      if (reference.kind === "ios-simulator" && meta.kind === "ios-simulator") {
        if (reference.udid) return reference.udid.toUpperCase() === meta.udid.toUpperCase()
        const named = live.filter(
          (other) =>
            other.meta.kind === "ios-simulator" && other.meta.name === reference.name && other.state !== "stopped",
        )
        return named.length === 1 && named[0] === resource
      }
      if (reference.kind === "android-emulator" && meta.kind === "android-emulator")
        return (
          (reference.serial !== undefined && reference.serial === meta.serial) ||
          (reference.avd !== undefined && reference.avd === meta.avd)
        )
      if (reference.kind === "chrome" && meta.kind === "chrome")
        return sameResource(meta, {
          kind: "chrome",
          session: reference.session,
          ...(reference.workspace ? { workspace: reference.workspace } : {}),
          ...(reference.cdp ? { cdp: reference.cdp } : {}),
        })
      return false
    }),
  )
}

export type Simulator = { readonly udid: string; readonly name: string; readonly booted: boolean }

/** Completes iOS references to simulator metadata: UDIDs must exist, names resolve (booted first). */
export function resolveSimulators(list: readonly Reference[], simulators: readonly Simulator[]): Resources.Meta[] {
  return list.flatMap((reference): Resources.Meta[] => {
    if (reference.kind === "android-emulator")
      return [
        {
          kind: "android-emulator",
          ...(reference.serial ? { serial: reference.serial } : {}),
          ...(reference.avd ? { avd: reference.avd } : {}),
        },
      ]
    if (reference.kind === "chrome")
      return [
        {
          kind: "chrome",
          session: reference.session,
          ...(reference.workspace ? { workspace: reference.workspace } : {}),
          ...(reference.cdp ? { cdp: reference.cdp } : {}),
        },
      ]
    const found = reference.udid
      ? simulators.find((item) => item.udid === reference.udid)
      : named(simulators, reference.name)
    return found ? [{ kind: "ios-simulator", udid: found.udid, name: found.name }] : []
  })
}

/** The simulator a name means: the only booted one with it, else the only one. Ambiguous names register nothing. */
function named(simulators: readonly Simulator[], name: string | undefined) {
  const candidates = simulators.filter((item) => item.name === name)
  const booted = candidates.filter((item) => item.booted)
  if (booted.length === 1) return booted[0]
  return booted.length === 0 && candidates.length === 1 ? candidates[0] : undefined
}

/** `simctl list devices -j` as flat simulators. */
export function parseSimulators(output: unknown): Simulator[] {
  if (typeof output !== "object" || output === null || !("devices" in output)) return []
  const groups = output.devices
  if (typeof groups !== "object" || groups === null) return []
  return Object.values(groups).flatMap((devices: unknown) =>
    (Array.isArray(devices) ? devices : []).flatMap((device: unknown): Simulator[] =>
      typeof device === "object" &&
      device !== null &&
      "udid" in device &&
      typeof device.udid === "string" &&
      "name" in device &&
      typeof device.name === "string"
        ? [
            {
              udid: device.udid.toUpperCase(),
              name: device.name,
              booted: "state" in device && device.state === "Booted",
            },
          ]
        : [],
    ),
  )
}
