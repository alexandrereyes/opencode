import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import {
  adapter as android,
  checkAvd,
  identity,
  repair,
  resolve,
  type RunningEmulator,
} from "../src/resources/adapters/android-emulator"
import type { Adapter, Entry } from "../src/resources/adapters/types"
import { known } from "../src/resources/discovery"
import { createHub } from "../src/resources/hub/hub"
import type { ResourceProtocol } from "../src/resources/protocol"

/**
 * Android identity across console-port reuse: the AVD is the resource, `emulator-<port>` only where it runs now. The
 * hub runs with the production `resolve` (probe) and `repair` (load) over fake running emulators and AVD folders, so
 * no adb, emulator or device is touched.
 */
const owner = { sessionID: "ses_child", rootSessionID: "ses_root", agent: "opushigh" }
const running = (avd: string, port: number, device = "Pixel 7"): RunningEmulator => ({
  pid: 0,
  serial: `emulator-${port}`,
  consolePort: port,
  grpcPort: port + 3000,
  avd,
  device,
})

const hubs: { close: () => void }[] = []
const directories: string[] = []
afterEach(async () => {
  hubs.splice(0).forEach((hub) => hub.close())
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

/** A hub whose Android adapter probes `world` with the production resolution and records what reaches devices. */
function makeHub(options: { file?: string; clock?: { value: number } } = {}) {
  const world = { running: [] as RunningEmulator[], existing: new Set<string>() }
  const reached: { id: string; serial?: string; event: ResourceProtocol.Input }[] = []
  const fake: Adapter = {
    kind: "android-emulator",
    probe: async (entries) => resolve(entries, world.running, world.existing),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array([0xff, 0xd8, 0xff, 0xd9]) }),
    input: async (entry, event) =>
      void reached.push({
        id: entry.id,
        ...(entry.meta.kind === "android-emulator" && entry.meta.serial ? { serial: entry.meta.serial } : {}),
        event,
      }),
  }
  const clock = options.clock ?? { value: 1_000_000 }
  const hub = createHub({
    adapters: { "ios-simulator": fake, "android-emulator": fake, chrome: fake },
    secret: "s",
    now: () => clock.value,
    ...(options.file ? { file: options.file } : {}),
  })
  hubs.push(hub)
  const list = () => [...hub.entries.values()].map((entry) => hub.view(entry))
  return { hub, world, reached, clock, list }
}

async function tempFile() {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resources-android-identity-"))
  directories.push(directory)
  return path.join(directory, "resources.json")
}

