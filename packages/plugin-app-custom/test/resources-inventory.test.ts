import { describe, expect, test } from "bun:test"
import { Effect } from "effect"
import type { Adapter, Entry } from "../src/resources/adapters/types"
import { booted } from "../src/resources/adapters/ios-simulator"
import { createAdapter, type AndroidSystem } from "../src/resources/adapters/android-emulator"
import { createHub, record } from "../src/resources/hub/hub"
import { present, type Known, type Sessions } from "../src/resources/presence"
import { makeProcessWatch, parsePs, seconds, sessions, uses } from "../src/resources/processes"
import { Resources } from "../src/resources/rpc"

// rev. 2026-11-18 (`docs/resources.md`, "Inventory and tests", "Owners").

const slim = "994DABA4-B939-4A12-94D1-4376E2658429"
const slim3 = "55134A48-DD2A-45B5-8B00-82344D770E44"
const other = "981CA83D-94F3-4B06-BB79-DA28596C2FAE"
const hour = 3_600_000

/** A `ps -Ao pid=,ppid=,etime=,command=` the way this Mac printed it while two test runs used devices. */
const ps = [
  `    1     0 17-17:52:00 /sbin/launchd`,
  `  500     1 02-00:00:00 /Users/a/.local/share/opencode-custom-v2/bin/bun plugin/index.js --opencode-resources-hub`,
  `  501   500    01:00 /Users/a/node_modules/@expo/serve-sim/dist/serve-sim.js --udid ${other}`,
  // A run of the brave-garden worktree, started over the bridge (its root is detached, as the bridge leaves it).
  ` 9152     1    12:35 bash -c run="$HOME/$1/run-$2"`,
  ` 9153  9152    12:34 bash /Users/a/Library/Caches/abacato-e2e/repo-brave-garden/scripts/e2e --ios --filter-namespace *.Chat`,
  `13808  9153    10:43 bash /Users/a/Library/Caches/abacato-e2e/repo-brave-garden/scripts/e2e --ios --filter-namespace *.Chat`,
  `13815 13808    10:43 /opt/homebrew/bin/dotnet test --project src/Abacato.Tests.E2E --no-build`,
  `13817 13808    10:43 tee /Users/a/Library/Caches/abacato-e2e/run-brave-garden/said-${slim3}`,
  `13838 13815    10:42 /Users/a/src/Abacato.Tests.E2E/bin/Debug/net11.0/Abacato.Tests.E2E --results-directory x`,
  `13845 13838    10:42 /opt/homebrew/bin/node appium/build/lib/main.js --port 56369 --address 127.0.0.1`,
  `13850 13845    10:40 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test-without-building -project WebDriverAgent.xcodeproj -destination id=${slim3}`,
  // An Android run of another worktree, with the agent's session in its environment (see `sessions`).
  `18208 18207    09:00 bash /Users/a/Library/Caches/abacato-e2e/repo-AbacatoV3-pedidos-editor/scripts/e2e --shards 1`,
  `21142 18208    07:38 /Users/a/Library/Android/sdk/platform-tools/adb -P 5037 -s emulator-5556 shell am instrument -w io.appium.uiautomator2.server.test`,
  // Leftovers whose parent is gone: Appium's WebDriverAgent, a hot reload's logcat. They do not count.
  `24851     1 02-15:37:59 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing test-without-building -project WebDriverAgent.xcodeproj -destination id=${slim}`,
  ` 6415     1  02:18:56 /Users/a/Library/Android/sdk/platform-tools/adb -s emulator-5558 logcat --pid=30468`,
  // The simulator's own processes, the emulator itself, an identity probe, a query just started.
  ` 7000   300 01:00:00 /Library/Developer/CoreSimulator/Volumes/iOS/launchd_sim /Users/a/Library/Developer/CoreSimulator/Devices/${other}/data/var/run/launchd_bootstrap.plist`,
  `  300   299 01:00:00 /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator`,
  ` 7100   300    10:00 /Users/a/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd abacato-e2e -port 5556`,
  ` 7200   300    00:10 /Users/a/Library/Android/sdk/platform-tools/adb -s emulator-5560 emu avd name`,
  ` 7300   300    00:01 xcrun simctl io ${other} screenshot /tmp/a.png`,
].join("\n")

