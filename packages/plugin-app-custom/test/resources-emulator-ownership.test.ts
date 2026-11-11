import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import {
  AnotherEmulator,
  createAdapter,
  type AndroidSystem,
  type RunningEmulator,
} from "../src/resources/adapters/android-emulator"
import type { Adapter, Entry } from "../src/resources/adapters/types"
import { localCommand, onlyAsksAndroid, references, touchesResources } from "../src/resources/discovery"
import { createHub, type Lock } from "../src/resources/hub/hub"
import { blocking } from "../src/resources/lock"
import type { Resources } from "../src/resources/rpc"
import { labelTarget, usage, type Caller } from "../src/resources/usage"

/**
 * The emulators the registry gets wrong (diagnosed on 11/11): serials of another machine's emulator read as this Mac's,
 * read-only queries taking an emulator over, a label given by serial landing on whoever held the port, stopped entries
 * still captured, and no way to shut down a forgotten emulator. Fakes only: no adb, emulator or device is touched.
 */
const caller: Caller = {
  sessionID: "ses_frente_d",
  rootSessionID: "ses_onboarding",
  agent: "opushigh",
  title: "Frente D: apps sem passeio",
  rootTitle: "Onboarding",
}

describe("commands run on another machine", () => {
  test("their serials are that machine's, never this Mac's", () => {
    // The command that registered host-6's emulator as this Mac's emulator-5554.
    const host6 =
      "ssh -o BatchMode=yes -o ConnectTimeout=8 brs@host-6 'docker exec opencode-android-emulator adb -s emulator-5554 exec-out screencap -p' > /tmp/x.png"
    expect(references(host6)).toEqual([])
    expect(touchesResources(host6)).toBe(false)
    for (const command of [
      "ssh host-6 adb -s emulator-5554 shell ls",
      "timeout 20 ssh brs@host-6 'adb -s emulator-5554 shell ls'",
      "docker exec opencode-android-emulator adb -s emulator-5554 shell ls",
      "docker compose -f infra.yml exec emulator adb -s emulator-5554 shell ls",
      "podman run --rm img adb -s emulator-5554 devices",
      "kubectl exec -it pod -- adb -s emulator-5554 shell ls",
      "gcloud compute ssh vm -- adb -s emulator-5554 shell ls",
      "adb -H 10.0.0.5 -s emulator-5554 shell ls",
      "ANDROID_ADB_SERVER_ADDRESS=host-6 adb -s emulator-5554 shell ls",
      "ssh host-6 bash <<'EOF'\nadb -s emulator-5554 shell ls\nEOF",
    ])
      expect({ command, found: references(command) }).toEqual({ command, found: [] })
  })

  test("what runs here still counts, around and after the remote part", () => {
    const serial = (value: string) => [{ kind: "android-emulator" as const, serial: value }]
    expect(references("ssh host-6 'adb -s emulator-5554 shell ls'; adb -s emulator-5556 shell ls")).toEqual(
      serial("emulator-5556"),
    )
    expect(
      references("ssh host-6 bash <<'EOF'\nadb -s emulator-5554 shell ls\nEOF\nadb -s emulator-5558 shell ls"),
    ).toEqual(serial("emulator-5558"))
    // The Linux machine's `mac` prefix and loopback adb servers are this Mac.
    expect(references("mac adb -s emulator-5554 shell ls")).toEqual(serial("emulator-5554"))
    expect(references("adb -H 127.0.0.1 -s emulator-5554 shell ls")).toEqual(serial("emulator-5554"))
    expect(references("docker build . && adb -s emulator-5554 install app.apk")).toEqual(serial("emulator-5554"))
    expect(localCommand("echo 'a; ssh b' && adb devices")).toBe("echo 'a; ssh b' \n\n adb devices")
  })

  test("Alexandre's control of this Mac's emulator never refuses a command for another machine's", () => {
    const lock: Lock = {
      id: "android-emulator:Abacato_cosmic_knight",
      kind: "android-emulator",
      label: "Pixel 6 · Abacato cosmic knight",
      meta: { kind: "android-emulator", serial: "emulator-5554", avd: "Abacato_cosmic_knight" },
      expiresAt: 0,
    }
    expect(blocking(localCommand("ssh host-6 'adb -s emulator-5554 shell ls'"), [lock])).toBeUndefined()
    expect(blocking(localCommand("adb -s emulator-5554 shell ls"), [lock])).toBe(lock)
  })
})

