import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { open, step, type Brake, type Reading } from "../src/bancada/daemon/brake"
import { free, largestFit, measured, room, times, type Cost } from "../src/bancada/daemon/budget"
import { createCore, type Machine } from "../src/bancada/daemon/core"
import { makeDevicePool, type Driver } from "../src/bancada/daemon/devices/pool"
import { block, emulatorPair } from "../src/bancada/daemon/devices/ports"
import { deviceCosts } from "../src/bancada/catalog/costs"
import { deviceFor } from "../src/bancada/daemon/devices/types"
import type { Launcher, Status } from "../src/bancada/daemon/executor"
import { darwinPressure, darwinSwap, hidIdle, linuxPressure, linuxSwap } from "../src/bancada/daemon/probes"
import { defaults } from "../src/bancada/machine-config"
import { BancadaProtocol } from "../src/bancada/protocol"

const build = { memMb: 8_192, cpuMilli: 6_000 }
const emulator = { memMb: 8_192, cpuMilli: 1_000 }
const none = () => ({ memMb: 0, cpuMilli: 0 })
const vector = (memMb: number, cpuMilli: number, builds = 1, android = 8, ios = 0) => ({
  memMb,
  cpuMilli,
  builds,
  android,
  ios,
})

describe("budget", () => {
  test("a cost is the p90 of what was measured from 3 samples on, the default before", () => {
    const sample = (memMb: number) => ({ memMb, cpuMilli: memMb / 4 })
    expect(measured([sample(4_000), sample(5_000)], emulator)).toEqual(emulator)
    const ten = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => sample(n * 1_000))
    expect(measured(ten, emulator)).toEqual({ memMb: 9_000, cpuMilli: 2_250 })
    expect(measured([sample(3_000), sample(1_000), sample(2_000)], emulator)).toEqual(sample(3_000))
  })

  test("an attempt reserves its peak at admission: its build, its devices and its extra, at most what fits", () => {
    const fit = (memMb: number, extra: (devices: number) => Cost = none) =>
      largestFit({
        room: vector(memMb, 20_000),
        platform: "android",
        min: 1,
        proposed: 3,
        build,
        device: emulator,
        extra,
      })
    expect([fit(40_000), fit(25_000), fit(16_384), fit(16_000)]).toEqual([3, 2, 1, undefined])
    // A test that needs Docker takes 2 GB and a core beside each device: in 36 GB one emulator fewer fits.
    const docker = (n: number) => times({ memMb: 2_048, cpuMilli: 1_000 }, n)
    expect([fit(36_000), fit(36_000, docker), fit(40_000, docker)]).toEqual([3, 2, 3])
    // No build free, nothing at all; a part without devices needs only its build.
    expect(
      largestFit({
        room: vector(96_000, 13_000, 0),
        platform: "android",
        min: 1,
        proposed: 1,
        build,
        device: emulator,
        extra: none,
      }),
    ).toBeUndefined()
    expect(
      largestFit({
        room: vector(8_192, 6_000),
        platform: "none",
        min: 0,
        proposed: 0,
        build,
        device: none(),
        extra: none,
      }),
    ).toBe(0)
  })

  test("while the owner uses the Mac new admissions get a share of memory and CPU; live reservations stay", () => {
    const capacity = vector(40_000, 10_000, 1, 3)
    const used = vector(8_192, 1_000, 0, 1)
    expect(room(capacity, used)).toEqual(vector(31_808, 9_000, 1, 2))
    expect(room(capacity, used, 0.6)).toEqual(vector(15_808, 5_000, 1, 2))
  })

  test("the pulse's free vector never lets the hub offer beyond what fits beside a build", () => {
    const devices = { android: emulator, ios: { memMb: 3_584, cpuMilli: 2_000 } }
    // Beside a build: 31.8 GB and 4 cores left, three emulators (memory) and two simulators (CPU).
    expect(free(vector(40_000, 10_000, 1, 8, 6), build, devices)).toEqual(vector(40_000, 10_000, 1, 3, 2))
    // The ceiling of emulators, and no build free (or none that fits): nothing.
    expect(free(vector(96_000, 13_000, 1, 2, 0), build, devices).android).toBe(2)
    expect(free(vector(96_000, 13_000, 0, 8, 6), build, devices)).toEqual(vector(96_000, 13_000, 0, 0, 0))
    // Three builds in the budget, CPU for two at once: two.
    expect(free(vector(64_000, 16_000, 3, 8, 6), build, devices).builds).toBe(2)
    expect(free(vector(6_000, 13_000, 1, 8, 6), build, devices)).toMatchObject({ builds: 0, android: 0 })
  })
})

