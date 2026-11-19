import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { Effect } from "effect"
import { bancadaCommand, BancadaError, makeBancadaClient } from "../src/bancada/client"
import { fromPs, fromStat, liveness } from "../src/bancada/daemon/launcher/process"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "../../server/test/fixture/server"

const command = bancadaCommand(path.join(import.meta.dir, "../src/bancada/client.ts"))
const owner = (instanceID: string, name: string) => async () => ({ instanceID, name, hub: false })

// Every process a test started, stopped afterwards: they live in sessions of their own and outlast a failed test.
const started: { folders: string[]; servers: Bun.Subprocess[]; hubs: ReturnType<typeof Bun.serve>[] } = {
  folders: [],
  servers: [],
  hubs: [],
}
afterEach(async () => {
  started.servers.splice(0).forEach((server) => server.kill("SIGKILL"))
  started.hubs.splice(0).forEach((hub) => void hub.stop(true))
  await Promise.all(
    started.folders.splice(0).map(async (folder) => {
      const info = await read(path.join(folder, "state"))
      if (info && (await liveness(info.pid)).state !== "dead") process.kill(info.pid, "SIGTERM")
      if (info) await until(async () => (await liveness(info.pid)).state === "dead", 5_000)
      await fs.rm(folder, { recursive: true, force: true })
    }),
  )
})

describe("process identity", () => {
  const stat = (state: string, name = "bun") =>
    `1234 (${name}) ${state} 1 1234 1234 0 -1 4194560 0 0 0 0 1 2 0 0 20 0 9 0 777 0 0`
  test.each([
    ["a running process", { text: stat("S") }, { state: "alive", started: "777" }],
    ["a name with spaces and parentheses", { text: stat("R", "a (b) c") }, { state: "alive", started: "777" }],
    ["a zombie", { text: stat("Z") }, { state: "dead" }],
    ["no such file", { error: "ENOENT" }, { state: "dead" }],
    ["a file it could not read", { error: "EACCES" }, { state: "unknown" }],
    ["a truncated line", { text: "1234 (bun) S 1" }, { state: "unknown" }],
  ] as const)("Linux: %s", (_name, read, expected) => expect(fromStat(read)).toEqual(expected))

  test.each([
    [
      "a running process",
      { code: 0, stdout: "S    Thu Nov 19 17:31:12 2026\n" },
      { state: "alive", started: "Thu Nov 19 17:31:12 2026" },
    ],
    ["a zombie", { code: 0, stdout: "Z    Thu Nov 19 17:31:12 2026" }, { state: "dead" }],
    ["no such process", { code: 1, stdout: "" }, { state: "dead" }],
    ["ps that missed its deadline or did not start", undefined, { state: "unknown" }],
    ["ps that failed otherwise", { code: 1, stdout: "ps: something odd" }, { state: "unknown" }],
  ] as const)("macOS: %s", (_name, result, expected) => expect(fromPs(result)).toEqual(expected))

  test("this machine: a live process is alive with its start time, a finished one is dead", async () => {
    const child = Bun.spawn(["true"])
    await child.exited
    expect(await liveness(process.pid)).toMatchObject({ state: "alive", started: expect.any(String) })
    expect(await liveness(child.pid)).toEqual({ state: "dead" })
  })
})

