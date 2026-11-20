import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { inspect } from "../src/bancada/commands"
import { createCore, type Machine } from "../src/bancada/daemon/core"
import { makePhones, type Run } from "../src/bancada/daemon/devices/physical"
import { makeDevicePool, type Driver } from "../src/bancada/daemon/devices/pool"
import type { Launcher } from "../src/bancada/daemon/executor"
import { migrate } from "../src/bancada/daemon/schema"
import type { Phone } from "../src/bancada/machine-config"
import type { BancadaProtocol } from "../src/bancada/protocol"

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
const catalog = [
  phone("poco", "IBHUYT85ZTYH5XDM", { tags: ["whatsapp-business"], realAccounts: true }),
  phone("redmi", "d8cf6fc2", { transport: "wifi", tags: ["whatsapp-business"] }),
  phone("iphone14", "00008110-00065DA13A78401E", { platform: "ios" }),
  phone("pessoal", "00008150-001559220263401C", { platform: "ios", policy: "negar" }),
]

/** A fake adb and devicectl: what each answers now, and every command asked (never a write but `adb connect`). */
function fakes() {
  const state = {
    devices: ["IBHUYT85ZTYH5XDM", "192.168.0.10:41001"],
    serialno: { "192.168.0.10:41001": "d8cf6fc2" } as Record<string, string>,
    mdns: "",
    connected: { "192.168.0.10:41555": "d8cf6fc2" } as Record<string, string>,
    ios: "Name   Hostname   Identifier   State   Model\niPhone 14   x.local   00008110-00065DA13A78401E   available (paired)   iPhone14,7\n",
  }
  const asked: string[] = []
  const run: Run = async (argv) => {
    const line = argv.join(" ")
    asked.push(line)
    if (line === "/adb devices")
      return {
        code: 0,
        stdout: `List of devices attached\n${state.devices.map((serial) => `${serial}\tdevice`).join("\n")}\n`,
      }
    const getprop = /^\/adb -s (\S+) shell getprop ro.serialno$/.exec(line)
    if (getprop) return { code: 0, stdout: `${state.serialno[getprop[1]!] ?? ""}\n` }
    if (line === "/adb mdns services") return { code: 0, stdout: state.mdns }
    const connect = /^\/adb connect (\S+)$/.exec(line)
    if (connect) {
      const id = state.connected[connect[1]!]
      if (id) {
        state.devices.push(connect[1]!)
        state.serialno[connect[1]!] = id
      }
      return { code: 0, stdout: "" }
    }
    if (line === "/usr/bin/xcrun devicectl list devices") return { code: 0, stdout: state.ios }
    return { code: 1, stdout: "" }
  }
  return { state, asked, phones: makePhones({ phones: () => catalog, adb: () => "/adb", ios: true, run }) }
}

describe("phones as connected now", () => {
  test("USB by its id, Wi-Fi behind its ip:porta, the iPhone by devicectl; one not to be reserved is never asked", async () => {
    const it = fakes()
    await it.phones.refresh()
    expect(["poco", "redmi", "iphone14", "pessoal"].map((alias) => it.phones.serial(alias))).toEqual([
      "IBHUYT85ZTYH5XDM",
      "192.168.0.10:41001",
      "00008110-00065DA13A78401E",
      undefined,
    ])
    // The address was asked once; a second reading asks it no more.
    await it.phones.refresh()
    expect(it.asked.filter((line) => line.includes("getprop"))).toHaveLength(1)
    expect(it.asked.some((line) => line.includes("00008150"))).toBe(false)
  })

  test("a Wi-Fi phone on a new port: found again only when asked to reconnect, through its mDNS announcement", async () => {
    const it = fakes()
    await it.phones.refresh()
    // It restarted: the old address is gone and adb no longer lists it.
    it.state.devices = ["IBHUYT85ZTYH5XDM"]
    it.state.mdns = "adb-d8cf6fc2-x1Yz\t_adb-tls-connect._tcp\t192.168.0.10:41555\n"
    await it.phones.refresh()
    expect(it.phones.connected("redmi")).toBe(false)
    expect(it.asked.some((line) => line.startsWith("/adb connect"))).toBe(false)
    await it.phones.refresh({ reconnect: ["redmi"] })
    expect(it.phones.serials("redmi")).toEqual(["192.168.0.10:41555"])
    expect(it.asked.filter((line) => line.startsWith("/adb connect"))).toEqual(["/adb connect 192.168.0.10:41555"])
  })

  test("USB unplugged, an iPhone unavailable: not connected", async () => {
    const it = fakes()
    it.state.devices = []
    it.state.ios =
      "Name   Hostname   Identifier   State   Model\niPhone 14   x.local   00008110-00065DA13A78401E   unavailable   iPhone14,7\n"
    await it.phones.refresh()
    expect(["poco", "redmi", "iphone14"].map((alias) => it.phones.connected(alias))).toEqual([false, false, false])
  })
})

const idle: Launcher = {
  start: async () => {},
  status: async () => ({ state: "rodando" }),
  cancel: async () => {},
  stop: async () => {},
  reap: async () => {},
  held: () => false,
  cleanup: async () => {},
}