describe("brake", () => {
  const config = defaults.brake
  const run = (readings: ReadonlyArray<Omit<Reading, "at">>, every = 5_000) =>
    readings.reduce<{ brake: Brake; closed: boolean[] }>(
      (state, reading, index) => {
        const brake = step(state.brake, { at: index * every, ...reading }, config)
        return { brake, closed: [...state.closed, brake.closed] }
      },
      { brake: open, closed: [] },
    )
  const fine = { pressure: 1, memFreePct: 60, swapUsedMb: 100, cpuIdlePct: 50, loadPerCore: 0.5 }

  test.each([
    ["memory pressure", { pressure: 2 }, "pressão de memória acima do normal"],
    ["little free memory", { memFreePct: 12 }, "memória livre em 12% (mínimo 20%)"],
    ["load per core", { loadPerCore: 3.4 }, "carga de 3.4 por núcleo (máximo 3)"],
  ])("closes at once on %s", (_name, bad, reason) => {
    const result = run([fine, { ...fine, ...bad }])
    expect(result.closed).toEqual([false, true])
    expect(result.brake.reasons).toEqual([reason])
  })

  test("closes when swap grows past the limit within 2 minutes, not when it grows slowly", () => {
    expect(run([fine, { ...fine, swapUsedMb: 250 }, { ...fine, swapUsedMb: 400 }]).closed).toEqual([false, false, true])
    // 150 MB a minute: never 256 MB inside a 2-minute window.
    const slow = [0, 1, 2, 3, 4, 5].map((minute) => ({ ...fine, swapUsedMb: 100 + minute * 150 }))
    expect(run(slow, 60_000).closed.some(Boolean)).toBe(true)
    const slower = [0, 1, 2, 3, 4, 5].map((minute) => ({ ...fine, swapUsedMb: 100 + minute * 100 }))
    expect(run(slower, 60_000).closed.some(Boolean)).toBe(false)
  })

  test("closes when the CPU stays idle below the minimum for 30 s, not on one busy reading", () => {
    const busy = { ...fine, cpuIdlePct: 2 }
    expect(run([fine, busy, fine, busy]).closed).toEqual([false, false, false, false])
    expect(run([busy, busy, busy, busy, busy, busy, busy]).closed).toEqual([
      false,
      false,
      false,
      false,
      false,
      false,
      true,
    ])
  })

  test("reopens only after six good readings in a row; a bad one starts over", () => {
    const bad = { ...fine, pressure: 4 }
    const result = run([bad, fine, fine, fine, bad, fine, fine, fine, fine, fine, fine])
    expect(result.closed).toEqual([true, true, true, true, true, true, true, true, true, true, false])
    expect(run([bad, fine]).brake.reasons).toEqual(["pressão de memória acima do normal"])
  })
})

describe("devices and ports", () => {
  test("each granted device gets 20 ports of its own; a local emulator an even console port and the next", () => {
    const range = { start: 48_000, end: 48_059 }
    expect(block(range, [])).toEqual({ start: 48_000, end: 48_019 })
    expect(
      block(range, [
        { start: 48_000, end: 48_019 },
        { start: 48_040, end: 48_059 },
      ]),
    ).toEqual({
      start: 48_020,
      end: 48_039,
    })
    expect(block(range, [{ start: 48_010, end: 48_029 }])).toEqual({ start: 48_030, end: 48_049 })
    expect(
      block(range, [
        { start: 48_000, end: 48_019 },
        { start: 48_020, end: 48_039 },
        { start: 48_040, end: 48_059 },
      ]),
    ).toBeUndefined()
    expect(emulatorPair({ start: 5_701, end: 5_799 }, new Set([5_702, 5_705]))).toEqual({ console: 5_706, adb: 5_707 })
    expect(emulatorPair({ start: 5_700, end: 5_701 }, new Set([5_701]))).toBeUndefined()
  })

  test("a trimmed device when the part accepts it and the machine can; an emulator in a container in the Docker mode", () => {
    const pick = (
      platform: BancadaProtocol.Platform,
      slim: "aceita" | "exige" | "recusa",
      docker = false,
      simslim = false,
    ) => deviceFor(platform, { slim }, { docker, simslim })?.subject
    expect([
      pick("android", "aceita"),
      pick("android", "recusa"),
      pick("android", "aceita", true),
      pick("ios", "aceita"),
      pick("ios", "aceita", false, true),
      pick("ios", "exige"),
      pick("none", "aceita"),
    ]).toEqual([
      "android-emulador:enxuto",
      "android-emulador:estoque",
      "android-docker:enxuto",
      "ios-simulador:estoque",
      "ios-simulador:enxuto",
      "ios-simulador:enxuto",
      undefined,
    ])
  })
})

