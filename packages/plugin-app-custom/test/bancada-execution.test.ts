import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { bancadaCommand, BancadaError, makeBancadaClient, type BancadaClient } from "../src/bancada/client"
import { runGit } from "../src/bancada/daemon/git"
import { liveness } from "../src/bancada/daemon/launcher/process"
import { BancadaProtocol } from "../src/bancada/protocol"
import type { Bancada } from "../src/bancada/rpc"
import { registerBancadaTools } from "../src/bancada/tools"
import type { Tool } from "@opencode/schema/tool"
import { Effect } from "effect"
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
      id: BancadaProtocol.jobID("ponta a ponta"),
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
  test("a runner killed mid-run loses the attempt; the part runs once more, then it is lost", async () => {
    const context = await setup()
    const submitted = await context.client.call<Bancada.Submitted>("submit", {
      id: BancadaProtocol.jobID("runner morto"),
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples", args: ["--dorme", "30"] }],
    })
    // Killed while it runs, it is infrastructure: the part runs once more (attempt 2), and that one is killed too.
    for (const attempt of [1, 2]) {
      await until(async () => {
        const part = (await view(context.client, submitted.job))?.parts.simples
        return part?.state === "rodando" && part.attempt === attempt
      }, 20_000)
      const runner = (await Bun.file(
        path.join(context.state, "attempts", submitted.job, `simples-${attempt}`, "runner.json"),
      ).json()) as { pid: number }
      process.kill(runner.pid, "SIGKILL")
    }
    await until(async () => (await view(context.client, submitted.job))?.state === "concluido", 20_000)
    expect((await view(context.client, submitted.job))?.result).toMatchObject([
      {
        part: "simples",
        state: "perdido",
        attempts: 2,
        outcome: { verdict: "infraestrutura", reason: "a execução morreu", approved: false },
      },
    ])
  }, 40_000)
})

describe("requests the process refuses or joins", () => {
  // Starts the process from source.
  test("no id, a test asked twice, a command without execute permission: refused before anything is queued", async () => {
    const context = await setup()
    await fs.chmod(path.join(context.repository, "scripts/run"), 0o644)
    await runGit(["commit", "-q", "-am", "run sem permissão"], { cwd: context.repository })
    const refusal = (input: Record<string, unknown>) =>
      context.client.call("submit", { sessionID: "ses_a", diretorio: context.repository, ...input }).then(
        () => undefined,
        (error: BancadaError) => ({ reason: error.reason, problems: error.problems }),
      )
    expect(await refusal({ testes: [{ teste: "simples" }] })).toMatchObject({ reason: "invalid" })
    expect(
      await refusal({ id: BancadaProtocol.jobID("duas vezes"), testes: [{ teste: "lento" }, { teste: "lento" }] }),
    ).toEqual({ reason: "invalid", problems: ["o teste lento aparece duas vezes no pedido"] })
    expect(await refusal({ id: BancadaProtocol.jobID("sem x"), testes: [{ teste: "simples" }] })).toEqual({
      reason: "invalid",
      // Every test of the example runs scripts/run: the contract lists each.
      problems: expect.arrayContaining([
        'teste.simples.run: "scripts/run" não é executável neste commit (chmod +x e commit)',
      ]),
    })
    // Nothing was queued nor left in the repository.
    expect((await runGit(["for-each-ref", "refs/bancada"], { cwd: context.repository })).stdout).toBe("")
  }, 20_000)

  test("two calls with the same id at once are one request, frozen once", async () => {
    const context = await setup()
    await Bun.write(path.join(context.repository, "novo.txt"), "só no snapshot\n")
    const request = {
      id: BancadaProtocol.jobID("duas chamadas"),
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples" }],
      snapshot: true,
    }
    const [first, second] = await Promise.all([
      context.client.call<Bancada.Submitted>("submit", request),
      context.client.call<Bancada.Submitted>("submit", request),
    ])
    expect(second).toEqual(first)
    expect(first).toMatchObject({ job: request.id, snapshot: { arquivos: [{ caminho: "novo.txt" }] } })
    await until(async () => (await view(context.client, request.id))?.state === "concluido", 20_000)
  }, 30_000)
})

describe("the machine file", () => {
  // Starts the process from source; the part waits 3 s for an offer that never comes.
  test("an invalid machine file offers nothing and says why in the log", async () => {
    const context = await setup()
    await Bun.write(context.config, `versao = 1\n[orcamento]\nmemoria_gb = "muita"\n`)
    const submitted = await context.client.call<Bancada.Submitted>("submit", {
      id: BancadaProtocol.jobID("arquivo inválido"),
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples" }],
    })
    await Bun.sleep(3_000)
    expect((await view(context.client, submitted.job))?.parts.simples?.state).toBe("na_fila")
    expect(await Bun.file(path.join(context.state, "bancada.log")).text()).toContain(
      "is invalid; this machine offers nothing:\n  orcamento.memoria_gb: precisa ser um número, > 0",
    )
  }, 20_000)
})

