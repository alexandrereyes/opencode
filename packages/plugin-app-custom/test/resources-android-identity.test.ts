import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import {
  AnotherEmulator,
  createAdapter,
  identity,
  repair,
  resolve,
  UnconfirmedEmulator,
  type AndroidSystem,
  type RunningEmulator,
} from "../src/resources/adapters/android-emulator"
import type { Connection } from "../src/resources/adapters/android-grpc"
import type { Adapter, Entry } from "../src/resources/adapters/types"
import { bareSerials, known, references } from "../src/resources/discovery"
import { createHub } from "../src/resources/hub/hub"
import type { ResourceProtocol } from "../src/resources/protocol"
import type { Resources } from "../src/resources/rpc"

/**
 * Android identity across console-port reuse: the AVD is the resource, `emulator-<port>` only where it runs now.
 * Hubs here run the production adapter (`createAdapter`) over a fake `AndroidSystem` that records every adb command and
 * gRPC connection, or the production `resolve` over fake running emulators. No adb, emulator or device is touched.
 */
const owner = { sessionID: "ses_child", rootSessionID: "ses_root", agent: "opushigh" }
const other = { sessionID: "ses_other", rootSessionID: "ses_other", agent: "build" }
const running = (avd: string, port: number, device = "Pixel 7"): RunningEmulator => ({
  pid: 0,
  serial: `emulator-${port}`,
  consolePort: port,
  grpcPort: port + 3000,
  avd,
  device,
})

const closers: (() => unknown)[] = []
const directories: string[] = []
afterEach(async () => {
  closers.splice(0).forEach((close) => close())
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

async function tempFile() {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resources-android-identity-"))
  directories.push(directory)
  return path.join(directory, "resources.json")
}

/**
 * The outside world of the Android adapter. `files` are the alive emulators' ini files (what `discovered` reads),
 * `console` what `adb -s <serial> emu avd name` answers (missing: the query fails), `emulators` what the probe sees.
 * `emu grpc` writes the emulator's ini with a gRPC port, as the real emulator does.
 */
function fakeSystem() {
  const world = {
    files: [] as RunningEmulator[],
    console: new Map<string, string>(),
    emulators: [] as RunningEmulator[],
    existing: new Set<string>(),
  }
  const commands: string[][] = []
  const connected: { port: number }[] = []
  const calls: string[] = []
  const connections: { closed: boolean }[] = []
  const io: AndroidSystem = {
    run: async (command) => {
      commands.push(command.slice(1))
      return new Uint8Array(0)
    },
    text: async (command) => {
      const args = command.slice(1)
      commands.push(args)
      const serial = args[1] ?? ""
      if (args.slice(2).join(" ") === "emu avd name") {
        const avd = world.console.get(serial)
        if (!avd) throw new Error("console unreachable")
        return `${avd}\nOK\n`
      }
      if (args[2] === "emu" && args[3] === "grpc") {
        const avd = world.console.get(serial)
        const port = Number(serial.slice("emulator-".length))
        if (avd) world.files.push({ ...running(avd, port), grpcPort: Number(args[4]) })
        return "OK\n"
      }
      if (args.at(-1) === "wm size") return "Physical size: 720x1600\n"
      if (args.at(-1)?.includes("dumpsys display")) return "mCurrentOrientation=0\n"
      return ""
    },
    connect: (endpoint): Connection => {
      connected.push({ port: endpoint.port })
      const state = { closed: false }
      connections.push(state)
      return {
        unary: async (method) => {
          calls.push(method)
          return new Uint8Array(0)
        },
        stream: async () => {},
        get closed() {
          return state.closed
        },
        close: () => void (state.closed = true),
      }
    },
    discovered: async () => world.files,
    emulators: async () => world.emulators,
    avdExists: async (avd) => world.existing.has(avd),
  }
  /** Commands that would reach a device beyond the read-only identity query. */
  const touching = () => commands.filter((args) => args.slice(2).join(" ") !== "emu avd name")
  return { io, world, commands, connected, calls, connections, touching }
}

const entry = (
  id: string,
  meta: Extract<Resources.Meta, { kind: "android-emulator" }>,
  status: Entry["status"] = "running",
): Entry => ({
  id,
  kind: "android-emulator",
  meta,
  status,
  discoveredAt: 1,
  lastUsedAt: 1,
  updatedAt: 1,
})

/** A hub with the production Android adapter over `system`, served on loopback for admin and ticket routes. */
function serveHub(system: ReturnType<typeof fakeSystem>, options: { file?: string } = {}) {
  const android = createAdapter(system.io)
  const unused: Adapter = {
    kind: "ios-simulator",
    probe: async () => new Map(),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array(0) }),
  }
  const hub = createHub({
    adapters: { "ios-simulator": unused, "android-emulator": android, chrome: { ...unused, kind: "chrome" } },
    secret: "s",
    ...(options.file ? { file: options.file } : {}),
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  closers.push(() => server.stop(true), hub.close)
  const admin = (route: string, init: RequestInit = {}) =>
    fetch(`http://127.0.0.1:${server.port}${route}`, {
      ...init,
      headers: { authorization: "Bearer s", "content-type": "application/json" },
    }).then((response) => response.json())
  const register = (body: unknown) => admin("/admin/resources", { method: "PUT", body: JSON.stringify(body) })
  const list = async (): Promise<Resources.Resource[]> => (await admin("/admin/resources")).resources
  const input = (id: string, events: ResourceProtocol.Input[]) =>
    fetch(
      `http://127.0.0.1:${server.port}/resources/${encodeURIComponent(id)}/input?ticket=${hub.ticket(id, "control")?.ticket}`,
      { method: "POST", body: JSON.stringify({ events }) },
    )
  return { hub, android, admin, register, list, input }
}

/** A hub whose Android probe is the production `resolve` over `world` (no adapter IO involved). */
function resolvingHub(options: { file?: string; clock?: { value: number } } = {}) {
  const world = { running: [] as RunningEmulator[], existing: new Set<string>() }
  const fake: Adapter = {
    kind: "android-emulator",
    probe: async (entries) => resolve(entries, world.running, world.existing),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]) }),
  }
  const clock = options.clock ?? { value: 1_000_000 }
  const hub = createHub({
    adapters: { "ios-simulator": fake, "android-emulator": fake, chrome: fake },
    secret: "s",
    now: () => clock.value,
    ...(options.file ? { file: options.file } : {}),
  })
  closers.push(hub.close)
  const list = () => [...hub.entries.values()].map((item) => hub.view(item))
  return { hub, world, list }
}

