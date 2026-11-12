import fs from "node:fs/promises"
import os from "node:os"
import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { Host } from "./rpc.js"

/**
 * `custom.host` (`docs/host.md`): the machine the server runs on, for the Mac app's rail. CPU and memory of the whole
 * machine, never a container's cgroup (inside the Linux BRS container `/proc/stat` and `/proc/meminfo` are the host's);
 * the disk of the server's home folder. Measured only when asked, from files on Linux and with one Mach call on macOS.
 */
export const registerHost = Effect.fn("Host.register")(function* (ctx: Omit<Plugin.Context, "storage">) {
  yield* ctx.rpc
    .register(Host.Definition, {
      get: (input) => Effect.promise(() => snapshot(input.parts)),
    })
    .pipe(Effect.orDie)
})

export interface Probes {
  readonly name: () => Promise<string>
  readonly cpu: () => Promise<Host.Cpu | undefined>
  readonly memory: () => Promise<Host.Memory | undefined>
  readonly disk: () => Promise<Host.Disk | undefined>
  readonly platform: string
  readonly now: () => number
}

/** The parts asked for (all by default); a part that fails or reads nothing is left out, never the whole answer. */
export async function snapshot(parts?: readonly Host.Part[], probes: Probes = defaults()): Promise<Host.Snapshot> {
  const wants = (part: Host.Part) => !parts || parts.includes(part)
  const safe = <T>(read: () => Promise<T | undefined>) => read().catch(() => undefined)
  const [name, cpu, memory, disk] = await Promise.all([
    probes.name().catch(() => os.hostname()),
    wants("cpu") ? safe(probes.cpu) : undefined,
    wants("memory") ? safe(probes.memory) : undefined,
    wants("disk") ? safe(probes.disk) : undefined,
  ])
  return {
    name,
    platform: probes.platform,
    scope: "machine",
    ...(cpu ? { cpu } : {}),
    ...(memory ? { memory } : {}),
    ...(disk ? { disk } : {}),
    at: probes.now(),
  }
}

function defaults(): Probes {
  return { name: hostName, cpu: readCpu, memory: readMemory, disk: readDisk, platform: process.platform, now: Date.now }
}

// MARK: Name

declare global {
  var opencodeCustomHostName: Promise<string> | undefined
  var opencodeCustomHostCpu: Sample | undefined
  var opencodeCustomHostMach: Mach | null | undefined
}

/** `OPENCODE_HOST_NAME`, else macOS's ComputerName (read once per process), else the host name. */
export function hostName(configured = process.env.OPENCODE_HOST_NAME): Promise<string> {
  if (configured?.trim()) return Promise.resolve(configured.trim().slice(0, 40))
  globalThis.opencodeCustomHostName ??= computerName()
  return globalThis.opencodeCustomHostName
}

