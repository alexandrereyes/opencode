import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import { inspect, reserved, touchesDevices } from "../src/bancada/commands"
import { createCore, type Machine } from "../src/bancada/daemon/core"
import type { Launcher } from "../src/bancada/daemon/executor"
import type { Phone } from "../src/bancada/machine-config"
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
const phone = (alias: string, id: string, more: Partial<Phone> = {}): Phone => ({
  alias,
  name: alias,
  id,
  platform: "android",
  transport: "usb",
  tags: [],
  realAccounts: false,
  policy: "reservavel",
  ...more,
})

describe("what the hook reads of a command", () => {
  test("parts per machine, the devices each names and the ones it starts", () => {
    expect(touchesDevices("git status && ls")).toBe(false)
    expect(touchesDevices("adb -s R58M devices")).toBe(true)
    expect(inspect("git status")).toEqual([])
    expect(
      inspect(
        "emulator -avd Pixel_9 -no-window & adb -s emulator-5556 install app.apk; mac xcrun simctl boot 'iPhone 16' && mac simslim on Mini",
      ),
    ).toEqual([
      {
        where: "here",
        command: expect.any(String),
        emulators: [{ serial: "emulator-5556" }, { avd: "Pixel_9" }],
        simulators: [],
        starts: [{ platform: "android", name: "Pixel_9" }],
      },
      {
        where: "mac",
        command: expect.any(String),
        emulators: [],
        simulators: [{ name: "iPhone 16" }],
        starts: [
          { platform: "ios", name: "iPhone 16" },
          { platform: "ios", name: "Mini" },
        ],
      },
    ])
    expect(inspect("emulator @Medium")[0]?.starts).toEqual([{ platform: "android", name: "Medium" }])
    expect(inspect("xcrun simctl bootstatus 1A2B3C4D-0000-0000-0000-000000000001 -b")[0]?.starts).toEqual([
      { platform: "ios", name: "1A2B3C4D-0000-0000-0000-000000000001" },
    ])
    expect(inspect("xcrun simctl bootstatus Mini")[0]?.starts).toEqual([])
    // A phone is named by its id only: the process looks for it in the part's text.
    expect(inspect("adb -s R58M123 shell getprop")).toMatchObject([
      { where: "here", command: "adb -s R58M123 shell getprop" },
    ])
  })

  test("a command the repository reserves to the Bancada (fora), however it is started; not with BANCADA_JOB", () => {
    const at = { root: "/repo", workdir: "/repo", outside: ["scripts/e2e.sh"] }
    expect(reserved("./scripts/e2e.sh --all", at)).toBe("./scripts/e2e.sh --all")
    expect(reserved("cd x; bash scripts/e2e.sh", at)).toBe("bash scripts/e2e.sh")
    expect(reserved("/repo/scripts/e2e.sh", { ...at, workdir: "/elsewhere" })).toBe("/repo/scripts/e2e.sh")
    expect(reserved("../scripts/e2e.sh", { ...at, workdir: "/repo/src" })).toBe("../scripts/e2e.sh")
    expect(reserved("BANCADA_JOB=j-1 ./scripts/e2e.sh", at)).toBeUndefined()
    expect(reserved("cat scripts/e2e.sh", at)).toBeUndefined()
    expect(reserved("echo ./scripts/e2e.sh | sh", at)).toBeUndefined()
    expect(reserved("./scripts/e2e.sh", { ...at, outside: [] })).toBeUndefined()
  })
})

/** A Mac that is the hub too, with room for one emulator, a phone to reserve and one not to. */
function mac() {
  const clock = { now: 1_000_000 }
  const machine: Machine = {
    machineID: "m-mac",
    instanceID: "i-mac",
    name: "Mac de Alexandre",
    platform: "darwin",
    hub: true,
    speed: "normal",
    capabilities: { android: {} },
    capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android: 1, ios: 0 },
    phones: [phone("poco", "R58M123"), phone("pessoal", "192.168.0.7:5555", { policy: "negar" })],
    prefix: "bancada-",
  }
  let n = 0
  const db = new Database(":memory:")
  const core = createCore({
    db,
    now: () => clock.now,
    random: () => `id-${++n}`,
    machine,
    launcher: idle,
    log: () => {},
  })
  const family = (root: string) => ({ sessionID: root, rootSessionID: root, rootTitle: `Sessão ${root}` })
  return { core, db, clock, gate: (root: string, command: string) => core.gate.decide(family(root), inspect(command)) }
}