describe("probes", () => {
  test("the machine's own outputs, as macOS and Linux print them", () => {
    expect(darwinPressure("1\n")).toBe(1)
    expect(darwinPressure("")).toBeUndefined()
    expect(darwinSwap("total = 7168.00M  used = 5714.19M  free = 1453.81M  (encrypted)")).toBeCloseTo(5_714.19)
    expect(darwinSwap("total = 0.00M  used = 1.50G  free = 0.00M")).toBe(1_536)
    expect(hidIdle('    | |     "HIDIdleTime" = 2337319012708')).toBeCloseTo(2_337_319.012708)
    const psi = (some: number, full: number) =>
      `some avg10=${some} avg60=0.00 avg300=0.00 total=1\nfull avg10=${full} avg60=0.00 avg300=0.00 total=1\n`
    expect([
      linuxPressure(psi(0, 0)),
      linuxPressure(psi(25, 3)),
      linuxPressure(psi(40, 15)),
      linuxPressure(undefined),
    ]).toEqual([1, 2, 4, undefined])
    expect(linuxSwap("MemTotal: 1 kB\nSwapTotal:     2097148 kB\nSwapFree:      1250000 kB\n")).toBeCloseTo(827.29, 1)
  })
})

describe("admission", () => {
  const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }
  const spec: BancadaProtocol.PartSpec = {
    part: "android",
    label: "Android",
    platform: "android",
    needs: ["android"],
    device: {},
    devices: { min: 1, max: 3 },
    exclusive: [],
    unsafe: false,
    build: true,
    args: [],
  }
  const mac = (more: Partial<Machine> = {}): Machine => ({
    machineID: "m-Mac",
    instanceID: "i-Mac",
    name: "Mac",
    platform: "darwin",
    hub: false,
    speed: "normal",
    capabilities: { android: {}, "segredos:opencode-skills": {} },
    capacity: { memMb: 40_960, cpuMilli: 12_000, builds: 1, android: 3, ios: 0 },
    secrets: ["opencode-skills"],
    ...more,
  })
  /** A machine with an execution whose state the test sets. */
  const machine = (more: Partial<Machine> = {}) => {
    const db = new Database(":memory:")
    const execution: { status: Status } = { status: { state: "compilando" } }
    const launcher: Launcher = {
      start: async () => {},
      status: async () => execution.status,
      cancel: async () => {},
      stop: async () => {},
      reap: async () => {},
      held: () => false,
      cleanup: async () => {},
    }
    let n = 0
    const core = createCore({
      db,
      now: () => 1_000,
      random: () => `id-${++n}`,
      machine: mac(more),
      launcher,
      log: () => {},
    })
    let seq = 0
    const offer = (
      part: Partial<BancadaProtocol.PartSpec> = {},
      devices = { min: 1, proposed: 3 },
      job = "j-7qk2m9xa",
    ) => {
      seq++
      core.incoming({
        protocol: BancadaProtocol.version,
        ack: null,
        out: {
          stream: "hub-stream",
          base: seq - 1,
          messages: [
            {
              seq,
              body: {
                type: "offer",
                job,
                part: part.part ?? "android",
                attempt: 1,
                spec: { ...spec, ...part },
                origin: { instanceID: "i", machineID: "m", name: "Linux", sessionID: "s", rootSessionID: "s" },
                code,
                devices,
              },
            },
          ],
        },
      })
      return core
        .outgoing()
        .out.messages.map((message) => message.body)
        .filter((body) => body.type === "offer.reply")
        .at(-1)
    }
    const leases = () =>
      db
        .query(
          "SELECT mem_mb AS memMb, cpu_milli AS cpuMilli, builds, android, state FROM lease ORDER BY created_at, id",
        )
        .all()
    const ports = () =>
      db.query("SELECT port_start AS start, port_end AS end FROM lease_device ORDER BY port_start").all()
    return { db, core, execution, offer, leases, ports }
  }

  test("the peak is reserved with as many devices as fit; the build's share goes back when the run starts", async () => {
    const it = machine()
    expect(it.offer()).toMatchObject({ accepted: true, devices: 3 })
    const emulator = deviceCosts["android-emulador"]
    expect(it.leases()).toEqual([
      {
        memMb: 8_192 + emulator.memMb * 3,
        cpuMilli: 6_000 + emulator.cpuMilli * 3,
        builds: 1,
        android: 3,
        state: "active",
      },
    ])
    expect(it.ports()).toEqual([
      { start: 48_000, end: 48_019 },
      { start: 48_020, end: 48_039 },
      { start: 48_040, end: 48_059 },
    ])
    // Building: no other build fits, the hub sees no build free.
    expect(it.core.outgoing().pulse.free).toMatchObject({ builds: 0, android: 0 })
    it.execution.status = { state: "rodando" }
    await it.core.tick()
    expect(it.leases()).toEqual([
      { memMb: emulator.memMb * 3, cpuMilli: emulator.cpuMilli * 3, builds: 0, android: 3, state: "active" },
    ])
    it.execution.status = { state: "done", ending: { stage: "run", exit: 0 } }
    await it.core.tick()
    expect(it.leases()).toMatchObject([{ state: "released" }])
    expect(it.ports()).toEqual([])
  })

  test("granted 3 and the plan has 2 scenarios: 1 starts while it builds, 1 more after the plan; the third goes back unstarted", async () => {
    const it = machine()
    expect(it.offer()).toMatchObject({ accepted: true, devices: 3 })
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-useful-"))
    const dir = path.join(root, "attempts", "j-7qk2m9xa", "g", "parts", "android")
    await fs.mkdir(path.join(dir, "out"), { recursive: true })
    await Bun.write(
      path.join(root, "attempts", "j-7qk2m9xa", "g", "attempt.json"),
      JSON.stringify({ parts: [{ part: "android", plan: ["scripts/plan"], run: ["scripts/run"] }] }),
    )
    const started: string[] = []
    const fake: Driver = {
      kind: "android-emulador",
      choose: async () => ({ key: "android:36", spec: {}, name: (n) => `bancada-a36-${n}` }),
      ready: async (device, slot) => {
        started.push(device.id)
        return { view: { id: device.id, portas: { inicio: slot.start, fim: slot.end } }, run: {} }
      },
      health: async () => "ok",
      giveBack: async () => {},
    }
    const pool = makeDevicePool({
      db: it.db,
      now: () => 1_000,
      drivers: () => ({ android: fake }),
      emulatorPorts: { start: 5700, end: 5799 },
      simslim: () => false,
      shrink: (key, devices) => it.core.shrink(key, devices),
      planPollMs: 10,
      log: () => {},
    })
    pool.prepare({ job: "j-7qk2m9xa", part: "android", attempt: 1, group: "g" }, dir)
    await Bun.sleep(100)
    expect(started).toEqual(["bancada-a36-1"])
    await Bun.write(
      path.join(dir, "out", "planned.json"),
      JSON.stringify({ versao: 1, cenarios: [{ id: "c1" }, { id: "c2" }] }),
    )
    await pool.settled()
    expect(started).toEqual(["bancada-a36-1", "bancada-a36-2"])
    const written = JSON.parse(await Bun.file(path.join(dir, "devices.json")).text())
    expect(written.aparelhos.map((item: { id: string }) => item.id)).toEqual(["bancada-a36-1", "bancada-a36-2"])
    const emulator = deviceCosts["android-emulador"]
    expect(it.leases()).toEqual([
      {
        memMb: 8_192 + emulator.memMb * 2,
        cpuMilli: 6_000 + emulator.cpuMilli * 2,
        builds: 1,
        android: 2,
        state: "active",
      },
    ])
    expect(it.ports()).toEqual([
      { start: 48_000, end: 48_019 },
      { start: 48_020, end: 48_039 },
    ])
    await fs.rm(root, { recursive: true, force: true })
  })

  test("emulators kept running count in the budget: they fit beside what is reserved, or some must stop", () => {
    const it = machine()
    expect(it.core.warmFits("android", 3)).toBe(true)
    expect(it.offer({}, { min: 1, proposed: 2 })).toMatchObject({ accepted: true, devices: 2 })
    // A build and two emulators reserved: one more emulator, not two.
    expect(it.core.warmFits("android", 1)).toBe(true)
    expect(it.core.warmFits("android", 2)).toBe(false)
  })

  test("what this machine measured counts instead of the default from 3 samples on", () => {
    const it = machine()
    ;[10_000, 12_000, 14_000].forEach((memMb, at) =>
      it.db.run(
        "INSERT INTO cost_sample (subject, mem_mb, cpu_milli, at) VALUES ('android-emulador:enxuto', ?, 1000, ?)",
        [memMb, at],
      ),
    )
    // 8 GB for the build and 14 GB per emulator: two fit in 40 GB, not three.
    expect(it.offer()).toMatchObject({ accepted: true, devices: 2 })
    expect(it.leases()).toMatchObject([{ memMb: 8_192 + 28_000 }])
  })

  test("with the owner at the Mac fewer devices fit; with the brake closed nothing is accepted until it reopens", () => {
    // 40 GB and 20 cores: three emulators beside a build; 60% of it while the owner is at the Mac, two.
    const capacity = { memMb: 40_960, cpuMilli: 20_000, builds: 1, android: 3, ios: 0 }
    expect(machine({ capacity }).offer()).toMatchObject({ accepted: true, devices: 3 })
    const present = machine({ capacity })
    present.core.observe({ at: 0, idleMs: 30_000 })
    expect(present.core.outgoing().pulse.presence).toBe(true)
    expect(present.offer()).toMatchObject({ accepted: true, devices: 2 })

    const braked = machine()
    expect(braked.core.observe({ at: 0, pressure: 4 })).toMatchObject({ changed: true, closed: true })
    expect(braked.core.outgoing().pulse.brake).toBe(true)
    expect(braked.offer()).toMatchObject({
      accepted: false,
      reason: { code: "freio", text: "freio fechado: pressão de memória acima do normal" },
    })
    ;[1, 2, 3, 4, 5, 6].forEach((n) => braked.core.observe({ at: n * 5_000, pressure: 1 }))
    expect(braked.core.outgoing().pulse.brake).toBe(false)
    expect(braked.offer({}, { min: 1, proposed: 1 }, "j-8qk2m9xa")).toMatchObject({ accepted: true })
  })

  test("a part with secrets only where its policy is listed; a capability that is gone refuses", () => {
    const it = machine()
    expect(
      it.offer(
        { part: "a", platform: "none", needs: [], devices: { min: 0, max: 0 }, secrets: "outra" },
        { min: 0, proposed: 0 },
      ),
    ).toMatchObject({
      accepted: false,
      reason: { code: "sem_maquina", text: "a policy outra não está na lista segredos desta máquina" },
    })
    expect(it.offer({ part: "b", needs: ["ios"] })).toMatchObject({
      accepted: false,
      reason: { code: "sem_maquina", text: "esta máquina não oferece mais ios" },
    })
    expect(
      it.offer(
        { part: "c", platform: "none", needs: [], devices: { min: 0, max: 0 }, secrets: "opencode-skills" },
        { min: 0, proposed: 0 },
      ),
    ).toMatchObject({ accepted: true, devices: 0 })
    // Without a list in the machine file no policy is resolved here.
    expect(
      machine({ secrets: [] }).offer(
        { part: "d", platform: "none", needs: [], devices: { min: 0, max: 0 }, secrets: "opencode-skills" },
        { min: 0, proposed: 0 },
      ),
    ).toMatchObject({ accepted: false })
  })
})