describe("notices and tools", () => {
  // Starts the process from source and runs the example's `simples` test for real.
  test("S8: a notice taken and never acknowledged goes again, with the same id; nothing is cleaned before the ack", async () => {
    const context = await setup("[tempos]\naviso_s = 1\n")
    const submitted = await context.client.call<Bancada.Submitted>("submit", {
      id: BancadaProtocol.jobID("S8"),
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples" }],
    })
    await until(async () => (await view(context.client, submitted.job))?.state === "concluido", 30_000)
    type Notices = { notices: { job: string; sessionID: string; id: string; text: string }[] }
    const events = () => context.client.call<Notices>("events", { waitMs: 0 })
    const first = await events()
    expect(first.notices).toMatchObject([
      {
        job: submitted.job,
        sessionID: "ses_a",
        id: expect.stringMatching(/^msg_/),
        text: expect.stringContaining(`[Bancada] ${submitted.job} terminou`),
      },
    ])
    // Taken by one instance: no other gets it while it may still be delivering.
    expect((await events()).notices).toEqual([])
    // That instance died between its message and its ack: the same notice, the same message id, goes again.
    await Bun.sleep(1_200)
    expect((await events()).notices).toEqual(first.notices)
    const attempts = path.join(context.state, "attempts", submitted.job)
    expect(await fs.exists(attempts)).toBe(true)
    await context.client.call("notice.ack", { job: submitted.job })
    expect((await events()).notices).toEqual([])
    // Delivered: the hub sends the cleanup, the attempt's folder goes.
    await until(async () => !(await fs.exists(attempts)), 20_000)
    expect((await view(context.client, submitted.job))?.state).toBe("entregue")
  }, 60_000)

  // The tools as an agent calls them, against a real process (the plugin's server is played by a small fake).
  test("bancada_run answers with the request and its place; with esperar, with the notice itself; status and cancel", async () => {
    const context = await setup()
    const added: Tool.Info[] = []
    const ctx = {
      tool: {
        transform: (edit: (editor: { add: (tool: Tool.Info) => void }) => void) =>
          Effect.sync(() => edit({ add: (tool) => void added.push(tool) })),
      },
      session: {
        get: (input: { sessionID: string }) =>
          Effect.succeed({
            id: input.sessionID,
            location: { directory: context.repository },
            title: "Sessão de teste",
          }),
      },
    } as unknown as Parameters<typeof registerBancadaTools>[0]
    await Effect.runPromise(Effect.scoped(registerBancadaTools(ctx, context.client, async () => "srv-a")))
    expect(added.map((tool) => [tool.name, tool.options?.codemode])).toEqual([
      ["bancada_run", false],
      ["bancada_status", false],
      ["bancada_cancel", false],
    ])
    const tool = (name: string) => added.find((item) => item.name === name)!
    const call = (name: string, input: unknown, id: string) =>
      Effect.runPromise(
        tool(name).execute(input, {
          sessionID: "ses_tool",
          agent: "build",
          messageID: "msg_1",
          id,
          progress: () => Effect.void,
        } as unknown as Tool.Context),
      )
    const first = await call("bancada_run", { testes: [{ teste: "simples", args: ["--dorme", "20"] }] }, "call_1")
    const job = BancadaProtocol.jobID("srv-a\ncall_1")
    expect(first.content).toMatch(new RegExp(`^Pedido ${job} enviado \\(commit [0-9a-f]{8}\\)\\.\nsimples: `))
    expect(first.content).toContain("O resultado chega sozinho como mensagem nesta sessão: não consulte em laço.")
    // The same call made again is the same request.
    expect((await call("bancada_run", { testes: [{ teste: "simples" }] }, "call_1")).content).toContain(`Pedido ${job}`)
    await until(async () => (await view(context.client, job))?.parts.simples?.state === "rodando", 20_000)
    expect((await call("bancada_status", {}, "call_2")).content).toContain(`${job} (commit `)
    expect((await call("bancada_cancel", { job }, "call_3")).content).toBe(
      `${job}: cancelamento pedido. O aviso do pedido diz como cada teste terminou.`,
    )
    // Held until the end: the notice comes back as the tool's result, and is not sent as a message.
    const waited = await call("bancada_run", { testes: [{ teste: "simples" }], esperar: true }, "call_4")
    const second = BancadaProtocol.jobID("srv-a\ncall_4")
    expect(waited.content).toMatch(
      new RegExp(`^\\[Bancada\\] ${second} terminou \\(commit [0-9a-f]{8}\\)\nSimples: 2 aprovados\\.`),
    )
    // Delivered by the tool: no message goes to the session for it.
    expect((await view(context.client, second))?.state).toBe("entregue")
    const notices = await context.client.call<{ notices: { job: string }[] }>("events", { waitMs: 0 })
    expect(notices.notices.map((notice) => notice.job)).not.toContain(second)
  }, 90_000)
})

/** The example project as the session's repository, and a client of a process that is the hub. */
async function setup(machine = "") {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-execution-"))
  folders.push(root)
  const repository = path.join(root, "projeto")
  await fs.cp(example, repository, { recursive: true })
  await initGit(repository)
  await runGit(["add", "-A"], { cwd: repository })
  await runGit(["commit", "-q", "-m", "exemplo"], { cwd: repository })
  const state = path.join(root, "state")
  // A machine file of its own, never the host's: room for the example's build, executions as processes.
  const config = path.join(root, "bancada.toml")
  await Bun.write(
    config,
    `versao = 1\n[orcamento]\nmemoria_gb = 32\ncpu = 16\n[execucao]\nmodo = "processo"\n${machine}`,
  )
  const client = makeBancadaClient({
    state,
    owner: async () => ({ instanceID: "srv-a", name: "Servidor A", hub: true }),
    command,
    config,
  })
  return { repository, state, client, config }
}

type View = {
  readonly state: string
  readonly parts: Record<string, { readonly state: string; readonly attempt?: number } | undefined>
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