describe("Android adapter: nothing reaches the AVD that took a resource's port", () => {
  const stale = entry("android-emulator:AVD_A", {
    kind: "android-emulator",
    avd: "AVD_A",
    serial: "emulator-5554",
    consolePort: 5554,
  })

  test("the occupant is checked before anything is sent: no gRPC switch-on, shell or connection to B", async () => {
    const system = fakeSystem()
    const android = createAdapter(system.io)
    // B holds the port without gRPC (no ini file), so the console says who it is.
    system.world.console.set("emulator-5554", "AVD_B")
    await expect(android.input!(stale, { type: "key", key: "Enter" })).rejects.toBeInstanceOf(AnotherEmulator)
    await expect(android.snapshot(stale)).rejects.toBeInstanceOf(AnotherEmulator)
    expect(system.touching()).toEqual([])
    expect(system.commands).toEqual([
      ["-s", "emulator-5554", "emu", "avd", "name"],
      ["-s", "emulator-5554", "emu", "avd", "name"],
    ])
    expect(system.connected).toEqual([])
  })

  test("an occupant with an ini file is told without running anything", async () => {
    const system = fakeSystem()
    const android = createAdapter(system.io)
    system.world.files = [running("AVD_B", 5554)]
    await expect(android.input!(stale, { type: "key", key: "Enter" })).rejects.toBeInstanceOf(AnotherEmulator)
    expect(system.commands).toEqual([])
    expect(system.connected).toEqual([])
  })

  test("a cached connection that still looks open never proves who holds the port", async () => {
    const system = fakeSystem()
    const android = createAdapter(system.io)
    system.world.files = [running("AVD_A", 5554)]
    await android.input!(stale, { type: "key", key: "Enter" })
    expect(system.connected).toHaveLength(1)
    expect(system.touching()).toEqual([
      ["-s", "emulator-5554", "shell", "wm size"],
      ["-s", "emulator-5554", "shell", "input keyevent KEYCODE_ENTER"],
    ])
    // A stopped and B took the port; the fake connection to A has not noticed (closed === false).
    system.world.files = [running("AVD_B", 5554)]
    system.commands.length = 0
    expect(system.connections[0]?.closed).toBe(false)
    await expect(android.input!(stale, { type: "key", key: "Enter" })).rejects.toBeInstanceOf(AnotherEmulator)
    await expect(android.snapshot(stale)).rejects.toBeInstanceOf(AnotherEmulator)
    expect(system.commands).toEqual([])
    expect(system.connected).toHaveLength(1)
    expect(system.calls).toEqual([])
  })

  test("an occupant that cannot be told fails closed for an AVD's resource", async () => {
    const system = fakeSystem()
    const android = createAdapter(system.io)
    await expect(android.input!(stale, { type: "key", key: "Enter" })).rejects.toBeInstanceOf(UnconfirmedEmulator)
    await expect(android.snapshot(stale)).rejects.toBeInstanceOf(UnconfirmedEmulator)
    expect(system.touching()).toEqual([])
    expect(system.connected).toEqual([])
  })

  test("gRPC is switched on only after the AVD is confirmed, and then input flows", async () => {
    const system = fakeSystem()
    const android = createAdapter(system.io)
    system.world.console.set("emulator-5554", "AVD_A")
    await android.input!(stale, { type: "touch", phase: "began", x: 0.5, y: 0.5 })
    expect(system.commands.slice(0, 2)).toEqual([
      ["-s", "emulator-5554", "emu", "avd", "name"],
      ["-s", "emulator-5554", "emu", "grpc", "8554"],
    ])
    expect(system.connected).toEqual([{ port: 8554 }])
    expect(system.calls).toEqual(["sendTouch"])
  })

  test("a resource known only by serial acts on the emulator that answers there (first discovery)", async () => {
    const system = fakeSystem()
    const android = createAdapter(system.io)
    system.world.files = [running("AVD_X", 5556)]
    await android.input!(
      entry("android-emulator:emulator-5556", { kind: "android-emulator", serial: "emulator-5556" }),
      {
        type: "key",
        key: "Enter",
      },
    )
    expect(system.connected).toHaveLength(1)
    // Nothing answers: refused.
    await expect(
      android.input!(entry("android-emulator:emulator-5558", { kind: "android-emulator", serial: "emulator-5558" }), {
        type: "key",
        key: "Enter",
      }),
    ).rejects.toBeInstanceOf(UnconfirmedEmulator)
  })
})

