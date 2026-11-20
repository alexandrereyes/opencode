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
import { makeBancadaHook } from "../src/bancada/hook"
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
  test("bancada_run tests the working tree, answers with each test's place and, in a subagent, with the result; status and cancel", async () => {
    const context = await setup()
    const added: Tool.Info[] = []
    // `ses_child` is a subagent of `ses_tool`; `ses_other`, another family.
    const sessions: Record<string, { parentID?: string; title: string }> = {
      ses_tool: { title: "Sessão de teste" },
      ses_child: { parentID: "ses_tool", title: "Testar o checkout" },
      ses_other: { title: "Outra" },
    }
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
            ...sessions[input.sessionID],
          }),
      },
    } as unknown as Parameters<typeof registerBancadaTools>[0]
    await Effect.runPromise(Effect.scoped(registerBancadaTools(ctx, context.client, async () => "srv-a")))
    expect(added.map((tool) => [tool.name, tool.options?.codemode])).toEqual([
      ["bancada_run", false],
      ["bancada_status", false],
      ["bancada_cancel", false],
      ["bancada_hold", false],
      ["bancada_release", false],
    ])
    const tool = (name: string) => added.find((item) => item.name === name)!
    const call = (name: string, input: unknown, id: string, sessionID = "ses_tool") =>
      Effect.runPromise(
        tool(name).execute(input, {
          sessionID,
          agent: "build",
          messageID: "msg_1",
          id,
          progress: () => Effect.void,
        } as unknown as Tool.Context),
      )
    // An edit not committed: what is tested is the working tree as it is.
    await Bun.write(path.join(context.repository, "novo.txt"), "editado agora\n")
    const first = await call("bancada_run", { testes: [{ teste: "simples", args: ["--dorme", "20"] }] }, "call_1")
    const job = BancadaProtocol.jobID("srv-a\ncall_1")
    const head = (await runGit(["rev-parse", "HEAD"], { cwd: context.repository })).stdout.trim().slice(0, 8)
    expect(first.content).toMatch(
      new RegExp(
        `^Pedido ${job} enviado\\. Código: commit ${head} mais 1 arquivo não commitado \\(novo\\.txt novo\\)\\.\nSimples: (preparando|compilando|rodando) em Servidor A\n`,
      ),
    )
    expect(first.content?.toString().split("\n").at(-1)).toBe(
      "O resultado chega sozinho, como mensagem nesta sessão, e ela é retomada na hora. Siga com outro trabalho ou encerre sua resposta. Não espere, não consulte bancada_status e não peça de novo.",
    )
    // The same call made again is the same request.
    expect((await call("bancada_run", { testes: [{ teste: "simples" }] }, "call_1")).content).toContain(`Pedido ${job}`)
    await until(async () => (await view(context.client, job))?.parts.simples?.state === "rodando", 20_000)
    expect((await call("bancada_status", {}, "call_2")).content).toBe(
      [
        `${job}:`,
        "  Simples: rodando em Servidor A",
        "",
        "O resultado chega sozinho como mensagem nesta sessão; não é preciso consultar de novo.",
      ].join("\n"),
    )
    // Another family cannot cancel it; this one can.
    expect((await call("bancada_cancel", { job }, "call_3", "ses_other")).content).toBe(
      `${job} é de outra sessão; esta tool só cancela pedidos desta sessão e dos subagentes dela.`,
    )
    expect((await call("bancada_cancel", { job }, "call_4")).content).toBe(
      `${job} cancelado. O que esperava saiu da fila; o que rodava está sendo parado.`,
    )
    expect((await call("bancada_cancel", { job: "j-00000000" }, "call_5")).content).toBe(
      "Nenhum pedido j-00000000 neste servidor.",
    )
    // Cancelled whole: its notice does not wake the session (nothing to act on).
    await until(async () => (await view(context.client, job))?.state === "concluido", 30_000)
    type Notices = { notices: { job: string; text: string; resume: boolean }[] }
    const cancelled = (await context.client.call<Notices>("events", { waitMs: 0 })).notices.find(
      (notice) => notice.job === job,
    )
    expect(cancelled).toMatchObject({
      resume: false,
      text: expect.stringMatching(new RegExp(`^\\[Bancada\\] ${job} foi cancelado`)),
    })
    await context.client.call("notice.ack", { job })
    // In a subagent the call waits: the notice comes back as the tool's result, and no message is made.
    const waited = await call("bancada_run", { testes: [{ teste: "simples" }] }, "call_6", "ses_child")
    const second = BancadaProtocol.jobID("srv-a\ncall_6")
    expect(waited.content).toMatch(
      new RegExp(
        `^\\[Bancada\\] ${second} terminou: aprovado \\(commit ${head} mais 1 arquivo não commitado\\)\nSimples: 2 aprovados\\.`,
      ),
    )
    expect((await view(context.client, second))?.state).toBe("entregue")
    const notices = await context.client.call<{ notices: { job: string }[] }>("events", { waitMs: 0 })
    expect(notices.notices.map((notice) => notice.job)).not.toContain(second)
    expect((await call("bancada_cancel", { job }, "call_7")).content).toBe(
      `${job} já tinha terminado; nada a cancelar.`,
    )
  }, 90_000)

  test("only the tool that waits holds a notice back: another client's status with waitMs holds nothing", async () => {
    const context = await setup()
    const submitted = await context.client.call<Bancada.Submitted>("submit", {
      id: BancadaProtocol.jobID("W2"),
      sessionID: "ses_a",
      diretorio: context.repository,
      testes: [{ teste: "simples" }],
    })
    // An app asking with a wait, as the public RPC allows.
    await context.client.call("status", { job: submitted.job, waitMs: 25_000 }, 30_000)
    await until(async () => (await view(context.client, submitted.job))?.state === "concluido", 30_000)
    type Notices = { notices: { job: string }[] }
    expect((await context.client.call<Notices>("events", { waitMs: 0 })).notices.map((item) => item.job)).toEqual([
      submitted.job,
    ])
  }, 60_000)

  test("the hook and the hold tools on a real process: fora, phones, slots, the family's own, and a process out", async () => {
    const context = await setup(
      `[[fisico]]\napelido = "poco"\nnome = "POCO X7"\nid = "IBHUYT85ZTYH5XDM"\nplataforma = "android"\ntransporte = "usb"\n` +
        `[[fisico]]\napelido = "pessoal"\nnome = "Pessoal"\nid = "192.168.0.7:5555"\nplataforma = "android"\ntransporte = "wifi"\npolitica = "negar"\n`,
    )
    const added: Tool.Info[] = []
    const titles: Record<string, string> = { ses_tool: "Sessão de teste", ses_other: "Outra" }
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
            title: titles[input.sessionID],
          }),
      },
    } as unknown as Parameters<typeof registerBancadaTools>[0]
    await Effect.runPromise(Effect.scoped(registerBancadaTools(ctx, context.client, async () => "srv-a")))
    const tool = (name: string) => added.find((item) => item.name === name)!
    const call = async (name: string, input: unknown, id: string, sessionID = "ses_tool") =>
      String(
        (
          await Effect.runPromise(
            tool(name).execute(input, {
              sessionID,
              agent: "build",
              messageID: "msg_1",
              id,
              progress: () => Effect.void,
            } as unknown as Tool.Context),
          )
        ).content,
      )
    const run = (client: BancadaClient) => {
      const hook = makeBancadaHook(ctx, client)
      return async (command: string, sessionID = "ses_tool", id = "call_h") => {
        const event = { tool: "shell", sessionID, agent: "build", messageID: "msg_1", id, input: { command } }
        const before = await Effect.runPromise(
          hook
            .before(event as never)
            .pipe(Effect.match({ onFailure: (error) => error.message, onSuccess: () => "passa" })),
        )
        const after = { ...event, status: "completed", result: { content: "ok" as unknown } }
        await Effect.runPromise(hook.after(after as never))
        return { before, after: after.result.content }
      }
    }
    const hook = run(context.client)
    // 1. A command the repository reserves to the Bancada.
    expect((await hook("./scripts/por-fora --tudo")).before).toBe(
      "Neste repositório, `./scripts/por-fora --tudo` só roda pela Bancada. Use `bancada_run` com o teste `simples` ou `lento` ou `android` ou `ios` ou `fisico` ou `exclusivo` ou `servidor`.",
    )
    expect((await hook("BANCADA_JOB=j-12345678 ./scripts/por-fora")).before).toBe("passa")
    // 2. Phones: the family's hold first; never one not to be reserved.
    expect((await hook("adb -s IBHUYT85ZTYH5XDM shell")).before).toBe(
      'Reserve antes com `bancada_hold({ aparelho: "poco" })`.',
    )
    expect((await hook("adb -s 192.168.0.7:5555 shell")).before).toBe(
      'O celular pessoal não pode ser usado por agentes (politica = "negar" no arquivo da máquina).',
    )
    const held = await call("bancada_hold", { aparelho: "poco" }, "call_1")
    const poco = BancadaProtocol.holdID("srv-a\ncall_1")
    expect(held.split("\n")[0]).toBe(`Reserva ${poco} concedida: o celular poco em Servidor A (id IBHUYT85ZTYH5XDM).`)
    expect((await hook("adb -s IBHUYT85ZTYH5XDM install app.apk")).before).toBe("passa")
    expect((await hook("adb -s IBHUYT85ZTYH5XDM shell", "ses_other")).before).toBe(
      'Reserve antes com `bancada_hold({ aparelho: "poco" })`.',
    )
    // Another family waits for it, and is told when it is theirs.
    const waiting = await call("bancada_hold", { aparelho: "poco" }, "call_2", "ses_other")
    const other = BancadaProtocol.holdID("srv-a\ncall_2")
    expect(waiting.split("\n")[0]).toBe(
      `Reserva ${other} na fila: o celular poco em Servidor A, 1º na fila (aguardando poco (com Sessão de teste em Servidor A)).`,
    )
    expect(await call("bancada_status", {}, "call_3", "ses_other")).toBe(
      `Reservas:\n  ${other}: o celular poco em Servidor A, 1º na fila (aguardando poco (com Sessão de teste em Servidor A))`,
    )
    expect(await call("bancada_release", { reserva: poco }, "call_4", "ses_other")).toBe(
      `${poco} é de outra sessão; esta tool só solta reservas desta sessão e dos subagentes dela.`,
    )
    expect(await call("bancada_release", { reserva: poco }, "call_5")).toBe(`Reserva ${poco} solta.`)
    type Note = { key: string; sessionID: string; text: string; resume: boolean }
    const seen: Note[] = []
    await until(async () => {
      seen.push(...(await context.client.call<{ notes: Note[] }>("events", { waitMs: 0 })).notes)
      return seen.length > 0
    }, 10_000)
    expect(seen).toMatchObject([
      {
        sessionID: "ses_other",
        resume: true,
        text: `[Bancada] Sua vaga saiu: o celular poco em Servidor A (reserva ${other}). Use agora; ela vence se ficar parada.`,
      },
    ])
    await context.client.call("note.ack", { key: seen[0]!.key })
    // 5. A start asks for a slot; the family uses it, another is told whose it is.
    expect((await hook("emulator -avd Pixel_Teste -no-window")).before).toBe("passa")
    expect((await hook("emulator -avd Pixel_Teste -wipe-data")).before).toBe("passa")
    expect((await hook("emulator -avd Pixel_Teste", "ses_other")).before).toBe(
      "Pixel_Teste está reservado para Sessão de teste (em Servidor A); não use aparelho de outra sessão.",
    )
    // The process out: a command passes with a warning; a start is refused.
    const out = run({
      call: () => Promise.reject(new BancadaError("process", "fora")),
    } as unknown as BancadaClient)
    expect(await out("adb devices")).toEqual({
      before: "passa",
      after: [
        { type: "text", text: "ok" },
        {
          type: "text",
          text: "[Bancada] O processo da Bancada não respondeu: este comando passou sem a conferência de aparelhos e reservas.",
        },
      ],
    })
    expect((await out("emulator @Outro")).before).toBe("a Bancada está reconciliando; tente de novo em instantes")
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
