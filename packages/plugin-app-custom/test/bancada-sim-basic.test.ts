import { describe, expect, test } from "bun:test"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld, type World } from "./fixture/bancada-sim"

const spec = (part: string, platform: BancadaProtocol.Platform): BancadaProtocol.PartSpec => ({
  part,
  label: part === "ios" ? "iOS" : "Android",
  platform,
  needs: [platform],
  device: {},
  devices: { min: 1, max: 1 },
  exclusive: [],
  unsafe: false,
  args: [],
})
const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
const passed = (ids: string[]) => ids.map((id) => ({ id, result: "passou" as const }))

/** The production layout: the hub (Linux) offers no device; the Mac offers Android and iOS, `slots` of each. */
function layout(world: World, slots: number) {
  world.addMachine({ name: "Linux", hub: true, platform: "linux" })
  world.addMachine({
    name: "Mac",
    capabilities: { android: {}, ios: {} },
    capacity: { memMb: 96_000, cpuMilli: 13_000, builds: 1, android: slots, ios: slots },
  })
}

describe("simulation", () => {
  test("S1: a request on the hub runs on the Mac, both parts, and its session hears once", async () => {
    const world = createWorld({ seed: 1 })
    layout(world, 2)
    world.script("j-7qk2m9xa", "android", {
      buildMs: 2_000,
      runMs: 10_000,
      exit: 0,
      planned: ["a1", "a2"],
      scenarios: passed(["a1", "a2"]),
    })
    world.script("j-7qk2m9xa", "ios", {
      buildMs: 2_000,
      runMs: 6_000,
      exit: 0,
      planned: ["i1"],
      scenarios: passed(["i1"]),
    })
    world.submit("Linux", {
      id: "j-7qk2m9xa",
      sessionID: "ses_transcricao",
      rootSessionID: "ses_transcricao",
      code,
      parts: [spec("android", "android"), spec("ios", "ios")],
    })
    await world.advance(60_000)
    world.settle()

    expect(world.facts.notices.get("j-7qk2m9xa")).toBe(1)
    expect(world.facts.delivered.get("j-7qk2m9xa")).toMatchObject([
      { part: "android", state: "concluido", attempts: 1, machine: { name: "Mac" }, outcome: { approved: true } },
      { part: "ios", state: "concluido", attempts: 1, machine: { name: "Mac" }, outcome: { approved: true } },
    ])
    expect(world.machines.get("Linux")!.core.status("j-7qk2m9xa")).toMatchObject({ state: "entregue" })
  })

  // Several seeds: each draws another sequence of losses, duplicates and delays.
  test.each(Array.from({ length: 20 }, (_, index) => index + 1))(
    "S5: a bad network in both directions neither duplicates nor loses anything (seed %i)",
    async (seed) => {
      const world = createWorld({
        seed,
        toHub: { drop: 0.3, duplicate: 0.2, delayMs: [0, 4_000] },
        toMachine: { drop: 0.3, duplicate: 0.2, delayMs: [0, 4_000] },
        partitions: [{ machine: "Mac", from: 1_010_000, to: 1_050_000 }],
      })
      // One Android slot: the two Android parts must take turns.
      layout(world, 1)
      world.script("j-aaaaaaaa", "android", {
        buildMs: 1_000,
        runMs: 8_000,
        exit: 0,
        planned: ["a1"],
        scenarios: passed(["a1"]),
      })
      world.script("j-aaaaaaaa", "ios", {
        buildMs: 1_000,
        runMs: 5_000,
        exit: 1,
        planned: ["i1", "i2"],
        scenarios: [
          { id: "i1", result: "passou" },
          { id: "i2", result: "falhou", message: 'Esperava "Transcrevendo…"; achou "0:07"' },
        ],
      })
      world.script("j-bbbbbbbb", "android", {
        buildMs: 1_000,
        runMs: 3_000,
        exit: 0,
        planned: ["b1", "b2"],
        scenarios: passed(["b1"]),
      })
      world.submit("Linux", {
        id: "j-aaaaaaaa",
        sessionID: "ses_hub",
        rootSessionID: "ses_hub",
        code,
        parts: [spec("android", "android"), spec("ios", "ios")],
      })
      world.submit("Mac", {
        id: "j-bbbbbbbb",
        sessionID: "ses_mac",
        rootSessionID: "ses_mac",
        code,
        parts: [spec("android", "android")],
      })
      await world.advance(240_000)
      world.settle()

      expect(world.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
        { part: "android", state: "concluido", outcome: { approved: true } },
        { part: "ios", state: "concluido", outcome: { approved: false, lost: [] } },
      ])
      // Exit 0 but a planned scenario without a result: never approved.
      expect(world.facts.delivered.get("j-bbbbbbbb")).toMatchObject([
        { part: "android", state: "concluido", outcome: { approved: false, lost: ["b2"] } },
      ])
      expect([...world.facts.starts.values()]).toEqual([1, 1, 1])
      // The hub counts the offers a machine has not received yet: it never offers more than the machine has.
      expect(world.facts.refusals.size).toBe(0)
    },
  )

  test("a request the hub acknowledged but could not register closes at its origin a minute later, with an alert", async () => {
    const world = createWorld({ seed: 3 })
    layout(world, 1)
    // A part named twice: the hub's queue names parts by test, its handler fails and the submit goes to dead_letter.
    world.submit("Mac", {
      id: "j-7qk2m9xa",
      sessionID: "ses_a",
      rootSessionID: "ses_a",
      code,
      parts: [spec("android", "android"), spec("android", "android")],
    })
    await world.advance(30_000)
    expect(world.facts.delivered.get("j-7qk2m9xa")).toBeUndefined()
    await world.advance(40_000)
    const closed = {
      part: "android",
      state: "invalido",
      attempts: 0,
      outcome: { verdict: "invalido", reason: "o hub não conseguiu registrar o pedido", approved: false },
    }
    expect(world.facts.delivered.get("j-7qk2m9xa")).toMatchObject([closed, closed])
    expect(world.facts.notices.get("j-7qk2m9xa")).toBe(1)
    expect(world.logs).toContainEqual(expect.stringContaining("alert: the hub acknowledged request j-7qk2m9xa"))
    const hub = world.machines.get("Linux")!.db
    expect(hub.query("SELECT COUNT(*) AS n FROM dead_letter").get()).toEqual({ n: 1 })
  })
})