const devices = [
  { id: `ios-simulator:${slim}`, meta: { kind: "ios-simulator", udid: slim } },
  { id: `ios-simulator:${slim3}`, meta: { kind: "ios-simulator", udid: slim3 } },
  { id: `ios-simulator:${other}`, meta: { kind: "ios-simulator", udid: other } },
  { id: "android-emulator:abacato-e2e", meta: { kind: "android-emulator", serial: "emulator-5556", avd: "abacato-e2e" } },
  { id: "android-emulator:maui-base-2", meta: { kind: "android-emulator", serial: "emulator-5558", avd: "maui-base-2" } },
  { id: "android-emulator:maui-base-4", meta: { kind: "android-emulator", serial: "emulator-5560", avd: "maui-base-4" } },
] satisfies { id: string; meta: Resources.Meta }[]

describe("processes using devices", () => {
  test("reads ps rows and elapsed times", () => {
    expect(seconds("02-15:37:59")).toBe(2 * 86_400 + 15 * 3_600 + 37 * 60 + 59)
    expect(seconds("10:43")).toBe(643)
    const rows = parsePs(ps)
    expect(rows.find((row) => row.pid === 13817)).toEqual({
      pid: 13817,
      ppid: 13808,
      elapsed: 643,
      command: `tee /Users/a/Library/Caches/abacato-e2e/run-brave-garden/said-${slim3}`,
    })
  })

  test("a running test names its devices; leftovers, the simulator's insides, hubs and probes do not", () => {
    const now = 10_000_000
    const found = uses(parsePs(ps), devices, 500, now)
    expect([...found.keys()].toSorted()).toEqual(["android-emulator:abacato-e2e", `ios-simulator:${slim3}`])
    // The outermost runner reports it, with the worktree its command lines name.
    expect(found.get(`ios-simulator:${slim3}`)).toEqual({
      pid: 9153,
      command: "bash /Users/a/Library/Caches/abacato-e2e/repo-brave-garden/scripts/e2e --ios --filter-namespace *.Chat",
      since: now - 754_000,
      folder: "brave-garden",
    })
    expect(found.get("android-emulator:abacato-e2e")).toMatchObject({ pid: 18208, folder: "AbacatoV3-pedidos-editor" })
  })

  test("the session comes from the runner's environment, read once per runner", async () => {
    expect(sessions(` 9153 bash scripts/e2e --ios PATH=/bin OPENCODE_SESSION_ID=ses_abc123 HOME=/Users/a\n18208 bash x`)).toEqual(
      new Map([[9153, "ses_abc123"]]),
    )
    const asked: number[][] = []
    const watch = makeProcessWatch(
      {
        list: async () => ps,
        environment: async (pids) => {
          asked.push([...pids])
          return pids.map((pid) => `${pid} cmd ${pid === 9153 ? "OPENCODE_SESSION_ID=ses_brave" : "X=1"}`).join("\n")
        },
      },
      500,
    )
    const first = await watch(devices, 1_000_000_000)
    expect(first.get(`ios-simulator:${slim3}`)?.sessionID).toBe("ses_brave")
    expect(first.get("android-emulator:abacato-e2e")?.sessionID).toBeUndefined()
    await watch(devices, 1_000_005_000)
    expect(asked).toEqual([[9153, 18208]])
    // Nothing running: no ps at all.
    const idle = makeProcessWatch({ list: async () => Promise.reject(new Error("no ps")), environment: async () => "" })
    expect((await idle([], 0)).size).toBe(0)
  })
})

