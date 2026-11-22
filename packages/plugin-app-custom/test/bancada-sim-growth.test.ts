import { describe, expect, test } from "bun:test"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld } from "./fixture/bancada-sim"

const code = { project: "abacato-v3", commit: "0a14f4237c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2", remotes: [], inRemote: false }
const spec = (part: string, more: Partial<BancadaProtocol.PartSpec> = {}): BancadaProtocol.PartSpec => ({
  part,
  label: part,
  platform: "android",
  needs: ["android"],
  device: {},
  devices: { min: 1, max: 4 },
  exclusive: [],
  unsafe: false,
  build: true,
  plan: true,
  args: [],
  ...more,
})
/** The three parts of `j-tsvq4me7` (AbacatoV3, 22/11), each with a plan. */
const parts = [
  spec("android"),
  spec("android-servidor", { needs: ["android", "docker"] }),
  spec("ios", { platform: "ios", needs: ["ios"] }),
]
const passed = (ids: string[]) => ids.map((id) => ({ id, result: "passou" as const }))
const run = (useful: number) => ({
  buildMs: 60_000,
  runMs: 120_000,
  exit: 0,
  planned: ["c1"],
  scenarios: passed(["c1"]),
  useful,
})

/** The hub on host-6 (slower, Android only) and the Mac with its machine file in production. */
function world(seed: number) {
  const sim = createWorld({ seed })
  sim.addMachine({
    name: "host-6",
    hub: true,
    platform: "linux",
    speed: "lento",
    capabilities: { android: {}, docker: {} },
    capacity: { memMb: 64 * 1024, cpuMilli: 16_000, builds: 1, android: 4, ios: 0 },
  })
  // cpu = 14, memoria_gb = 96, compilacoes = 2, max_android = 6, max_ios = 6.
  sim.addMachine({
    name: "Mac",
    capabilities: { android: {}, ios: { simslim: true }, docker: {} },
    capacity: { memMb: 96 * 1024, cpuMilli: 14_000, builds: 2, android: 6, ios: 6 },
  })
  return sim
}
const ask = (sim: ReturnType<typeof world>) =>
  sim.submit("host-6", { id: "j-tsvq4me7", sessionID: "ses_a", rootSessionID: "ses_a", code, parts })
const granted = (sim: ReturnType<typeof world>) =>
  sim.machines.get("Mac")!.db.query("SELECT part, devices, per_device AS perDevice FROM attempt ORDER BY part").all()

