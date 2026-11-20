import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import { createCore, type Machine } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import { expiry, worstEnd } from "../src/bancada/daemon/holds"
import type { Phone } from "../src/bancada/machine-config"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld } from "./fixture/bancada-sim"

const idle: Launcher = {
  start: async () => {},
  status: async () => ({ state: "rodando" }),
  cancel: async () => {},
  stop: async () => {},
  reap: async () => {},
  held: () => false,
  cleanup: async () => {},
}
const minute = 60_000
const times = { idleQueuedMs: 10 * minute, idleMs: 60 * minute, totalQueuedMs: 30 * minute, placeMs: 15 * minute }
const phone = (alias: string, more: Partial<Phone> = {}): Phone => ({
  alias,
  name: alias,
  id: `${alias}-serial`,
  platform: "android",
  transport: "usb",
  tags: [],
  realAccounts: false,
  policy: "reservavel",
  ...more,
})

/** A Mac that is the hub too, with room for one emulator and two phones; the clock moves by hand. */
function mac(phones: Phone[] = [phone("poco"), phone("pessoal", { policy: "negar" })], android = 1) {
  const clock = { now: 1_000_000 }
  const machine: Machine = {
    machineID: "m-mac",
    instanceID: "i-mac",
    name: "Mac de Alexandre",
    platform: "darwin",
    hub: true,
    speed: "normal",
    capabilities: { android: {} },
    capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android, ios: 0 },
    phones,
  }
  let n = 0
  const core = createCore({
    db: new Database(":memory:"),
    now: () => clock.now,
    random: () => `id-${++n}`,
    machine,
    launcher: idle,
    log: () => {},
  })
  const ask = (hold: string, root: string, target: Parameters<typeof core.hold>[0]["target"]) =>
    core.hold({ hold, sessionID: root, rootSessionID: root, rootTitle: `Sessão ${root}`, target })
  const later = async (ms: number) => {
    clock.now += ms
    await core.tick()
  }
  return { clock, core, ask, later }
}

describe("hold rules", () => {
  test("expiry: idle 10 min with someone waiting, idle 60 min alone, 30 min in all with someone waiting; pinned never", () => {
    const at = 1_000_000
    const hold = { acquiredAt: at, lastActivityAt: at }
    expect(expiry(hold, at + 9 * minute, true, times)).toBeUndefined()
    expect(expiry(hold, at + 10 * minute, true, times)).toBe("parada há 10 min com alguém esperando")
    expect(expiry(hold, at + 59 * minute, false, times)).toBeUndefined()
    expect(expiry(hold, at + 60 * minute, false, times)).toBe("parada há 60 min")
    const busy = { acquiredAt: at, lastActivityAt: at + 25 * minute }
    expect(expiry(busy, at + 30 * minute, true, times)).toBe("30 min no total com alguém esperando")
    expect(expiry({ ...hold, pinnedUntil: at + 120 * minute }, at + 90 * minute, true, times)).toBeUndefined()
    expect(worstEnd(busy, times)).toBe(at + 30 * minute)
  })
})