function fakes(found: { ios: Resources.Meta[]; android: Resources.Meta[] }) {
  const adapter = (kind: Resources.Kind, list: () => Resources.Meta[]): Adapter => ({
    kind,
    probe: async (entries) => new Map(entries.map((entry) => [entry.id, { status: "running" as const }])),
    snapshot: async () => Promise.reject(new Error("no")),
    inventory: async () => list(),
  })
  return {
    "ios-simulator": adapter("ios-simulator", () => found.ios),
    "android-emulator": adapter("android-emulator", () => found.android),
    chrome: adapter("chrome", () => []),
  }
}

describe("hub inventory and tests", () => {
  test("every running simulator and emulator is listed, nobody's and free, once", async () => {
    const clock = { value: 5 * hour }
    const found = {
      ios: [{ kind: "ios-simulator", udid: slim, name: "AbacatoV3 E2E slim", device: "iPhone 17 Pro" }] as Resources.Meta[],
      android: [{ kind: "android-emulator", serial: "emulator-5556", avd: "abacato-e2e", device: "Pixel 7" }] as Resources.Meta[],
    }
    const hub = createHub({ adapters: fakes(found), secret: "s", now: () => clock.value, inventory: true })
    // One an agent already used stays its own.
    hub.upsert({
      kind: "ios-simulator",
      meta: { kind: "ios-simulator", udid: slim3 },
      owner: { sessionID: "ses_a", rootSessionID: "ses_a" },
      used: true,
    })
    found.ios.push({ kind: "ios-simulator", udid: slim3, name: "slim 3" })
    await hub.inventory()
    await hub.inventory()
    const listed = [...hub.entries.values()].map(hub.view)
    expect(listed.map((resource) => resource.id).toSorted()).toEqual(
      ["android-emulator:abacato-e2e", `ios-simulator:${slim}`, `ios-simulator:${slim3}`].toSorted(),
    )
    const fresh = listed.find((resource) => resource.id === `ios-simulator:${slim}`)!
    expect(fresh.owner).toBeUndefined()
    expect(fresh.state).toBe("idle")
    expect(fresh.label).toBe("iPhone 17 Pro · AbacatoV3 E2E slim")
    expect(listed.find((resource) => resource.id === `ios-simulator:${slim3}`)?.owner?.sessionID).toBe("ses_a")
    // Without the option (a Linux hub), nothing is listed on its own.
    const linux = createHub({ adapters: fakes(found), secret: "s", now: () => clock.value })
    await linux.inventory()
    expect(linux.entries.size).toBe(0)
  })

  test("a known resource that had gone comes back when it runs again", async () => {
    const clock = { value: hour }
    const found = { ios: [] as Resources.Meta[], android: [] as Resources.Meta[] }
    const hub = createHub({ adapters: fakes(found), secret: "s", now: () => clock.value, inventory: true })
    hub.upsert({ kind: "ios-simulator", meta: { kind: "ios-simulator", udid: slim }, owner: { sessionID: "a", rootSessionID: "a" } })
    const id = `ios-simulator:${slim}`
    hub.entries.set(id, { ...hub.entries.get(id)!, status: "gone" })
    found.ios.push({ kind: "ios-simulator", udid: slim })
    await hub.inventory()
    expect(hub.entries.get(id)?.status).toBe("running")
  })

  test("a process using a device marks it in use by a test, and the change is announced", async () => {
    const clock = { value: 10 * hour }
    const found = { ios: [{ kind: "ios-simulator", udid: slim3 }] as Resources.Meta[], android: [] as Resources.Meta[] }
    let using = true
    const hub = createHub({
      adapters: fakes(found),
      secret: "s",
      now: () => clock.value,
      inventory: true,
      processes: async (list) =>
        new Map(
          using
            ? list.map((device) => [
                device.id,
                { pid: 9, command: "MY_TOKEN=x bash scripts/e2e --ios", since: clock.value - 60_000, folder: "brave-garden", sessionID: "ses_b" },
              ])
            : [],
        ),
    })
    await hub.inventory()
    await hub.watch()
    const view = hub.view(hub.entries.get(`ios-simulator:${slim3}`)!)
    expect(view.test).toEqual({
      command: "bash scripts/e2e --ios",
      since: clock.value - 60_000,
      sessionID: "ses_b",
      folder: "brave-garden",
    })
    const events = await hub.claim(0)
    expect(events.some((event) => event.type === "changed" && event.ids.includes(`ios-simulator:${slim3}`))).toBe(true)
    using = false
    await hub.watch()
    expect(hub.view(hub.entries.get(`ios-simulator:${slim3}`)!).test).toBeUndefined()
  })

  test("the history keeps each command's session and drops those older than a day", () => {
    const at = 100 * hour
    const old = { call: "c1", command: "adb -s emulator-5554 install a.apk", at: at - 3 * 24 * hour, sessionID: "ses_old", endedAt: at - 3 * 24 * hour }
    const next = record([old], { call: "c2", command: "adb -s emulator-5554 shell am start", running: false }, { sessionID: "ses_new", rootSessionID: "ses_root", agent: "build" }, at)
    expect(next).toEqual([
      { call: "c2", command: "adb -s emulator-5554 shell am start", at, sessionID: "ses_new", agent: "build", endedAt: at },
    ])
    const clock = { value: at }
    const hub = createHub({ adapters: fakes({ ios: [], android: [] }), secret: "s", now: () => clock.value })
    const entry: Entry = {
      id: "android-emulator:a",
      kind: "android-emulator",
      meta: { kind: "android-emulator", avd: "a" },
      owner: { sessionID: "ses_new", rootSessionID: "ses_root" },
      status: "running",
      discoveredAt: 0,
      lastUsedAt: at - hour,
      updatedAt: 0,
      activity: [old, { call: "c3", command: "recent", at: at - hour, sessionID: "ses_new", endedAt: at - hour }],
    }
    hub.entries.set(entry.id, entry)
    expect(hub.view(entry).activity).toEqual([{ at: at - hour, command: "recent", sessionID: "ses_new" }])
  })
})