describe("commands that only ask", () => {
  test("listing and naming emulators is not using them", () => {
    for (const command of [
      "adb devices",
      "adb devices -l | grep emulator",
      "adb -s emulator-5640 emu avd name",
      "adb -s emulator-5554 shell getprop ro.build.version.sdk",
      "emulator -list-avds",
      // Desembaraçar's check on 11/11, which made it the owner of two emulators it never used.
      `export ANDROID_HOME="$HOME/Library/Android/sdk" PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"; for s in emulator-5602 emulator-5640; do echo "$s: $(adb -s $s emu avd name 2>/dev/null | head -1 | tr -d '\\r')"; done; ls ~/.local/bin/android-emulator 2>/dev/null`,
    ])
      expect({ command, asks: onlyAsksAndroid(command) }).toEqual({ command, asks: true })
    for (const command of [
      "adb -s emulator-5554 install -r app.apk",
      "adb devices; adb -s emulator-5554 shell am start -n app/.Main",
      "adb -s emulator-5554 emu kill",
      "~/.local/bin/android-emulator --detach -avd Abacato_cosmic_knight -no-window",
      "echo nada",
    ])
      expect({ command, asks: onlyAsksAndroid(command) }).toEqual({ command, asks: false })
  })

  test("a query registers nothing; a use takes the emulator over; a start records who started it", () => {
    const android = { kind: "android-emulator", serial: "emulator-5640" } as const
    expect(usage("adb -s emulator-5640 emu avd name", android, caller, 10, true)).toBeUndefined()
    expect(usage("adb -s emulator-5640 shell am start -n app/.Main", android, caller, 10, true)).toEqual({
      owner: { sessionID: "ses_frente_d", rootSessionID: "ses_onboarding", agent: "opushigh" },
    })
    const start = "~/.local/bin/android-emulator --detach -avd Abacato_feat_pc_apps -no-window"
    const avd = { kind: "android-emulator", avd: "Abacato_feat_pc_apps" } as const
    expect(usage(start, avd, caller, 10, true)?.startedBy).toEqual({ ...caller, at: 10 })
    // Only once the start command completed; another AVD it does not start.
    expect(usage(start, avd, caller, 10, false)?.startedBy).toBeUndefined()
    expect(usage(start, { kind: "android-emulator", avd: "Outro" }, caller, 10, true)?.startedBy).toBeUndefined()
    // Simulators are not affected by Android queries.
    expect(
      usage("adb devices; xcrun simctl boot X", { kind: "ios-simulator", udid: "X" }, caller, 10, true),
    ).toBeDefined()
  })
})

const resource = (
  id: string,
  meta: Extract<Resources.Meta, { kind: "android-emulator" }>,
  state: Resources.State,
  label = id,
): Resources.Resource => ({
  id,
  kind: "android-emulator",
  label,
  state,
  meta,
  discoveredAt: 1,
  lastUsedAt: 1,
  updatedAt: 1,
  live: { stream: true, input: true },
})

describe("resource_label by serial", () => {
  const knight = resource(
    "android-emulator:Abacato_cosmic_knight",
    { kind: "android-emulator", serial: "emulator-5554", avd: "Abacato_cosmic_knight" },
    "agent",
    "Emulador do untangle (cosmic knight)",
  )

  test("refuses a serial an AVD with its own resource holds, naming the AVD to use", () => {
    // The host-6 label: a serial-only entry left from an earlier emulator, while cosmic knight holds the port.
    const stale = resource(
      "android-emulator:emulator-5554~2",
      { kind: "android-emulator", serial: "emulator-5554" },
      "gone",
    )
    const found = labelTarget([knight, stale], "emulator-5554")
    expect("refusal" in found && found.refusal).toContain("ref Abacato_cosmic_knight")
    expect("refusal" in found && found.refusal).toContain("another machine")
    // By its AVD it is named as before.
    expect(labelTarget([knight, stale], "Abacato_cosmic_knight")).toEqual({ resource: knight, bare: false })
  })

  test("refuses a serial no emulator answers on, and names one known only by a running serial", () => {
    const stale = resource(
      "android-emulator:emulator-5582",
      { kind: "android-emulator", serial: "emulator-5582" },
      "gone",
    )
    expect("refusal" in labelTarget([stale], "emulator-5582")).toBe(true)
    expect("refusal" in labelTarget([], "emulator-5590")).toBe(true)
    const fresh = resource(
      "android-emulator:emulator-5590",
      { kind: "android-emulator", serial: "emulator-5590" },
      "idle",
    )
    expect(labelTarget([fresh], "emulator-5590")).toEqual({ resource: fresh, bare: true })
  })
})

