import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Adapter, Entry } from "../src/resources/adapters/types"
import { parseRunning } from "../src/resources/adapters/android-emulator"
import { parse } from "../src/resources/adapters/ios-simulator"
import { parseSimulators, references, resolveSimulators } from "../src/resources/discovery"
import { createHub, idFor, label, sameResource, type Lock } from "../src/resources/hub/hub"
import { links } from "../src/resources/index"
import { sign, verify } from "../src/resources/hub/ticket"
import { blocking, refusal, returned } from "../src/resources/lock"
import { ResourceProtocol } from "../src/resources/protocol"
import { Resources } from "../src/resources/rpc"
import { hubCommand, makeHubClient } from "../src/resources/supervisor"

const jpegPixel = Buffer.from(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AN//Z",
  "base64",
)

const udid = "4D3C2B1A-0000-4000-8000-000000000001"

function fakeAdapter() {
  const inputs: ResourceProtocol.Input[] = []
  const status = { value: "running" as Entry["status"] }
  const adapter: Adapter = {
    kind: "ios-simulator",
    probe: async (entries) => new Map(entries.map((entry) => [entry.id, { status: status.value }])),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array(jpegPixel), width: 1, height: 1 }),
    stream: async (_entry, sink, signal) => {
      sink.hello({ format: "jpeg", width: 1, height: 1 })
      sink.frame(new Uint8Array(jpegPixel), { capturedAt: 1 })
      await new Promise((resolve) => signal.addEventListener("abort", resolve))
    },
    input: async (_entry, event) => void inputs.push(event),
  }
  return { adapter, inputs, status }
}

const servers: { stop: (force?: boolean) => unknown }[] = []
afterEach(() => servers.splice(0).forEach((server) => server.stop(true)))

