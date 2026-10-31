import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { references, touchesResources } from "../src/resources/discovery"
import { protocol, type Lock } from "../src/resources/hub/hub"
import { blocking } from "../src/resources/lock"
import type { Resources } from "../src/resources/rpc"
import { hubCommand, hubSettings, HubError, makeHubClient, pathMap } from "../src/resources/supervisor"

const udid = "4D3C2B1A-0000-4000-8000-000000000001"
const roots: string[] = []
const servers: { stop: (force?: boolean) => unknown }[] = []

afterEach(async () => {
  servers.splice(0).forEach((server) => server.stop(true))
  await Promise.all(roots.splice(0).map((root) => fs.rm(root, { recursive: true, force: true })))
})

const map = "/home/u/=/Users/u/OrbStack/dev/home/u/"

describe("path map", () => {
  test("translates working directories by prefix, both ways, and leaves others alone", () => {
    const paths = pathMap(`${map}:/srv=/Volumes/srv`)
    expect(paths.toHub("/home/u/app")).toBe("/Users/u/OrbStack/dev/home/u/app")
    expect(paths.toHub("/home/u")).toBe("/Users/u/OrbStack/dev/home/u")
    expect(paths.toHub("/home/user2/app")).toBe("/home/user2/app")
    expect(paths.toHub("/srv/x")).toBe("/Volumes/srv/x")
    expect(paths.toHub("/Users/u/Dev/app")).toBe("/Users/u/Dev/app")
    expect(paths.fromHub("/Users/u/OrbStack/dev/home/u/app")).toBe("/home/u/app")
    expect(paths.fromHub("/Users/u/Dev/app")).toBe("/Users/u/Dev/app")
    expect(pathMap("garbage:=x:y=").toHub("/home/u")).toBe("/home/u")
  })

  test("remote mode comes only from the new variables", () => {
    expect(hubSettings({ XDG_STATE_HOME: "/state" })).toEqual({ state: "/state/opencode/resources-hub" })
    const settings = hubSettings({
      XDG_STATE_HOME: "/state",
      OPENCODE_RESOURCES_HUB_REMOTE_INFO: "/Users/u/hub/state/hub.json",
      OPENCODE_RESOURCES_HUB_REMOTE_HOST: "host.orb.internal",
      OPENCODE_RESOURCES_HUB_PATH_MAP: map,
    })
    expect(settings.remote).toEqual({ info: "/Users/u/hub/state/hub.json", host: "host.orb.internal" })
    expect(settings.paths?.toHub("/home/u/x")).toBe("/Users/u/OrbStack/dev/home/u/x")
    expect(hubSettings({ OPENCODE_RESOURCES_HUB_REMOTE_INFO: "/x/hub.json" }).remote?.host).toBe("127.0.0.1")
  })

  test("validates a host-side discovery command without interpreting it through a shell", () => {
    const command = ["mac", "/mnt/mac/bin/cat", "/mnt/mac/Users/u/hub.json"]
    expect(
      hubSettings({
        OPENCODE_RESOURCES_HUB_REMOTE_INFO: "/Users/u/hub.json",
        OPENCODE_RESOURCES_HUB_REMOTE_INFO_COMMAND: JSON.stringify(command),
      }).remote?.command,
    ).toEqual(command)
    for (const value of ["[]", "[1]", "not json"])
      expect(() => hubSettings({ OPENCODE_RESOURCES_HUB_REMOTE_INFO_COMMAND: value })).toThrow()
  })
})

describe("commands run on the Mac with `mac`", () => {
  test("still name their resources", () => {
    expect(references("mac playwright-cli -s=foo open https://x", "", "/home/u/app")).toEqual([
      { kind: "chrome", session: "foo", workspace: "/home/u/app" },
    ])
    expect(references(`mac npx -y agent-device --platform ios --udid ${udid} snapshot`)).toEqual([
      { kind: "ios-simulator", udid },
    ])
    expect(references(`mac xcrun simctl boot ${udid}`)).toEqual([{ kind: "ios-simulator", udid }])
    expect(references(`mac xcrun simctl boot "OpenCode Teste"`)).toEqual([
      { kind: "ios-simulator", name: "OpenCode Teste" },
    ])
    expect(references("mac npx -y agent-device --serial emulator-5554 snapshot")).toEqual([
      { kind: "android-emulator", serial: "emulator-5554" },
    ])
    expect(references("mac emulator -avd Pixel_9 -no-window")).toEqual([{ kind: "android-emulator", avd: "Pixel_9" }])
    for (const command of ["mac playwright-cli list-sessions", "mac npx -y agent-device devices", "mac adb devices"])
      expect(touchesResources(command)).toBe(true)
    expect(touchesResources("mac open -a Finder")).toBe(false)
  })

  test("are refused on locked resources, explicit or implicit", () => {
    const simulator: Lock = {
      id: `ios-simulator:${udid}`,
      kind: "ios-simulator",
      label: "OpenCode Teste",
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
      id: "chrome:default",
      kind: "chrome",
      label: "default",
      meta: { kind: "chrome", session: "default", workspace: "/home/u/app" },
      expiresAt: 0,
    }
    const locks = [simulator, emulator, browser]
    expect(blocking(`mac xcrun simctl boot ${udid}`, locks)).toBe(simulator)
    expect(blocking("mac xcrun simctl openurl booted https://x", locks)).toBe(simulator)
    expect(blocking(`mac npx -y agent-device press --udid ${udid} 1 1`, locks)).toBe(simulator)
    expect(blocking("mac adb shell input tap 1 1", locks)).toBe(emulator)
    expect(blocking("mac playwright-cli snapshot", locks, "/home/u/app")).toBe(browser)
    expect(blocking("mac playwright-cli -s=other snapshot", locks, "/home/u/app")).toBeUndefined()
  })
})

