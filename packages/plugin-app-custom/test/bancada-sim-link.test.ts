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
const ok = (runMs: number) => ({
  buildMs: 2_000,
  runMs,
  exit: 0,
  planned: ["c1"],
  scenarios: [{ id: "c1", result: "passou" as const }],
})
const room = { memMb: 64_000, cpuMilli: 16_000, builds: 2, android: 2, ios: 2 }
const ask = (sim: ReturnType<typeof createWorld>, at: string, id: string, parts: BancadaProtocol.PartSpec[]) =>
  sim.submit(at, { id, sessionID: `ses-${id}`, rootSessionID: `ses-${id}`, code, parts })

describe("simulation: the link to the hub", () => {
  test("S7: with the hub out, the Mac serves its sessions' new requests alone; the one never confirmed waits; back, nothing runs twice", async () => {
    // The hub is cut off from the Mac for 3 minutes, from 1 s in.
    const sim = createWorld({ seed: 31, partitions: [{ machine: "Mac", from: 1_001_000, to: 1_181_000 }] })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: { android: {} }, capacity: room })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(60_000))
    sim.script("j-bbbbbbbb", "android", ok(60_000))
    sim.script("j-cccccccc", "android", ok(60_000))
    // Asked before the Mac knows the hub is out: it waits for the hub's confirmation, never taken here.
    await sim.advance(5_000)
    ask(sim, "Mac", "j-aaaaaaaa", [spec("android")])
    await sim.advance(45_000)
    const mac = sim.machines.get("Mac")!.core
    expect(mac.hub()).toMatchObject({ state: "unavailable" })
    expect(mac.alerts()).toMatchObject([{ id: "hub:fora", kind: "hub" }])
    // Asked now: served here. One that needs an exclusive lock waits for the hub (a global lock has no owner here).
    ask(sim, "Mac", "j-bbbbbbbb", [spec("android")])
    ask(sim, "Mac", "j-cccccccc", [spec("android", { exclusive: ["abacato:servidor-dev"] })])
    await sim.advance(20_000)
    expect(mac.status("j-aaaaaaaa")).toMatchObject({ state: "aguardando_confirmacao" })
    expect(mac.status("j-bbbbbbbb")).toMatchObject({ state: "na_fila", parts: { android: { state: "rodando" } } })
    expect(mac.status("j-cccccccc")).toMatchObject({
      state: "aguardando_confirmacao",
      parts: { android: { reason: { code: "aguardando_hub", text: "aguardando o hub" } } },
    })
    await sim.advance(60_000)
    expect(sim.facts.delivered.get("j-bbbbbbbb")).toMatchObject([
      { state: "concluido", machine: { name: "Mac" }, outcome: { approved: true } },
    ])
    // The hub comes back: the waiting ones run once, and it hears of the request served alone.
    await sim.advance(5 * 60_000)
    sim.settle()
    expect(mac.hub()).toEqual({ state: "ok" })
    expect(mac.alerts()).toEqual([])
    expect(["j-aaaaaaaa", "j-bbbbbbbb", "j-cccccccc"].map((id) => sim.facts.starts.get(`${id}/android`))).toEqual([
      1, 1, 1,
    ])
    const hub = sim.machines.get("Linux")!.db
    expect(hub.query("SELECT id, state FROM hub_job WHERE id = 'j-bbbbbbbb'").get()).toEqual({
      id: "j-bbbbbbbb",
      state: "local",
    })
  })

  test("S11: a machine of another protocol version is refused by name and serves its own requests alone, saying why", async () => {
    const sim = createWorld({ seed: 32, versions: { Mac: 2 } })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: { android: {} }, capacity: room })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok(30_000))
    await sim.advance(2_000)
    const mac = sim.machines.get("Mac")!.core
    expect(mac.hub()).toMatchObject({
      state: "unavailable",
      reason: "o hub fala outra versão do protocolo (this hub speaks another protocol)",
    })
    expect(mac.alerts()).toMatchObject([{ id: "hub:protocol_mismatch", kind: "hub" }, { id: "hub:fora" }])
    ask(sim, "Mac", "j-aaaaaaaa", [spec("android")])
    await sim.advance(2 * 60_000)
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { state: "concluido", machine: { name: "Mac" }, outcome: { approved: true } },
    ])
    // The hub never registered the machine nor its request.
    const hub = sim.machines.get("Linux")!.db
    expect(hub.query("SELECT COUNT(*) AS n FROM hub_machine WHERE machine_id = 'm-Mac'").get()).toEqual({ n: 0 })
  })

  test("S6: the hub's process restarts with a queue and executions: the queue comes back from its database, nothing is lost or repeated", async () => {
    const sim = createWorld({ seed: 33, partitions: [{ machine: "Mac", from: 1_015_000, to: 1_040_000 }] })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: {}, capacity: room })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: { ...room, android: 1 } })
    sim.script("j-aaaaaaaa", "android", ok(60_000))
    sim.script("j-bbbbbbbb", "android", ok(30_000))
    sim.script("j-cccccccc", "android", ok(30_000))
    await sim.advance(1_000)
    // One runs on the Mac, one waits for its emulator, one is asked on the hub while the Mac is cut off.
    ask(sim, "Linux", "j-aaaaaaaa", [spec("android")])
    await sim.advance(5_000)
    ask(sim, "Linux", "j-bbbbbbbb", [spec("android")])
    await sim.advance(10_000)
    ask(sim, "Linux", "j-cccccccc", [spec("android")])
    // The hub's process is out for a minute and comes back on the same database.
    sim.sleep("Linux", true)
    await sim.advance(60_000)
    sim.sleep("Linux", false)
    sim.restart("Linux")
    await sim.advance(5 * 60_000)
    sim.settle()
    expect(["j-aaaaaaaa", "j-bbbbbbbb", "j-cccccccc"].map((id) => sim.facts.starts.get(`${id}/android`))).toEqual([
      1, 1, 1,
    ])
    expect(
      ["j-aaaaaaaa", "j-bbbbbbbb", "j-cccccccc"].map((id) => sim.facts.delivered.get(id)?.[0]?.outcome?.approved),
    ).toEqual([true, true, true])
  })
})