function serve(clock: { value: number }) {
  const fake = fakeAdapter()
  const hub = createHub({
    adapters: { "ios-simulator": fake.adapter, "android-emulator": fake.adapter, chrome: fake.adapter },
    secret: "test-secret",
    now: () => clock.value,
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  servers.push(server)
  const admin = (route: string, init: RequestInit = {}) =>
    fetch(`http://127.0.0.1:${server.port}${route}`, {
      ...init,
      headers: { authorization: "Bearer test-secret", "content-type": "application/json" },
    })
  return { hub, server, fake, admin }
}

function socket(url: string) {
  const ws = new WebSocket(url)
  ws.binaryType = "arraybuffer"
  const messages: (ResourceProtocol.ServerMessage | Uint8Array)[] = []
  const waiters: (() => void)[] = []
  ws.onmessage = (event) => {
    messages.push(typeof event.data === "string" ? JSON.parse(event.data) : new Uint8Array(event.data))
    waiters.splice(0).forEach((wake) => wake())
  }
  const next = async (predicate: (message: ResourceProtocol.ServerMessage | Uint8Array) => boolean) => {
    const deadline = Date.now() + 5_000
    while (Date.now() < deadline) {
      const found = messages.find(predicate)
      if (found) return found
      await new Promise<void>((resolve) => {
        waiters.push(resolve)
        setTimeout(resolve, 100)
      })
    }
    throw new Error("message not received")
  }
  return { ws, messages, next, opened: new Promise((resolve) => (ws.onopen = resolve)) }
}

describe("resources contract", () => {
  test("publishes the custom.resources RPC and its limits", () => {
    expect(Resources.Definition.id).toBe("custom.resources")
    expect(Object.keys(Resources.Definition.methods)).toEqual([
      "list",
      "get",
      "snapshot",
      "ticket",
      "control",
      "dismiss",
    ])
    expect(Object.keys(Resources.Definition.events)).toEqual(["changed"])
    expect(Resources.limits.controlIdleMs).toBe(120_000)
  })

  test("frames carry version, keyframe flag and capture time", () => {
    const frame = ResourceProtocol.encodeFrame(new Uint8Array([7, 8]), 1234.5, true)
    expect(ResourceProtocol.decodeFrame(frame)).toEqual({
      keyframe: true,
      capturedAt: 1234.5,
      payload: new Uint8Array([7, 8]),
    })
    expect(ResourceProtocol.decodeFrame(new Uint8Array([2, 0]))).toBeUndefined()
  })

  test("labels follow the kind's metadata", () => {
    expect(label({ meta: { kind: "ios-simulator", udid, name: "OpenCode Salto Turno", device: "iPhone 17" } })).toBe(
      "iPhone 17 · OpenCode Salto Turno",
    )
    expect(label({ meta: { kind: "android-emulator", avd: "abacato_v2", device: "Pixel 9" } })).toBe(
      "Pixel 9 · abacato v2",
    )
    expect(label({ meta: { kind: "chrome", session: "login", url: "http://localhost:5173/login" } })).toBe(
      "localhost:5173/login",
    )
    expect(label({ name: "Login", meta: { kind: "chrome", session: "login" } })).toBe("Login")
  })
})

describe("tickets", () => {
  test("verify only the signed resource before expiry", () => {
    const ticket = sign("secret", { r: "chrome:a", c: "control", e: 2_000, l: "lock" })
    expect(verify("secret", ticket, "chrome:a", 1_000)).toEqual({ r: "chrome:a", c: "control", e: 2_000, l: "lock" })
    expect(verify("secret", ticket, "chrome:b", 1_000)).toBeUndefined()
    expect(verify("secret", ticket, "chrome:a", 3_000)).toBeUndefined()
    expect(verify("other", ticket, "chrome:a", 1_000)).toBeUndefined()
    const [payload, signature] = ticket.split(".")
    const forged = Buffer.from(JSON.stringify({ r: "chrome:a", c: "control", e: 9_999 })).toString("base64url")
    expect(verify("secret", `${forged}.${signature}`, "chrome:a", 1_000)).toBeUndefined()
    expect(verify("secret", `${payload}`, "chrome:a", 1_000)).toBeUndefined()
  })
})

describe("control lock", () => {
  const simulator: Lock = {
    id: `ios-simulator:${udid}`,
    kind: "ios-simulator",
    label: "iPhone 17 · OpenCode Teste",
    meta: { kind: "ios-simulator", udid, name: "OpenCode Teste" },
    expiresAt: 0,
  }
  const emulator: Lock = {
    id: "android-emulator:Pixel_9",
    kind: "android-emulator",
    label: "Pixel 9",
    meta: { kind: "android-emulator", serial: "emulator-5554", avd: "Pixel_9" },
    expiresAt: 0,
  }
  const browser: Lock = {
    id: "chrome:login",
    kind: "chrome",
    label: "localhost:5173/login",
    meta: { kind: "chrome", session: "login", cdp: "http://127.0.0.1:9333" },
    expiresAt: 0,
  }
  const locks = [simulator, emulator, browser]

  test("refuses commands naming or implicitly targeting a locked resource", () => {
    expect(blocking(`xcrun simctl io ${udid} screenshot a.png`, locks)).toBe(simulator)
    expect(blocking(`agent-device press --udid ${udid} 10 10`, locks)).toBe(simulator)
    expect(blocking(`xcrun simctl boot "OpenCode Teste"`, locks)).toBe(simulator)
    expect(blocking("xcrun simctl openurl booted https://x", locks)).toBe(simulator)
    expect(blocking("adb -s emulator-5554 shell input tap 1 1", locks)).toBe(emulator)
    expect(blocking("adb shell input tap 1 1", locks)).toBe(emulator)
    expect(blocking("emulator -avd Pixel_9 -no-window", locks)).toBe(emulator)
    expect(blocking("playwright-cli -s=login click e3", locks)).toBe(browser)
    expect(blocking("curl http://127.0.0.1:9333/json", locks)).toBe(browser)
  })

  test("lets unrelated commands through", () => {
    expect(blocking("xcrun simctl list devices", locks)).toBeUndefined()
    expect(blocking(`xcrun simctl io ${udid}X screenshot a.png`, locks)).toBeUndefined()
    expect(blocking("adb -s emulator-5556 shell ls", locks)).toBeUndefined()
    expect(blocking("emulator -avd Pixel_9_Pro", locks)).toBeUndefined()
    expect(blocking("playwright-cli -s=login2 click e3", locks)).toBeUndefined()
    expect(blocking("playwright-cli click e3", locks)).toBeUndefined()
    expect(blocking("curl http://127.0.0.1:93330/json", locks)).toBeUndefined()
    expect(blocking("git status", [])).toBeUndefined()
  })

  test("names the resource in refusals and hand-back notices", () => {
    expect(refusal(simulator)).toContain("Alexandre está usando o simulador iOS iPhone 17 · OpenCode Teste; aguarde")
    expect(returned({ kind: "chrome", label: "localhost:5173/login", reason: "returned" })).toContain(
      "Alexandre interagiu com o Chrome localhost:5173/login e devolveu o controle",
    )
    expect(returned({ kind: "chrome", label: "x", reason: "expired" })).toContain("2 minutos sem toque")
  })
})

describe("hub", () => {
  test("registers, derives state and serves snapshots only with a ticket", async () => {
    const clock = { value: 1_000_000 }
    const { hub, admin, server } = serve(clock)
    const created = await (
      await admin("/admin/resources", {
        method: "PUT",
        body: JSON.stringify({
          kind: "ios-simulator",
          meta: { kind: "ios-simulator", udid, device: "iPhone 17", name: "OpenCode Teste" },
          owner: { sessionID: "ses_child", rootSessionID: "ses_root", agent: "explore" },
          used: true,
        }),
      })
    ).json()
    expect(created).toMatchObject({ id: `ios-simulator:${udid}`, label: "iPhone 17 · OpenCode Teste", state: "agent" })
    expect(created.live).toEqual({ stream: true, input: true })
    // The same UDID updates the entry instead of adding another.
    await admin("/admin/resources", {
      method: "PUT",
      body: JSON.stringify({ kind: "ios-simulator", meta: { kind: "ios-simulator", udid, runtime: "iOS 27.0" } }),
    })
    clock.value += Resources.limits.agentRecentMs
    const listed = (await (await admin("/admin/resources")).json()).resources
    expect(listed).toHaveLength(1)
    expect(listed[0]).toMatchObject({
      state: "live",
      owner: { rootSessionID: "ses_root" },
      meta: { runtime: "iOS 27.0", name: "OpenCode Teste" },
    })
    clock.value += Resources.limits.liveRecentMs
    expect((await (await admin(`/admin/resources/${encodeURIComponent(created.id)}`)).json()).state).toBe("idle")

    const base = `http://127.0.0.1:${server.port}/resources/${encodeURIComponent(created.id)}`
    expect((await fetch(`${base}/snapshot`)).status).toBe(401)
    expect((await fetch(`http://127.0.0.1:${server.port}/admin/resources`)).status).toBe(401)
    const view = hub.ticket(created.id, "view")
    const image = await fetch(`${base}/snapshot?ticket=${view?.ticket}`)
    expect(image.headers.get("content-type")).toBe("image/jpeg")
    expect(new Uint8Array(await image.arrayBuffer())).toEqual(new Uint8Array(jpegPixel))
    expect(hub.ticket(created.id, "control")).toBeUndefined()
  })

  test("streams to viewers, accepts input only under control and reports hand-back", async () => {
    const clock = { value: 1_000_000 }
    const { hub, server, fake, admin } = serve(clock)
    const resource = hub.upsert({
      kind: "ios-simulator",
      meta: { kind: "ios-simulator", udid },
      owner: { sessionID: "ses_child", rootSessionID: "ses_root" },
    })
    await hub.claim(0)
    const base = `ws://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}/stream`
    const viewer = socket(`${base}?ticket=${hub.ticket(resource.id, "view")?.ticket}`)
    await viewer.opened
    expect(
      await viewer.next((message) => !(message instanceof Uint8Array) && message.type === "control"),
    ).toMatchObject({
      holder: null,
    })
    expect(await viewer.next((message) => !(message instanceof Uint8Array) && message.type === "hello")).toMatchObject({
      format: "jpeg",
    })
    const frame = await viewer.next((message) => message instanceof Uint8Array)
    expect(ResourceProtocol.decodeFrame(frame as Uint8Array)?.payload).toEqual(new Uint8Array(jpegPixel))
    viewer.ws.send(JSON.stringify({ type: "ping", t: 5 }))
    expect(await viewer.next((message) => !(message instanceof Uint8Array) && message.type === "pong")).toMatchObject({
      t: 5,
    })
    viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "touch", phase: "began", x: 0.5, y: 0.5 }] }))
    expect(await viewer.next((message) => !(message instanceof Uint8Array) && message.type === "error")).toMatchObject({
      message: "not_in_control",
    })

    const taken = await (
      await admin(`/admin/resources/${encodeURIComponent(resource.id)}/control`, {
        method: "POST",
        body: JSON.stringify({ action: "take" }),
      })
    ).json()
    expect(taken.resource.state).toBe("user")
    expect(taken.resource.control.expiresAt).toBe(clock.value + Resources.limits.controlIdleMs)
    const locks = (await (await admin("/admin/locks")).json()).locks
    expect(locks).toMatchObject([{ id: resource.id, kind: "ios-simulator" }])
    const control = socket(`${base}?ticket=${hub.ticket(resource.id, "control")?.ticket}`)
    await control.opened
    expect(
      await control.next((message) => !(message instanceof Uint8Array) && message.type === "control"),
    ).toMatchObject({
      holder: "user",
      mine: true,
    })
    control.ws.send(
      JSON.stringify({
        type: "input",
        events: [
          { type: "touch", phase: "began", x: 0.25, y: 0.75 },
          { type: "text", text: "segredo" },
        ],
      }),
    )
    const deadline = Date.now() + 5_000
    while (fake.inputs.length < 2 && Date.now() < deadline) await Bun.sleep(10)
    expect(fake.inputs).toEqual([
      { type: "touch", phase: "began", x: 0.25, y: 0.75 },
      { type: "text", text: "segredo" },
    ])

    // Two minutes after the last input, control returns and one hand-back event is queued.
    await hub.claim(0)
    clock.value += Resources.limits.controlIdleMs
    hub.expire()
    expect(
      await viewer.next(
        (message) =>
          !(message instanceof Uint8Array) &&
          message.type === "control" &&
          message.holder === null &&
          viewer.messages.filter((item) => !(item instanceof Uint8Array) && item.type === "control").length > 1,
      ),
    ).toBeDefined()
    const events = await hub.claim(0)
    expect(events).toContainEqual({
      type: "released",
      id: resource.id,
      kind: "ios-simulator",
      label: resource.label,
      owner: { sessionID: "ses_child", rootSessionID: "ses_root" },
      reason: "expired",
    })
    expect(await hub.claim(0)).toEqual([])
    viewer.ws.close()
    control.ws.close()
  })

  test("probe marks dead resources and persists the registry", async () => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-resources-"))
    try {
      const fake = fakeAdapter()
      const file = path.join(directory, "resources.json")
      const options = {
        adapters: { "ios-simulator": fake.adapter, "android-emulator": fake.adapter, chrome: fake.adapter },
        secret: "s",
        file,
      }
      const first = createHub(options)
      const resource = first.upsert({ kind: "ios-simulator", meta: { kind: "ios-simulator", udid } })
      fake.status.value = "gone"
      await first.probe()
      expect(first.view(first.entries.get(resource.id)!).state).toBe("gone")
      const deadline = Date.now() + 5_000
      while (!(await Bun.file(file).exists()) && Date.now() < deadline) await Bun.sleep(20)
      await Bun.sleep(50)
      const second = createHub(options)
      await second.start()
      second.close()
      expect(second.entries.get(resource.id)?.status).toBe("gone")
    } finally {
      await fs.rm(directory, { recursive: true, force: true })
    }
  })
})