describe("holds on the machine that has the device", () => {
  test("a light slot takes one device's room; another family waits with its place and gets the next room, told once", async () => {
    const it = mac()
    expect(it.ask("h-a", "ses_a", { kind: "vaga", platform: "android", name: "Pixel_9" })).toMatchObject({
      state: "concedida",
    })
    // The same family asking again for the same device keeps its hold.
    expect(it.ask("h-a2", "ses_a", { kind: "vaga", platform: "android", name: "Pixel_9" })).toMatchObject({
      hold: "h-a",
      state: "concedida",
    })
    expect(it.ask("h-b", "ses_b", { kind: "vaga", platform: "android", name: "Medium" })).toMatchObject({
      state: "esperando",
      position: 1,
    })
    // The waiting slot takes the next room: the queue of tests sees none.
    expect(it.core.outgoing().pulse.free.android).toBe(0)
    it.core.release("h-a")
    await it.later(1_000)
    expect(it.core.holds.find("h-b")?.state).toBe("concedida")
    expect(it.core.notes()).toMatchObject([
      {
        session_id: "ses_b",
        resume: 1,
        text: "[Bancada] Sua vaga saiu: a vaga para Medium (Android) em Mac de Alexandre (reserva h-b). Use agora; ela vence se ficar parada.",
      },
    ])
  })

  test("a phone: one family at a time; idle 10 min with someone waiting, it expires (a note that does not wake) and the next takes it", async () => {
    const it = mac()
    expect(it.ask("h-a", "ses_a", { kind: "fisico", device: "poco" })).toMatchObject({
      state: "concedida",
      device: JSON.stringify({ id: "poco-serial" }),
    })
    expect(it.ask("h-b", "ses_b", { kind: "fisico", device: "poco" })).toMatchObject({
      state: "esperando",
      position: 1,
      reason: "aguardando poco (com Sessão ses_a em Mac de Alexandre)",
    })
    // Use by its family renews it; B keeps its place by asking again.
    await it.later(8 * minute)
    it.core.touch("h-a")
    expect(it.ask("h-b2", "ses_b", { kind: "fisico", device: "poco" })?.hold).toBe("h-b")
    await it.later(8 * minute)
    expect(it.core.holds.find("h-a")?.state).toBe("concedida")
    it.ask("h-b3", "ses_b", { kind: "fisico", device: "poco" })
    await it.later(3 * minute)
    expect(it.core.holds.find("h-a")?.state).toBe("vencida")
    expect(it.core.holds.find("h-b")?.state).toBe("concedida")
    expect(it.core.notes().map((note) => [note.session_id, note.resume, note.text])).toEqual([
      [
        "ses_a",
        0,
        "[Bancada] A reserva h-a (o celular poco em Mac de Alexandre) venceu: parada há 11 min com alguém esperando. Se ainda precisar, peça de novo com bancada_hold.",
      ],
      [
        "ses_b",
        1,
        "[Bancada] Sua vaga saiu: o celular poco em Mac de Alexandre (reserva h-b). Use agora; ela vence se ficar parada.",
      ],
    ])
  })

  test("a place not asked again in 15 min is lost; a phone not to be reserved is refused; one kept for someone never expires", async () => {
    const until = 1_000_000 + 24 * 60 * minute
    const it = mac([
      phone("poco"),
      phone("pessoal", { policy: "negar" }),
      phone("fixo", { reserved: { until, for: "QA" } }),
    ])
    it.ask("h-a", "ses_a", { kind: "fisico", device: "poco" })
    it.ask("h-b", "ses_b", { kind: "fisico", device: "poco" })
    await it.later(16 * minute)
    expect(it.core.holds.find("h-b")).toMatchObject({ state: "solta", reason: "o lugar na fila venceu" })
    expect(it.ask("h-c", "ses_c", { kind: "fisico", device: "pessoal" })).toMatchObject({
      state: "negada",
      reason: "pessoal não é reservável",
    })
    it.ask("h-d", "ses_d", { kind: "fisico", device: "fixo" })
    it.ask("h-e", "ses_e", { kind: "fisico", device: "fixo" })
    await it.later(120 * minute)
    expect(it.core.holds.find("h-d")?.state).toBe("concedida")
  })
})