describe("Android resource identity", () => {
  test("A: an AVD that stops never becomes the next AVD on its port", async () => {
    const { hub, world, list } = makeHub()
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
    // A is stopped, still itself, and no longer holds the port.
    expect(hub.entries.get(a.id)).toMatchObject({
      status: "stopped",
      meta: { kind: "android-emulator", avd: "AVD_A", device: "Pixel 9" },
    })
    expect(hub.entries.get(a.id)?.meta).not.toHaveProperty("serial")
    expect(hub.view(hub.entries.get(a.id)!).activity).toHaveLength(1)

    // B arrives by serial and AVD: a new resource, not A.
    const b = hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554", avd: "AVD_B" },
      owner,
      used: true,
    })
    await hub.probe()
    expect(b.id).toBe("android-emulator:AVD_B")
    expect(list().map((item) => [item.id, item.state, item.meta.kind === "android-emulator" && item.meta.avd])).toEqual(
      [
        [a.id, "stopped", "AVD_A"],
        [b.id, "agent", "AVD_B"],
      ],
    )
    // A later command naming only the serial is B's.
    expect(known([{ kind: "android-emulator", serial: "emulator-5554" }], list()).map((item) => item.id)).toEqual([
      b.id,
    ])
  })

  test("B: a resource first known by serial learns its AVD without a duplicate, keeping its serial ID", async () => {
    const { hub, world, list } = makeHub()
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
    // The serial-made ID is legitimate: nothing repairs it.
    expect(repair(hub.entries.get(first.id)!)).toBeUndefined()

    // When that AVD stops and another starts on the same port, the serial ID stays the first AVD's.
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

  test("C: a persisted registry corrupted by port reuse is repaired on load, without merging the two AVDs", async () => {
    const file = await tempFile()
    const shared = { serial: "emulator-5554", consolePort: 5554, grpcPort: 8554, device: "Pixel 7" }
    const stored: Entry[] = [
      {
        id: "android-emulator:Abacato_feat_decisoes_auditoria",
        kind: "android-emulator",
        owner,
        meta: { kind: "android-emulator", avd: "Abacato_curious_falcon", ...shared },
        status: "running",
        discoveredAt: 1_793_539_960_859,
        lastUsedAt: 1_793_539_970_000,
        updatedAt: 1_793_799_368_816,
        activity: [{ call: "call_old", command: "adb -s emulator-5554 install app.apk", at: 1_793_539_965_000 }],
      },
      {
        id: "android-emulator:Abacato_curious_falcon",
        kind: "android-emulator",
        owner,
        meta: { kind: "android-emulator", avd: "Abacato_curious_falcon", ...shared },
        status: "running",
        discoveredAt: 1_793_799_368_816,
        lastUsedAt: 1_793_799_369_000,
        updatedAt: 1_793_799_369_000,
      },
    ]
    await Bun.write(file, JSON.stringify(stored))
    const { hub, world, list } = makeHub({ file, clock: { value: 1_793_799_400_000 } })
    world.existing = new Set(["Abacato_feat_decisoes_auditoria", "Abacato_curious_falcon"])
    world.running = [running("Abacato_curious_falcon", 5554)]
    await hub.start()
    await hub.probe()
    const [old, current] = stored.map((entry) => hub.entries.get(entry.id)!)
    // The old AVD gets its own identity back; history, owner and discovery time stay.
    expect(old).toMatchObject({
      status: "stopped",
      meta: { kind: "android-emulator", avd: "Abacato_feat_decisoes_auditoria" },
      owner,
      discoveredAt: 1_793_539_960_859,
      activity: stored[0]!.activity,
    })
    expect(old!.meta).not.toHaveProperty("serial")
    expect(current).toMatchObject({
      status: "running",
      meta: { avd: "Abacato_curious_falcon", serial: "emulator-5554" },
    })
    expect(list().filter((item) => item.state !== "stopped" && item.state !== "gone")).toHaveLength(1)

    // The repair is persisted, and loading it again (a restart) changes nothing.
    await Bun.sleep(400)
    const persisted = await Bun.file(file).json()
    const again = makeHub({ file, clock: { value: 1_793_799_500_000 } })
    again.world.existing = world.existing
    again.world.running = world.running
    await again.hub.start()
    await again.hub.probe()
    expect([...again.hub.entries.values()].map((entry) => [entry.id, entry.status, entry.meta])).toEqual(
      persisted.map((entry: Entry) => [entry.id, entry.status, entry.meta]),
    )
  })

  test("C: entries made from serials that ended up as the same AVD keep their history; one represents it", async () => {
    const { hub, world, list } = makeHub()
    world.existing = new Set(["AVD_X"])
    world.running = [running("AVD_X", 5560)]
    const base = { kind: "android-emulator" as const, status: "running" as const, lastUsedAt: 1, updatedAt: 1 }
    const legacy: Entry = {
      ...base,
      id: "android-emulator:emulator-5554",
      meta: { kind: "android-emulator", avd: "AVD_X", serial: "emulator-5554" },
      discoveredAt: 10,
      activity: [{ call: "call_legacy", command: "adb -s emulator-5554 logcat", at: 10 }],
    }
    const canonical: Entry = {
      ...base,
      id: "android-emulator:AVD_X",
      meta: { kind: "android-emulator", avd: "AVD_X" },
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
    // New use goes to the representative.
    hub.upsert({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5560", avd: "AVD_X" },
      owner,
    })
    expect(hub.entries.get(canonical.id)?.owner).toEqual(owner)
    expect(hub.entries.get(legacy.id)?.owner).toBeUndefined()
  })

  test("D: two AVDs with the same label stay two resources, and a new serial keeps the AVD's own history", async () => {
    const { hub, world, list } = makeHub()
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
    // A restarts on another port: same resource, same history, new serial.
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

  test("E: control stays with the resource it was taken on and no input reaches the AVD that reused its port", async () => {
    const file = await tempFile()
    const corrupted: Entry = {
      id: "android-emulator:AVD_OLD",
      kind: "android-emulator",
      owner,
      meta: { kind: "android-emulator", avd: "AVD_NEW", serial: "emulator-5554", consolePort: 5554 },
      status: "running",
      discoveredAt: 1,
      lastUsedAt: 1,
      updatedAt: 1,
    }
    await Bun.write(file, JSON.stringify([corrupted]))
    const { hub, world, reached } = makeHub({ file })
    world.existing = new Set(["AVD_OLD", "AVD_NEW"])
    world.running = [running("AVD_NEW", 5554)]
    await hub.start()
    const taken = await hub.control(corrupted.id, "take")
    expect(taken?.token).toBeDefined()
    await hub.probe()
    // The lock survives the repair; the resource is its own AVD again and has no device to send input to.
    expect(hub.locks.has(corrupted.id)).toBe(true)
    expect(hub.view(hub.entries.get(corrupted.id)!).state).toBe("user")
    expect(hub.entries.get(corrupted.id)?.meta).toEqual({ kind: "android-emulator", avd: "AVD_OLD" })
    expect(reached).toEqual([])
    // The production adapter refuses to act without a serial, before any adb or gRPC call.
    const repaired = hub.entries.get(corrupted.id)!
    await expect(android.input!(repaired, { type: "key", key: "Enter" })).rejects.toThrow("not attached")
    await expect(android.snapshot(repaired)).rejects.toThrow("not attached")
    // A connection opened on a port now held by another AVD is refused.
    expect(() => checkAvd({ serial: "emulator-5554", avd: "AVD_OLD" }, "AVD_NEW")).toThrow("now runs the AVD AVD_NEW")
    expect(() => checkAvd({ serial: "emulator-5554", avd: "AVD_OLD" }, "AVD_OLD")).not.toThrow()
    expect(identity(repaired)).toBe("AVD_OLD")
    await hub.control(corrupted.id, "release")
  })

  test("F: concurrent probes and registrations do not bring duplicates back", async () => {
    const { hub, world, list } = makeHub()
    world.existing = new Set(["AVD_A", "AVD_B"])
    world.running = [running("AVD_A", 5554)]
    const work = [
      hub.probe(),
      Promise.resolve(
        hub.upsert({ kind: "android-emulator", meta: { kind: "android-emulator", serial: "emulator-5554" } }),
      ),
      Promise.resolve(hub.upsert({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "AVD_A" } })),
      hub.probe(),
    ]
    await Promise.all(work)
    world.running = [running("AVD_B", 5554)]
    await Promise.all([
      hub.probe(),
      Promise.resolve(
        hub.upsert({
          kind: "android-emulator",
          meta: { kind: "android-emulator", serial: "emulator-5554", avd: "AVD_B" },
        }),
      ),
      hub.probe(),
    ])
    await hub.probe()
    const live = list().filter((item) => item.state !== "stopped" && item.state !== "gone")
    expect(live.map((item) => item.meta.kind === "android-emulator" && item.meta.avd)).toEqual(["AVD_B"])
    const avds = list().map((item) => identity(item))
    expect(new Set(avds).size).toBe(avds.length)
  })
})