describe("hub process", () => {
  test("starts once per state directory and answers the plugin client", async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-resources-hub-"))
    // The plugin creates the state directory before the hub writes its log there.
    const state = path.join(root, "state", "resources-hub")
    const command = hubCommand(path.join(import.meta.dir, "../src/resources/supervisor.ts"))
    expect(command[1]).toEndWith("hub/bin.ts")
    const clients = [makeHubClient({ state, command }), makeHubClient({ state, command })]
    try {
      expect(await clients[0]!.locks()).toEqual([])
      const [first, second] = await Promise.all(clients.map((client) => client.list()))
      expect(first).toEqual({ resources: [] })
      expect(second).toEqual({ resources: [] })
      const info = await Bun.file(path.join(state, "hub.json")).json()
      expect((await fs.stat(path.join(state, "hub.json"))).mode & 0o777).toBe(0o600)
      expect(await clients[1]!.port()).toBe(info.port)
      const ticket = await clients[0]!.ticket("missing", "view").catch((error: Error) => error)
      expect(ticket).toBeInstanceOf(Error)
    } finally {
      const info = await Bun.file(path.join(state, "hub.json"))
        .json()
        .catch(() => undefined)
      if (info) process.kill(info.pid, "SIGTERM")
      await Bun.sleep(200)
      await fs.rm(root, { recursive: true, force: true })
    }
  }, 15_000)
})