/** The outside world of the Android adapter: running emulators and their consoles; `emu kill` takes one away. */
function fakeAndroid() {
  const running: RunningEmulator[] = [
    { pid: 0, serial: "emulator-5602", consolePort: 5602, grpcPort: 8602, avd: "Abacato_feat_pc_apps" },
  ]
  const commands: string[] = []
  const io: AndroidSystem = {
    run: async () => new Uint8Array(0),
    text: async (command) => {
      const args = command.slice(1)
      commands.push(args.join(" "))
      const serial = args[1]
      if (args.slice(2).join(" ") === "emu avd name")
        return `${running.find((item) => item.serial === serial)?.avd ?? ""}\nOK\n`
      if (args.slice(2).join(" ") === "emu kill")
        running.splice(0, running.length, ...running.filter((item) => item.serial !== serial))
      return "OK\n"
    },
    connect: () => {
      throw new Error("no gRPC in these tests")
    },
    discovered: async () => running,
    emulators: async () => running,
    avdExists: async () => true,
  }
  return { io, running, commands }
}

const entry = (
  id: string,
  meta: Extract<Resources.Meta, { kind: "android-emulator" }>,
  status: Entry["status"] = "running",
): Entry => ({ id, kind: "android-emulator", meta, status, discoveredAt: 1, lastUsedAt: 1, updatedAt: 1 })

describe("shutting an emulator down", () => {
  test("the adapter proves the AVD on the serial before emu kill and waits for it to go", async () => {
    const fake = fakeAndroid()
    const adapter = createAdapter(fake.io)
    // Known only by serial: whose emulator answers there is not this entry's to say.
    await expect(
      adapter.stop!(entry("android-emulator:emulator-5602", { kind: "android-emulator", serial: "emulator-5602" })),
    ).rejects.toThrow()
    // Another AVD holds the serial now.
    await expect(
      adapter.stop!(
        entry("android-emulator:Outro", { kind: "android-emulator", serial: "emulator-5602", avd: "Outro" }),
      ),
    ).rejects.toBeInstanceOf(AnotherEmulator)
    expect(fake.commands.filter((command) => command.endsWith("emu kill"))).toEqual([])
    await adapter.stop!(
      entry("android-emulator:Abacato_feat_pc_apps", {
        kind: "android-emulator",
        serial: "emulator-5602",
        avd: "Abacato_feat_pc_apps",
      }),
    )
    expect(fake.commands.filter((command) => command.endsWith("emu kill"))).toEqual(["-s emulator-5602 emu kill"])
    expect(fake.running).toEqual([])
  })
})