/** A hub on "another machine": a fake admin API whose secret and port can change, as a restarted hub's do. */
async function fakeHub() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-remote-hub-"))
  roots.push(root)
  const info = path.join(root, "Users/u/hub/state/hub.json")
  const state = {
    secret: "first",
    protocol,
    hosts: [] as string[],
    shutdowns: 0,
    upserts: [] as unknown[],
    resources: [] as Resources.Resource[],
    /** Routes the hub accepts but never answers, as a wedged hub does. */
    hang: [] as string[],
  }
  const resource = (meta: Resources.Meta): Resources.Resource => ({
    id: `${meta.kind}:x`,
    kind: meta.kind,
    label: "x",
    state: "agent",
    meta,
    discoveredAt: 1,
    lastUsedAt: 1,
    updatedAt: 1,
    live: { stream: true, input: true },
  })
  const serve = () =>
    Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      async fetch(request) {
        state.hosts.push(new URL(request.url).hostname)
        if (request.headers.get("authorization") !== `Bearer ${state.secret}`)
          return new Response(null, { status: 401 })
        const route = new URL(request.url).pathname
        if (state.hang.includes(route)) return new Promise<Response>(() => {})
        if (route === "/admin/health") return Response.json({ protocol: state.protocol, pid: 1 })
        if (route === "/admin/shutdown") {
          state.shutdowns++
          return Response.json({})
        }
        if (route === "/admin/simulators")
          return Response.json({ simulators: [{ udid, name: "OpenCode Teste", booted: true }] })
        if (route === "/admin/locks")
          return Response.json({
            locks: state.resources.map((item) => ({ ...item, expiresAt: 0 })),
          })
        if (route === "/admin/resources" && request.method === "PUT") {
          const body = (await request.json()) as { meta: Resources.Meta }
          state.upserts.push(body)
          const created = resource(body.meta)
          state.resources = [created]
          return Response.json(created)
        }
        if (route === "/admin/resources") return Response.json({ resources: state.resources })
        return new Response(null, { status: 404 })
      },
    })
  const announce = async (port: number) => {
    await Bun.write(info, JSON.stringify({ protocol, pid: 999_999_999, port, secret: state.secret }))
  }
  return { root, info, state, serve, announce }
}

