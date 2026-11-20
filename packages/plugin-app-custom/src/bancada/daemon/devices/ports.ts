import type { Range } from "../../machine-config.js"

/**
 * Ports (`docs/bancada.md`, "Devices"): each granted device gets a block of consecutive ports of the machine's
 * `portas.projeto`, never shared with a live reservation; a local emulator gets a console/adb pair of
 * `portas.emulador`.
 */

/** The first block of `size` ports of `range` that overlaps none of `taken`. */
export function block(range: Range, taken: ReadonlyArray<Range>, size = 20): Range | undefined {
  const sorted = taken.toSorted((a, b) => a.start - b.start)
  const start = sorted.reduce(
    (next, used) => (used.end >= next && used.start < next + size ? used.end + 1 : next),
    range.start,
  )
  return start + size - 1 <= range.end ? { start, end: start + size - 1 } : undefined
}

/** An emulator's console port (even, as the emulator expects) and its adb port, the next one, both free. */
export function emulatorPair(range: Range, taken: ReadonlySet<number>) {
  const first = range.start % 2 === 0 ? range.start : range.start + 1
  const console = Array.from(
    { length: Math.max(0, Math.floor((range.end - first + 1) / 2)) },
    (_, index) => first + index * 2,
  ).find((port) => !taken.has(port) && !taken.has(port + 1))
  return console === undefined ? undefined : { console, adb: console + 1 }
}