describe("android inventory", () => {
  test("emulators whose AVD is known, from one adb listing per cycle", async () => {
    let listed = 0
    const io: AndroidSystem = {
      run: async () => new Uint8Array(),
      text: async () => "",
      connect: () => {
        throw new Error("no")
      },
      discovered: async () => [],
      emulators: async () => {
        listed++
        return [
          { pid: 1, serial: "emulator-5556", consolePort: 5556, avd: "abacato-e2e", device: "Pixel 7", grpcToken: "secret" },
          { pid: 0, serial: "emulator-5570", consolePort: 5570 },
        ]
      },
      avdExists: async () => true,
    }
    const adapter = createAdapter(io)
    await adapter.probe([])
    const metas = await adapter.inventory!()
    expect(metas).toEqual([
      { kind: "android-emulator", serial: "emulator-5556", avd: "abacato-e2e", consolePort: 5556, device: "Pixel 7" },
    ])
    expect(listed).toBe(1)
  })

  test("booted simulators", () => {
    const devices = new Map([
      [slim, { udid: slim, name: "slim", state: "Booted", device: "iPhone 17 Pro", runtime: "iOS 27.0" }],
      [other, { udid: other, name: "off", state: "Shutdown" }],
    ])
    expect(booted(devices)).toEqual([
      { kind: "ios-simulator", udid: slim, name: "slim", device: "iPhone 17 Pro", runtime: "iOS 27.0" },
    ])
  })
})

