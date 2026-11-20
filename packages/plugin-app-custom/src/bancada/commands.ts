import path from "node:path"
import { localCommand, machineParts, references } from "../resources/discovery.js"

/**
 * What a shell command does to devices, as the Bancada's hook reads it (`docs/bancada.md`, "Hook"): per machine it
 * runs on (here, or behind the `mac` bridge), the emulators and simulators it names and the ones it starts. The process
 * decides on these; this side only reads the command.
 */

/** An emulator or simulator the command starts: `emulator -avd X`, `emulator @X`, `simctl boot X`, `simslim on X`. */
export type Start = { readonly platform: "android" | "ios"; readonly name: string }

export type Part = {
  readonly where: "here" | "mac"
  /** The part's own text, where the process looks for phones of the catalog. */
  readonly command: string
  readonly emulators: ReadonlyArray<{ readonly serial?: string; readonly avd?: string }>
  readonly simulators: ReadonlyArray<{ readonly udid?: string; readonly name?: string }>
  readonly starts: ReadonlyArray<Start>
}

/** Tools that drive a device: the cheap filter before anything is asked (phones too: `devicectl`, `idevice*`). */
const deviceTools =
  /(^|[\s;&|(/])(adb|emulator|android-emulator|agent-device|maestro|serve-emu|serve-sim|simctl|xcodebuild|idb|axe|simslim|devicectl|idevice\w*|appium|fastboot)(\s|$)/

/** Whether a command may touch a device at all: only then is the process asked. */
export function touchesDevices(command: string) {
  return deviceTools.test(localCommand(command))
}

/** The command's parts per machine, with what each names and starts; parts that name nothing still go (phones). */
export function inspect(command: string): Part[] {
  const parts = machineParts(command)
  return (["here", "mac"] as const).flatMap((where) => {
    const text = parts[where].trim()
    if (!text || !deviceTools.test(text)) return []
    const named = references(text)
    const emulators = named.flatMap((item) =>
      item.kind === "android-emulator"
        ? [{ ...(item.serial ? { serial: item.serial } : {}), ...(item.avd ? { avd: item.avd } : {}) }]
        : [],
    )
    const simulators = named.flatMap((item) =>
      item.kind === "ios-simulator"
        ? [{ ...(item.udid ? { udid: item.udid } : {}), ...(item.name ? { name: item.name } : {}) }]
        : [],
    )
    return [{ where, command: text, emulators, simulators, starts: starts(text) }]
  })
}

const operand = String.raw`("([^"]+)"|'([^']+)'|([^\s;&|)'"]+))`

/** The devices a command boots. Every `-avd` and `@` the emulator tools take is a start. */
function starts(command: string): Start[] {
  const android = references(command).flatMap((item) =>
    item.kind === "android-emulator" && item.avd ? [{ platform: "android" as const, name: item.avd }] : [],
  )
  const named = (pattern: RegExp) =>
    [...command.matchAll(pattern)].map((match) => (match[2] ?? match[3] ?? match[4] ?? "").trim()).filter(Boolean)
  const ios = [
    ...named(new RegExp(String.raw`\bsimctl\s+boot\s+${operand}`, "g")),
    ...named(new RegExp(String.raw`\bsimctl\s+bootstatus\s+${operand}[^;&|\n]*\s-b\b`, "g")),
    ...named(new RegExp(String.raw`\bsimslim\s+on\s+${operand}`, "g")),
  ]
    .filter((name) => name !== "booted")
    .map((name) => ({ platform: "ios" as const, name }))
  const seen = new Set<string>()
  return [...android, ...ios].filter((item) => {
    const key = `${item.platform}:${item.name}`
    if (seen.has(key)) return false
    seen.add(key)
    return true
  })
}

/**
 * The first simple command, run on this machine, that starts with a path the repository reserves to the Bancada
 * (`fora` of `.bancada.toml`), directly or as a shell's script, without `BANCADA_JOB` in its environment.
 */
export function reserved(command: string, input: { root: string; workdir: string; outside: ReadonlyArray<string> }) {
  const outside = new Set(input.outside.map((item) => path.resolve(input.root, item)))
  if (outside.size === 0) return undefined
  return localCommand(command)
    .split("\n")
    .map((line) => line.trim())
    .find((line) => {
      const words = line.split(/\s+/).filter(Boolean)
      if (words.some((word, index) => index < first(words) && word.startsWith("BANCADA_JOB="))) return false
      const at = first(words)
      const tool = words[at]
      if (!tool) return false
      const program = ["sh", "bash", "zsh", "dash"].includes(tool.split("/").pop()!)
        ? words.slice(at + 1).find((word) => !word.startsWith("-"))
        : tool
      if (!program || !(program.includes("/") || program.includes("."))) return false
      return outside.has(path.resolve(input.workdir, program.replace(/^['"]|['"]$/g, "")))
    })
}

/** Where the program starts: after `VAR=value` assignments and wrappers (`env`, `exec`, `nohup`, `time`, `timeout N`). */
function first(words: readonly string[]) {
  let index = 0
  for (; index < words.length; index++) {
    const word = words[index]!
    if (/^[A-Za-z_]\w*=/.test(word) || ["exec", "env", "nohup", "command", "time"].includes(word)) continue
    if (word === "timeout") {
      index++
      continue
    }
    break
  }
  return index
}
