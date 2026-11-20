import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld } from "./fixture/bancada-sim"

const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
const spec = (part: string, more: Partial<BancadaProtocol.PartSpec> = {}): BancadaProtocol.PartSpec => ({
  part,
  label: part,
  platform: "android",
  needs: ["android"],
  device: {},
  devices: { min: 1, max: 1 },
  exclusive: [],
  unsafe: false,
  build: true,
  args: [],
  ...more,
})
const passed = (ids: string[]) => ids.map((id) => ({ id, result: "passou" as const }))
const ok = (runMs: number, planned = ["c1"]) => ({
  buildMs: 2_000,
  runMs,
  exit: 0,
  planned,
  scenarios: passed(planned),
})
const room = { memMb: 64_000, cpuMilli: 16_000, builds: 2, android: 2, ios: 2 }
const ask = (
  sim: ReturnType<typeof createWorld>,
  at: string,
  id: string,
  parts: BancadaProtocol.PartSpec[],
  session = id,
) => sim.submit(at, { id, sessionID: session, rootSessionID: session, code, parts })

describe("simulation: the queue", () => {
  // Short times: silent after 10 s, away after 20 s, lost after a minute of silence.
  test("S4: the Mac goes for good: Android runs again on the host-6, iOS waits for it, the phone part never repeats", async () => {
    const sim = createWorld({ seed: 4, timings: { silentMs: 10_000, uncertainMs: 20_000, lostMs: 60_000 } })
    // The host-6 is slow (no history: its estimate × 2.5), so everything goes to the Mac first.
    sim.addMachine({
      name: "Linux",
      hub: true,
      platform: "linux",
      speed: "lento",
      capabilities: { android: {} },
      capacity: room,
    })
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {}, ios: {}, "android-fisico": {} },
      capacity: { ...room, builds: 3 },
    })
    sim.script("j-aaaaaaaa", "android", ok(120_000))
    sim.script("j-bbbbbbbb", "ios", ok(120_000))
    sim.script("j-cccccccc", "celular", ok(120_000))
    // The Mac calls in before the requests arrive.
    await sim.advance(1_000)
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android")])
    ask(sim, "Linux", "j-bbbbbbbb", [spec("ios", { platform: "ios", needs: ["ios"] })])
    ask(sim, "Linux", "j-cccccccc", [spec("celular", { needs: ["android-fisico"], unsafe: true })])
    await sim.advance(10_000)
    expect(
      ["j-aaaaaaaa/android", "j-bbbbbbbb/ios", "j-cccccccc/celular"].map((id) =>
        sim.seen(...(id.split("/") as [string, string])).at(-1),
      ),
    ).toEqual(["rodando", "rodando", "rodando"])
    sim.sleep("Mac", true)
    await sim.advance(4 * 60_000)
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { part: "android", state: "concluido", attempts: 2, machine: { name: "Linux" }, outcome: { approved: true } },
    ])
    expect(sim.facts.delivered.get("j-cccccccc")).toMatchObject([
      { part: "celular", state: "perdido", attempts: 1, outcome: { reason: "a máquina Mac não respondeu" } },
    ])
    // iOS has only the Mac: it waits for it, by name.
    expect(sim.facts.delivered.get("j-bbbbbbbb")).toBeUndefined()
    const hub = sim.machines.get("Linux")!.db
    expect(hub.query("SELECT state, told FROM hub_part WHERE job_id = 'j-bbbbbbbb'").get()).toMatchObject({
      state: "na_fila",
      told: expect.stringContaining("maquina_fora"),
    })
    // Back, it runs the iOS part again and stops what the hub gave up there.
    sim.sleep("Mac", false)
    await sim.advance(5 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-bbbbbbbb")).toMatchObject([
      { part: "ios", attempts: 2, outcome: { approved: true } },
    ])
    expect(sim.facts.starts.get("j-cccccccc/celular")).toBe(1)
  })

  test("S9: a device falls twice: the lost scenarios run once more, never a third time; a good retry joins green", async () => {
    const sim = createWorld({ seed: 9 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    const fell = (device: string, planned: string[], failing: string, passing: string[]) => ({
      buildMs: 1_000,
      runMs: 5_000,
      exit: 1,
      planned,
      scenarios: [...passed(passing), { id: failing, result: "falhou" as const, message: "travou", device }],
      fell: [device],
    })
    sim.script("j-aaaaaaaa", "android", fell("emu-2", ["a1", "a2"], "a2", ["a1"]), 1)
    sim.script("j-aaaaaaaa", "android", fell("emu-3", ["a2"], "a2", []), 2)
    sim.script("j-bbbbbbbb", "android", fell("emu-4", ["b1", "b2"], "b2", ["b1"]), 1)
    sim.script("j-bbbbbbbb", "android", ok(5_000, ["b2"]), 2)
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android")])
    ask(sim, "Linux", "j-bbbbbbbb", [spec("android")])
    await sim.advance(2 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      {
        state: "perdido",
        attempts: 2,
        outcome: { verdict: "infraestrutura", lost: ["a2"], scenarios: [{ id: "a1", result: "passou" }] },
      },
    ])
    expect(sim.facts.delivered.get("j-bbbbbbbb")).toMatchObject([
      { state: "concluido", attempts: 2, outcome: { verdict: "aprovado", lost: [] } },
    ])
    expect([sim.facts.starts.get("j-aaaaaaaa/android"), sim.facts.starts.get("j-bbbbbbbb/android")]).toEqual([2, 2])
  })

  test("S12: a late result of an old attempt stays in its history and changes nothing; the new attempt decides", async () => {
    // The Mac is cut off for 90 s: lost after a minute, the part runs again on the other Mac.
    const sim = createWorld({
      seed: 12,
      timings: { silentMs: 10_000, uncertainMs: 20_000, lostMs: 60_000 },
      partitions: [{ machine: "Mac", from: 1_005_000, to: 1_095_000 }],
    })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(30_000), 1)
    sim.script("j-aaaaaaaa", "android", ok(60_000), 2)
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android")])
    await sim.advance(4_000)
    sim.addMachine({ name: "Mac2", capabilities: { android: {} }, capacity: room })
    await sim.advance(100_000)
    // Attempt 1 ended on the Mac during the cut and said so on its return: the part still runs attempt 2.
    expect(sim.seen("j-aaaaaaaa", "android").at(-1)).toBe("rodando")
    await sim.advance(2 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { state: "concluido", attempts: 2, machine: { name: "Mac2" }, outcome: { approved: true } },
    ])
    expect(sim.seen("j-aaaaaaaa", "android").filter((state) => state === "concluido")).toEqual(["concluido"])
  })

  test("S14: the hub's database is replaced mid-run: the Mac shows itself, its open request and the attempt, which never runs again", async () => {
    const sim = createWorld({ seed: 14 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(60_000))
    ask(sim, "Mac", "j-aaaaaaaa", [spec("android")])
    await sim.advance(10_000)
    expect(sim.seen("j-aaaaaaaa", "android").at(-1)).toBe("rodando")
    sim.replaceDb("Linux")
    await sim.advance(2 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { state: "concluido", attempts: 1, outcome: { approved: true } },
    ])
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
  })

  test("S14: the Mac's database is wiped mid-run: what the hub had there is lost by the pulse, and runs again", async () => {
    const sim = createWorld({ seed: 15 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(60_000))
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android")])
    await sim.advance(10_000)
    sim.replaceDb("Mac")
    await sim.advance(3 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { state: "concluido", attempts: 2, outcome: { approved: true } },
    ])
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(2)
  })

  test("S14: databases restored from a copy taken before, on each side, never run a request twice nor lose it", async () => {
    const sim = createWorld({ seed: 16 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(60_000))
    sim.script("j-bbbbbbbb", "android", ok(30_000))
    ask(sim, "Mac", "j-aaaaaaaa", [spec("android")])
    await sim.advance(10_000)
    const hubCopy = sim.machines.get("Linux")!.db.serialize()
    const macCopy = sim.machines.get("Mac")!.db.serialize()
    await sim.advance(10_000)
    sim.replaceDb("Linux", Database.deserialize(hubCopy))
    await sim.advance(10_000)
    sim.replaceDb("Mac", Database.deserialize(macCopy))
    ask(sim, "Mac", "j-bbbbbbbb", [spec("android")])
    await sim.advance(3 * 60_000)
    sim.settle()
    expect(["j-aaaaaaaa", "j-bbbbbbbb"].map((id) => sim.facts.delivered.get(id)?.[0]?.outcome?.approved)).toEqual([
      true,
      true,
    ])
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
  })

  test("S18: a request cancelled with its machine silent closes cancelled at once, never runs again, and stops there on its return", async () => {
    const sim = createWorld({
      seed: 18,
      timings: { silentMs: 10_000, uncertainMs: 20_000, lostMs: 60_000 },
      partitions: [{ machine: "Mac", from: 1_015_000, to: 1_200_000 }],
    })
    // The host-6 is slow without history: the part goes to the Mac.
    sim.addMachine({
      name: "Linux",
      hub: true,
      platform: "linux",
      speed: "lento",
      capabilities: { android: {} },
      capacity: room,
    })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(10 * 60_000))
    await sim.advance(1_000)
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android")])
    await sim.advance(10_000)
    const on = sim.machines.get("Linux")!.db.query("SELECT machine_id FROM hub_part").get()
    expect(on).toEqual({ machine_id: "m-Mac" })
    await sim.advance(20_000)
    expect(sim.seen("j-aaaaaaaa", "android").at(-1)).toBe("incerto")
    sim.machines.get("Linux")!.core.cancel("j-aaaaaaaa")
    await sim.advance(2_000)
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([{ part: "android", state: "cancelado" }])
    // Past the 15 min of uncertainty (1 min here), nothing is offered again anywhere.
    await sim.advance(2 * 60_000)
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
    // Back, the Mac hears the cancel and stops its execution.
    await sim.advance(2 * 60_000)
    sim.settle()
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
  })

  test("S19: two parts of a request on a Mac with one build slot are one group; a part without build reserves none", async () => {
    const sim = createWorld({ seed: 19 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({ name: "Mac", capabilities: { android: {}, ios: {} }, capacity: { ...room, builds: 1 } })
    const long = { ...ok(20_000), buildMs: 15_000 }
    sim.script("j-aaaaaaaa", "android", long)
    sim.script("j-aaaaaaaa", "ios", long)
    sim.script("j-bbbbbbbb", "lint", ok(5_000))
    await sim.advance(1_000)
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android"), spec("ios", { platform: "ios", needs: ["ios"] })])
    await sim.advance(3_000)
    const mac = sim.machines.get("Mac")!.db
    expect(mac.query("SELECT SUM(builds) AS builds FROM lease WHERE state = 'active'").get()).toEqual({ builds: 1 })
    // Building: no build slot left, yet a part without build is taken.
    // Only the Mac has Xcode: a check without devices nor build.
    ask(sim, "Linux", "j-bbbbbbbb", [
      spec("lint", { platform: "none", needs: ["ios"], devices: { min: 0, max: 0 }, build: false }),
    ])
    await sim.advance(2_000)
    expect(
      mac.query("SELECT a.part, l.builds FROM attempt a JOIN lease l ON l.id = a.lease_id ORDER BY a.part").all(),
    ).toEqual([
      { part: "android", builds: 1 },
      { part: "ios", builds: 0 },
      { part: "lint", builds: 0 },
    ])
    await sim.advance(60_000)
    sim.settle()
    expect(sim.facts.launches.filter((launch) => launch.job === "j-aaaaaaaa")).toEqual([
      { machine: "Mac", job: "j-aaaaaaaa", group: "android-1+ios-1", parts: ["android", "ios"] },
    ])
  })
})