describe("process", () => {
  // Starts processes from source; the loser waits out the database's lock wait before it leaves.
  test("clients racing on one folder start a single process, which refuses another server by name", async () => {
    const root = await folder()
    const state = path.join(root, "state")
    const clients = [0, 1].map(() => makeBancadaClient({ state, owner: owner("srv-a", "Servidor A"), command }))
    expect(await Promise.all(clients.map((client) => client.call("wake", {})))).toEqual([
      { protocol: 1, state: "ok" },
      { protocol: 1, state: "ok" },
    ])
    // Both clients spawned one: the loser found the folder taken and left (it may still be leaving).
    const log = () => Bun.file(path.join(state, "bancada.log")).text()
    await until(async () => (await log()).includes("another Bancada process holds"), 5_000)
    expect((await log()).match(/ started pid=/g)).toHaveLength(1)
    expect((await log()).match(/another Bancada process holds/g)).toHaveLength(1)
    const info = await read(state)
    expect(await log()).toContain(`started pid=${info?.pid}`)
    expect((await fs.stat(path.join(state, "bancada.json"))).mode & 0o777).toBe(0o600)

    const other = makeBancadaClient({ state, owner: owner("srv-b", "Servidor B"), command })
    const refused = await other.call("wake", {}).catch((error: unknown) => error)
    expect(refused).toBeInstanceOf(BancadaError)
    expect(refused).toMatchObject({ reason: "owner", owner: { instanceID: "srv-a", name: "Servidor A" } })
  }, 15_000)

  // Starts two processes from source, one of which collects garbage.
  test("a second process on the folder gives up, even after the first collected all its garbage", async () => {
    const root = await folder()
    const state = path.join(root, "state")
    const collecting = [process.execPath, path.join(import.meta.dir, "fixture/bancada-collecting.ts")]
    const client = makeBancadaClient({ state, owner: owner("srv-a", "Servidor A"), command: collecting })
    await client.call("wake", {})
    const info = await read(state)
    if (!info) throw new Error("no bancada.json")
    // A Database only a collected local held would be closed by now, and its lock with it (prova E6).
    await until(() => Bun.file(path.join(state, "collected")).exists(), 5_000)

    const second = Bun.spawn([...command], {
      env: {
        ...process.env,
        BUN_BE_BUN: "1",
        OPENCODE_BANCADA_STATE: state,
        OPENCODE_BANCADA_PARENT: String(process.pid),
      },
      stdout: "pipe",
      stderr: "pipe",
    })
    const [output, code] = await Promise.all([new Response(second.stdout).text(), second.exited])
    expect(code).toBe(0)
    expect(output).toContain(`another Bancada process holds ${state}; leaving`)
    expect((await read(state))?.pid).toBe(info.pid)
    expect(await client.call("wake", {})).toEqual({ protocol: 1, state: "ok" })
  }, 15_000)

  // Boots a whole server with the plugin in a child process, then waits for the process's 2 s check of its server.
  test("a server starts it on wake, and it leaves with the server, even killed, after saying goodbye to the hub", async () => {
    const root = await folder()
    const state = path.join(root, "state")
    const calls: { path: string; authorization: string | null; body: unknown }[] = []
    const hub = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      fetch: async (request) => {
        calls.push({
          path: new URL(request.url).pathname,
          authorization: request.headers.get("authorization"),
          body: await request.json().catch(() => undefined),
        })
        return Response.json({ output: {} })
      },
    })
    started.hubs.push(hub)
    // Nothing of production's server environment reaches the test server.
    const env = {
      ...Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("OPENCODE_"))),
      OPENCODE_BANCADA: "1",
      OPENCODE_BANCADA_STATE: state,
      OPENCODE_SUMMARY_HUB: `http://127.0.0.1:${hub.port}`,
      OPENCODE_SUMMARY_HUB_PASSWORD: "hub-secret",
      OPENCODE_HOST_NAME: "Servidor de teste",
      OPENCODE_WATCH_GATEWAY_PORT: "0",
    }
    const server = Bun.spawn([process.execPath, path.join(import.meta.dir, "fixture/bancada-server.ts"), root], {
      cwd: path.join(import.meta.dir, ".."),
      env,
      stdout: Bun.file(path.join(root, "server.log")),
      stderr: Bun.file(path.join(root, "server.log")),
    })
    started.servers.push(server)
    await until(() => Bun.file(path.join(root, "server.json")).exists(), 20_000)
    const { base, headers, project } = (await Bun.file(path.join(root, "server.json")).json()) as {
      base: string
      headers: Record<string, string>
      project: string
    }
    const url = new URL("/api/rpc/custom.bancada/wake", base)
    url.searchParams.set("location[directory]", project)
    const wake = async () =>
      fetch(url, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({ input: {} }),
      }).then(async (response) => ({ status: response.status, body: await response.json() }))
    // The plugin of a fresh Location may still be loading (`rpc.unavailable`).
    await until(async () => (await wake()).status === 200, 20_000)
    expect(await wake()).toEqual({ status: 200, body: { output: { protocol: 1, state: "ok" } } })
    const info = await read(state)
    if (!info) throw new Error("no bancada.json")
    expect((await liveness(info.pid)).state).toBe("alive")

    server.kill("SIGKILL")
    await until(async () => (await liveness(info.pid)).state === "dead", 10_000)
    // The hub also gets this server's unified summary (`custom.summary`), which is another feature's.
    expect(calls.filter((call) => call.path.startsWith("/api/rpc/custom.bancada/"))).toEqual([
      {
        path: "/api/rpc/custom.bancada/sync",
        authorization: `Basic ${Buffer.from("opencode:hub-secret").toString("base64")}`,
        body: {
          input: expect.objectContaining({
            protocol: 1,
            machineID: info.machineID,
            name: "Servidor de teste",
            leaving: "restart",
          }),
        },
      },
    ])
    expect(await Bun.file(path.join(state, "bancada.json")).exists()).toBe(false)
  }, 30_000)
})

