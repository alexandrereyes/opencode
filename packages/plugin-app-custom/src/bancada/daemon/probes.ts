import fs from "node:fs/promises"
import os from "node:os"
import { readCpu, readMemory } from "../../host/index.js"
import type { Reading } from "./brake.js"

/**
 * Readings of the whole machine for the brake and the owner's presence (`docs/bancada.md`, "Brake"): memory and its
 * pressure, swap, CPU idle and load, and (macOS) how long keyboard and mouse have been idle. Each value read on its
 * own: one that fails is left out, never the whole reading. The process takes one every 5 s, off the core's round.
 */
export async function probe(platform: NodeJS.Platform = process.platform): Promise<Reading> {
  const [memory, cpu, pressure, swap, idle] = await Promise.all([
    readMemory().catch(() => undefined),
    readCpu().catch(() => undefined),
    platform === "darwin"
      ? command(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"])
      : text("/proc/pressure/memory"),
    platform === "darwin" ? command(["/usr/sbin/sysctl", "-n", "vm.swapusage"]) : text("/proc/meminfo"),
    platform === "darwin"
      ? command(["/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4", "-k", "HIDIdleTime"])
      : undefined,
  ])
  const pressureLevel = platform === "darwin" ? darwinPressure(pressure) : linuxPressure(pressure)
  const swapUsedMb = platform === "darwin" ? darwinSwap(swap) : linuxSwap(swap)
  const idleMs = hidIdle(idle)
  return {
    at: Date.now(),
    ...(memory && memory.total > 0 ? { memFreePct: ((memory.total - memory.used) / memory.total) * 100 } : {}),
    ...(cpu ? { cpuIdlePct: 100 - cpu.percent } : {}),
    loadPerCore: os.loadavg()[0]! / os.availableParallelism(),
    ...(pressureLevel === undefined ? {} : { pressure: pressureLevel }),
    ...(swapUsedMb === undefined ? {} : { swapUsedMb }),
    ...(idleMs === undefined ? {} : { idleMs }),
  }
}

/** `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical. */
export function darwinPressure(text: string | undefined) {
  const level = Number(text?.trim())
  return text?.trim() && Number.isInteger(level) ? level : undefined
}

/**
 * `/proc/pressure/memory` (PSI) as macOS's levels: tasks stalled on memory more than 10% of the last 10 s is a
 * warning (2); all of them at once more than 10% of it is critical (4).
 */
export function linuxPressure(text: string | undefined) {
  const avg10 = (kind: string) => Number(new RegExp(`^${kind} avg10=([\\d.]+)`, "m").exec(text ?? "")?.[1])
  const some = avg10("some")
  const full = avg10("full")
  if (!Number.isFinite(some)) return undefined
  if (Number.isFinite(full) && full > 10) return 4
  return some > 10 ? 2 : 1
}

/** `vm.swapusage`: `total = 2048.00M  used = 1234.56M  free = 813.44M  (encrypted)`. */
export function darwinSwap(text: string | undefined) {
  const match = /used = ([\d.]+)([KMG])/.exec(text ?? "")
  if (!match) return undefined
  return Number(match[1]) * ({ K: 1 / 1_024, M: 1, G: 1_024 } as const)[match[2] as "K" | "M" | "G"]
}

/** `/proc/meminfo`: SwapTotal − SwapFree, in MB. */
export function linuxSwap(text: string | undefined) {
  const value = (key: string) => Number(new RegExp(`^${key}:\\s+(\\d+) kB`, "m").exec(text ?? "")?.[1])
  const total = value("SwapTotal")
  const free = value("SwapFree")
  return Number.isFinite(total) && Number.isFinite(free) ? (total - free) / 1_024 : undefined
}

/** `ioreg`'s `"HIDIdleTime" = <nanoseconds>`, in ms. */
export function hidIdle(text: string | undefined) {
  const match = /"HIDIdleTime" = (\d+)/.exec(text ?? "")
  return match ? Number(match[1]) / 1_000_000 : undefined
}

function text(file: string) {
  return fs.readFile(file, "utf8").catch(() => undefined)
}

/** A command with a short deadline; nothing when it fails, misses its deadline or cannot start. */
async function command(argv: string[]) {
  const child = spawn(argv)
  if (!child) return undefined
  const [output, code] = await Promise.all([new Response(child.stdout).text(), child.exited])
  return code === 0 ? output : undefined
}

function spawn(argv: string[]) {
  try {
    return Bun.spawn(argv, { stdin: "ignore", stdout: "pipe", stderr: "ignore", timeout: 3_000 })
  } catch {
    return undefined
  }
}
