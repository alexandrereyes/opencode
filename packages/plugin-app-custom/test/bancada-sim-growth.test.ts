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
  sim.machines.get("Mac")!.db.query("SELECT part, devices, devices_cap AS cap FROM attempt ORDER BY part").all()

describe("simulation: devices after the plan", () => {
  test("j-tsvq4me7: the Mac takes the three parts at once with one build and each one's minimum; the plan uses 1 device each, nothing grows", async () => {
    const sim = world(22)
    parts.forEach((part) => sim.script("j-tsvq4me7", part.part, run(1)))
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(3_000)
    // Accepted at once, none refused: each reserves its minimum, the hub's proposal is how far it may grow.
    expect(sim.facts.refusals.size).toBe(0)
    expect(granted(sim)).toEqual([
      { part: "android", devices: 1, cap: 2 },
      { part: "android-servidor", devices: 1, cap: 2 },
      { part: "ios", devices: 1, cap: 4 },
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

  test("the three plans ask for 4 devices in the same round: each grows as far as the budget allows, up to the hub's proposal, never beyond", async () => {
    const sim = world(23)
    parts.forEach((part) => sim.script("j-tsvq4me7", part.part, run(4)))
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(10 * 60_000)
    sim.settle()
    // After the build 7 cores are free: Android grows to its proposal (2 cores), Android + servidor too (3 cores, its
    // containers count), iOS gets the last 2 cores' worth (one simulator more), not the 4 it was proposed.
    expect(sim.facts.grown.map((item) => [item.attempt, item.wanted, item.devices])).toEqual([
      ["j-tsvq4me7/android/1", 4, 2],
      ["j-tsvq4me7/android-servidor/1", 4, 2],
      ["j-tsvq4me7/ios/1", 4, 2],
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
})