// Boots a server in this process with the whole plugin, in two Locations.
it.live(
  "without OPENCODE_BANCADA=1 the plugin answers off and creates nothing",
  () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped("opencode-bancada-off-")
      const state = path.join(tmp.path, "state")
      const plugin = pathToFileURL(path.resolve(import.meta.dir, "../src/index.ts")).href
      const [unset, zero] = ["unset", "zero"].map((name) => path.join(tmp.path, name))
      yield* Effect.promise(() =>
        Promise.all(
          [unset!, zero!].map(async (project) => {
            await fs.mkdir(path.join(project, ".opencode", "plugins"), { recursive: true })
            await fs.writeFile(
              path.join(project, ".opencode", "plugins", "app-custom.ts"),
              `export { default } from ${JSON.stringify(plugin)}\n`,
            )
          }),
        ),
      )
      // The preload removes every OPENCODE_BANCADA* variable; this test also names a folder, which must stay untouched.
      expect(process.env.OPENCODE_BANCADA).toBeUndefined()
      process.env.OPENCODE_BANCADA_STATE = state
      yield* Effect.addFinalizer(() =>
        Effect.sync(() => {
          delete process.env.OPENCODE_BANCADA_STATE
          delete process.env.OPENCODE_BANCADA
        }),
      )
      const server = yield* startServer(path.join(tmp.path, "config"))
      const wake = (project: string) =>
        Effect.promise(async () => {
          const url = new URL("/api/rpc/custom.bancada/wake", server.base)
          url.searchParams.set("location[directory]", project)
          const deadline = Date.now() + 15_000
          while (Date.now() < deadline) {
            const response = await fetch(url, {
              method: "POST",
              headers: { ...server.headers, "content-type": "application/json" },
              body: JSON.stringify({ input: {} }),
            })
            const body = (await response.json()) as { type?: string; data?: unknown }
            if (body.type !== "rpc.unavailable") return { status: response.status, body }
            await Bun.sleep(100)
          }
        })
      const off = { status: 400, body: { type: "unavailable", data: { reason: "off" } } }
      // Each Location loads the plugin, which reads the switch then: unset for the first, the production "0" for the second.
      expect(yield* wake(unset!)).toMatchObject(off)
      process.env.OPENCODE_BANCADA = "0"
      expect(yield* wake(zero!)).toMatchObject(off)
      expect(yield* Effect.promise(() => fs.exists(state))).toBe(false)
    }),
  20_000,
)

async function folder() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-"))
  started.folders.push(root)
  return root
}

async function read(state: string) {
  return (await Bun.file(path.join(state, "bancada.json"))
    .json()
    .catch(() => undefined)) as { pid: number; port: number; secret: string; machineID: string } | undefined
}

async function until(condition: () => Promise<boolean>, ms: number) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await condition()) return
    await Bun.sleep(100)
  }
  throw new Error(`condition not met within ${ms} ms`)
}
