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
const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
const passed = (ids: string[]) => ids.map((id) => ({ id, result: "passou" as const }))

function world() {
  // A part uncertain for an hour is lost: these scenarios test sleeping and restarts, not giving up on a machine.
  const result = createWorld({ seed: 7, timings: { silentMs: 45_000, lostMs: 60 * 60_000 } })
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

  test("S16: the hub's process is out for two minutes while the Mac runs a part: nothing goes silent or uncertain", async () => {
    const sim = world()
    sim.script("j-7qk2m9xa", "android", {
      buildMs: 4_000,
      runMs: 300_000,
      exit: 0,
      planned: ["a1"],
      scenarios: passed(["a1"]),
    })
    await sim.advance(10_000)
    expect(sim.seen("j-7qk2m9xa", "android").at(-1)).toBe("rodando")
    // The hub's process is gone (a deploy): it runs nothing and hears nobody, then a new one opens its database.
    sim.sleep("Linux", true)
    await sim.advance(120_000)
    sim.restart("Linux")
    sim.sleep("Linux", false)
    // Its very first round, before any machine called: a whole step would hide the mistake behind the Mac's call.
    await sim.round("Linux")
    const hub = sim.machines.get("Linux")!.db
    expect(hub.query("SELECT state FROM hub_machine WHERE machine_id = 'm-Mac'").get()).toEqual({ state: "ok" })
    expect(hub.query("SELECT state FROM hub_part WHERE job_id = 'j-7qk2m9xa'").get()).toEqual({ state: "rodando" })
    await sim.advance(240_000)
    sim.settle()
    expect(sim.seen("j-7qk2m9xa", "android")).not.toContain("incerto")
    expect(sim.facts.delivered.get("j-7qk2m9xa")).toMatchObject([{ part: "android", outcome: { approved: true } }])
  })

  test("S17: a start that takes two minutes, on the Mac and on the hub, never holds a round", async () => {
    const sim = createWorld({ seed: 11, timings: { silentMs: 45_000 } })
    // Two builds on the hub: C's start holds one while D runs.
    sim.addMachine({
      name: "Linux",
      hub: true,
      platform: "linux",
      capabilities: { docker: {} },
      capacity: { memMb: 32_768, cpuMilli: 16_000, builds: 2, android: 0, ios: 0 },
    })
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {} },
      capacity: { memMb: 96_000, cpuMilli: 13_000, builds: 1, android: 2, ios: 0 },
    })
    const docker: BancadaProtocol.PartSpec = {
      ...android,
      part: "docker",
      label: "Docker",
      platform: "none",
      needs: ["docker"],
      devices: { min: 0, max: 0 },
    }
    const quick = { buildMs: 2_000, runMs: 5_000, exit: 0, planned: ["c1"], scenarios: passed(["c1"]) }
    sim.script("j-aaaaaaaa", "android", { ...quick, runMs: 10_000 })
    // The code of these two comes from far: their starts take two minutes.
    sim.script("j-bbbbbbbb", "android", { ...quick, startMs: 120_000 })
    sim.script("j-cccccccc", "docker", { ...quick, startMs: 120_000 })
    sim.script("j-dddddddd", "docker", quick)
    const ask = (id: string, part: BancadaProtocol.PartSpec) =>
      sim.submit("Linux", { id, sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [part] })
    ask("j-aaaaaaaa", android)
    await sim.advance(5_000)
    expect(sim.seen("j-aaaaaaaa", "android").at(-1)).toBe("rodando")
    ask("j-bbbbbbbb", android)
    ask("j-cccccccc", docker)
    await sim.advance(15_000)
    // The Mac read and reported its other attempt while B's code was still coming.
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([{ part: "android", outcome: { approved: true } }])
    expect([sim.seen("j-bbbbbbbb", "android").at(-1), sim.seen("j-cccccccc", "docker").at(-1)]).toEqual([
      "aceito",
      "aceito",
    ])
    // On the hub, a new request is acknowledged, offered and run while C's code is still coming.
    ask("j-dddddddd", docker)
    await sim.advance(1_000)
    expect(sim.seen("j-dddddddd", "docker")).toContain("aceito")
    await sim.advance(10_000)
    expect(sim.facts.delivered.get("j-dddddddd")).toMatchObject([{ part: "docker", outcome: { approved: true } }])
    expect(sim.seen("j-cccccccc", "docker").at(-1)).toBe("aceito")
    await sim.advance(120_000)
    sim.settle()
    expect(["j-bbbbbbbb/android", "j-cccccccc/docker"].map((part) => sim.facts.starts.get(part))).toEqual([1, 1])
  })

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

  test("S10: seven sessions ask at once on a Mac with room for three emulators: the budget never breaks, all are served", async () => {
    const sim = createWorld({ seed: 10 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    // 40 GB and 10 cores: a build (8 GB, 6 cores) beside up to three emulators (8 GB, 1 core each), one build at once.
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {} },
      capacity: { memMb: 40_960, cpuMilli: 10_000, builds: 1, android: 3, ios: 0 },
    })
    const ids = ["j-11111111", "j-22222222", "j-33333333", "j-44444444", "j-55555555", "j-66666666", "j-77777777"]
    ids.forEach((id, index) => {
      sim.script(id, "android", {
        buildMs: 3_000,
        runMs: 20_000,
        exit: 0,
        planned: ["c1"],
        scenarios: passed(["c1"]),
      })
      sim.submit("Linux", {
        id,
        sessionID: `ses_${index}`,
        rootSessionID: `ses_${index}`,
        code,
        parts: [{ ...android, devices: { min: 1, max: 2 } }],
      })
    })
    await sim.advance(10 * 60_000)
    sim.settle()
    expect(ids.map((id) => sim.facts.delivered.get(id)?.[0]?.outcome?.approved)).toEqual(ids.map(() => true))
    // Never above the budget (the world checks every step), and more than one emulator at a time when it fit.
    expect(sim.facts.peak.get("Mac")).toBe(3)
  })
})