describe("simulation: devices after the plan", () => {
  test("j-tsvq4me7: the Mac takes the three parts at once with one build and each one's minimum; the plan uses 1 device each, nothing grows", async () => {
    const sim = world(22)
    parts.forEach((part) => sim.script("j-tsvq4me7", part.part, run(1)))
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(3_000)
    // Accepted at once, none refused: each reserves its minimum; without history, 6 scenarios are worth a device.
    expect(sim.facts.refusals.size).toBe(0)
    expect(granted(sim)).toEqual([
      { part: "android", devices: 1, perDevice: 6 },
      { part: "android-servidor", devices: 1, perDevice: 6 },
      { part: "ios", devices: 1, perDevice: 6 },
    ])
    expect(
      sim.machines.get("Mac")!.db.query("SELECT SUM(builds) AS builds FROM lease WHERE state = 'active'").get(),
    ).toEqual({ builds: 1 })
    await sim.advance(10 * 60_000)
    sim.settle()
    expect(sim.facts.grown.map((item) => item.devices)).toEqual([1, 1, 1])
    expect(sim.facts.launches).toEqual([
      {
        machine: "Mac",
        job: "j-tsvq4me7",
        group: "android-1+android-servidor-1+ios-1",
        parts: parts.map((p) => p.part),
      },
    ])
    expect(sim.facts.delivered.get("j-tsvq4me7")).toMatchObject(
      parts.map((part) => ({ part: part.part, state: "concluido", attempts: 1, machine: { name: "Mac" } })),
    )
  })

  test("the three parts are worth 4 devices each and say so in the same round: they grow while the budget allows, never beyond", async () => {
    const sim = world(23)
    parts.forEach((part) => sim.script("j-tsvq4me7", part.part, run(4)))
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(10 * 60_000)
    sim.settle()
    // After the build 7 cores are free: Android takes 3 more emulators (6 cores), beyond the 2 the hub proposed; what
    // is left fits no other device of the others (Android + servidor's containers count).
    expect(sim.facts.grown.map((item) => [item.attempt, item.wanted, item.devices])).toEqual([
      ["j-tsvq4me7/android/1", 4, 4],
      ["j-tsvq4me7/android-servidor/1", 4, 1],
      ["j-tsvq4me7/ios/1", 4, 1],
    ])
    // The world checks every step that no machine reserved beyond its budget; all ran on the Mac and passed.
    expect(sim.facts.peak.get("Mac")).toBe(6)
    expect(sim.facts.delivered.get("j-tsvq4me7")).toMatchObject(
      parts.map((part) => ({ part: part.part, state: "concluido", machine: { name: "Mac" } })),
    )
  })

  test.each([1, 2, 3, 4, 5])(
    "seven requests with plans, builds ending together and plans asking for more, seed %i: the budget never breaks, all are served",
    async (seed) => {
      const sim = world(100 + seed)
      const ids = ["j-11111111", "j-22222222", "j-33333333", "j-44444444", "j-55555555", "j-66666666", "j-77777777"]
      ids.forEach((id, index) => {
        parts.forEach((part, at) =>
          sim.script(id, part.part, { ...run(1 + ((index + at + seed) % 4)), buildMs: 30_000 }),
        )
        sim.submit("host-6", { id, sessionID: `ses_${index}`, rootSessionID: `ses_${index}`, code, parts })
      })
      await sim.advance(60 * 60_000)
      sim.settle()
      expect(ids.map((id) => sim.facts.delivered.get(id)?.every((part) => part.outcome?.approved))).toEqual(
        ids.map(() => true),
      )
      // Some plans got more devices than their minimum.
      expect(sim.facts.grown.some((item) => item.devices > 1)).toBe(true)
    },
    30_000,
  )

  /** The Mac as it is now (`cpu = 20`) with the hub on a machine without devices; one build at a time. */
  function busy(seed: number, busyMs = 120_000) {
    const sim = createWorld({ seed })
    sim.addMachine({ name: "host-6", hub: true, platform: "linux" })
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {} },
      capacity: { memMb: 96 * 1024, cpuMilli: 20_000, builds: 1, android: 6, ios: 0 },
    })
    // Another request holds 5 emulators (2 minutes by default): the hub proposes the next one a single device.
    sim.script("j-5emzzz01", "android", { ...run(5), buildMs: 0, runMs: busyMs, useful: undefined })
    sim.submit("host-6", {
      id: "j-5emzzz01",
      sessionID: "ses_b",
      rootSessionID: "ses_b",
      code,
      parts: [spec("android", { devices: { min: 5, max: 5 }, build: false, plan: false })],
    })
    return sim
  }

  test("j-3a1pc4x6: offered one device while the Mac was busy, it grows to what its scenarios are worth once the other request ended during its build", async () => {
    const sim = busy(31)
    sim.script("j-3a1pc4x6", "android", { ...run(4), buildMs: 180_000 })
    await sim.advance(5_000)
    sim.submit("host-6", {
      id: "j-3a1pc4x6",
      sessionID: "ses_a",
      rootSessionID: "ses_a",
      code,
      parts: [spec("android")],
    })
    await sim.advance(5_000)
    expect(
      sim.machines
        .get("host-6")!
        .db.query("SELECT devices_granted AS granted FROM hub_part WHERE job_id = 'j-3a1pc4x6'")
        .get(),
    ).toEqual({ granted: 1 })
    await sim.advance(10 * 60_000)
    sim.settle()
    expect(sim.facts.grown).toEqual([{ machine: "Mac", attempt: "j-3a1pc4x6/android/1", wanted: 4, devices: 4 }])
    expect(sim.facts.delivered.get("j-3a1pc4x6")).toMatchObject([{ state: "concluido", machine: { name: "Mac" } }])
  })

  test("a part of the queue waiting for room on the Mac for Android: the part whose plan spoke does not grow, and it runs with what it has", async () => {
    const sim = busy(32, 10 * 60_000)
    sim.script("j-3a1pc4x6", "android", { ...run(4), buildMs: 180_000 })
    sim.script("j-espera01", "android", { ...run(1), useful: undefined })
    await sim.advance(5_000)
    sim.submit("host-6", {
      id: "j-3a1pc4x6",
      sessionID: "ses_a",
      rootSessionID: "ses_a",
      code,
      parts: [spec("android")],
    })
    await sim.advance(5_000)
    // Another request comes while it builds, needing a build and 2 emulators: it waits for room on the Mac, where
    // 3 more emulators would fit once the build ended.
    sim.submit("host-6", {
      id: "j-espera01",
      sessionID: "ses_c",
      rootSessionID: "ses_c",
      code,
      parts: [spec("android", { devices: { min: 2, max: 2 }, plan: false })],
    })
    await sim.advance(20 * 60_000)
    sim.settle()
    expect(sim.facts.grown).toEqual([{ machine: "Mac", attempt: "j-3a1pc4x6/android/1", wanted: 4, devices: 1 }])
    expect(sim.facts.delivered.get("j-espera01")).toMatchObject([{ state: "concluido", machine: { name: "Mac" } }])
  })
})
