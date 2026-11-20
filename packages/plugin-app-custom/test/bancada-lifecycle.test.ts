import { Database } from "bun:sqlite"
import { describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { androidLocal } from "../src/bancada/daemon/devices/android-local"
import { iosSimulators } from "../src/bancada/daemon/devices/ios"
import { makeDevicePool, type Driver } from "../src/bancada/daemon/devices/pool"
import { migrate } from "../src/bancada/daemon/schema"
import { makeAndroidLifecycle, type Shell } from "../src/resources/adapters/android-lifecycle"
import { makeIosLifecycle } from "../src/resources/adapters/ios-lifecycle"

/** A machine that answers commands by the first rule that matches, and keeps the transcript. */
function machine(
  rules: [RegExp, { code?: number; stdout?: string; stderr?: string }][],
  files: Record<string, string> = {},
) {
  const transcript: string[] = []
  const alive = new Set<number>()
  let clock = 0
  const shell: Shell = {
    run: async (argv, options) => {
      const line = argv.join(" ")
      transcript.push(`${options?.stdin ? `${JSON.stringify(options.stdin)} | ` : ""}${line}`)
      const found = rules.find(([pattern]) => pattern.test(line))?.[1] ?? { code: 1 }
      if (/emu kill$/.test(line)) alive.clear()
      return { code: found.code ?? 0, stdout: found.stdout ?? "", stderr: found.stderr ?? "" }
    },
    detach: async (argv, options) => {
      transcript.push(`detach ${argv.join(" ")} > ${path.basename(options.log)}`)
      alive.add(4242)
      return { pid: 4242, started: "Thu Nov 20 10:00:00 2026" }
    },
    alive: async (pid) => (alive.has(pid) ? "alive" : "dead"),
    signal: (pid, signal) => {
      transcript.push(`kill -${signal} ${pid}`)
      alive.delete(pid)
    },
    read: async (file) => files[file],
    write: async (file, text) => {
      files[file] = text
    },
    remove: async (file) => {
      transcript.push(`rm -rf ${file}`)
      delete files[file]
    },
    sleep: async (ms) => {
      clock += ms
    },
    now: () => clock,
  }
  return { shell, transcript, files }
}

const tools = {
  sdk: "/sdk",
  adb: "/sdk/platform-tools/adb",
  emulator: "/sdk/emulator/emulator",
  avdmanager: "/sdk/cmdline-tools/latest/bin/avdmanager",
  javaHome: "/jbr",
  avdHome: "/home/.android/avd",
}
const image = { api: 36, tag: "google_apis", abi: "arm64-v8a" }
const key = { job: "j-1", part: "android", attempt: 1, group: "g" }

describe("Android lifecycle", () => {
  test("first time: created by the SDK's avdmanager, light profile, booted, trimmed, snapshot saved, delivered", async () => {
    const it = machine(
      [
        [/avdmanager create avd/, {}],
        [/getprop sys.boot_completed/, { stdout: "1\n" }],
        [/pm path android/, { stdout: "package:/system/framework/framework-res.apk\n" }],
        [/pm path com\.google/, { stdout: "com.google.android.youtube\n" }],
        [/snapshot save/, { stdout: "OK\r\n" }],
        [/ip route get/, { stdout: "10.0.2.2 dev eth0 src 10.0.2.15\n" }],
        [/toybox nc/, { stdout: "OKAY00040029" }],
        [/emu avd name/, { stdout: "bancada-test-a36-ga-arm64-enxuto-1\r\nOK\r\n" }],
        [/./, {}],
      ],
      {
        "/home/.android/avd/bancada-test-a36-ga-arm64-enxuto-1.avd/config.ini":
          "hw.ramSize=1536\nhw.gpu.mode=auto\nabi.type=arm64-v8a\n",
      },
    )
    const driver = androidLocal({
      lifecycle: makeAndroidLifecycle(it.shell, tools),
      prefix: "bancada-test-",
      images: () => [image, { api: "37.0", tag: "google_apis_playstore", abi: "arm64-v8a" }],
      port: async () => 5700,
      logs: "/state/devices",
      machine: () => "Mac de Alexandre",
      log: () => {},
    })
    const choice = await driver.choose({ api: ">=36" }, "enxuto")
    if (typeof choice === "string") throw new Error(choice)
    expect(choice.name(1)).toBe("bancada-test-a36-ga-arm64-enxuto-1")
    const ready = await driver.ready(
      { id: choice.name(1), kind: "android-emulador", profile: "enxuto", spec: choice.spec },
      { start: 48_000, end: 48_019 },
      key,
    )
    expect(ready.view).toEqual({
      id: "bancada-test-a36-ga-arm64-enxuto-1",
      tipo: "android-emulador",
      plataforma: "android",
      serial: "emulator-5700",
      udid: null,
      adb: { host: "127.0.0.1", porta: 5037 },
      abi: "arm64-v8a",
      api: 36,
      perfil: "enxuto",
      portas: { inicio: 48_000, fim: 48_019 },
      host: "10.0.2.2",
      maquina: "Mac de Alexandre",
    })
    expect(it.files["/home/.android/avd/bancada-test-a36-ga-arm64-enxuto-1.avd/config.ini"]).toBe(
      "abi.type=arm64-v8a\nhw.gpu.enabled=yes\nhw.gpu.mode=host\nhw.cpu.ncore=2\nhw.ramSize=2048\nhw.lcd.width=720\nhw.lcd.height=1600\nhw.lcd.density=280\nhw.lcd.vsync=30\n",
    )
    const commands = it.transcript.filter((line) => !/getprop|pm path android/.test(line))
    expect(commands[0]).toBe(
      '"no\\n" | /sdk/cmdline-tools/latest/bin/avdmanager create avd -n bancada-test-a36-ga-arm64-enxuto-1 -k system-images;android-36;google_apis;arm64-v8a -d pixel_6',
    )
    expect(commands[1]).toBe(
      "detach /sdk/emulator/emulator -avd bancada-test-a36-ga-arm64-enxuto-1 -ports 5700,5701 -no-window -no-audio -no-boot-anim -no-metrics -camera-back none -camera-front none -gpu host -cores 2 -memory 2048 -snapshot bancada-limpo -no-snapshot-save > bancada-test-a36-ga-arm64-enxuto-1.log",
    )
    expect(commands[2]).toStartWith(
      "/sdk/platform-tools/adb -s emulator-5700 shell pm path com.google.android.googlequicksearchbox",
    )
    expect(commands.slice(3)).toEqual([
      "/sdk/platform-tools/adb -s emulator-5700 emu avd snapshot save bancada-limpo",
      "/sdk/platform-tools/adb -s emulator-5700 shell svc wifi disable",
      "/sdk/platform-tools/adb -s emulator-5700 forward --remove-all",
      "/sdk/platform-tools/adb -s emulator-5700 reverse --remove-all",
      "/sdk/platform-tools/adb -s emulator-5700 shell pkill -x nc; true",
      "/sdk/platform-tools/adb -s emulator-5700 shell ip route get 10.0.2.2",
      "/sdk/platform-tools/adb -s emulator-5700 shell printf 000chost:version | toybox nc -q 2 -w 3 10.0.2.2 5037",
    ])
    // Given back: the serial proves it runs that AVD before the console's kill.
    it.transcript.length = 0
    await driver.giveBack(
      { id: choice.name(1), kind: "android-emulador", profile: "enxuto", spec: choice.spec },
      ready.run,
    )
    expect(it.transcript).toEqual([
      "/sdk/platform-tools/adb -s emulator-5700 emu avd name",
      "/sdk/platform-tools/adb -s emulator-5700 emu kill",
    ])
  })

  test("a later boot comes from the snapshot: nothing trimmed nor saved; a serial running another AVD is never stopped", async () => {
    const it = machine(
      [
        [/getprop sys.boot_completed/, { stdout: "1\n" }],
        [/pm path android/, { stdout: "package:x\n" }],
        [/ip route get/, { stdout: "10.0.2.2 dev eth0\n" }],
        [/toybox nc/, { stdout: "OKAY00040029" }],
        [/emu avd name/, { stdout: "abacato-e2e-1\r\nOK\r\n" }],
        [/./, {}],
      ],
      {
        "/home/.android/avd/bancada-test-a36-ga-arm64-estoque-2.ini": "path=…",
        "/state/devices/bancada-test-a36-ga-arm64-estoque-2.log":
          "INFO | Successfully loaded snapshot 'bancada-limpo'\n",
      },
    )
    const lifecycle = makeAndroidLifecycle(it.shell, tools)
    const driver = androidLocal({
      lifecycle,
      prefix: "bancada-test-",
      images: () => [image],
      port: async () => 5702,
      logs: "/state/devices",
      machine: () => "Mac",
      log: () => {},
    })
    const device = {
      id: "bancada-test-a36-ga-arm64-estoque-2",
      kind: "android-emulador" as const,
      profile: "estoque" as const,
      spec: image,
    }
    const ready = await driver.ready(device, { start: 48_020, end: 48_039 }, key)
    expect(it.transcript.some((line) => /avdmanager|snapshot save|pm disable-user/.test(line))).toBe(false)
    await expect(driver.giveBack(device, ready.run)).rejects.toThrow(
      "emulator-5702 roda abacato-e2e-1, não bancada-test-a36-ga-arm64-estoque-2: não desligo",
    )
    expect(it.transcript.some((line) => line.endsWith("emu kill"))).toBe(false)
    expect(await lifecycle.health("emulator-5702", 4242, "Thu Nov 20 10:00:00 2026")).toBe("ok")
    expect(await lifecycle.health("emulator-5702", 999, undefined)).toBe("morto")
  })
})

describe("iOS lifecycle", () => {
  const runtimes = JSON.stringify({
    runtimes: [
      {
        identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        version: "26.5",
        isAvailable: true,
        platform: "iOS",
      },
      {
        identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        version: "27.0",
        isAvailable: true,
        platform: "iOS",
      },
    ],
  })
  const types = JSON.stringify({
    devicetypes: [{ identifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", name: "iPhone 17 Pro" }],
  })
  const listed = (state: string, name = "bancada-test-iphone-17-pro-1") =>
    JSON.stringify({ devices: { "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{ udid: "U-1", name, state }] } })

  test("created, booted trimmed by simslim, checked; given back shut down and erased, never another's", async () => {
    const it = machine([
      [/list runtimes/, { stdout: runtimes }],
      [/list devicetypes/, { stdout: types }],
      [/list devices/, { stdout: JSON.stringify({ devices: {} }) }],
      [/simctl create/, { stdout: "U-1\n" }],
      [/./, {}],
    ])
    const driver = iosSimulators({
      lifecycle: makeIosLifecycle(it.shell, { simslim: "/opt/homebrew/bin/simslim" }),
      prefix: "bancada-test-",
      profile: "/state/simslim-profile.json",
      machine: () => "Mac",
      log: () => {},
    })
    const choice = await driver.choose({ ios: ">=26.0", model: "iPhone 17 Pro" }, "enxuto")
    if (typeof choice === "string") throw new Error(choice)
    const device = { id: choice.name(1), kind: "ios-simulador" as const, profile: "enxuto" as const, spec: choice.spec }
    const ready = await driver.ready(device, { start: 48_040, end: 48_059 }, key)
    expect(ready.view).toMatchObject({
      id: "bancada-test-iphone-17-pro-1",
      udid: "U-1",
      host: "127.0.0.1",
      tipo: "ios-simulador",
    })
    expect(it.transcript.filter((line) => !/ list /.test(line))).toEqual([
      "/usr/bin/xcrun simctl create bancada-test-iphone-17-pro-1 com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0",
      "/opt/homebrew/bin/simslim on U-1 --profile /state/simslim-profile.json",
      "/usr/bin/xcrun simctl bootstatus U-1 -b",
    ])
    const back = machine([
      [/list devices/, { stdout: listed("Booted") }],
      [/./, {}],
    ])
    await iosSimulators({
      lifecycle: makeIosLifecycle(back.shell, {}),
      prefix: "bancada-test-",
      profile: "",
      machine: () => "Mac",
      log: () => {},
    }).giveBack(device, ready.run)
    expect(back.transcript.filter((line) => !/ list /.test(line))).toEqual([
      "/usr/bin/xcrun simctl shutdown U-1",
      "/usr/bin/xcrun simctl erase U-1",
    ])
    const other = machine([
      [/list devices/, { stdout: listed("Booted", "AbacatoV3 E2E 1") }],
      [/./, {}],
    ])
    await expect(makeIosLifecycle(other.shell, {}).giveBack("U-1", "bancada-test-iphone-17-pro-1")).rejects.toThrow(
      "não desligo",
    )
    expect(other.transcript.some((line) => /shutdown|erase/.test(line))).toBe(false)
  })
})

describe("device pool", () => {
  test("ready devices go to devices.json; a failure to devices.error; a device mute 60 s falls; two falls put it aside", async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-pool-"))
    const db = new Database(":memory:")
    migrate(db)
    const clock = { now: 1_000_000 }
    const health = { value: "ok" as "ok" | "mudo" | "morto", fail: false }
    const given: string[] = []
    const fake: Driver = {
      kind: "android-emulador",
      choose: async () => ({ key: "android:36", spec: { api: 36 }, name: (n) => `bancada-test-a36-${n}` }),
      ready: async (device, slot) => {
        if (health.fail) throw new Error(`${device.id} não terminou de ligar`)
        return { view: { id: device.id, portas: { inicio: slot.start, fim: slot.end } }, run: { serial: device.id } }
      },
      health: async () => health.value,
      giveBack: async (device) => void given.push(device.id),
    }
    const pool = makeDevicePool({
      db,
      now: () => clock.now,
      drivers: () => ({ android: fake }),
      emulatorPorts: { start: 5700, end: 5799 },
      simslim: () => false,
      log: () => {},
    })
    const spec = {
      part: "android",
      label: "Android",
      platform: "android",
      needs: ["android"],
      device: {},
      devices: { min: 2, max: 2 },
      exclusive: [],
      unsafe: false,
      build: true,
      args: [],
    }
    const attempt = (n: number) => {
      db.run(
        "INSERT INTO attempt (job_id, part, n, origin, code, spec, devices, state, lease_id, accepted_at) VALUES ('j-1', 'android', ?, '{}', '{}', ?, 2, 'rodando', ?, 0)",
        [n, JSON.stringify(spec), `l${n}`],
      )
      db.run("INSERT INTO lease_device (lease_id, device_id, port_start, port_end) VALUES (?, NULL, 48000, 48019)", [
        `l${n}`,
      ])
      db.run("INSERT INTO lease_device (lease_id, device_id, port_start, port_end) VALUES (?, NULL, 48020, 48039)", [
        `l${n}`,
      ])
      return { job: "j-1", part: "android", attempt: n, group: "g" }
    }
    const settle = () => pool.settled()
    const first = attempt(1)
    const part1 = path.join(dir, "1")
    await fs.mkdir(part1)
    pool.prepare(first, part1)
    await settle()
    const written = await Bun.file(path.join(part1, "devices.json")).text()
    expect(written.split("\n")).toEqual([
      '{ "versao": 1, "aparelhos": [',
      '  {"id":"bancada-test-a36-1","portas":{"inicio":48000,"fim":48019}},',
      '  {"id":"bancada-test-a36-2","portas":{"inicio":48020,"fim":48039}}',
      "] }",
      "",
    ])
    // Mute for less than 60 s: nothing; for 60 s: it fell, and its part's file names it.
    health.value = "mudo"
    await pool.watch()
    clock.now += 30_000
    await pool.watch()
    expect(await Bun.file(path.join(part1, "caiu")).exists()).toBe(false)
    clock.now += 30_000
    await pool.watch()
    expect(await Bun.file(path.join(part1, "caiu")).text()).toBe("bancada-test-a36-1\nbancada-test-a36-2\n")
    // The attempt ended: its devices go back.
    pool.reap([])
    await settle()
    expect(given).toEqual(["bancada-test-a36-1", "bancada-test-a36-2"])
    // A second attempt takes the same devices; they fall again: 30 min aside, a third attempt gets new ones.
    const second = attempt(2)
    const part2 = path.join(dir, "2")
    await fs.mkdir(part2)
    pool.prepare(second, part2)
    await settle()
    expect(await Bun.file(path.join(part2, "devices.json")).text()).toContain("bancada-test-a36-1")
    clock.now += 60_000
    await pool.watch()
    clock.now += 60_000
    await pool.watch()
    pool.reap([])
    await settle()
    health.fail = true
    const third = attempt(3)
    const part3 = path.join(dir, "3")
    await fs.mkdir(part3)
    pool.prepare(third, part3)
    await settle()
    expect(await Bun.file(path.join(part3, "devices.error")).text()).toBe("bancada-test-a36-3 não terminou de ligar\n")
    expect(
      db.query<{ id: string }, []>("SELECT id FROM device WHERE quarantined_until IS NOT NULL ORDER BY id").all(),
    ).toEqual([{ id: "bancada-test-a36-1" }, { id: "bancada-test-a36-2" }])
    await fs.rm(dir, { recursive: true, force: true })
  })
})