/** The Mac as the hub, with the catalog above and its phones as the fake adb shows them. */
async function mac(more: Partial<Phone>[] = [], android = 0) {
  const it = fakes()
  await it.phones.refresh()
  const clock = { now: 1_000_000 }
  const phones = catalog.map((item, index) => ({ ...item, ...more[index] }))
  const machine: Machine = {
    machineID: "m-mac",
    instanceID: "i-mac",
    name: "Mac de Alexandre",
    platform: "darwin",
    hub: true,
    speed: "normal",
    capabilities: {
      android: {},
      "android-fisico": {
        aparelhos: phones
          .filter((item) => item.platform === "android")
          .map((item) => ({
            apelido: item.alias,
            etiquetas: item.tags,
            contasReais: item.realAccounts,
            conectado: true,
          })),
      },
    },
    // By default room for no emulator: a phone's test never waits for one.
    capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android, ios: 0 },
    phones,
    prefix: "bancada-",
  }
  let n = 0
  const db = new Database(":memory:")
  const core = createCore({
    db,
    now: () => clock.now,
    random: () => `id${++n}`,
    machine,
    launcher: idle,
    log: () => {},
    phones: it.phones,
  })
  return { ...it, core, db, clock }
}

const physical: BancadaProtocol.PartSpec = {
  part: "whatsapp",
  label: "WhatsApp",
  platform: "android",
  needs: ["android-fisico"],
  device: { tags: ["whatsapp-business"] },
  devices: { min: 1, max: 1 },
  exclusive: [],
  unsafe: true,
  build: true,
  args: [],
}
/** An emulator and a phone in one test (`celular`). */
const both: BancadaProtocol.PartSpec = {
  ...physical,
  part: "real",
  label: "Conta real",
  needs: ["android", "android-fisico"],
  device: {},
  phone: { tags: ["whatsapp-business"] },
}
const code = { project: "exemplo", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d", remotes: [], inRemote: false }

describe("a phone's test", () => {
  test("takes a phone with the tags before anything else, even with no room for an emulator; it never expires while it runs", async () => {
    const it = await mac()
    it.core.submit({ id: "j-11111111", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [physical] })
    await it.core.tick()
    const attempt = it.db
      .query<{ phone_hold: string; devices: number }, []>("SELECT phone_hold, devices FROM attempt")
      .get()
    expect(attempt).toMatchObject({ devices: 0 })
    const hold = it.core.holds.decided(attempt!.phone_hold)
    expect(hold).toMatchObject({ state: "concedida", attempt: "j-11111111/whatsapp/1", root_session_id: "ses_a" })
    expect(JSON.parse(hold!.target)).toEqual({ kind: "fisico", device: "poco" })
    // While the test drives it, no session's command may (the hook only sees the sessions' shells).
    const gate = (root: string) =>
      it.core.gate.decide(
        { sessionID: root, rootSessionID: root },
        inspect("adb -s IBHUYT85ZTYH5XDM shell getprop ro.product.model"),
      )
    expect(gate("ses_a")).toMatchObject({ allow: false })
    expect(gate("ses_b")).toMatchObject({ allow: false })
    // Hours later, with someone waiting for it: still the test's.
    it.core.hold({
      hold: "r-b",
      sessionID: "ses_b",
      rootSessionID: "ses_b",
      target: { kind: "fisico", device: "poco" },
    })
    it.clock.now += 3 * 60 * 60_000
    await it.core.tick()
    expect(it.core.holds.decided(attempt!.phone_hold)?.state).toBe("concedida")
    // The attempt gave it back: the one waiting gets it.
    it.core.holds.done("j-11111111/whatsapp/1")
    await it.core.tick()
    expect(it.core.holds.find("r-b")?.state).toBe("concedida")
  })

  test("a phone kept for someone (reservado) is never given to a test; without a free one the offer is refused", async () => {
    const it = await mac([
      { reserved: { until: 2_000_000, for: "Agendamento" } },
      { reserved: { until: 2_000_000, for: "Agendamento" } },
    ])
    it.core.submit({ id: "j-22222222", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [physical] })
    await it.core.tick()
    expect(it.db.query("SELECT * FROM attempt").all()).toEqual([])
    expect(it.db.query<{ state: string }, []>("SELECT state FROM hold").all()).toEqual([])
  })
})

describe("the hook and the phones", () => {
  test("a Wi-Fi phone is cited by its ip:porta too, here or behind the mac bridge; one not to be reserved never", async () => {
    const it = await mac()
    const gate = (command: string) =>
      it.core.gate.decide({ sessionID: "ses_a", rootSessionID: "ses_a" }, inspect(command))
    expect(gate("adb -s 192.168.0.10:41001 shell input keyevent 3")).toEqual({
      allow: false,
      message: 'Reserve antes com `bancada_hold({ aparelho: "redmi" })`.',
    })
    expect(gate("mac adb -s 192.168.0.10:41001 shell input keyevent 3")).toMatchObject({ allow: false })
    expect(gate("xcrun devicectl device info details --device 00008150-001559220263401C")).toEqual({
      allow: false,
      message: 'O celular pessoal não pode ser usado por agentes (politica = "negar" no arquivo da máquina).',
    })
    it.core.hold({
      hold: "r-a",
      sessionID: "ses_a",
      rootSessionID: "ses_a",
      target: { kind: "fisico", device: "redmi" },
    })
    expect(it.core.holds.find("r-a")).toMatchObject({
      state: "concedida",
      device: JSON.stringify({ id: "d8cf6fc2", serial: "192.168.0.10:41001" }),
    })
    expect(gate("adb -s 192.168.0.10:41001 shell input keyevent 3")).toEqual({ allow: true })
  })
})

describe("a phone in devices.json", () => {
  test("the one the test's hold took, as connected now; given back as it is, only its hold ending", async () => {
    const it = await mac()
    it.core.submit({ id: "j-33333333", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [physical] })
    await it.core.tick()
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-phone-"))
    const done: string[] = []
    const pool = makeDevicePool({
      db: it.db,
      now: () => it.clock.now,
      drivers: () => ({}),
      emulatorPorts: { start: 5700, end: 5799 },
      simslim: () => false,
      phone: {
        find: (alias) => catalog.find((item) => item.alias === alias),
        serial: it.phones.serial,
        connected: it.phones.connected,
        done: (attempt) => void done.push(attempt),
        machine: () => "Mac de Alexandre",
      },
      log: () => {},
    })
    const key = { job: "j-33333333", part: "whatsapp", attempt: 1, group: "g" }
    pool.prepare(key, dir)
    await pool.settled()
    const view = JSON.parse(await Bun.file(path.join(dir, "devices.json")).text())
    expect(view.aparelhos).toEqual([
      expect.objectContaining({
        id: "IBHUYT85ZTYH5XDM",
        tipo: "android-fisico",
        apelido: "poco",
        serial: "IBHUYT85ZTYH5XDM",
        adb: { host: "127.0.0.1", porta: 5037 },
        etiquetas: ["whatsapp-business"],
        contasReais: true,
        host: null,
      }),
    ])
    const before = it.asked.length
    pool.reap([])
    await pool.settled()
    expect(done).toEqual(["j-33333333/whatsapp/1"])
    // Nothing was run on the phone to give it back.
    expect(it.asked.slice(before)).toEqual([])
    await fs.rm(dir, { recursive: true, force: true })
  })
})

describe("an emulator and a phone in one test", () => {
  test("the phone first, the emulator from the budget; without room for the emulator the phone goes back", async () => {
    const cramped = await mac()
    cramped.core.submit({ id: "j-44444444", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [both] })
    await cramped.core.tick()
    expect(cramped.db.query("SELECT * FROM attempt").all()).toEqual([])
    expect(cramped.db.query("SELECT id FROM hold WHERE state = 'concedida'").all()).toEqual([])

    const it = await mac([], 1)
    it.core.submit({ id: "j-55555555", sessionID: "ses_a", rootSessionID: "ses_a", code, parts: [both] })
    await it.core.tick()
    const attempt = it.db
      .query<{ phone_hold: string; devices: number }, []>("SELECT phone_hold, devices FROM attempt")
      .get()
    expect(attempt?.devices).toBe(1)
    expect(JSON.parse(it.core.holds.decided(attempt!.phone_hold)!.target)).toEqual({ kind: "fisico", device: "poco" })
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-phone-"))
    const emulator: Driver = {
      kind: "android-emulador",
      choose: async () => ({ key: "a36", spec: {}, name: (n) => `bancada-a36-${n}` }),
      ready: async (device, slot) => ({
        view: {
          id: device.id,
          tipo: "android-emulador",
          serial: "emulator-5740",
          portas: { inicio: slot.start, fim: slot.end },
        },
        run: { serial: "emulator-5740" },
      }),
      health: async () => "ok",
      giveBack: async () => {},
    }
    const pool = makeDevicePool({
      db: it.db,
      now: () => it.clock.now,
      drivers: () => ({ android: emulator }),
      emulatorPorts: { start: 5740, end: 5799 },
      simslim: () => false,
      phone: {
        find: (alias) => catalog.find((item) => item.alias === alias),
        serial: it.phones.serial,
        connected: it.phones.connected,
        done: () => {},
        machine: () => "Mac de Alexandre",
      },
      log: () => {},
    })
    pool.prepare({ job: "j-55555555", part: "real", attempt: 1, group: "g" }, dir)
    await pool.settled()
    const view = JSON.parse(await Bun.file(path.join(dir, "devices.json")).text())
    expect(view.aparelhos.map((item: { id: string; tipo: string }) => [item.id, item.tipo])).toEqual([
      ["bancada-a36-1", "android-emulador"],
      ["IBHUYT85ZTYH5XDM", "android-fisico"],
    ])
    // Each its own block of the project's ports.
    expect(view.aparelhos[0].portas).not.toEqual(view.aparelhos[1].portas)
    await fs.rm(dir, { recursive: true, force: true })
  })
})