describe("remote hub client", () => {
  test("discovers through a command and follows secret rotation without opening the shared info path", async () => {
    const hub = await fakeHub()
    const server = hub.serve()
    servers.push(server)
    await hub.announce(server.port!)
    const client = makeHubClient({
      state: path.join(hub.root, "local-state"),
      remote: {
        info: "/unmounted/Users/u/hub.json",
        host: "localhost",
        command: [process.execPath, "-e", "process.stdout.write(await Bun.file(process.argv[1]).text())", hub.info],
      },
    })
    expect(await client.locks()).toEqual([])
    hub.state.secret = "rotated"
    await hub.announce(server.port!)
    expect(await client.list()).toEqual({ resources: [] })
    expect(await client.port()).toBe(server.port!)
  })

  test("a failed or stalled command never falls back to a readable shared info file", async () => {
    const hub = await fakeHub()
    const server = hub.serve()
    servers.push(server)
    await hub.announce(server.port!)
    for (const script of ["process.exit(1)", "setInterval(() => {}, 1000)"])
      expect(
        await makeHubClient({
          state: path.join(hub.root, "local-state"),
          remote: { info: hub.info, host: "localhost", command: [process.execPath, "-e", script] },
          timeout: 100,
        }).locks(),
      ).toBeUndefined()
    expect(hub.state.hosts).toEqual([])
  })

  test("never starts or stops the hub, reaches it on the remote host and follows a restart", async () => {
    const hub = await fakeHub()
    const marker = path.join(hub.root, "spawned")
    const client = makeHubClient({
      state: path.join(hub.root, "local-state"),
      command: ["/bin/sh", "-c", `touch ${marker}`],
      remote: { info: hub.info, host: "localhost" },
      paths: pathMap(map),
    })
    expect(client.remote).toBe(true)

    // No hub.json yet: unavailable, nothing spawned, no lock answer.
    const missing = await client.list().catch((error: unknown) => error)
    expect(missing).toBeInstanceOf(HubError)
    expect((missing as HubError).reason).toBe("hub")
    expect((missing as HubError).message).toContain(hub.info)
    expect(await client.locks()).toBeUndefined()
    expect(await client.port()).toBeUndefined()
    await Bun.sleep(100)
    expect(await Bun.file(marker).exists()).toBe(false)

    const first = hub.serve()
    servers.push(first)
    await hub.announce(first.port!)
    expect(await client.list(false)).toEqual({ resources: [] })
    expect(await client.port()).toBe(first.port!)
    expect(hub.state.hosts.every((host) => host === "localhost")).toBe(true)

    // Working directories go to the hub as the Mac sees them and come back as this machine does.
    const created = await client.upsert({
      kind: "chrome",
      meta: { kind: "chrome", session: "default", workspace: "/home/u/app" },
      used: true,
    })
    expect(hub.state.upserts).toEqual([
      {
        kind: "chrome",
        meta: { kind: "chrome", session: "default", workspace: "/Users/u/OrbStack/dev/home/u/app" },
        used: true,
      },
    ])
    expect(created.meta).toEqual({ kind: "chrome", session: "default", workspace: "/home/u/app" })
    expect((await client.list()).resources[0]!.meta).toEqual(created.meta)
    expect((await client.locks())?.[0]!.meta).toEqual(created.meta)
    expect(await client.simulators()).toEqual([{ udid, name: "OpenCode Teste", booted: true }])

    // A restarted hub: new secret on a new port. The old one refuses; hub.json is read again.
    hub.state.secret = "second"
    const second = hub.serve()
    servers.push(second)
    first.stop(true)
    await hub.announce(second.port!)
    expect(await client.list()).toEqual({
      resources: hub.state.resources.map((item) => ({ ...item, meta: created.meta })),
    })
    expect(await client.port()).toBe(second.port!)

    // Another protocol is left alone: no shutdown, no spawn, just unavailable.
    hub.state.protocol = protocol + 1
    hub.state.secret = "third"
    await hub.announce(second.port!)
    await expect(client.list()).rejects.toBeInstanceOf(HubError)
    expect(hub.state.shutdowns).toBe(0)
    expect(await Bun.file(marker).exists()).toBe(false)
  })

  test("a hub that accepts but never answers leaves shells waiting only for the admin deadline", async () => {
    const hub = await fakeHub()
    const server = hub.serve()
    servers.push(server)
    await hub.announce(server.port!)
    const client = makeHubClient({
      state: path.join(hub.root, "local-state"),
      remote: { info: hub.info, host: "localhost" },
      timeout: 300,
    })
    expect(await client.locks()).toEqual([])

    // Cached and healthy until now: the lock read is bounded and unanswered (`undefined` makes the shell warn).
    hub.state.hang = ["/admin/locks", "/admin/resources"]
    let started = Date.now()
    expect(await client.locks()).toBeUndefined()
    expect(Date.now() - started).toBeLessThan(1_500)
    started = Date.now()
    expect(await client.list(false).catch((error: unknown) => error)).toBeInstanceOf(HubError)
    expect(Date.now() - started).toBeLessThan(1_500)

    // A hub whose health check hangs too is dropped after the health deadline, never retried at once.
    hub.state.hang.push("/admin/health")
    started = Date.now()
    expect(await client.locks()).toBeUndefined()
    expect(Date.now() - started).toBeLessThan(2_500)

    hub.state.hang = []
    expect(await client.locks()).toEqual([])
  })
})

describe("standalone hub", () => {
  test("runs without a parent, writes its Playwright config and stops on SIGTERM", async () => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-standalone-hub-"))
    roots.push(root)
    const state = path.join(root, "state")
    const env: Record<string, string | undefined> = { ...process.env, OPENCODE_RESOURCES_HUB_STATE: state }
    delete env.OPENCODE_RESOURCES_HUB_PARENT
    delete env.OPENCODE_RESOURCES_HUB_PORT
    const child = Bun.spawn([...hubCommand(path.join(import.meta.dir, "../src/resources/supervisor.ts"))], {
      env,
      stdout: "ignore",
      stderr: "ignore",
    })
    try {
      const info = path.join(state, "hub.json")
      for (let attempt = 0; attempt < 100 && !(await Bun.file(info).exists()); attempt++) await Bun.sleep(100)
      expect((await Bun.file(info).json()).pid).toBe(child.pid)
      expect(await Bun.file(path.join(state, "playwright-cli.json")).json()).toEqual({
        browser: { launchOptions: { args: ["--remote-debugging-port=0"] } },
      })
      // Past the parent check interval, it is still serving.
      await Bun.sleep(2_500)
      expect(child.exitCode).toBeNull()
      const client = makeHubClient({ state, remote: { info, host: "127.0.0.1" } })
      expect(await client.list()).toEqual({ resources: [] })
      child.kill("SIGTERM")
      expect(await child.exited).toBe(0)
      expect(await Bun.file(info).exists()).toBe(false)
    } finally {
      child.kill("SIGKILL")
    }
  }, 20_000)
})
