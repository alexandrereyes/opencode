import { describe, expect, test } from "bun:test"
import { duration, wait, type Sample } from "../src/bancada/daemon/estimate"

const minute = 60_000
const sample = (runMs: number, buildMs = minute, devices = 1, scenarios?: number): Sample => ({
  runMs,
  buildMs,
  devices,
  ...(scenarios === undefined ? {} : { scenarios }),
})

describe("estimate", () => {
  test("duration: the median run here plus the median build, none when a sibling already builds here", () => {
    const here = [sample(4 * minute), sample(6 * minute), sample(20 * minute, 3 * minute)]
    expect(duration({ here, elsewhere: [], slow: false, devices: 1, built: false })).toBe(7 * minute)
    expect(duration({ here, elsewhere: [], slow: false, devices: 1, built: true })).toBe(6 * minute)
  })

  test("duration: with the planned scenarios known, time per scenario × scenarios ÷ devices", () => {
    // 10 scenarios took 10 minutes on 2 devices: 2 device-minutes each; 30 scenarios on 3 devices take 20 minutes.
    const here = [sample(10 * minute, 0, 2, 10)]
    expect(duration({ here, elsewhere: [], slow: false, devices: 3, planned: 30, built: false })).toBe(20 * minute)
    // History that never counted its scenarios keeps the plain median.
    expect(
      duration({ here: [sample(9 * minute, 0)], elsewhere: [], slow: false, devices: 3, planned: 30, built: false }),
    ).toBe(9 * minute)
  })

  test("duration: without history here the others' median (× 2.5 on a slow machine); without any, 5 minutes", () => {
    const elsewhere = [sample(2 * minute, 0), sample(4 * minute, 0)]
    expect(duration({ here: [], elsewhere, slow: false, devices: 1, built: false })).toBe(3 * minute)
    expect(duration({ here: [], elsewhere, slow: true, devices: 1, built: false })).toBe(7.5 * minute)
    expect(duration({ here: [], elsewhere: [], slow: false, devices: 1, built: false })).toBe(5 * minute)
    expect(duration({ here: [], elsewhere: [], slow: true, devices: 1, built: false })).toBe(12.5 * minute)
    // A slow machine with its own history needs no factor.
    expect(duration({ here: [sample(2 * minute, 0)], elsewhere, slow: true, devices: 1, built: false })).toBe(
      2 * minute,
    )
  })

  test("wait: none when it fits now; else until enough of what runs ends, plus what is held ahead", () => {
    const now = 1_000_000
    const base = { now, ceiling: 4, min: 2, braked: false, ahead: [] as number[] }
    expect(wait({ ...base, free: { builds: 1, devices: 2 }, running: [] })).toBe(0)
    const running = [
      { endsAt: now + 9 * minute, devices: 2, building: false },
      { endsAt: now + 3 * minute, devices: 1, building: false },
      { endsAt: now + 5 * minute, devices: 1, building: true },
    ]
    // One device free, no build: the attempt ending in 3 min frees a device, the one in 5 min a build.
    expect(wait({ ...base, free: { builds: 0, devices: 1 }, running })).toBe(5 * minute)
    expect(wait({ ...base, free: { builds: 1, devices: 2 }, running, ahead: [4 * minute] })).toBe(4 * minute)
    expect(wait({ ...base, min: 5, free: { builds: 1, devices: 4 }, running })).toBe(Number.POSITIVE_INFINITY)
    // A brake reopens after good readings, never because something ended.
    expect(wait({ ...base, braked: true, free: { builds: 1, devices: 4 }, running: [] })).toBe(5 * minute)
  })
})