async function computerName() {
  const fallback = os.hostname().replace(/\.local$/, "")
  if (process.platform !== "darwin") return fallback
  try {
    const child = Bun.spawn(["/usr/sbin/scutil", "--get", "ComputerName"], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
    const name = (await new Response(child.stdout).text()).trim()
    return (await child.exited) === 0 && name ? name.slice(0, 40) : fallback
  } catch {
    return fallback
  }
}

// MARK: CPU

export interface Ticks {
  readonly idle: number
  readonly total: number
}

/** `/proc/stat`'s first line (user nice system idle iowait irq softirq steal; guest is already in user) and its cores. */
export function parseProcStat(text: string): { ticks: Ticks; cores: number } | undefined {
  const lines = text.split("\n")
  const fields = lines.find((line) => /^cpu\s/.test(line))?.trim().split(/\s+/).slice(1, 9).map(Number)
  if (!fields || fields.length < 4 || fields.some((value) => !Number.isFinite(value))) return undefined
  const idle = fields[3] + (fields[4] ?? 0)
  const total = fields.reduce((sum, value) => sum + value, 0)
  const cores = lines.filter((line) => /^cpu\d+\s/.test(line)).length
  return { ticks: { idle, total }, cores: cores || os.cpus().length }
}

/** macOS: the cores' times summed (`host_processor_info`, through `os.cpus()`). */
export function cpuTicks(cpus = os.cpus()): { ticks: Ticks; cores: number } | undefined {
  if (cpus.length === 0) return undefined
  let idle = 0
  let total = 0
  for (const cpu of cpus) {
    idle += cpu.times.idle
    total += cpu.times.user + cpu.times.nice + cpu.times.sys + cpu.times.idle + cpu.times.irq
  }
  return { ticks: { idle, total }, cores: cpus.length }
}

/** The busy share between two readings, 0–100; undefined when no time passed. */
export function busy(previous: Ticks, next: Ticks): number | undefined {
  const total = next.total - previous.total
  if (!(total > 0)) return undefined
  const value = ((total - (next.idle - previous.idle)) / total) * 100
  return Math.round(Math.min(100, Math.max(0, value)) * 10) / 10
}

interface Sample {
  readonly ticks: Ticks
  readonly at: number
  readonly percent?: number
}

async function currentTicks() {
  if (process.platform === "linux") return parseProcStat(await fs.readFile("/proc/stat", "utf8"))
  return cpuTicks()
}

/**
 * The share since the previous call (one process-wide sample, `globalThis`: the plugin is evaluated once per Location).
 * Calls closer than 0.5 s share the last value; a first call, or one after 10 s of silence, reads twice 0.25 s apart.
 */
export async function readCpu(
  read: () => Promise<{ ticks: Ticks; cores: number } | undefined> = currentTicks,
  now: () => number = Date.now,
  wait: (ms: number) => Promise<void> = (ms) => Bun.sleep(ms),
): Promise<Host.Cpu | undefined> {
  const previous = globalThis.opencodeCustomHostCpu
  if (previous?.percent !== undefined && now() - previous.at < 500) {
    const cores = (await read())?.cores
    return cores ? { percent: previous.percent, cores } : undefined
  }
  let start = previous && now() - previous.at <= 10_000 ? previous.ticks : undefined
  if (!start) {
    start = (await read())?.ticks
    if (!start) return undefined
    await wait(250)
  }
  const next = await read()
  if (!next) return undefined
  const percent = busy(start, next.ticks)
  globalThis.opencodeCustomHostCpu = { ticks: next.ticks, at: now(), percent }
  return percent === undefined ? undefined : { percent, cores: next.cores }
}

// MARK: Memory

/** Linux: MemTotal − MemAvailable (the page cache counts as free); older kernels without MemAvailable add it up. */
export function parseMeminfo(text: string): Host.Memory | undefined {
  const value = (key: string) => {
    const match = new RegExp(`^${key}:\\s+(\\d+)\\s*kB`, "m").exec(text)
    return match ? Number(match[1]) * 1024 : undefined
  }
  const total = value("MemTotal")
  if (!total) return undefined
  const available =
    value("MemAvailable") ??
    [value("MemFree"), value("Buffers"), value("Cached")].reduce<number | undefined>(
      (sum, part) => (sum === undefined || part === undefined ? undefined : sum + part),
      0,
    )
  if (available === undefined) return undefined
  return { used: Math.max(0, total - available), total }
}

export interface Pages {
  readonly pageSize: number
  readonly internal: number
  readonly purgeable: number
  readonly wired: number
  readonly compressor: number
}

/** Activity Monitor's "Memory Used": app memory (anonymous pages less the purgeable ones), wired and compressed. */
export function darwinUsed(pages: Pages) {
  return Math.max(0, pages.internal - pages.purgeable + pages.wired + pages.compressor) * pages.pageSize
}

/** `vm_stat`'s output, the fallback when the Mach call is unavailable. */
export function parseVmStat(text: string): Pages | undefined {
  const pageSize = Number(/page size of (\d+) bytes/.exec(text)?.[1])
  const count = (label: string) => {
    const match = new RegExp(`^${label}:\\s+(\\d+)\\.`, "m").exec(text)
    return match ? Number(match[1]) : undefined
  }
  const internal = count("Anonymous pages")
  const purgeable = count("Pages purgeable")
  const wired = count("Pages wired down")
  const compressor = count("Pages occupied by compressor")
  if (!pageSize || internal === undefined || purgeable === undefined || wired === undefined || compressor === undefined)
    return undefined
  return { pageSize, internal, purgeable, wired, compressor }
}

interface Mach {
  readonly read: () => Pages | undefined
}

/**
 * `host_statistics64(HOST_VM_INFO64)` through `bun:ffi`, what `vm_stat` itself calls: microseconds, no process. The
 * host port is taken once. `vm_statistics64` as 38 `natural_t` words: wire_count at 3, purgeable_count at 22,
 * compressor_page_count at 32, internal_page_count at 35.
 */
async function mach(): Promise<Mach | null> {
  if (globalThis.opencodeCustomHostMach !== undefined) return globalThis.opencodeCustomHostMach
  try {
    const { dlopen, FFIType, ptr } = await import("bun:ffi")
    const lib = dlopen("/usr/lib/libSystem.B.dylib", {
      mach_host_self: { args: [], returns: FFIType.u32 },
      host_statistics64: { args: [FFIType.u32, FFIType.i32, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
      getpagesize: { args: [], returns: FFIType.i32 },
    })
    const host = lib.symbols.mach_host_self()
    const words = new Uint32Array(38)
    const count = new Uint32Array(1)
    const pageSize = lib.symbols.getpagesize()
    if (!(pageSize > 0)) throw new Error("getpagesize failed")
    globalThis.opencodeCustomHostMach = {
      read: () => {
        count[0] = 38
        if (lib.symbols.host_statistics64(host, 4, ptr(words), ptr(count)) !== 0) return undefined
        return { pageSize, wired: words[3], purgeable: words[22], compressor: words[32], internal: words[35] }
      },
    }
  } catch {
    globalThis.opencodeCustomHostMach = null
  }
  return globalThis.opencodeCustomHostMach
}

let vmStatCache: { at: number; pages: Pages | undefined } | undefined

/** `vm_stat` once per 1.5 s at most, when the Mach call cannot be made. */
async function vmStat() {
  if (vmStatCache && Date.now() - vmStatCache.at < 1_500) return vmStatCache.pages
  const child = Bun.spawn(["/usr/bin/vm_stat"], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
  const text = await new Response(child.stdout).text()
  const pages = (await child.exited) === 0 ? parseVmStat(text) : undefined
  vmStatCache = { at: Date.now(), pages }
  return pages
}

export async function readMemory(): Promise<Host.Memory | undefined> {
  if (process.platform === "linux") return parseMeminfo(await fs.readFile("/proc/meminfo", "utf8"))
  if (process.platform !== "darwin") return undefined
  const pages = (await mach())?.read() ?? (await vmStat())
  return pages ? { used: darwinUsed(pages), total: os.totalmem() } : undefined
}

// MARK: Disk

/** The volume of the server's home folder (on the Linux BRS, `/workspace`, which lives on the host's own disk). */
export async function readDisk(path = os.homedir()): Promise<Host.Disk | undefined> {
  const stats = await fs.statfs(path)
  const total = stats.blocks * stats.bsize
  return total > 0 ? { free: stats.bavail * stats.bsize, total, path } : undefined
}