describe("Android identity in the hub", () => {
  test("A: an AVD that stops never becomes the next AVD on its port", async () => {
    const { hub, world, list } = resolvingHub()
    world.existing = new Set(["AVD_A", "AVD_B"])
    world.running = [running("AVD_A", 5554, "Pixel 9")]
    const a = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554", avd: "AVD_A" },
      owner,
      used: true,
      activity: { call: "call_a", command: "adb -s emulator-5554 shell input tap 1 1", running: false },
    })
    await hub.probe()
    expect(hub.entries.get(a.id)?.meta).toMatchObject({ avd: "AVD_A", serial: "emulator-5554", device: "Pixel 9" })
    world.running = [running("AVD_B", 5554)]
    await hub.probe()
    expect(hub.entries.get(a.id)).toMatchObject({
      status: "stopped",
      meta: { kind: "android-emulator", avd: "AVD_A", device: "Pixel 9" },
    })
    expect(hub.entries.get(a.id)?.meta).not.toHaveProperty("serial")
    const b = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554", avd: "AVD_B" },
      owner,
      used: true,
    })
    await hub.probe()
    expect(b.id).toBe("android-emulator:AVD_B")
    expect(list().map((item) => [item.id, item.state])).toEqual([
      [a.id, "stopped"],
      [b.id, "agent"],
    ])
    expect(hub.view(hub.entries.get(a.id)!).activity).toHaveLength(1)
  })

  test("A (registration): a bare serial right after the port changed hands goes to the new AVD, not the stale entry", async () => {
    const system = fakeSystem()
    const { hub, register, list } = serveHub(system)
    system.world.existing = new Set(["AVD_A", "AVD_B"])
    system.world.files = [running("AVD_A", 5554)]
    system.world.emulators = [running("AVD_A", 5554)]
    const a = await register({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554" },
      owner,
      used: true,
      activity: { call: "call_a", command: "adb -s emulator-5554 install a.apk", running: false },
    })
    // The emulator says which AVD the serial is, so the entry is that AVD from the start.
    expect(a.id).toBe("android-emulator:AVD_A")
    await hub.probe()
    expect(hub.entries.get(a.id)).toMatchObject({ status: "running", meta: { avd: "AVD_A" } })
    // A stops, B takes 5554; no probe yet, so A's entry still says running on 5554.
    system.world.files = [running("AVD_B", 5554)]
    const b = await register({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554" },
      owner: other,
      used: true,
      activity: { call: "call_b", command: "adb -s emulator-5554 shell input tap 1 1", running: false },
    })
    expect(b.id).toBe("android-emulator:AVD_B")
    expect(hub.entries.get(a.id)).toMatchObject({ owner, meta: { avd: "AVD_A" } })
    expect(hub.entries.get(a.id)?.activity?.map((item) => item.call)).toEqual(["call_a"])
    // The console cannot tell: the serial gets an entry of its own, A stays untouched.
    system.world.files = []
    const unknown = await register({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554" },
      owner: other,
      activity: { call: "call_c", command: "adb -s emulator-5554 logcat", running: false },
    })
    expect([a.id, b.id]).not.toContain(unknown.id)
    expect(hub.entries.get(a.id)?.activity?.map((item) => item.call)).toEqual(["call_a"])
    expect((await list()).map((item) => item.id).toSorted()).toEqual([a.id, b.id, unknown.id].toSorted())
  })

  test("B: a resource first known by serial learns its AVD without a duplicate, keeping its serial ID", async () => {
    const { hub, world, list } = resolvingHub()
    world.existing = new Set(["AVD_A"])
    world.running = [running("AVD_A", 5556)]
    const first = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5556" },
      owner,
    })
    expect(first.id).toBe("android-emulator:emulator-5556")
    await hub.probe()
    expect(hub.entries.get(first.id)?.meta).toMatchObject({ avd: "AVD_A", serial: "emulator-5556" })
    hub.upsert({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "AVD_A" }, owner, used: true })
    hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5556", avd: "AVD_A" },
      owner,
      used: true,
    })
    await hub.probe()
    expect(list().map((item) => item.id)).toEqual([first.id])
    expect(repair(hub.entries.get(first.id)!, 0)).toBeUndefined()
    world.running = [running("AVD_C", 5556)]
    world.existing.add("AVD_C")
    await hub.probe()
    expect(hub.entries.get(first.id)).toMatchObject({ status: "stopped", meta: { avd: "AVD_A" } })
    const c = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5556" },
      owner,
    })
    // Its serial ID is taken by AVD_A's entry, so the newcomer gets a fresh one instead of overwriting it.
    expect(c.id).toBe("android-emulator:emulator-5556~2")
    await hub.probe()
    expect(hub.entries.get(c.id)?.meta).toMatchObject({ avd: "AVD_C", serial: "emulator-5556" })
    expect(hub.entries.get(first.id)?.meta).toMatchObject({ avd: "AVD_A" })
  })

  test("C: the production hub repairs a corrupted registry on load and serves the repaired state", async () => {
    const file = await tempFile()
    const shared = { serial: "emulator-5554", consolePort: 5554, grpcPort: 8554, device: "Pixel 7" }
    const stored: Entry[] = [
      {
        ...entry("android-emulator:Abacato_feat_decisoes_auditoria", {
          kind: "android-emulator",
          avd: "Abacato_curious_falcon",
          ...shared,
        }),
        owner,
        discoveredAt: 1_793_539_960_859,
        activity: [{ call: "call_old", command: "adb -s emulator-5554 install app.apk", at: 1_793_539_965_000 }],
      },
      {
        ...entry("android-emulator:Abacato_curious_falcon", {
          kind: "android-emulator",
          avd: "Abacato_curious_falcon",
          ...shared,
        }),
        owner,
        discoveredAt: 1_793_799_368_816,
      },
    ]
    await Bun.write(file, JSON.stringify(stored))
    const system = fakeSystem()
    system.world.existing = new Set(["Abacato_feat_decisoes_auditoria", "Abacato_curious_falcon"])
    system.world.files = [running("Abacato_curious_falcon", 5554)]
    system.world.emulators = system.world.files
    const { hub, list } = serveHub(system, { file })
    await hub.start()
    const loaded = await list()
    // Right after load, before any probe: the old AVD is itself again, stopped, with its history and owner.
    expect(loaded.find((item) => item.id === stored[0]!.id)).toMatchObject({
      state: "stopped",
      meta: { kind: "android-emulator", avd: "Abacato_feat_decisoes_auditoria" },
      owner,
      discoveredAt: 1_793_539_960_859,
    })
    expect(loaded.find((item) => item.id === stored[0]!.id)?.activity).toHaveLength(1)
    await hub.probe()
    const probed = Object.fromEntries(
      (await list()).map((item) => [item.id, [item.state, item.meta.kind === "android-emulator" && item.meta.serial]]),
    )
    expect(probed).toEqual({
      [stored[1]!.id]: ["idle", "emulator-5554"],
      [stored[0]!.id]: ["stopped", undefined],
    })
    expect(system.touching()).toEqual([])
    // Persisted, and loading it again (a restart) changes nothing.
    await Bun.sleep(400)
    const persisted = await Bun.file(file).json()
    const again = serveHub(system, { file })
    await again.hub.start()
    await again.hub.probe()
    expect([...again.hub.entries.values()].map((item) => [item.id, item.status, item.meta])).toEqual(
      persisted.map((item: Entry) => [item.id, item.status, item.meta]),
    )
  })

  test("C: entries made from serials that ended up as the same AVD keep their history; one represents it", async () => {
    const { hub, world, list } = resolvingHub()
    world.existing = new Set(["AVD_X"])
    world.running = [running("AVD_X", 5560)]
    const legacy: Entry = {
      ...entry("android-emulator:emulator-5554", { kind: "android-emulator", avd: "AVD_X", serial: "emulator-5554" }),
      discoveredAt: 10,
      activity: [{ call: "call_legacy", command: "adb -s emulator-5554 logcat", at: 10 }],
    }
    const canonical: Entry = {
      ...entry("android-emulator:AVD_X", { kind: "android-emulator", avd: "AVD_X" }),
      discoveredAt: 20,
    }
    hub.entries.set(legacy.id, legacy)
    hub.entries.set(canonical.id, canonical)
    await hub.probe()
    expect(hub.entries.get(canonical.id)).toMatchObject({ status: "running", meta: { serial: "emulator-5560" } })
    expect(hub.entries.get(legacy.id)).toMatchObject({
      status: "stopped",
      meta: { kind: "android-emulator", avd: "AVD_X" },
    })
    expect(hub.entries.get(legacy.id)?.activity).toEqual(legacy.activity)
    expect(list().filter((item) => item.state !== "stopped")).toHaveLength(1)
    hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5560", avd: "AVD_X" },
      owner,
    })
    expect(hub.entries.get(canonical.id)?.owner).toEqual(owner)
    expect(hub.entries.get(legacy.id)?.owner).toBeUndefined()
  })

  test("D: two AVDs with the same label stay two resources, and a new serial keeps the AVD's own history", async () => {
    const { hub, world, list } = resolvingHub()
    world.existing = new Set(["Abacato_A", "Abacato_B"])
    world.running = [running("Abacato_A", 5554), running("Abacato_B", 5556)]
    const a = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", avd: "Abacato_A" },
      name: "Abacato",
      owner,
      activity: { call: "call_1", command: "emulator -avd Abacato_A", running: false },
    })
    const b = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", avd: "Abacato_B" },
      name: "Abacato",
    })
    await hub.probe()
    expect(list().map((item) => [item.label, item.id])).toEqual([
      ["Abacato", a.id],
      ["Abacato", b.id],
    ])
    world.running = [running("Abacato_A", 5558), running("Abacato_B", 5556)]
    await hub.probe()
    hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5558", avd: "Abacato_A" },
    })
    expect(hub.entries.get(a.id)).toMatchObject({ status: "running", meta: { serial: "emulator-5558" } })
    expect(hub.view(hub.entries.get(a.id)!).activity).toHaveLength(1)
    expect(hub.entries.get(b.id)?.meta).toMatchObject({ serial: "emulator-5556" })
  })

  test("E: control taken on a corrupted entry keeps its lock, and its input never reaches the AVD on its old port", async () => {
    const file = await tempFile()
    const corrupted: Entry = {
      ...entry("android-emulator:AVD_OLD", {
        kind: "android-emulator",
        avd: "AVD_NEW",
        serial: "emulator-5554",
        consolePort: 5554,
      }),
      owner,
    }
    await Bun.write(file, JSON.stringify([corrupted]))
    const system = fakeSystem()
    system.world.existing = new Set(["AVD_OLD", "AVD_NEW"])
    system.world.files = [running("AVD_NEW", 5554)]
    system.world.emulators = system.world.files
    const { hub, list, input } = serveHub(system, { file })
    await hub.start()
    const taken = await hub.control(corrupted.id, "take")
    expect(taken?.token).toBeDefined()
    const response = await input(corrupted.id, [
      { type: "touch", phase: "began", x: 0.5, y: 0.5 },
      { type: "text", text: "segredo" },
    ])
    expect(response.status).toBe(200)
    await hub.probe()
    await Bun.sleep(50)
    expect(hub.locks.has(corrupted.id)).toBe(true)
    expect((await list()).find((item) => item.id === corrupted.id)).toMatchObject({
      state: "user",
      meta: { kind: "android-emulator", avd: "AVD_OLD" },
    })
    expect(system.touching()).toEqual([])
    expect(system.connected).toEqual([])
    expect(system.calls).toEqual([])
    await hub.control(corrupted.id, "release")
  })

  test("F: concurrent probes and registrations do not bring duplicates back", async () => {
    const system = fakeSystem()
    const { hub, register, list } = serveHub(system)
    system.world.existing = new Set(["AVD_A", "AVD_B"])
    system.world.files = [running("AVD_A", 5554)]
    system.world.emulators = system.world.files
    await Promise.all([
      hub.probe(),
      register({ kind: "android-emulator", meta: { kind: "android-emulator", serial: "emulator-5554" } }),
      register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "AVD_A" } }),
      hub.probe(),
    ])
    system.world.files = [running("AVD_B", 5554)]
    system.world.emulators = system.world.files
    await Promise.all([
      hub.probe(),
      register({ kind: "android-emulator", meta: { kind: "android-emulator", serial: "emulator-5554" } }),
      register({ kind: "android-emulator", meta: { kind: "android-emulator", serial: "emulator-5554", avd: "AVD_B" } }),
      hub.probe(),
    ])
    await hub.probe()
    const all = await list()
    expect(all.filter((item) => item.state !== "stopped" && item.state !== "gone").map(identity)).toEqual(["AVD_B"])
    const avds = all.map(identity)
    expect(new Set(avds).size).toBe(avds.length)
  })

  test("discovery leaves bare serials to the hub instead of the AVD that held them at the last probe", () => {
    const resource = (id: string, meta: Resources.Meta, state: Resources.State = "idle"): Resources.Resource => ({
      id,
      kind: meta.kind,
      label: "x",
      state,
      meta,
      discoveredAt: 0,
      lastUsedAt: 0,
      updatedAt: 0,
      live: { stream: true, input: true },
    })
    const a = resource("android-emulator:AVD_A", { kind: "android-emulator", avd: "AVD_A", serial: "emulator-5554" })
    const bare = resource("android-emulator:emulator-5556", { kind: "android-emulator", serial: "emulator-5556" })
    const corrupted = resource("android-emulator:AVD_OLD", { kind: "android-emulator", avd: "AVD_A" })
    const all = [a, bare, corrupted]
    expect(known(references("adb -s emulator-5554 shell input tap 1 1"), all)).toEqual([])
    expect(bareSerials(references("adb -s emulator-5554 shell input tap 1 1"), all)).toEqual([
      { kind: "android-emulator", serial: "emulator-5554" },
    ])
    expect(known(references("adb -s emulator-5556 logcat"), all)).toEqual([bare])
    expect(bareSerials(references("adb -s emulator-5556 logcat"), all)).toEqual([])
    // An AVD names the entry that is that AVD, not one whose rewritten meta says so.
    expect(known(references("emulator -avd AVD_A -no-window"), all)).toEqual([a])
  })
})
