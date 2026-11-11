import { identity } from "./adapters/android-emulator.js"
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

/**
 * Whether a shell command runs a tool that drives simulators, emulators or Playwright browsers, named or not (also
 * through the Linux machine's `mac` prefix, which runs it on the Mac). Only what runs here counts (`localCommand`).
 */
export function touchesResources(command: string) {
  return touches(command, ["ios-simulator", "android-emulator", "chrome"])
}

/** `touchesResources` for some kinds only. */
export function touches(command: string, kinds: readonly Resources.Kind[]) {
  const local = localCommand(command)
  return (
    (kinds.includes("ios-simulator") && simulatorTools.test(local)) ||
    (kinds.includes("android-emulator") && emulatorTools.test(local)) ||
    (kinds.includes("chrome") && /\bplaywright-cli\b/.test(local))
  )
}

/**
 * A command's parts per machine, for a server whose Mac has its own hub (`OPENCODE_RESOURCES_HUB_MAC_SOCKET`):
 * `mac` holds what runs on the Mac through the `mac` prefix, without the prefix and its options (`mac -C dir adb …` is
 * `adb …`), the script of `mac sh|bash|zsh -c '…'` instead of the shell, and the here-documents a shell there runs as
 * its script; `here` holds what runs on this machine. Parts handed to another machine (`localCommand`) are in neither,
 * and so is every here-document that is data (`script`).
 */
export function machineParts(command: string) {
  const here: string[] = []
  const mac: string[] = []
  const list = simpleCommands(command)
  list.forEach((item, index) => {
    const target = machineOf(item.text)
    const onMac = macCommand(item.text)
    if (target === "here") here.push(bare(item.text))
    if (target === "mac" && onMac !== undefined) mac.push(shellScript(onMac) ?? bare(onMac))
    const shell = script(list, index)
    if (!shell) return
    const body = item.documents.map((document) => document.join("\n")).join("\n")
    const runs = machineOf(shell.text)
    if (runs === "mac") mac.push(localCommand(body))
    if (runs !== "here") return
    const parts = machineParts(body)
    here.push(parts.here)
    mac.push(parts.mac)
  })
  return { here: here.join("\n"), mac: mac.join("\n") }
}

/** Where a simple command runs: here, on the Mac through `mac`, or elsewhere (`undefined`, see `localCommand`). */
function machineOf(text: string) {
  const onMac = macCommand(text)
  if (onMac === undefined) return remote(text) ? undefined : ("here" as const)
  return remote(onMac) ? undefined : ("mac" as const)
}

/**
 * A command's simple commands in order, each with the separator that ends it and the bodies of the here-documents it
 * opens. Bodies follow the line that opens them, in order (`cat <<A; bash <<B` reads A's body, then B's), and never
 * count as simple commands of their own. A `<<` inside quotes opens nothing; `<<<` is a here-string.
 */
function simpleCommands(command: string) {
  const list: { readonly text: string; readonly separator: string; readonly documents: string[][] }[] = []
  const pending: { readonly delimiter: string; readonly indented: boolean; readonly lines: string[] }[] = []
  let index = 0
  while (index < command.length) {
    const end = simpleEnd(command, index)
    const text = command.slice(index, end)
    index = end + 1
    const opened = [...unquoted(text).matchAll(heredocs)].map((match) => ({
      delimiter: match[3]!,
      indented: match[1] === "-",
      lines: [] as string[],
    }))
    pending.push(...opened)
    list.push({ text, separator: command[end] ?? "", documents: opened.map((document) => document.lines) })
    if (command[end] !== "\n" && end < command.length) continue
    for (const document of pending.splice(0)) {
      while (index < command.length) {
        const next = command.indexOf("\n", index)
        const line = command.slice(index, next === -1 ? command.length : next)
        index = next === -1 ? command.length : next + 1
        if ((document.indented ? line.replace(/^\t+/, "") : line) === document.delimiter) break
        document.lines.push(line)
      }
    }
  }
  return list
}

