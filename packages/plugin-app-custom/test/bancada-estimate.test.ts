import { describe, expect, test } from "bun:test"
import { duration, perScenario, wait, type Sample } from "../src/bancada/daemon/estimate"

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

  test("duration: without history here the others' median (× 3 on a slow machine); without any, 5 minutes", () => {
    const elsewhere = [sample(2 * minute, 0), sample(4 * minute, 0)]
    expect(duration({ here: [], elsewhere, slow: false, devices: 1, built: false })).toBe(3 * minute)
    expect(duration({ here: [], elsewhere, slow: true, devices: 1, built: false })).toBe(9 * minute)
    expect(duration({ here: [], elsewhere: [], slow: false, devices: 1, built: false })).toBe(5 * minute)
    expect(duration({ here: [], elsewhere: [], slow: true, devices: 1, built: false })).toBe(15 * minute)
    // A slow machine with its own history needs no factor.
    expect(duration({ here: [sample(2 * minute, 0)], elsewhere, slow: true, devices: 1, built: false })).toBe(
      2 * minute,
    )
  })

  test("per scenario: what one scenario took on one device there, else elsewhere (× 3 on a slow machine); nothing without counted history", () => {
    // 20 scenarios in 4 minutes on 4 devices: 48 s each; 10 in 5 minutes on 1: 30 s; the median of 48 s and 30 s.
    const here = [sample(4 * minute, 0, 4, 20), sample(5 * minute, 0, 1, 10), sample(9 * minute, 0)]
    expect(perScenario({ here, elsewhere: [], slow: false })).toBe(39_000)
    expect(perScenario({ here: [], elsewhere: here, slow: true })).toBe(117_000)
    expect(perScenario({ here: [sample(9 * minute, 0)], elsewhere: [], slow: false })).toBeUndefined()
  })

  test("wait: none when it fits now; else until enough of what runs ends (the queue), or room (the budget)", () => {
    const now = 1_000_000
    const base = { now, ceiling: 4, min: 2, builds: 1, braked: false, ahead: [] }
    expect(wait({ ...base, free: { builds: 1, devices: 2 }, running: [] })).toEqual({ ms: 0, by: "now" })
    const running = [
      { endsAt: now + 9 * minute, devices: 2, building: false },
      { endsAt: now + 3 * minute, devices: 1, building: false },
      { endsAt: now + 5 * minute, devices: 1, building: true },
    ]
    // One device free, no build: the attempt ending in 3 min frees a device, the one in 5 min a build.
    expect(wait({ ...base, free: { builds: 0, devices: 1 }, running })).toEqual({ ms: 5 * minute, by: "queue" })
    // Without build (or with its group's build held), the device is enough.
    expect(wait({ ...base, builds: 0, free: { builds: 0, devices: 1 }, running })).toEqual({
      ms: 3 * minute,
      by: "queue",
    })
    expect(wait({ ...base, min: 5, free: { builds: 1, devices: 4 }, running })).toEqual({
      ms: Number.POSITIVE_INFINITY,
      by: "never",
    })
    // Nothing that runs frees enough (the owner's presence took the room): unknown, 5 minutes.
    expect(wait({ ...base, free: { builds: 1, devices: 0 }, running: [] })).toEqual({ ms: 5 * minute, by: "budget" })
    // A brake reopens after good readings, never because something ended.
    expect(wait({ ...base, braked: true, free: { builds: 1, devices: 4 }, running: [] })).toEqual({
      ms: 5 * minute,
      by: "brake",
    })
  })

  test("wait: each part ahead takes its turn when it fits and holds it for its duration; the next waits for it", () => {
    const now = 1_000_000
    const base = { now, ceiling: 4, min: 1, builds: 1, braked: false }
    // One emulator, busy for 3 more minutes. The 1st waits 3 min; the 2nd waits for the 1st's 4 min on top.
    const running = [{ endsAt: now + 3 * minute, devices: 1, building: false }]
    const free = { builds: 1, devices: 0 }
    expect(wait({ ...base, free, running, ahead: [] })).toEqual({ ms: 3 * minute, by: "queue" })
    const first = { devices: 1, builds: 1, durationMs: 4 * minute }
    expect(wait({ ...base, free, running, ahead: [first] })).toEqual({ ms: 7 * minute, by: "queue" })
    // Two emulators: the 1st takes the one that frees, the 2nd the other one, when it frees.
    const two = [...running, { endsAt: now + 5 * minute, devices: 1, building: false }]
    expect(wait({ ...base, free: { builds: 2, devices: 0 }, running: two, ahead: [first] })).toEqual({
      ms: 5 * minute,
      by: "queue",
    })
    // A part ahead that nothing frees enough for keeps its place and takes nothing.
    const big = { devices: 3, builds: 1, durationMs: 4 * minute }
    expect(wait({ ...base, free, running, ahead: [big] })).toEqual({ ms: 3 * minute, by: "queue" })
  })
})
