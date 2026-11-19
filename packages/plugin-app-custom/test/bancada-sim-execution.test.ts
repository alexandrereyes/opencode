import { describe, expect, test } from "bun:test"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld } from "./fixture/bancada-sim"

const android: BancadaProtocol.PartSpec = {
  part: "android",
  label: "Android",
  platform: "android",
  needs: ["android"],
  device: {},
  devices: { min: 1, max: 1 },
  exclusive: [],
  unsafe: false,
  args: [],
}
const code = { project: "exemplo", commit: "3417b7e3", remotes: [], inRemote: false }
const passed = (ids: string[]) => ids.map((id) => ({ id, result: "passou" as const }))

function world() {
  const result = createWorld({ seed: 7, timings: { silentMs: 45_000 } })
  result.addMachine({ name: "Linux", hub: true, platform: "linux" })
  result.addMachine({
    name: "Mac",
    capabilities: { android: {} },
    capacity: { memMb: 96_000, cpuMilli: 13_000, builds: 1, android: 1, ios: 0 },
  })
  result.script("j-7qk2m9xa", "android", {
    buildMs: 4_000,
    runMs: 20_000,
    exit: 0,
    planned: ["a1", "a2"],
    scenarios: passed(["a1", "a2"]),
  })
  result.submit("Linux", { id: "j-7qk2m9xa", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [android] })
  return result
}

describe("simulation: executions outlive the Bancada process", () => {
  // Restarted right after accepting, while building, while running, and after the end before the hub heard of it.
  test.each([2_000, 5_000, 15_000, 27_000])(
    "S2: the Mac's Bancada process dies and comes back at %i ms: it reconciles and the result is single",
    async (at) => {
      const sim = world()
      await sim.advance(at)
      const restarted = sim.restart("Mac")
      await sim.advance(60_000)
      sim.settle()
      expect(restarted.reconciling()).toBe(false)
      expect(sim.facts.starts.get("j-7qk2m9xa/android")).toBe(1)
      expect(sim.facts.delivered.get("j-7qk2m9xa")).toMatchObject([
        { part: "android", state: "concluido", attempts: 1, outcome: { approved: true } },
      ])
    },
  )

  test("S3: the Mac sleeps 20 minutes in the middle of a run: incerto, then its real state, and nothing is lost", async () => {
    const sim = world()
    await sim.advance(12_000)
    expect(sim.seen("j-7qk2m9xa", "android").at(-1)).toBe("rodando")
    sim.sleep("Mac", true)
    await sim.advance(20 * 60_000)
    expect(sim.seen("j-7qk2m9xa", "android").at(-1)).toBe("incerto")
    sim.sleep("Mac", false)
    await sim.advance(60_000)
    sim.settle()
    // Back from incerto to where it was, then to the end: the sleep never counted as running time. (The world records
    // once per step, so states a step passes through, like `aceito`, may not show.)
    expect(sim.seen("j-7qk2m9xa", "android").slice(-4)).toEqual(["rodando", "incerto", "rodando", "concluido"])
    expect(sim.facts.delivered.get("j-7qk2m9xa")).toMatchObject([
      { part: "android", state: "concluido", attempts: 1, outcome: { approved: true } },
    ])
  })
})