describe("adapter parsing", () => {
  test("reads simulators and running emulators", () => {
    expect(
      parse({
        devices: {
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {
              udid,
              name: "OpenCode Teste",
              state: "Booted",
              deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            },
          ],
        },
      }),
    ).toEqual([{ udid, name: "OpenCode Teste", state: "Booted", device: "iPhone 17 Pro", runtime: "iOS 27.0" }])
    expect(parseRunning("pid=0\nport.serial=5556\nport.adb=5557\navd.name=Pixel_9\ngrpc.port=8556\n")).toEqual({
      pid: 0,
      serial: "emulator-5556",
      consolePort: 5556,
      grpcPort: 8556,
      avd: "Pixel_9",
    })
  })
})

describe("discovery", () => {
  const sim = "77441AC7-5092-422F-8223-B53AC7973439"
  test("finds simulators, emulators and Playwright browsers named by commands", () => {
    expect(references(`xcrun simctl io ${sim.toLowerCase()} screenshot a.png`)).toEqual([
      { kind: "ios-simulator", udid: sim },
    ])
    expect(references(`xcodebuild test -destination 'platform=iOS Simulator,name=OpenCode Teste,OS=27.0'`)).toEqual([
      { kind: "ios-simulator", name: "OpenCode Teste" },
    ])
    expect(references(`xcrun simctl boot "OpenCode Teste"`)).toEqual([
      { kind: "ios-simulator", name: "OpenCode Teste" },
    ])
    expect(
      references(`xcrun simctl create "Novo" com.apple.CoreSimulator.SimDeviceType.iPhone-17`, `${sim}\n`),
    ).toEqual([{ kind: "ios-simulator", udid: sim }])
    expect(references(`npx -y agent-device snapshot --platform ios --udid ${sim}`)).toEqual([
      { kind: "ios-simulator", udid: sim },
    ])
    expect(references("adb -s emulator-5554 shell input tap 10 10")).toEqual([
      { kind: "android-emulator", serial: "emulator-5554" },
    ])
    expect(references("~/.local/bin/android-emulator -avd abacato_v2 -no-window")).toEqual([
      { kind: "android-emulator", avd: "abacato_v2" },
    ])
    expect(references("emulator @Pixel_9 -no-snapshot")).toEqual([{ kind: "android-emulator", avd: "Pixel_9" }])
    expect(references("playwright-cli -s=login open http://localhost:5173 --browser=chrome", "", "/w/app")).toEqual([
      { kind: "chrome", session: "login", workspace: "/w/app" },
    ])
    expect(references("playwright-cli click e3", "", "/w/app")).toEqual([
      { kind: "chrome", session: "default", workspace: "/w/app" },
    ])
  })

  test("ignores listings, teardown, physical devices and unrelated UUIDs", () => {
    expect(references("xcrun simctl list devices")).toEqual([])
    expect(references(`xcrun simctl delete ${sim}`)).toEqual([])
    expect(references("xcrun simctl io booted screenshot a.png")).toEqual([])
    expect(references(`echo ${sim}`)).toEqual([])
    expect(references("adb -s d8cf6fc2 shell ls")).toEqual([])
    expect(references("xcrun devicectl device info details --device 00008110-00065DA13A78401E")).toEqual([])
    expect(references("playwright-cli list")).toEqual([])
    expect(references("playwright-cli -s=login close")).toEqual([])
  })

  test("resolves simulator names, skips ambiguous ones and drops unknown UDIDs", () => {
    const simulators = parseSimulators({
      devices: {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          { udid: sim.toLowerCase(), name: "OpenCode Teste", state: "Shutdown" },
          { udid: "77441AC7-5092-422F-8223-B53AC7973430", name: "OpenCode Teste", state: "Booted" },
          { udid: "77441AC7-5092-422F-8223-B53AC7973431", name: "Duplicado", state: "Booted" },
          { udid: "77441AC7-5092-422F-8223-B53AC7973432", name: "Duplicado", state: "Booted" },
        ],
      },
    })
    expect(
      resolveSimulators(
        [
          { kind: "ios-simulator", name: "OpenCode Teste" },
          { kind: "ios-simulator", name: "Duplicado" },
          { kind: "ios-simulator", udid: sim },
          { kind: "ios-simulator", udid: "00000000-0000-4000-8000-000000000000" },
          { kind: "chrome", session: "login", cdp: "http://127.0.0.1:9333" },
        ],
        simulators,
      ),
    ).toEqual([
      { kind: "ios-simulator", udid: "77441AC7-5092-422F-8223-B53AC7973430", name: "OpenCode Teste" },
      { kind: "ios-simulator", udid: sim, name: "OpenCode Teste" },
      { kind: "chrome", session: "login", cdp: "http://127.0.0.1:9333" },
    ])
  })

  test("links open the resource in the app and default Playwright sessions stay per worktree", () => {
    expect(links([{ id: `ios-simulator:${sim}`, kind: "ios-simulator", label: "iPhone 17 · X" }])).toBe(
      `Recurso no app: [Simulador iOS · iPhone 17 · X](opencode-resource:ios-simulator%3A${sim})`,
    )
    expect(idFor({ kind: "chrome", session: "default", workspace: "/w/app-a" })).toBe("chrome:default@app-a")
    expect(
      sameResource(
        { kind: "chrome", session: "default", workspace: "/w/a" },
        { kind: "chrome", session: "default", workspace: "/w/b" },
      ),
    ).toBe(false)
    expect(
      sameResource(
        { kind: "chrome", session: "login" },
        { kind: "chrome", session: "login", cdp: "http://127.0.0.1:1" },
      ),
    ).toBe(true)
    const lock: Lock = {
      id: "chrome:default@a",
      kind: "chrome",
      label: "x",
      meta: { kind: "chrome", session: "default", workspace: "/w/a" },
      expiresAt: 0,
    }
    expect(blocking("playwright-cli click e1", [lock], "/w/a")).toBe(lock)
    expect(blocking("playwright-cli click e1", [lock], "/w/b")).toBeUndefined()
  })
})
