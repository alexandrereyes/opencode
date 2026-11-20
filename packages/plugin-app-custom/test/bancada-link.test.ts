import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { randomBytes } from "node:crypto"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { bancadaCommand, makeBancadaClient, type BancadaClient } from "../src/bancada/client"
import { runGit } from "../src/bancada/daemon/git"
import { liveness } from "../src/bancada/daemon/launcher/process"
import { BancadaProtocol } from "../src/bancada/protocol"
import type { Bancada } from "../src/bancada/rpc"
import { initGit } from "../../core/test/fixture/git"

// Two servers with this package's plugin, each in a process of its own (`fixture/bancada-server.ts`), each with its
// Bancada process: the hub and a machine that reaches it by `custom.bancada` over HTTP, as two computers would.
const example = path.join(import.meta.dir, "fixture/bancada-exemplo")
const command = bancadaCommand(path.join(import.meta.dir, "../src/bancada/client.ts"))

type Server = { readonly base: string; readonly headers: Record<string, string>; readonly project: string }
const world: {
  root?: string
  servers: Bun.Subprocess[]
  hub?: Server
  machine?: Server
  repository?: string
  client?: BancadaClient
} = { servers: [] }

beforeAll(async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-link-"))
  world.root = root
  // The example project, with a test only the hub offers and 5 MB that do not compress: its code travels in chunks.
  const repository = path.join(root, "projeto")
  await fs.cp(example, repository, { recursive: true })
  await Bun.write(path.join(repository, "dados.bin"), randomBytes(5 * 1024 * 1024))
  await fs.appendFile(
    path.join(repository, ".bancada.toml"),
    `\n[teste.remoto]\nherda   = "simples"\nrotulo  = "Remoto"\nprecisa = ["so-no-hub"]\n`,
  )
  await initGit(repository)
  await runGit(["add", "-A"], { cwd: repository })
  await runGit(["commit", "-q", "-m", "exemplo"], { cwd: repository })
  world.repository = repository
  const machineFile = (tags: string[]) =>
    `versao = 1\netiquetas = ${JSON.stringify(tags)}\n[orcamento]\nmemoria_gb = 32\ncpu = 16\n[execucao]\nmodo = "processo"\n`
  await Bun.write(path.join(root, "hub.toml"), machineFile(["so-no-hub"]))
  await Bun.write(path.join(root, "machine.toml"), machineFile([]))
  world.hub = await start(path.join(root, "hub"), {
    OPENCODE_HUB: "1",
    OPENCODE_BANCADA_STATE: path.join(root, "hub", "state"),
    OPENCODE_BANCADA_CONFIG: path.join(root, "hub.toml"),
    OPENCODE_HOST_NAME: "Hub de teste",
  })
  world.machine = await start(path.join(root, "machine"), {
    OPENCODE_BANCADA_STATE: path.join(root, "machine", "state"),
    OPENCODE_BANCADA_CONFIG: path.join(root, "machine.toml"),
    OPENCODE_HOST_NAME: "Máquina de teste",
    OPENCODE_SUMMARY_HUB: world.hub.base,
    // The test servers' password (`startServer`).
    OPENCODE_SUMMARY_HUB_PASSWORD: "secret",
  })
  // The machine's process serves its server: the test speaks to it as that server (its admin API).
  const identity = await rpc<{ instanceID: string; name: string; hub: boolean }>(
    world.machine,
    "custom.instance/get",
    {},
  )
  world.client = makeBancadaClient({
    state: path.join(root, "machine", "state"),
    owner: async () => ({ ...identity, link: { target: world.hub!.base, password: "secret" } }),
    command,
  })
}, 60_000)

afterAll(async () => {
  world.servers.forEach((server) => server.kill("SIGKILL"))
  const root = world.root
  if (!root) return
  // Each Bancada process leaves within 2 s of its server; their runners and commands with them.
  for (const state of [path.join(root, "hub", "state"), path.join(root, "machine", "state")]) {
    const info = (await Bun.file(path.join(state, "bancada.json"))
      .json()
      .catch(() => undefined)) as { pid: number } | undefined
    if (info) await until(async () => (await liveness(info.pid)).state === "dead", 10_000).catch(() => undefined)
  }
  await fs.rm(root, { recursive: true, force: true })
})

