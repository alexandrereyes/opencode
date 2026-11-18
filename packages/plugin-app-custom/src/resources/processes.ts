import type { Resources } from "./rpc.js"

/**
 * "Em uso por teste" (`docs/resources.md`, "Inventory and tests"): which simulators and emulators processes of the hub's
 * machine use now, from one `ps` per cycle. A process uses a device when its command line names the simulator's UDID or
 * the emulator's serial (`xcodebuild … id=<UDID>`, WebDriverAgent, `adb -s emulator-5556 shell am instrument`, a test
 * script's `tee …/said-<UDID>`). What does not count:
 *
 * - paths inside a simulator (`CoreSimulator/Devices/<UDID>/…`): the simulator's own processes and its apps;
 * - orphans (parent PID 1): what a finished run left behind, such as Appium's WebDriverAgent or `adb logcat`; a real
 *   run's processes have a living parent;
 * - the resources hubs' own helpers (serve-sim, their `adb` probes) and the emulator itself;
 * - processes younger than `minimumAgeMs`: one-off queries (`adb -s … getprop`, `simctl io … screenshot`).
 */
export interface ProcessRow {
  readonly pid: number
  readonly ppid: number
  /** Seconds since it started. */
  readonly elapsed: number
  readonly command: string
}

export interface Device {
  readonly id: string
  readonly meta: Resources.Meta
}

export interface Use {
  /** The process that reports the use: the outermost test runner above the one that names the device. */
  readonly pid: number
  readonly command: string
  /** Epoch ms when it started. */
  readonly since: number
  readonly folder?: string
}

export const minimumAgeMs = 3_000

/** `ps -Ao pid=,ppid=,etime=,command=` rows. */
export function parsePs(output: string): ProcessRow[] {
  return output.split("\n").flatMap((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line)
    if (!match) return []
    return [{ pid: Number(match[1]), ppid: Number(match[2]), elapsed: seconds(match[3]!), command: match[4]! }]
  })
}

/** `[[dd-]hh:]mm:ss` as seconds. */
export function seconds(etime: string) {
  const [days, rest] = etime.includes("-") ? etime.split("-") : ["0", etime]
  const parts = (rest ?? "").split(":").map(Number)
  const value = parts.reduce((total, part) => total * 60 + (Number.isFinite(part) ? part : 0), 0)
  return Number(days) * 86_400 + value
}

const simulatorPath = /CoreSimulator\/Devices\/[0-9A-Fa-f-]{36}/g
const emulatorProcess = /(?:qemu-system|\/emulator\/emulator\b|(?:^|\/)emulator\s+(?:.*\s)?-avd\s)/
const ownProbe = /\bemu\s+avd\s+name\b/
const runner =
  /(?:\/scripts\/|\bscripts\/|\bdotnet\s+(?:test|run|watch)\b|\bxcodebuild\b|\bappium\b|\bmaestro\b|\bgradlew?\b|\bflutter\b|\bdetox\b|\bagent-device\b|\bpytest\b|\bswift\s+test\b|\bbun\s+test\b|\bnpx\b|\bplaywright\b)/
const folderPattern = /\/Worktrees\/([\w.-]+)|\/(?:run|repo)-([\w.-]+?)(?=\/|\s|$)/

/**
 * Each device a process uses now, with the use that started first. `self` is this hub's PID: its own subtree (and any
 * other resources hub's, by its `--opencode-resources-hub` command line) never counts.
 */
export function uses(rows: readonly ProcessRow[], devices: readonly Device[], self: number, now: number) {
  const byPid = new Map(rows.map((row) => [row.pid, row]))
  const chain = (row: ProcessRow) => {
    const list: ProcessRow[] = []
    let current: ProcessRow | undefined = row
    while (current && list.length < 64 && !list.includes(current)) {
      list.push(current)
      current = current.ppid > 1 ? byPid.get(current.ppid) : undefined
    }
    return list
  }
  const hub = (row: ProcessRow) =>
    chain(row).some((item) => item.pid === self || item.command.includes("--opencode-resources-hub"))
  const tokens = devices.flatMap((device) => {
    const token = tokenOf(device.meta)
    return token ? [{ device, pattern: new RegExp(`(?<!\\w)${escape(token)}(?!\\w)`, "i") }] : []
  })
  const found = new Map<string, Use>()
  if (tokens.length === 0) return found
  for (const row of rows) {
    if (row.ppid <= 1 || row.elapsed * 1000 < minimumAgeMs) continue
    const text = row.command.replace(simulatorPath, "")
    const named = tokens.filter((token) => token.pattern.test(text))
    if (named.length === 0 || emulatorProcess.test(row.command) || ownProbe.test(row.command) || hub(row)) continue
    const ancestors = chain(row)
    const reported = ancestors.findLast((item) => item.ppid > 1 && runner.test(item.command)) ?? row
    const folder = ancestors.flatMap((item) => {
      const match = folderPattern.exec(item.command)
      return match ? [match[1] ?? match[2]!] : []
    })[0]
    const use: Use = {
      pid: reported.pid,
      command: reported.command,
      since: now - reported.elapsed * 1000,
      ...(folder ? { folder } : {}),
    }
    for (const { device } of named) {
      const current = found.get(device.id)
      if (!current || use.since < current.since) found.set(device.id, use)
    }
  }
  return found
}

/** `OPENCODE_SESSION_ID` per PID, from `ps -E -ww -o pid=,command= -p …` (the environment follows the arguments). */
export function sessions(output: string) {
  return new Map(
    output.split("\n").flatMap((line) => {
      const pid = /^\s*(\d+)\s/.exec(line)?.[1]
      const session = /(?:^|\s)OPENCODE_SESSION_ID=(ses_[A-Za-z0-9]+)(?=\s|$)/.exec(line)?.[1]
      return pid && session ? [[Number(pid), session] as const] : []
    }),
  )
}

function tokenOf(meta: Resources.Meta) {
  if (meta.kind === "ios-simulator") return meta.udid
  if (meta.kind === "android-emulator") return meta.serial
  return undefined
}

function escape(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

export interface ProcessSystem {
  /** `ps -Ao pid=,ppid=,etime=,command=`. */
  list(): Promise<string>
  /** `ps -E -ww -o pid=,command= -p <pids>`. */
  environment(pids: readonly number[]): Promise<string>
}

/**
 * The hub's process watch: one `ps` per call, plus one `ps -E` for the runners not seen before (their session never
 * changes, so it is cached by PID while they live).
 */
export function makeProcessWatch(system: ProcessSystem, self = process.pid) {
  const known = new Map<number, string | undefined>()
  return async (devices: readonly Device[], now: number) => {
    if (devices.length === 0) return new Map<string, Use & { readonly sessionID?: string }>()
    const rows = parsePs(await system.list())
    const found = uses(rows, devices, self, now)
    const alive = new Set(rows.map((row) => row.pid))
    for (const pid of known.keys()) if (!alive.has(pid)) known.delete(pid)
    const missing = [...new Set([...found.values()].map((use) => use.pid))].filter((pid) => !known.has(pid))
    if (missing.length > 0) {
      // A runner that ended between the two `ps` makes the second fail: nothing is cached, the next cycle asks again.
      const output = await system.environment(missing).catch(() => undefined)
      if (output !== undefined) {
        const read = sessions(output)
        missing.forEach((pid) => known.set(pid, read.get(pid)))
      }
    }
    return new Map(
      [...found].map(([id, use]) => {
        const sessionID = known.get(use.pid)
        return [id, { ...use, ...(sessionID ? { sessionID } : {}) }] as const
      }),
    )
  }
}