describe("holds on another machine, through the hub", () => {
  /** A Linux hub whose sessions ask for devices of the Mac (room for two emulators) and its phone. */
  function pair() {
    const sim = createWorld({ seed: 11 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {}, "fisico:poco": {} },
      capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android: 2, ios: 0 },
      phones: [phone("poco")],
    })
    const linux = sim.machines.get("Linux")!.core
    const ask = (hold: string, root: string, target: Parameters<typeof linux.hold>[0]["target"], machine = "mac") =>
      linux.hold({ hold, sessionID: root, rootSessionID: root, rootTitle: `Sessão ${root}`, machine, target })
    return { sim, linux, mac: sim.machines.get("Mac")!.core, ask }
  }

  test("the Mac decides a Linux session's slot; the origin mirrors it, renews it by use and lets it go", async () => {
    const it = pair()
    await it.sim.advance(2_000)
    expect(it.ask("h-a", "ses_a", { kind: "vaga", platform: "android", name: "bancada-test-x" })?.state).toBe("pedida")
    await it.sim.advance(5_000)
    expect(it.linux.holds.find("h-a")).toMatchObject({
      state: "concedida",
      device: JSON.stringify({ nome: "bancada-test-x", maquina: "Mac" }),
    })
    expect(it.mac.holds.here().map((row) => [row.id, row.origin_machine])).toEqual([["h-a", "m-Linux"]])
    // A phone by its alias only: the hub finds the machine whose catalog has it.
    it.ask("h-p", "ses_a", { kind: "fisico", device: "poco" }, "")
    await it.sim.advance(5_000)
    expect(it.linux.holds.find("h-p")).toMatchObject({ state: "concedida" })
    // Use renews it on the Mac (one renewal a minute travels).
    await it.sim.advance(50 * minute, 10_000)
    it.linux.touch("h-a")
    await it.sim.advance(20 * minute, 10_000)
    expect(it.mac.holds.decided("h-a")?.state).toBe("concedida")
    it.linux.release("h-a")
    await it.sim.advance(5_000)
    expect(it.mac.holds.decided("h-a")?.state).toBe("solta")
    expect(it.linux.holds.find("h-a")?.state).toBe("solta")
    // The phone not touched for 60 min expired there; the session gets a note that does not wake it.
    expect(it.linux.holds.find("h-p")?.state).toBe("vencida")
    expect(it.linux.notes().map((note) => [note.session_id, note.resume, note.text])).toEqual([
      [
        "ses_a",
        0,
        "[Bancada] A reserva h-p (o celular poco em Mac) venceu: parada há 60 min. Se ainda precisar, peça de novo com bancada_hold.",
      ],
    ])
  }, 30_000)

  test("with the hub out, a device of another machine is refused: o hub está fora", async () => {
    const it = pair()
    await it.sim.advance(2_000)
    it.sim.sleep("Linux", true)
    await it.sim.advance(60_000)
    const mac = it.sim.machines.get("Mac")!.core
    expect(mac.holds.family("ses_m")).toEqual([])
    const refused = mac.hold({
      hold: "h-m",
      sessionID: "ses_m",
      rootSessionID: "ses_m",
      machine: "m-Linux",
      target: { kind: "vaga", platform: "android", name: "x" },
    })
    expect(refused).toMatchObject({ state: "negada", reason: "o hub está fora" })
    // Its own devices are still decided here.
    expect(
      mac.hold({
        hold: "h-n",
        sessionID: "ses_m",
        rootSessionID: "ses_m",
        target: { kind: "vaga", platform: "android", name: "x" },
      }),
    ).toMatchObject({ state: "concedida" })
  }, 30_000)

  test("S10 with light slots: seven sessions run tests while three ask for slots; the budget never breaks, all are served", async () => {
    const sim = createWorld({ seed: 10 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {} },
      capacity: { memMb: 40_960, cpuMilli: 10_000, builds: 1, android: 3, ios: 0 },
    })
    const spec: BancadaProtocol.PartSpec = {
      part: "android",
      label: "Android",
      platform: "android",
      needs: ["android"],
      device: {},
      devices: { min: 1, max: 2 },
      exclusive: [],
      unsafe: false,
      build: true,
      args: [],
    }
    const ids = ["j-11111111", "j-22222222", "j-33333333", "j-44444444", "j-55555555", "j-66666666", "j-77777777"]
    ids.forEach((id, index) => {
      sim.script(id, "android", {
        buildMs: 3_000,
        runMs: 20_000,
        exit: 0,
        planned: ["c1"],
        scenarios: [{ id: "c1", result: "passou" }],
      })
      sim.submit("Linux", {
        id,
        sessionID: `ses_${index}`,
        rootSessionID: `ses_${index}`,
        code: { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false },
        parts: [spec],
      })
    })
    await sim.advance(2_000)
    const mac = sim.machines.get("Mac")!.core
    const slots = ["h-1", "h-2", "h-3"]
    slots.forEach((hold, index) =>
      mac.hold({
        hold,
        sessionID: `ses_v${index}`,
        rootSessionID: `ses_v${index}`,
        target: { kind: "vaga", platform: "android", name: `emu-${index}` },
      }),
    )
    // Each slot is used a while and let go; meanwhile the waiting ones keep asking.
    for (const _ of Array.from({ length: 12 })) {
      await sim.advance(30_000)
      slots.forEach((hold, index) => {
        const row = mac.holds.find(hold)
        if (row?.state === "concedida") return mac.release(hold)
        mac.hold({
          hold,
          sessionID: `ses_v${index}`,
          rootSessionID: `ses_v${index}`,
          target: { kind: "vaga", platform: "android", name: `emu-${index}` },
        })
      })
    }
    await sim.advance(10 * minute)
    sim.settle()
    expect(ids.map((id) => sim.facts.delivered.get(id)?.[0]?.outcome?.approved)).toEqual(ids.map(() => true))
    expect(slots.map((hold) => mac.holds.find(hold)?.state)).toEqual(["solta", "solta", "solta"])
    expect(sim.facts.peak.get("Mac")).toBe(3)
  }, 60_000)
})