const servers: { stop: (force?: boolean) => unknown }[] = []
const directories: string[] = []
afterEach(async () => {
  servers.splice(0).forEach((server) => server.stop(true))
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

/** A hub over the production Android adapter and the fake world, served on loopback. */
async function serveHub(clock: { value: number }) {
  const fake = fakeAndroid()
  const unused: Adapter = {
    kind: "ios-simulator",
    probe: async (entries) => new Map(entries.map((item) => [item.id, { status: "running" as const }])),
    snapshot: async () => ({ mime: "image/jpeg", data: new Uint8Array(0) }),
  }
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resources-ownership-"))
  directories.push(directory)
  const file = path.join(directory, "resources.json")
  const hub = createHub({
    adapters: {
      "ios-simulator": unused,
      "android-emulator": createAdapter(fake.io),
      chrome: { ...unused, kind: "chrome" },
    },
    secret: "s",
    file,
    now: () => clock.value,
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  servers.push(server)
  const admin = (route: string, init: RequestInit = {}) =>
    fetch(`http://127.0.0.1:${server.port}${route}`, {
      ...init,
      headers: { authorization: "Bearer s", "content-type": "application/json" },
    })
  return { hub, fake, admin, server, file }
}

const pcApps = "android-emulator:Abacato_feat_pc_apps"
const startedBy = { ...caller, at: 5 }

describe("hub", () => {
  test("keeps who started an emulator apart from its owner, persists it and drops it when it stops", async () => {
    const clock = { value: 10 }
    const { hub, fake, file } = await serveHub(clock)
    const meta = { kind: "android-emulator", avd: "Abacato_feat_pc_apps" } as const
    await hub.register({ kind: "android-emulator", meta, owner: caller, startedBy, used: true })
    const later = { sessionID: "ses_root", rootSessionID: "ses_root", agent: "build" }
    const used = await hub.register({ kind: "android-emulator", meta, owner: later, used: true })
    expect(used.owner).toEqual(later)
    expect(used.startedBy).toEqual(startedBy)
    await hub.probe()
    await Bun.sleep(400)
    const stored = JSON.parse(await fs.readFile(file, "utf8")) as { id: string; startedBy?: unknown }[]
    expect(stored.find((item) => item.id === pcApps)?.startedBy).toEqual(startedBy)
    fake.running.splice(0)
    await hub.probe()
    expect(hub.view(hub.entries.get(pcApps)!)).toMatchObject({ state: "stopped" })
    expect(hub.view(hub.entries.get(pcApps)!).startedBy).toBeUndefined()
  })

  test("a resource that is not running is neither captured nor streamed", async () => {
    const clock = { value: 10 }
    const { hub, admin, server } = await serveHub(clock)
    hub.entries.set(
      "android-emulator:emulator-5554~2",
      entry("android-emulator:emulator-5554~2", { kind: "android-emulator", serial: "emulator-5554" }, "gone"),
    )
    const snapshot = await admin(`/admin/resources/${encodeURIComponent("android-emulator:emulator-5554~2")}/snapshot`)
    expect(snapshot.status).toBe(409)
    expect(await snapshot.json()).toEqual({ reason: "gone" })
    const ticket = hub.ticket("android-emulator:emulator-5554~2", "view")!
    const ws = new WebSocket(
      `ws://127.0.0.1:${server.port}/resources/${encodeURIComponent("android-emulator:emulator-5554~2")}/stream?ticket=${ticket.ticket}`,
    )
    const messages: unknown[] = []
    await new Promise<void>((resolve) => {
      ws.onmessage = (event) => messages.push(JSON.parse(String(event.data)))
      ws.onclose = () => resolve()
    })
    expect(messages).toContainEqual({ type: "end", reason: "stopped" })
  })

  test("stops a free emulator of this Mac and refuses the rest", async () => {
    const clock = { value: 1_000_000 }
    const { hub, admin, fake } = await serveHub(clock)
    const stop = (id: string) => admin(`/admin/resources/${encodeURIComponent(id)}/stop`, { method: "POST" })
    const meta = { kind: "android-emulator", avd: "Abacato_feat_pc_apps" } as const
    await hub.register({ kind: "android-emulator", meta, owner: caller, startedBy, used: true })
    await hub.probe()
    expect((await stop("android-emulator:nada")).status).toBe(404)
    // Offered on an emulator known by its AVD (the app shows "Desligar" only then), never on a serial-only one.
    expect(hub.view(hub.entries.get(pcApps)!).capabilities).toEqual({ stop: true })
    hub.entries.set(
      "android-emulator:emulator-5590",
      entry("android-emulator:emulator-5590", { kind: "android-emulator", serial: "emulator-5590" }),
    )
    expect(hub.view(hub.entries.get("android-emulator:emulator-5590")!).capabilities).toBeUndefined()
    // In use by an agent a moment ago.
    const busy = await stop(pcApps)
    expect(busy.status).toBe(409)
    expect(await busy.json()).toEqual({ reason: "busy" })
    // Alexandre controls it.
    clock.value += 3_600_000
    await hub.control(pcApps, "take")
    expect(await (await stop(pcApps)).json()).toEqual({ reason: "busy" })
    await hub.control(pcApps, "release")
    // Free: shut down, and the probe that follows marks it stopped.
    expect((await stop(pcApps)).status).toBe(200)
    expect(fake.commands.filter((command) => command.endsWith("emu kill"))).toEqual(["-s emulator-5602 emu kill"])
    expect(hub.view(hub.entries.get(pcApps)!).state).toBe("stopped")
    expect(await (await stop(pcApps)).json()).toEqual({ reason: "gone" })
    // Other kinds have no stop.
    await hub.register({ kind: "ios-simulator", meta: { kind: "ios-simulator", udid: "SIM" }, owner: caller })
    expect(await (await stop("ios-simulator:SIM")).json()).toEqual({ reason: "unsupported" })
  })
})
