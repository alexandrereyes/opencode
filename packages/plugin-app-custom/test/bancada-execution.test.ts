import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { bancadaCommand, makeBancadaClient, type BancadaClient } from "../src/bancada/client"
import { runGit } from "../src/bancada/daemon/git"
import { liveness } from "../src/bancada/daemon/launcher/process"
import type { BancadaProtocol } from "../src/bancada/protocol"
import type { Bancada } from "../src/bancada/rpc"
import { initGit } from "../../core/test/fixture/git"

const command = bancadaCommand(path.join(import.meta.dir, "../src/bancada/client.ts"))
const example = path.join(import.meta.dir, "fixture/bancada-exemplo")
const folders: string[] = []

// The Bancada process, its runners and the commands they started live in sessions of their own: a failed test
// would leave them behind.
afterEach(async () => {
  await Promise.all(
    folders.splice(0).map(async (root) => {
      const state = path.join(root, "state")
      const info = await read(state)
      if (info && (await liveness(info.pid)).state !== "dead") process.kill(info.pid, "SIGTERM")
      ;(await groups(state)).forEach((pid) => kill(pid))
      if (info) await until(async () => (await liveness(info.pid)).state === "dead", 5_000)
      await fs.rm(root, { recursive: true, force: true })
    }),
  )
})

describe("execution through the Bancada process", () => {
  // Starts the process from source twice and the example's scripts as real processes.
  test("a request runs from the session's repository, and the process killed mid-run comes back and closes it once", async () => {
    const context = await setup()
    await Bun.write(path.join(context.repository, "novo.txt"), "só no snapshot\n")
    await Bun.write(path.join(context.repository, "ignorado.txt"), "fica de fora\n")
    const before = await worktree(context.repository)
    const submitted = await context.client.call<Bancada.Submitted>("submit", {
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples", args: ["--dorme", "4", "--marca", "novo.txt"] }],
      snapshot: true,
    })
    expect(submitted).toMatchObject({
      state: "aguardando_confirmacao",
      snapshot: { arquivos: [{ caminho: "novo.txt", mudanca: "novo" }] },
    })
    expect(await worktree(context.repository)).toEqual(before)

    await until(async () => (await view(context.client, submitted.job))?.parts.simples?.state === "rodando", 20_000)
    const first = await read(context.state)
    if (!first) throw new Error("no bancada.json")
    process.kill(first.pid, "SIGKILL")
    await until(async () => (await liveness(first.pid)).state === "dead", 5_000)
    // The next call starts another process on the same folder, which reads its execution again.
    expect(await context.client.call<Bancada.Wake>("wake", {})).toMatchObject({ protocol: 1 })
    expect((await read(context.state))?.pid).not.toBe(first.pid)

    await until(async () => (await view(context.client, submitted.job))?.state === "concluido", 30_000)
    expect((await view(context.client, submitted.job))?.result).toMatchObject([
      { part: "simples", state: "concluido", attempts: 1, outcome: { verdict: "aprovado", planned: ["c1", "c2"] } },
    ])
    const dir = path.join(context.state, "attempts", submitted.job, "simples-1")
    expect((await Bun.file(path.join(dir, "events.jsonl")).text()).match(/"type":"checkout"/g)).toHaveLength(1)
    expect(await Bun.file(path.join(dir, "parts/simples/out/marca")).text()).toBe("só no snapshot\n")
    expect(await worktree(context.repository)).toEqual(before)
    const log = await Bun.file(path.join(context.state, "bancada.log")).text()
    expect(log.match(/ started pid=/g)).toHaveLength(2)
    expect(log).not.toContain("failed")
  }, 60_000)

  // Starts the process from source and kills the runner while the example's run sleeps.
  test("a runner killed mid-run loses the part: the execution died", async () => {
    const context = await setup()
    const submitted = await context.client.call<Bancada.Submitted>("submit", {
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples", args: ["--dorme", "30"] }],
    })
    await until(async () => (await view(context.client, submitted.job))?.parts.simples?.state === "rodando", 20_000)
    const runner = (await Bun.file(
      path.join(context.state, "attempts", submitted.job, "simples-1", "runner.json"),
    ).json()) as { pid: number }
    process.kill(runner.pid, "SIGKILL")
    await until(async () => (await view(context.client, submitted.job))?.state === "concluido", 20_000)
    expect((await view(context.client, submitted.job))?.result).toMatchObject([
      {
        part: "simples",
        state: "perdido",
        attempts: 1,
        outcome: { verdict: "infraestrutura", reason: "a execução morreu", approved: false },
      },
    ])
  }, 40_000)
})

/** The example project as the session's repository, and a client of a process that is the hub. */
async function setup() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-execution-"))
  folders.push(root)
  const repository = path.join(root, "projeto")
  await fs.cp(example, repository, { recursive: true })
  await initGit(repository)
  await runGit(["add", "-A"], { cwd: repository })
  await runGit(["commit", "-q", "-m", "exemplo"], { cwd: repository })
  const state = path.join(root, "state")
  const client = makeBancadaClient({
    state,
    owner: async () => ({ instanceID: "srv-a", name: "Servidor A", hub: true }),
    command,
  })
  return { repository, state, client }
}

type View = {
  readonly state: string
  readonly parts: Record<string, { readonly state: string } | undefined>
  readonly result?: ReadonlyArray<BancadaProtocol.PartResult>
}
const view = async (client: BancadaClient, job: string) =>
  (await client.call<{ jobs: View[] }>("status", { job })).jobs[0]

/** Everything git sees in the working tree, ignored files included: a request must leave it as it was. */
async function worktree(repository: string) {
  const status = await runGit(["status", "--porcelain", "--ignored"], { cwd: repository })
  const stash = await runGit(["stash", "list"], { cwd: repository })
  return { status: status.stdout, stash: stash.stdout }
}

/** The runners and the commands they started, by process group. */
async function groups(state: string) {
  const found = await Array.fromAsync(new Bun.Glob("attempts/*/*/{runner.json,events.jsonl}").scan({ cwd: state }))
  const pids = await Promise.all(
    found.map(async (file) => {
      const text = await Bun.file(path.join(state, file)).text()
      if (file.endsWith("runner.json")) return [(JSON.parse(text) as { pid: number }).pid]
      return text
        .split("\n")
        .filter(Boolean)
        .map((line) => JSON.parse(line) as { type: string; pid?: number })
        .flatMap((event) => (event.type === "command.start" && event.pid ? [event.pid] : []))
    }),
  )
  return pids.flat()
}

function kill(pid: number) {
  try {
    process.kill(-pid, "SIGKILL")
  } catch {
    // Already gone.
  }
}

async function read(state: string) {
  return (await Bun.file(path.join(state, "bancada.json"))
    .json()
    .catch(() => undefined)) as { pid: number } | undefined
}

async function until(condition: () => Promise<boolean>, ms: number) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    if (await condition()) return
    await Bun.sleep(100)
  }
  throw new Error(`condition not met within ${ms} ms`)
}