describe("owners", () => {
  const families: Record<string, Known> = {
    ses_pedido: { sessionID: "ses_pedido", rootSessionID: "ses_pedido", title: "Pedido", rootTitle: "Pedido" },
    ses_editor: { sessionID: "ses_editor", rootSessionID: "ses_pedido", agent: "build", title: "Onda 3A: editor do pedido", rootTitle: "Pedido" },
    ses_agenda: { sessionID: "ses_agenda", rootSessionID: "ses_agenda", title: "Agendamento de mensagens", rootTitle: "Agendamento de mensagens" },
  }
  const sessions: Sessions = {
    get: (id) => Effect.succeed(families[id]),
    inFolder: (folder) =>
      Effect.succeed(folder === "brave-garden" ? [families.ses_agenda!] : folder === "AbacatoV3-pedidos-editor" ? [families.ses_editor!] : []),
  }
  const now = 100 * hour
  const base = (fields: Partial<Resources.Resource>): Resources.Resource => ({
    id: "ios-simulator:x",
    kind: "ios-simulator",
    label: "x",
    state: "idle",
    meta: { kind: "ios-simulator", udid: "x" },
    discoveredAt: 0,
    lastUsedAt: now - hour,
    updatedAt: 0,
    live: { stream: true, input: true },
    ...fields,
  })
  const run = (resource: Resources.Resource) => Effect.runPromise(present([resource], sessions, now)).then(([one]) => one!)

  test("a recent owner stays, with its titles", async () => {
    const owner = (await run(base({ owner: { sessionID: "ses_editor", rootSessionID: "ses_pedido" } }))).owner
    expect(owner).toEqual({
      sessionID: "ses_editor",
      rootSessionID: "ses_pedido",
      agent: "build",
      title: "Onda 3A: editor do pedido",
      rootTitle: "Pedido",
      source: "command",
    })
  })

  test("an owner whose session is gone, or idle for hours, expires", async () => {
    const gone = await run(base({ owner: { sessionID: "ses_deleted", rootSessionID: "ses_deleted" } }))
    expect(gone.owner).toBeUndefined()
    expect(gone.previousOwner).toEqual({ sessionID: "ses_deleted", rootSessionID: "ses_deleted" })
    const idle = await run(base({ owner: { sessionID: "ses_pedido", rootSessionID: "ses_pedido" }, lastUsedAt: now - 3 * 24 * hour }))
    expect(idle.owner).toBeUndefined()
    expect(idle.previousOwner?.title).toBe("Pedido")
    // In use by an agent right now: it stays, however old the last finished use.
    const busy = await run(base({ owner: { sessionID: "ses_pedido", rootSessionID: "ses_pedido" }, lastUsedAt: now - 3 * 24 * hour, state: "agent" }))
    expect(busy.owner?.sessionID).toBe("ses_pedido")
  })

  test("a test names its owner: the session in its environment, else probably the worktree's", async () => {
    const test = { command: "bash scripts/e2e --ios", since: now - 60_000 }
    const byProcess = await run(base({ test: { ...test, sessionID: "ses_agenda" } }))
    expect(byProcess.owner).toMatchObject({ sessionID: "ses_agenda", source: "process" })
    expect(byProcess.owner?.probable).toBeUndefined()
    // The folder, when the environment does not say it; the earlier owner, another family's, becomes the previous one.
    const byFolder = await run(base({ test: { ...test, folder: "brave-garden" }, owner: { sessionID: "ses_pedido", rootSessionID: "ses_pedido" } }))
    expect(byFolder.owner).toMatchObject({ sessionID: "ses_agenda", source: "folder", probable: true, title: "Agendamento de mensagens" })
    expect(byFolder.previousOwner?.sessionID).toBe("ses_pedido")
    // A folder no session of this server has: nobody's, still in use by a test.
    const unknown = await run(base({ test: { ...test, folder: "AbacatoV3-pedidos-juncao" } }))
    expect(unknown.owner).toBeUndefined()
    expect(unknown.test).toBeDefined()
    // An agent using it now keeps it, whatever the test.
    const busy = await run(base({ state: "agent", owner: { sessionID: "ses_pedido", rootSessionID: "ses_pedido" }, test: { ...test, folder: "brave-garden" } }))
    expect(busy.owner?.sessionID).toBe("ses_pedido")
  })
})
