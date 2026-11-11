import { afterEach, describe, expect, test } from "bun:test"
import { Effect } from "effect"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Adapter } from "../src/resources/adapters/types"
import { onlyAsksAndroid, type Reference } from "../src/resources/discovery"
import { createHub, protocol, type HubEvent } from "../src/resources/hub/hub"
import { commandLock, makeHubs, routes, scopes, type Machine } from "../src/resources/hubs"
import { HubError, macHubSettings, makeHubClient, type HubSettings } from "../src/resources/supervisor"
import { startedAVDs } from "../src/resources/usage"

const udid = "4D3C2B1A-0000-4000-8000-000000000001"
const roots: string[] = []
const servers: { stop: (force?: boolean) => unknown }[] = []

afterEach(async () => {
  servers.splice(0).forEach((server) => server.stop(true))
  await Promise.all(roots.splice(0).map((root) => fs.rm(root, { recursive: true, force: true })))
})

describe("a command's parts per machine", () => {
  const table: [string, string, boolean, { machine: Machine; references: Reference[] }[]][] = [
    [
      "without the Mac's hub, `mac` stays local, as on OrbStack",
      "mac adb -s emulator-5554 shell ls",
      false,
      [{ machine: "local", references: [{ kind: "android-emulator", serial: "emulator-5554" }] }],
    ],
    ["the sidecar's adb is outside Recursos", "adb -s emulator-5554 shell input tap 1 1", true, []],
    [
      "mac and its options",
      "mac -C ~/Dev -- emulator -avd Pixel_9 -no-window",
      true,
      [{ machine: "mac", references: [{ kind: "android-emulator", avd: "Pixel_9" }] }],
    ],
    [
      "a script run by a shell on the Mac",
      "mac bash -lc 'cd x && adb -s emulator-5556 install app.apk'",
      true,
      [{ machine: "mac", references: [{ kind: "android-emulator", serial: "emulator-5556" }] }],
    ],
    [
      "a here-document fed to the Mac, piped on, followed by a local command",
      `mac bash <<'EOF' | tee log\nxcrun simctl boot ${udid}\nadb -s emulator-5556 shell ls\nEOF\nadb -s emulator-5554 devices`,
      true,
      [
        {
          machine: "mac",
          references: [
            { kind: "ios-simulator", udid },
            { kind: "android-emulator", serial: "emulator-5556" },
          ],
        },
      ],
    ],
    [
      "this machine's browsers, not the Mac's",
      "playwright-cli -s=foo open https://x && mac playwright-cli -s=bar open https://y",
      true,
      [{ machine: "local", references: [{ kind: "chrome", session: "foo", workspace: "/w" }] }],
    ],
    ["another machine reached from the Mac", "mac ssh host-6 adb -s emulator-5554 shell ls", true, []],
    [
      "a simulator is always the Mac's",
      `agent-device --udid ${udid} snapshot`,
      true,
      [{ machine: "mac", references: [{ kind: "ios-simulator", udid }] }],
    ],
  ]
  test.each(table)("%s", (_, command, mac, expected) => {
    expect(
      routes(scopes(command, mac), "", "/w").map((route) => ({ machine: route.machine, references: route.references })),
    ).toEqual(expected)
  })

  test("what the Mac part asks or starts is read from the Mac part alone", () => {
    const [route] = routes(
      scopes(
        "adb -s emulator-5554 shell input tap 1 1; emulator -avd Sidecar & mac adb -s emulator-5554 emu avd name",
        true,
      ),
    )
    expect(route?.machine).toBe("mac")
    expect(onlyAsksAndroid(route!.command)).toBe(true)
    const [started] = routes(scopes("emulator -avd Sidecar & mac android-emulator --detach -avd Mac_AVD", true))
    expect(startedAVDs(started!.command)).toEqual(["Mac_AVD"])
  })
})

/** A fake adapter: everything runs, nothing is captured but one tiny picture, stops are recorded. */
function adapter(kind: Adapter["kind"], stopped: string[]): Adapter {
  return {
    kind,
    probe: async (entries) => new Map(entries.map((entry) => [entry.id, { status: "running" as const }])),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array([1, 2, 3]), width: 1, height: 1 }),
    stop: async (entry) => void stopped.push(entry.id),
  }
}