describe("two servers' Bancadas over custom.bancada", () => {
  test("the machine's request runs on the hub, with its 5 MB of code sent through the hub in chunks", async () => {
    const client = world.client!
    const submitted = await client.call<Bancada.Submitted>(
      "submit",
      {
        id: BancadaProtocol.jobID("pelo hub"),
        sessionID: "ses_a",
        diretorio: world.repository!,
        testes: [{ teste: "remoto" }],
      },
      120_000,
    )
    expect(submitted.state).toBe("aguardando_confirmacao")
    const view = async () =>
      (
        await client.call<{ jobs: { state: string; result?: BancadaProtocol.PartResult[] }[] }>("status", {
          job: submitted.job,
        })
      ).jobs[0]
    await until(async () => (await view())?.state === "concluido", 60_000)
    expect((await view())?.result).toMatchObject([
      { part: "remoto", state: "concluido", machine: { name: "Hub de teste" }, outcome: { verdict: "aprovado" } },
    ])
    // It ran on the hub, from the bundle: the hub has the attempt's folder, the machine none.
    const hubAttempts = path.join(world.root!, "hub", "state", "attempts", submitted.job)
    expect(await fs.exists(path.join(hubAttempts, "remoto-1", "events.jsonl"))).toBe(true)
    expect(await fs.exists(path.join(world.root!, "machine", "state", "attempts", submitted.job))).toBe(false)
    const machineLog = await Bun.file(path.join(world.root!, "machine", "state", "bancada.log")).text()
    expect(machineLog).not.toContain("failed")
  }, 90_000)

  test("a wrong password is refused by the hub's server; a server that is not the hub refuses by name", async () => {
    const call = (server: Server, authorization: string) =>
      fetch(new URL("/api/rpc/custom.bancada/sync", server.base), {
        method: "POST",
        headers: { authorization, "content-type": "application/json" },
        body: JSON.stringify({ input: { protocol: 1 } }),
      }).then(async (response) => ({ status: response.status, body: await response.json().catch(() => undefined) }))
    expect((await call(world.hub!, `Basic ${btoa("opencode:errada")}`)).status).toBe(401)
    expect(await call(world.machine!, world.machine!.headers.authorization!)).toMatchObject({
      status: 400,
      body: { type: "not_hub" },
    })
    // Another protocol is refused by name, never half read.
    const other = await fetch(new URL("/api/rpc/custom.bancada/sync", world.hub!.base), {
      method: "POST",
      headers: { ...world.hub!.headers, "content-type": "application/json" },
      body: JSON.stringify({ input: { protocol: 2, machineID: "m-x" } }),
    }).then((response) => response.json())
    expect(other).toMatchObject({ type: "protocol_mismatch", data: { expected: 1 } })
  }, 30_000)
})

/** A test server with the plugin, in a process of its own, with exactly this environment (none of the host's). */
async function start(root: string, env: Record<string, string>): Promise<Server> {
  // Run from the project, whose plugin it loads: a call without a Location (another server's) reaches it there, as
  // the globally installed plugin of production is reached in any Location.
  await fs.mkdir(path.join(root, "project"), { recursive: true })
  const server = Bun.spawn([process.execPath, path.join(import.meta.dir, "fixture/bancada-server.ts"), root], {
    cwd: path.join(root, "project"),
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("OPENCODE_"))),
      OPENCODE_BANCADA: "1",
      OPENCODE_WATCH_GATEWAY_PORT: "0",
      ...env,
    },
    stdout: Bun.file(path.join(root, "server.log")),
    stderr: Bun.file(path.join(root, "server.log")),
  })
  world.servers.push(server)
  await until(() => Bun.file(path.join(root, "server.json")).exists(), 30_000)
  const found = (await Bun.file(path.join(root, "server.json")).json()) as Server
  // The plugin of a fresh Location may still be loading.
  await until(async () => (await rpcResponse(found, "custom.bancada/wake", {})).status === 200, 30_000)
  return found
}

function rpcResponse(server: Server, route: string, input: unknown) {
  const url = new URL(`/api/rpc/${route}`, server.base)
  url.searchParams.set("location[directory]", server.project)
  return fetch(url, {
    method: "POST",
    headers: { ...server.headers, "content-type": "application/json" },
    body: JSON.stringify({ input }),
  })
}

async function rpc<T>(server: Server, route: string, input: unknown) {
  return ((await (await rpcResponse(server, route, input)).json()) as { output: T }).output
}

async function until(condition: () => Promise<boolean>, ms: number) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await condition()) return
    await Bun.sleep(100)
  }
  throw new Error(`condition not met within ${ms} ms`)
}
