import type { BrakeConfig } from "../machine-config.js"

/**
 * The brake (`docs/bancada.md`, "Brake"): whatever the budget says, a machine under pressure takes nothing new. It
 * closes on any bad reading and reopens after `samplesToReopen` good ones in a row (one every 5 s). Closed, it only
 * bars new admissions; it never stops anything. Pure: the process reads the machine and hands each reading in.
 */

/** One reading of the machine; a value it could not read is left out and counts as fine. */
export type Reading = {
  readonly at: number
  /** 1 normal, 2 warning, 4 critical (macOS's `kern.memorystatus_vm_pressure_level`; Linux's PSI mapped). */
  readonly pressure?: number
  readonly memFreePct?: number
  readonly swapUsedMb?: number
  readonly cpuIdlePct?: number
  readonly loadPerCore?: number
  /** Since when the owner did not touch keyboard or mouse (macOS). */
  readonly idleMs?: number
}

export type Brake = {
  readonly closed: boolean
  /** Good readings in a row while closed. */
  readonly good: number
  /** Why it is closed (the readings that closed it). */
  readonly reasons: ReadonlyArray<string>
  /** Swap readings of the last 2 minutes. */
  readonly swap: ReadonlyArray<{ readonly at: number; readonly mb: number }>
  /** Since when the CPU has been idle below the minimum, without a reading above it. */
  readonly idleLowSince?: number
}

export const open: Brake = { closed: false, good: 0, reasons: [], swap: [] }

export const windows = { swapMs: 2 * 60_000, idleMs: 30_000 }

export function step(brake: Brake, reading: Reading, config: BrakeConfig): Brake {
  const swap = [
    ...brake.swap,
    ...(reading.swapUsedMb === undefined ? [] : [{ at: reading.at, mb: reading.swapUsedMb }]),
  ].filter((item) => reading.at - item.at <= windows.swapMs)
  const idleLow = reading.cpuIdlePct !== undefined && reading.cpuIdlePct < config.cpuIdleMinPct
  const idleLowSince =
    reading.cpuIdlePct === undefined ? brake.idleLowSince : idleLow ? (brake.idleLowSince ?? reading.at) : undefined
  const growth = reading.swapUsedMb === undefined ? 0 : reading.swapUsedMb - Math.min(...swap.map((item) => item.mb))
  const reasons = [
    reading.pressure !== undefined && reading.pressure >= 2 ? "pressão de memória acima do normal" : undefined,
    reading.memFreePct !== undefined && reading.memFreePct < config.memFreeMinPct
      ? `memória livre em ${Math.round(reading.memFreePct)}% (mínimo ${config.memFreeMinPct}%)`
      : undefined,
    growth > config.swapGrowthMb ? `swap cresceu ${Math.round(growth)} MB em 2 min` : undefined,
    idleLowSince !== undefined && reading.at - idleLowSince >= windows.idleMs
      ? `CPU ociosa abaixo de ${config.cpuIdleMinPct}% por 30 s`
      : undefined,
    reading.loadPerCore !== undefined && reading.loadPerCore > config.loadPerCoreMax
      ? `carga de ${reading.loadPerCore.toFixed(1)} por núcleo (máximo ${config.loadPerCoreMax})`
      : undefined,
  ].filter((reason) => reason !== undefined)
  const base = { swap, ...(idleLowSince === undefined ? {} : { idleLowSince }) }
  if (reasons.length > 0) return { ...base, closed: true, good: 0, reasons }
  if (!brake.closed) return { ...base, closed: false, good: 0, reasons: [] }
  const good = brake.good + 1
  return good >= config.samplesToReopen
    ? { ...base, closed: false, good: 0, reasons: [] }
    : { ...base, closed: true, good, reasons: brake.reasons }
}