function realHub(secret: string, stopped: string[], clock: { value: number }) {
  return createHub({
    adapters: {
      "ios-simulator": adapter("ios-simulator", stopped),
      "android-emulator": adapter("android-emulator", stopped),
      chrome: adapter("chrome", stopped),
    },
    secret,
    now: () => clock.value,
  })
}

/** This machine's hub, already running (its `hub.json` in the state directory), and the Mac's behind a Unix socket. */
async function twoHubs(
  options: Pick<HubSettings, "timeout" | "slowTimeout" | "backoff"> & { readonly listWait?: number } = {},
) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "mac-hub-"))
  roots.push(root)
  const stopped: string[] = []
  const clock = { value: Date.now() }
  const local = realHub("local-secret", stopped, clock)
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: local.fetch, websocket: local.websocket })
  servers.push(server)
  const state = path.join(root, "state")
  await fs.mkdir(state)
  await Bun.write(
    path.join(state, "hub.json"),
    JSON.stringify({ protocol, pid: process.pid, port: server.port, secret: "local-secret" }),
  )
  const mac = realHub("mac-secret", stopped, clock)
  const socket = path.join(root, "hub.sock")
  const info = path.join(root, "mac-hub.json")
  const runs = path.join(root, "runs")
  await Bun.write(info, JSON.stringify({ protocol, pid: 1, port: 4181, secret: "mac-secret" }))
  const macServer = Bun.serve({ unix: socket, fetch: mac.fetch, websocket: mac.websocket })
  servers.push(macServer)
  const { settings } = macHubSettings({
    OPENCODE_RESOURCES_HUB_MAC_SOCKET: socket,
    // Counts its runs: the Mac's `hub.json` is read again only after a failure, and not during the backoff.
    OPENCODE_RESOURCES_HUB_MAC_INFO_COMMAND: JSON.stringify(["/bin/sh", "-c", 'echo >> "$0"; cat "$1"', runs, info]),
  })
  const localClient = makeHubClient({ state, command: ["/bin/false"] })
  const { listWait: _, ...overrides } = options
  const macClient = makeHubClient({ ...settings!, ...overrides })
  return {
    local,
    mac,
    server,
    macServer,
    socket,
    stopped,
    clock,
    runs: async () => ((await Bun.file(runs).exists()) ? (await Bun.file(runs).text()).split("\n").length - 1 : 0),
    hubs: makeHubs(localClient, macClient, options.listWait ? { listWait: options.listWait } : {}),
    alone: makeHubs(localClient),
  }
}