/** `<<WORD`, `<<-WORD`, `<<'WORD'`, `<< "WORD"`; not a `<<<` here-string. */
const heredocs = /(?<!<)<<(-?)\s*(['"]?)([A-Za-z_][\w-]*)\2(?![\w-])/g
const hereStrings = /<<<\s*(?:'[^']*'|"(?:[^"\\]|\\.)*"|\S+)/g
const shells = ["sh", "bash", "zsh", "dash", "ksh"]

/**
 * The simple command that runs the here-documents of `list[index]` as a script, or `undefined` when they are data. They
 * are a script only for a shell reading its commands from standard input: `sh`, `bash`, `zsh`, `dash` or `ksh`
 * (through `mac`, wrappers such as `sudo`, `env`, `nohup`, `time` or `timeout N`, assignments or a path) with no
 * script operand and no `-c` (`bash`, `bash -s arg`, `bash -l -`, `mac bash`; not `bash run.sh` or `bash -c '…'`,
 * whose standard input is data), or for a plain `cat` piped straight into such a shell (`cat <<EOF | bash`). Every
 * other reader (`cat > file`, `tee`, `python3 -`, `node`, `psql`, `git commit -F -`, `curl --data @-`, a shell behind
 * a filter) gets data: it names no resource, whatever it says. Command substitutions in a data here-document with an
 * unquoted delimiter do run, but are not looked for: text must not turn into resources, and a lock is not meant to be
 * bypassed that way. A here-string (`<<<`) is data unless a shell reads it.
 */
function script(list: ReturnType<typeof simpleCommands>, index: number) {
  const item = list[index]!
  if (item.documents.length === 0) return undefined
  if (readsScript(item.text)) return item
  const next = list[index + 1]
  return item.separator === "|" && next && plainCat(item.text) && readsScript(next.text) ? next : undefined
}

/** Whether a simple command is a shell that reads its script from standard input (see `script`). */
function readsScript(text: string): boolean {
  const onMac = macCommand(text)
  if (onMac !== undefined) return readsScript(onMac)
  const words = beforeRedirections(text)
  const first = wrappedCommand(words)
  if (!shells.includes(words[first]?.split("/").pop() ?? "")) return false
  const operands = words.slice(first + 1)
  for (let index = 0; index < operands.length; index++) {
    const word = operands[index]!
    if (word === "-s" || /^-[A-Za-z]*s[A-Za-z]*$/.test(word)) return !/^-[A-Za-z]*c/.test(word)
    if (/^[-+][A-Za-z]*c[A-Za-z]*$/.test(word)) return false
    if (word === "-") return true
    if (word === "--") return operands.length === index + 1
    if (word === "-o" || word === "+o") index++
    else if (!/^[-+]/.test(word)) return false
  }
  return true
}

/** Whether a simple command is `cat` alone (or `cat -`), copying standard input through. */
function plainCat(text: string) {
  const words = beforeRedirections(text)
  const first = wrappedCommand(words)
  return words[first]?.split("/").pop() === "cat" && words.slice(first + 1).every((word) => word === "-")
}

/** The words of a simple command before its first redirection (`<<EOF`, `> file`, `2>&1`). */
function beforeRedirections(text: string) {
  const cut = /^[^<>]*/.exec(unquoted(text))![0].replace(/\s\d+$/, "")
  return cut.trim().split(/\s+/).filter(Boolean)
}

/** Like `commandWord`, also past the wrappers' own options (`env -i bash`, `sudo -E bash`). */
function wrappedCommand(words: readonly string[]) {
  let index = 0
  let wrapped = false
  for (; index < words.length; index++) {
    const word = words[index]!
    if (/^[A-Za-z_]\w*=/.test(word) || ["sudo", "exec", "env", "nohup", "command", "time"].includes(word))
      wrapped = true
    else if (word === "timeout") {
      wrapped = true
      index++
    } else if (!wrapped || !word.startsWith("-")) break
  }
  return index
}

/** The text with its quoted strings emptied, except a here-document's quoted delimiter (`<<'EOF'`). */
function unquoted(text: string) {
  return text.replace(/(?<!<<-?\s*)('[^']*'|"(?:[^"\\]|\\.)*")/g, "''")
}

/** A simple command without its here-document operators, and without its here-string unless a shell reads it. */
function bare(text: string) {
  const kept = text.replace(heredocs, "")
  return readsScript(text) ? kept : kept.replace(hereStrings, "")
}

/** The command a `mac …` simple command runs on the Mac (after `mac` and its options), else `undefined`. */
function macCommand(segment: string) {
  const words = [...segment.matchAll(/\S+/g)]
  const first = commandWord(words.map((match) => match[0]))
  if (words[first]?.[0].split("/").pop() !== "mac") return undefined
  let next = first + 1
  while (next < words.length) {
    const word = words[next]![0]
    if (["-t", "--tty", "-T", "--no-tty"].includes(word) || word.startsWith("--cwd=")) next++
    else if (word === "-C" || word === "--cwd") next += 2
    else if (word === "--") {
      next++
      break
    } else break
  }
  const start = words[next]?.index
  return start === undefined ? "" : segment.slice(start)
}

/** The script of `sh|bash|zsh [-l…] -c '…'`, which runs as its own commands. */
function shellScript(command: string) {
  const match =
    /^\s*(?:\S*\/)?(?:sh|bash|zsh)\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*c\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')/.exec(command)
  return match ? (match[1] ?? match[2] ?? "") : undefined
}

/**
 * Index of the command word: leading assignments, `sudo`, `exec`, `env`, `nohup`, `command`, `time` and
 * `timeout <duration>` wrap it.
 */
function commandWord(words: readonly string[]) {
  let first = 0
  for (; first < words.length; first++) {
    const word = words[first]!
    if (/^[A-Za-z_]\w*=/.test(word) || ["sudo", "exec", "env", "nohup", "command", "time"].includes(word)) continue
    if (word === "timeout") {
      first++
      continue
    }
    break
  }
  return first
}

/**
 * Resources named by a shell command (and, for `simctl create`, its output). Commands that end one are ignored, and so
 * are the parts that run on another machine (`localCommand`): an `emulator-5554` there is that machine's emulator.
 */
export function references(command: string, output = "", workdir?: string): Reference[] {
  const local = localCommand(command)
  return dedupe([...simulators(local, output), ...emulators(local), ...browsers(local, workdir)])
}

/**
 * The parts of a shell command that run on this machine. A simple command handed to another machine is dropped with
 * its quoted arguments and its here-document: `ssh host …` (also `mosh`, `autossh`, `gcloud compute ssh`), `docker`,
 * `podman` or `nerdctl` `exec`/`run` (also through `compose`), `kubectl`/`oc` `exec`, and `adb` talking to another
 * machine's server (`-H <host>`, `ANDROID_ADB_SERVER_ADDRESS=<host>`). The Linux machine's `mac` and `orb` prefixes
 * stay local: they run on the Mac or use its adb server. A here-document counts only as the script of a shell that
 * runs here (`script`); one given to any other command is data and is dropped, like a here-string such a command reads.
 */
export function localCommand(command: string): string {
  const list = simpleCommands(command)
  return list
    .flatMap((item, index) => {
      if (remote(item.text)) return []
      const shell = script(list, index)
      const body =
        shell && !remote(shell.text)
          ? [localCommand(item.documents.map((document) => document.join("\n")).join("\n"))]
          : []
      return [bare(item.text), ...body]
    })
    .join("\n")
}

/** Where the simple command starting at `start` ends: the next unquoted `;`, `&`, `|`, `(`, `)` or newline. */
function simpleEnd(command: string, start: number) {
  let quote: string | undefined
  for (let index = start; index < command.length; index++) {
    const char = command[index]!
    if (quote) {
      if (char === "\\" && quote === '"') index++
      else if (char === quote) quote = undefined
      continue
    }
    if (char === "\\") index++
    else if (char === "'" || char === '"' || char === "`") quote = char
    else if (";&|()\n".includes(char)) return index
  }
  return command.length
}

const loopback = /^(localhost|127\.0\.0\.1|::1|\[::1\])$/

/**
 * An Android tool where a command starts (also inside `$(…)` and after `do`, `then`, `xargs` or wrappers), with its
 * arguments up to the next separator: `ls ~/.local/bin/android-emulator` runs no emulator tool.
 */
const androidInvocation =
  /(?:^|[;&|(\n`]|\$\()\s*(?:(?:[A-Za-z_]\w*=\S*|sudo|exec|env|nohup|command|time|do|then|else|xargs|!|timeout\s+\S+)\s+)*(?:\S*\/)?(adb|emulator|android-emulator|agent-device|maestro|serve-emu)(?=\s|$)([^;&|)\n"'`]*)/g

/** Whether a simple command runs on another machine (see `localCommand`). */
function remote(segment: string) {
  const words = segment.trim().split(/\s+/).filter(Boolean)
  const first = commandWord(words)
  const remoteServer = words.slice(0, first).some((word) => {
    const address = /^ANDROID_ADB_SERVER_ADDRESS=['"]?([^'"\s]+)/.exec(word)?.[1]
    return address !== undefined && !loopback.test(address)
  })
  if (remoteServer) return true
  const tool = words[first]?.split("/").pop() ?? ""
  const args = words.slice(first + 1, first + 7)
  if (["ssh", "mosh", "autossh"].includes(tool)) return true
  if (tool === "gcloud") return args.includes("ssh")
  if (["docker", "podman", "nerdctl"].includes(tool)) return args.some((word) => word === "exec" || word === "run")
  if (["kubectl", "oc"].includes(tool)) return args.includes("exec")
  if (tool === "adb") {
    const host = words.slice(first + 1).findIndex((word) => word === "-H")
    const value = host === -1 ? undefined : words[first + 2 + host]
    return value !== undefined && !loopback.test(value.replace(/^['"]|['"]$/g, ""))
  }
  return false
}

/**
 * Whether a command only asks about Android emulators: every emulator tool it runs here is `adb devices`,
 * `adb version`, `adb get-state|get-serialno|get-devpath|wait-for-…`, `adb emu avd name|path|id`, `adb shell getprop`
 * or `emulator -list-avds|-version`. Such a command neither marks an emulator in use nor makes its session the owner.
 */
export function onlyAsksAndroid(command: string) {
  const invocations = [...localCommand(command).matchAll(androidInvocation)]
  if (invocations.length === 0) return false
  return invocations.every(([, tool, rest]) => {
    const args = (rest ?? "").trim()
    if (tool === "emulator") return /^(-list-avds|-version)\b/.test(args)
    if (tool !== "adb") return false
    const command = args.replace(/^(?:(?:-[stHPL])\s+\S+\s+|-[de]\s+)*/, "")
    return /^(devices|version|get-state|get-serialno|get-devpath|wait-for-\S+|emu\s+avd\s+(name|path|id)|shell\s+getprop)\b/.test(
      command,
    )
  })
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
      // An AVD names the resource that is that AVD (its ID outranks a rewritten `meta.avd`). A bare serial names only a
      // resource known by serial alone: whose AVD holds it now is the emulator's to say (`bareSerials`).
      if (reference.kind === "android-emulator" && meta.kind === "android-emulator")
        return reference.avd !== undefined
          ? reference.avd === identity(resource)
          : reference.serial !== undefined && reference.serial === meta.serial && identity(resource) === undefined
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

/**
 * Bare Android serials a command names that a registered AVD resource held at its last probe. They go to the hub as
 * serials, and the hub asks the emulator on that port which AVD it is (`Adapter.identify`), since the AVD that held it
 * a few seconds ago may have stopped and another taken the port.
 */
export function bareSerials(list: readonly Reference[], resources: readonly Resources.Resource[]): Resources.Meta[] {
  const serials = list.flatMap((reference) =>
    reference.kind === "android-emulator" && reference.avd === undefined && reference.serial !== undefined
      ? [reference.serial]
      : [],
  )
  return [...new Set(serials)]
    .filter((serial) =>
      resources.some(
        (resource) =>
          resource.state !== "gone" &&
          resource.meta.kind === "android-emulator" &&
          resource.meta.serial === serial &&
          identity(resource) !== undefined,
      ),
    )
    .map((serial) => ({ kind: "android-emulator", serial }))
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
