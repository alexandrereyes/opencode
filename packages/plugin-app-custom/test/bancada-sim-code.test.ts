import { describe, expect, test } from "bun:test"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld } from "./fixture/bancada-sim"

const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
const spec: BancadaProtocol.PartSpec = {
  part: "android",
  label: "Android",
  platform: "android",
  needs: ["android"],
  device: {},
  devices: { min: 1, max: 1 },
  exclusive: [],
  unsafe: false,
  build: true,
  args: [],
}
const ok = {
  buildMs: 2_000,
  runMs: 30_000,
  exit: 0,
  planned: ["c1"],
  scenarios: [{ id: "c1", result: "passou" as const }],
}
const room = { memMb: 64_000, cpuMilli: 16_000, builds: 2, android: 2, ios: 2 }
// Three chunks and a bit: the bundle goes and comes in pieces.
const bundleBytes = 3 * 1024 * 1024 + 123

/** A Mac without emulators asks; the request can run only on another machine, so its code travels. */
function world(seed: number, options: Omit<Parameters<typeof createWorld>[0], "seed" | "codeTravels"> = {}) {
  const sim = createWorld({ seed, codeTravels: { bundleBytes }, ...options })
  sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: { android: {} }, capacity: room })
  sim.addMachine({ name: "Mac", capabilities: {}, capacity: room })
  sim.script("j-aaaaaaaa", "android", ok)
  return sim
}
const ask = (sim: ReturnType<typeof createWorld>) =>
  sim.submit("Mac", {
    id: "j-aaaaaaaa",
    sessionID: "ses_a",
    rootSessionID: "ses_a",
    code,
    parts: [spec],
    repository: "/Users/alexandre/exemplo",
  })