describe("the Mac's hub", () => {
  test("lists the Mac's simulators and emulators with this machine's browsers, and tickets go to their hub", async () => {
    const { local, mac, server, socket, hubs } = await twoHubs()
    await local.register({ kind: "chrome", meta: { kind: "chrome", session: "foo" }, used: true })
    // Left by the time this hub served simulators and emulators too: hidden, the Mac's hub has them now.
    await local.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Old" }, used: true })
    await mac.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Pixel_9" }, used: true })
    await mac.register({ kind: "ios-simulator", meta: { kind: "ios-simulator", udid }, used: true })
    await mac.register({ kind: "chrome", meta: { kind: "chrome", session: "mac" }, used: true })
    expect((await hubs.list()).resources.map((resource) => resource.id).toSorted()).toEqual([
      "android-emulator:Pixel_9",
      "chrome:foo",
      `ios-simulator:${udid}`,
    ])

    const emulator = await hubs.ticket("android-emulator:Pixel_9", "view")
    expect(emulator).toMatchObject({ path: "/resources/mac/android-emulator%3APixel_9", loopbackPort: 0 })
    // Redeemed by the Mac's hub, the way the proxy delivers `/resources/mac/…` without the `/mac`.
    const snapshot = await fetch(`http://hub/resources/android-emulator%3APixel_9/snapshot?ticket=${emulator.ticket}`, {
      unix: socket,
    })
    expect(snapshot.status).toBe(200)
    expect(await hubs.ticket("chrome:foo", "view")).toMatchObject({
      path: "/resources/chrome%3Afoo",
      loopbackPort: server.port,
    })
  })

  test("each part of a command meets the locks of its own machine's hub", async () => {
    const { local, mac, hubs, alone } = await twoHubs()
    await local.register({ kind: "chrome", meta: { kind: "chrome", session: "default" } })
    await local.register({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554", avd: "Old" },
    })
    await mac.register({
      kind: "android-emulator",
      meta: { kind: "android-emulator", serial: "emulator-5554", avd: "Pixel_9" },
    })
    await local.control("chrome:default", "take")
    await local.control("android-emulator:Old", "take")
    await mac.control("android-emulator:Pixel_9", "take")
    const lock = async (command: string, mac = true) =>
      (await commandLock(mac ? hubs : alone, (mac ? hubs : alone).scopes(command))).lock?.id
    expect(await lock("adb -s emulator-5554 shell input tap 1 1")).toBeUndefined()
    expect(await lock("mac adb -s emulator-5554 shell input tap 1 1")).toBe("android-emulator:Pixel_9")
    expect(await lock("mac adb shell input tap 1 1")).toBe("android-emulator:Pixel_9")
    expect(await lock("playwright-cli snapshot")).toBe("chrome:default")
    expect(await lock("mac playwright-cli snapshot")).toBeUndefined()
    // Without the Mac's hub, as before: one hub, and `mac` runs against it.
    expect(await lock("mac adb -s emulator-5554 shell input tap 1 1", false)).toBe("android-emulator:Old")
    expect(await lock("adb -s emulator-5554 shell input tap 1 1", false)).toBe("android-emulator:Old")
  })

  test("asleep, it delays neither lists nor shells that stay here, and is not asked again during its backoff", async () => {
    const { local, macServer, hubs, runs } = await twoHubs({ timeout: 300, listWait: 300 })
    await local.register({ kind: "chrome", meta: { kind: "chrome", session: "foo" } })
    expect((await commandLock(hubs, hubs.scopes("mac adb devices"))).unchecked).toBe(false)
    const before = await runs()
    // Accepts connections and never answers, like a tunnel to a Mac that went to sleep.
    macServer.reload({ fetch: () => new Promise<Response>(() => {}) })

    let started = Date.now()
    expect((await hubs.list()).resources.map((resource) => resource.id)).toEqual(["chrome:foo"])
    expect(Date.now() - started).toBeLessThan(800)
    started = Date.now()
    expect(await commandLock(hubs, hubs.scopes("git status && playwright-cli -s=foo snapshot"))).toEqual({
      lock: undefined,
      unchecked: false,
    })
    expect(Date.now() - started).toBeLessThan(200)
    // A device tool alone, here, drives the sidecar's emulator: no simulator named, so not the Mac's business.
    expect((await commandLock(hubs, hubs.scopes("npx agent-device --serial emulator-5554 snapshot"))).unchecked).toBe(
      false,
    )

    // The list's request found it away; commands on the Mac run with the warning, at once, without reading hub.json.
    await Bun.sleep(400)
    const after = await runs()
    started = Date.now()
    for (const _ of [1, 2, 3])
      expect((await commandLock(hubs, hubs.scopes("mac adb -s emulator-5554 shell ls"))).unchecked).toBe(true)
    expect(Date.now() - started).toBeLessThan(200)
    expect(await runs()).toBe(after)
    expect(after - before).toBeLessThanOrEqual(1)
  })

  test("a capture slower than its deadline keeps the Mac's resources listed; a Mac asleep during one does not", async () => {
    const { mac, macServer, hubs, runs } = await twoHubs({ timeout: 300, slowTimeout: 300, listWait: 300 })
    const id = "android-emulator:Pixel_9"
    await mac.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Pixel_9" } })
    expect((await hubs.list()).resources.map((resource) => resource.id)).toEqual([id])
    const before = await runs()

    // Only the capture hangs, as an emulator slow to answer does; the hub's health still answers.
    macServer.reload({
      fetch: (request, server) =>
        new URL(request.url).pathname.endsWith("/snapshot")
          ? new Promise<Response>(() => {})
          : mac.fetch(request, server),
      websocket: mac.websocket,
    })
    expect(
      await hubs
        .owner(id)
        .snapshot(id)
        .catch((error: unknown) => error),
    ).toBeInstanceOf(HubError)
    expect((await hubs.list()).resources.map((resource) => resource.id)).toEqual([id])
    expect(await runs()).toBe(before)

    // Asleep: the health check after the capture's deadline fails too, so the hub is away and shells do not wait.
    macServer.reload({ fetch: () => new Promise<Response>(() => {}) })
    expect(
      await hubs
        .owner(id)
        .snapshot(id)
        .catch((error: unknown) => error),
    ).toBeInstanceOf(HubError)
    const started = Date.now()
    expect((await commandLock(hubs, hubs.scopes("mac adb devices"))).unchecked).toBe(true)
    expect(Date.now() - started).toBeLessThan(100)
  })

  /** The Mac's hub, answering, then asleep long enough to be in its backoff (until `armed` + 2 s). */
  async function asleep() {
    const hubs = await twoHubs({ timeout: 300, listWait: 300, backoff: { initial: 2_000, max: 16_000 } })
    await hubs.mac.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Pixel_9" } })
    expect((await commandLock(hubs.hubs, hubs.hubs.scopes("mac adb devices"))).unchecked).toBe(false)
    hubs.macServer.reload({ fetch: () => new Promise<Response>(() => {}) })
    expect((await commandLock(hubs.hubs, hubs.hubs.scopes("mac adb devices"))).unchecked).toBe(true)
    return {
      ...hubs,
      armed: Date.now(),
      wake: () => hubs.macServer.reload({ fetch: hubs.mac.fetch, websocket: hubs.mac.websocket }),
    }
  }

  test("a list the app asks for finds the Mac awake again before its backoff ends", async () => {
    const { hubs, wake } = await asleep()
    wake()
    expect((await hubs.list()).resources).toEqual([])
    expect((await hubs.list({ probe: true })).resources.map((resource) => resource.id)).toEqual([
      "android-emulator:Pixel_9",
    ])
    expect((await commandLock(hubs, hubs.scopes("mac adb devices"))).unchecked).toBe(false)
  })

  test("a list that finds the Mac still asleep neither extends its backoff nor reads hub.json again at once", async () => {
    const { hubs, wake, armed, runs } = await asleep()
    const before = await runs()
    for (const _ of [1, 2]) await hubs.mac!.list(true, true).catch(() => undefined)
    expect((await runs()) - before).toBe(1)
    wake()
    await Bun.sleep(armed + 2_200 - Date.now())
    expect((await commandLock(hubs, hubs.scopes("mac adb devices"))).unchecked).toBe(false)
  })

  test("relays both hubs' events, neither waiting for the other", async () => {
    const { hubs } = await twoHubs()
    const seen: HubEvent[] = []
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          yield* hubs.relay((event) => Effect.sync(() => void seen.push(event)))
          // This machine's hub has nothing to say: its long poll stays open while the Mac's answers.
          yield* Effect.promise(() => hubs.mac!.announce(["android-emulator:Pixel_9"]))
          yield* Effect.promise(() => waitFor(() => seen.length >= 1))
          yield* Effect.promise(() => hubs.local.announce(["chrome:foo"]))
          yield* Effect.promise(() => waitFor(() => seen.length >= 2))
        }),
      ),
    )
    expect(seen).toEqual([
      { type: "changed", ids: ["android-emulator:Pixel_9"] },
      { type: "changed", ids: ["chrome:foo"] },
    ])
  })

  test("tells the app once when the Mac's hub goes away and once when it is back, and lists after that do not", async () => {
    const { hubs, mac, macServer } = await twoHubs({
      timeout: 300,
      listWait: 300,
      backoff: { initial: 1_000, max: 8_000 },
    })
    const seen: HubEvent[] = []
    const settled = async (count: number) => {
      await waitFor(() => seen.length >= count)
      await Bun.sleep(200)
      expect(seen).toEqual(Array.from({ length: count }, () => ({ type: "changed", ids: [] })))
    }
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          yield* hubs.relay((event) => Effect.sync(() => void seen.push(event)))
          const lock = () => Effect.promise(() => commandLock(hubs, hubs.scopes("mac adb devices")))
          const list = () => Effect.promise(() => hubs.list({ probe: true }))
          expect((yield* lock()).unchecked).toBe(false)
          yield* list()

          macServer.reload({ fetch: () => new Promise<Response>(() => {}), websocket: mac.websocket })
          expect((yield* lock()).unchecked).toBe(true)
          // The app reloads: the list probes the hub, still away, and so do shells meanwhile.
          yield* list()
          expect((yield* lock()).unchecked).toBe(true)
          yield* Effect.promise(() => settled(1))

          // Awake again, after the probe above gave up (its health check has 1.5 s).
          macServer.reload({ fetch: mac.fetch, websocket: mac.websocket })
          yield* Effect.sleep("2 seconds")
          yield* list()
          yield* Effect.promise(() => settled(2))
          // The app reloads again: the hub answers as before, nothing new to announce.
          yield* list()
          expect((yield* lock()).unchecked).toBe(false)
          yield* Effect.promise(() => settled(2))
        }),
      ),
    )
  })

  test("shuts down only an emulator this server's agents started; without the Mac's hub nothing changes", async () => {
    const { local, mac, hubs, alone, stopped, clock } = await twoHubs()
    const startedBy = { sessionID: "ses_a", rootSessionID: "ses_a", at: 1 }
    await mac.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Theirs" } })
    await mac.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Ours" }, startedBy })
    await local.register({ kind: "android-emulator", meta: { kind: "android-emulator", avd: "Here" } })
    // Nobody used them for an hour: free.
    clock.value += 3_600_000
    await mac.probe()
    await local.probe()

    expect((await hubs.get("android-emulator:Theirs")).capabilities).toBeUndefined()
    expect((await hubs.list()).resources.find((item) => item.id === "android-emulator:Theirs")?.capabilities).toBe(
      undefined,
    )
    const refused = await hubs.stop("android-emulator:Theirs").catch((error: unknown) => error)
    expect(refused).toBeInstanceOf(HubError)
    expect((refused as HubError).reason).toBe("unsupported")
    expect((await hubs.get("android-emulator:Ours")).capabilities).toEqual({ stop: true })
    await hubs.stop("android-emulator:Ours")
    expect((await alone.get("android-emulator:Here")).capabilities).toEqual({ stop: true })
    await alone.stop("android-emulator:Here")
    expect(stopped).toEqual(["android-emulator:Ours", "android-emulator:Here"])
  })

  // A typo in the deployment leaves the plugin up, without the Mac's hub, and says which variable is wrong.
  const secretish = "/Users/someone/private/hub.json"
  const configurations: [string, Record<string, string>, string | undefined][] = [
    ["neither variable: off, silently", {}, undefined],
    ["the socket without the command", { OPENCODE_RESOURCES_HUB_MAC_SOCKET: "/run/x.sock" }, "missing"],
    [
      "a command that is not a JSON argv",
      { OPENCODE_RESOURCES_HUB_MAC_SOCKET: "/run/x.sock", OPENCODE_RESOURCES_HUB_MAC_INFO_COMMAND: `cat ${secretish}` },
      "not a JSON array of strings",
    ],
    [
      "an empty argv",
      { OPENCODE_RESOURCES_HUB_MAC_SOCKET: "/run/x.sock", OPENCODE_RESOURCES_HUB_MAC_INFO_COMMAND: "[]" },
      "not a JSON array of strings",
    ],
    [
      "the command without the socket",
      { OPENCODE_RESOURCES_HUB_MAC_INFO_COMMAND: JSON.stringify(["cat", secretish]) },
      "without OPENCODE_RESOURCES_HUB_MAC_SOCKET",
    ],
  ]
  test.each(configurations)("misconfigured: %s", (_, env, problem) => {
    const found = macHubSettings(env)
    expect(found.settings).toBeUndefined()
    if (problem === undefined) return expect(found.problem).toBeUndefined()
    expect(found.problem).toContain(problem)
    expect(found.problem).not.toContain(secretish)
    expect(found.problem).not.toContain("/run/x.sock")
  })
})

async function waitFor(condition: () => boolean) {
  const deadline = Date.now() + 5_000
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition not met")
    await Bun.sleep(20)
  }
}