describe("the hook's decision", () => {
  test("a phone needs the family's hold; one not to be reserved is always refused", () => {
    const it = mac()
    expect(it.gate("ses_a", "adb -s R58M123 install app.apk")).toEqual({
      allow: false,
      message: 'Reserve antes com `bancada_hold({ aparelho: "poco" })`.',
    })
    expect(it.gate("ses_a", "adb -s 192.168.0.7:5555 shell")).toEqual({
      allow: false,
      message: 'O celular pessoal não pode ser usado por agentes (politica = "negar" no arquivo da máquina).',
    })
    it.core.hold({
      hold: "r-poco",
      sessionID: "ses_a",
      rootSessionID: "ses_a",
      target: { kind: "fisico", device: "poco" },
    })
    it.clock.now += 5 * 60_000
    expect(it.gate("ses_a", "adb -s R58M123 install app.apk")).toEqual({ allow: true })
    // Renewed by that use.
    expect(it.core.holds.decided("r-poco")?.last_activity_at).toBe(it.clock.now)
    // Another family: refused.
    expect(it.gate("ses_b", "adb -s R58M123 install app.apk")).toMatchObject({ allow: false })
  })

  test("starting an emulator asks for a slot on the spot; the family uses it, another is refused, a third waits", () => {
    const it = mac()
    expect(it.gate("ses_a", "emulator -avd Pixel_9 -no-window")).toEqual({ allow: true })
    expect(it.core.holds.family("ses_a")).toMatchObject([
      { state: "concedida", target: expect.stringContaining("Pixel_9") },
    ])
    // The family's own device: passes (and is renewed).
    expect(it.gate("ses_a", "emulator -avd Pixel_9 -wipe-data")).toEqual({ allow: true })
    expect(it.core.holds.family("ses_a")).toHaveLength(1)
    expect(it.gate("ses_b", "emulator -avd Pixel_9")).toEqual({
      allow: false,
      message: "Pixel_9 está reservado para Sessão ses_a (em Mac de Alexandre); não use aparelho de outra sessão.",
    })
    expect(it.gate("ses_c", "emulator @Medium")).toEqual({
      allow: false,
      message: "Sem vaga agora (sem folga para mais um aparelho agora; 1º na fila). Você será avisado quando sair.",
    })
    // A device the Bancada made for a test, and an emulator on a test's ports.
    expect(it.gate("ses_a", "adb -s emulator-5554 shell; emulator -avd bancada-android-1")).toEqual({
      allow: false,
      message:
        "bancada-android-1 é um aparelho de um teste da Bancada em andamento; não use. Para rodar testes, use bancada_run.",
    })
    it.db.run(
      "INSERT INTO lease (id, kind, owner, android, ios, mem_mb, cpu_milli, builds, state, created_at) VALUES ('l1', 'attempt', 'x', 0, 0, 0, 0, 0, 'active', 0)",
    )
    it.db.run("INSERT INTO lease_device (lease_id, device_id, port_start, port_end) VALUES ('l1', NULL, 5580, 5581)")
    expect(it.gate("ses_a", "adb -s emulator-5580 shell")).toMatchObject({ allow: false })
    // An emulator nobody holds, started elsewhere: passes without a record.
    expect(it.gate("ses_a", "adb -s emulator-5600 shell")).toEqual({ allow: true })
  })
})

describe("the hook on a Linux server whose mac bridge leads to another machine", () => {
  function pair() {
    const sim = createWorld({ seed: 12 })
    sim.addMachine({ name: "Linux", hub: true, platform: "linux" })
    sim.addMachine({
      name: "Mac",
      capabilities: { android: {} },
      capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android: 1, ios: 0 },
      hardware: "hw-mac",
    })
    const linux = sim.machines.get("Linux")!.core
    const asker = (root: string) => ({ sessionID: root, rootSessionID: root, rootTitle: `Sessão ${root}` })
    return { sim, linux, gate: (root: string, command: string) => linux.gate.decide(asker(root), inspect(command)) }
  }

  test("the slot is asked of the machine behind the bridge through the hub; the mirror lets the family pass", async () => {
    const it = pair()
    await it.sim.advance(2_000)
    it.linux.bridge("hw-mac")
    const first = it.gate("ses_a", "mac emulator -avd bancada-test-x")
    const pending = "pending" in first ? [...first.pending] : []
    expect(pending).toEqual([expect.stringMatching(/^r-/)])
    await it.sim.advance(3_000)
    expect(it.linux.gate.answer(pending)).toEqual({ allow: true })
    expect(it.sim.machines.get("Mac")!.core.holds.here()).toMatchObject([{ origin_machine: "m-Linux" }])
    expect(it.gate("ses_a", "mac adb -s emulator-5554 shell; mac emulator -avd bancada-test-x")).toEqual({
      allow: true,
    })
    expect(it.gate("ses_b", "mac emulator -avd bancada-test-x")).toEqual({
      allow: false,
      message: "bancada-test-x está reservado para outra sessão deste servidor.",
    })
  }, 30_000)

  test("with the hub out, a start behind the bridge is refused: o hub está fora", async () => {
    const it = pair()
    await it.sim.advance(2_000)
    const mac = it.sim.machines.get("Mac")!.core
    // The Mac's hub (the Linux) is out; a start behind the Mac's own bridge would go to another machine.
    it.sim.sleep("Linux", true)
    await it.sim.advance(60_000)
    mac.bridge("hw-none")
    expect(mac.gate.decide({ sessionID: "ses_m", rootSessionID: "ses_m" }, inspect("mac emulator -avd x"))).toEqual({
      allow: false,
      message: "Sem vaga agora (o hub está fora).",
    })
  }, 30_000)
})