describe("simulation: code through the hub (S13)", () => {
  test("the Mac's request runs on the host-6 with the Mac's bundle, in chunks, checked; nothing of it stays", async () => {
    const sim = world(41)
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(3 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { state: "concluido", machine: { name: "Linux" }, outcome: { approved: true } },
    ])
    expect(sim.facts.bundles).toEqual([{ machine: "Linux", job: "j-aaaaaaaa" }])
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
    // The origin's bundle, the executor's copy and the hub's transfer are gone.
    expect([...sim.disk.keys()]).toEqual([])
    expect(sim.machines.get("Linux")!.db.query("SELECT COUNT(*) AS n FROM hub_blob").get()).toEqual({ n: 0 })
  })

  test("a request of the hub's own session runs on the Mac with the hub's bundle", async () => {
    const sim = createWorld({ seed: 47, codeTravels: { bundleBytes } })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: {}, capacity: room })
    sim.addMachine({ name: "Mac", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok)
    await sim.advance(1_000)
    sim.submit("Linux", {
      id: "j-aaaaaaaa",
      sessionID: "ses_a",
      rootSessionID: "ses_a",
      code,
      parts: [spec],
      repository: "/workspace/exemplo",
    })
    await sim.advance(3 * 60_000)
    sim.settle()
    expect(sim.facts.bundles).toEqual([{ machine: "Mac", job: "j-aaaaaaaa" }])
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([{ state: "concluido", outcome: { approved: true } }])
    expect([...sim.disk.keys()]).toEqual([])
    expect(sim.machines.get("Linux")!.db.query("SELECT COUNT(*) AS n FROM code_out").get()).toEqual({ n: 0 })
  })

  test("only the transfer's sender writes it and only its receiver reads it", async () => {
    const sim = createWorld({ seed: 45, codeTravels: { bundleBytes } })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: {}, capacity: room })
    sim.addMachine({ name: "Mac", capabilities: {}, capacity: room })
    // Mac2 runs it: the hub names Mac the sender and Mac2 the receiver.
    sim.addMachine({ name: "Mac2", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok)
    await sim.advance(1_000)
    ask(sim)
    const hub = sim.machines.get("Linux")!
    const ready = () =>
      hub.db.query<{ transfer: string }, []>("SELECT transfer FROM hub_blob WHERE state = 'pronta'").get()
    for (const _ of Array.from({ length: 30 })) if (!ready()) await sim.advance(1_000)
    const transfer = ready()!.transfer
    const read = (machineID: string, instanceID: string) =>
      hub.core.blobGet({ protocol: 1, machineID, instanceID, transfer, index: 0, offset: 0, size: 10 })
    expect(await read("m-Mac", "i-Mac")).toEqual({ ok: false, reason: "unknown" })
    expect(await read("m-Mac2", "i-outro")).toEqual({ ok: false, reason: "unknown" })
    expect(await read("m-Mac2", "i-Mac2")).toMatchObject({ ok: true, end: false })
    const write = await hub.core.blobPut({
      protocol: 1,
      machineID: "m-Mac2",
      instanceID: "i-Mac2",
      transfer,
      file: { index: 1, path: "x", size: 1, sha256: "0".repeat(64) },
      offset: 0,
      data: "AA==",
      end: true,
    })
    expect(write).toEqual({ ok: false, reason: "unknown" })
  })

  test("the origin is cut off when its code is asked: the part waits for it, an alert at 10 min, and it runs once back", async () => {
    // The Mac's request reaches the hub, then the Mac is cut off for 12 minutes.
    const sim = world(42, { partitions: [{ machine: "Mac", from: 1_003_000, to: 1_723_000 }] })
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(9 * 60_000)
    const hub = sim.machines.get("Linux")!.core
    expect(hub.alerts()).toEqual([])
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBeUndefined()
    await sim.advance(2 * 60_000)
    expect(hub.alerts()).toMatchObject([
      {
        kind: "aguardando_codigo",
        text: expect.stringContaining("o código do pedido j-aaaaaaaa não chegou a Linux há 10 min: a origem Mac"),
      },
    ])
    await sim.advance(4 * 60_000)
    sim.settle()
    expect(hub.alerts()).toEqual([])
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([{ state: "concluido", outcome: { approved: true } }])
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
  })

  test("a transfer that expired before its executor got it is asked for again, and the request still runs once", async () => {
    // A third machine runs it; it is cut off after asking, past the transfer's 2 minutes.
    const sim = createWorld({
      seed: 43,
      codeTravels: { bundleBytes },
      timings: { transferMs: 2 * 60_000 },
      partitions: [{ machine: "Mac2", from: 1_006_000, to: 1_246_000 }],
    })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux", capabilities: {}, capacity: room })
    sim.addMachine({ name: "Mac", capabilities: {}, capacity: room })
    sim.addMachine({ name: "Mac2", capabilities: { android: {} }, capacity: room })
    sim.script("j-aaaaaaaa", "android", ok)
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(10 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([
      { state: "concluido", machine: { name: "Mac2" }, outcome: { approved: true } },
    ])
    expect(sim.logs).toContainEqual(expect.stringContaining("the code of j-aaaaaaaa did not arrive: a transferência"))
    expect(sim.facts.starts.get("j-aaaaaaaa/android")).toBe(1)
  })

  test("an upload cut in the middle resumes from what the hub already has", async () => {
    const sim = world(46)
    sim.cut(3)
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(3 * 60_000)
    sim.settle()
    const mib = 1024 * 1024
    // The third chunk was lost; asked again from the start, the hub said what it had and the rest followed.
    expect(sim.facts.puts.map((put) => put.offset)).toEqual([0, mib, 2 * mib, 0, 2 * mib, 3 * mib])
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([{ state: "concluido", outcome: { approved: true } }])
  })

  test("a bundle that arrives with another SHA-256 is never fetched from: asked again, and the good one runs", async () => {
    const sim = world(44)
    sim.spoil(1)
    await sim.advance(1_000)
    ask(sim)
    await sim.advance(3 * 60_000)
    sim.settle()
    expect(sim.logs).toContainEqual(expect.stringContaining("o pacote chegou corrompido (SHA-256 diferente)"))
    expect(sim.facts.bundles).toEqual([{ machine: "Linux", job: "j-aaaaaaaa" }])
    expect(sim.facts.delivered.get("j-aaaaaaaa")).toMatchObject([{ state: "concluido", outcome: { approved: true } }])
  })
})
