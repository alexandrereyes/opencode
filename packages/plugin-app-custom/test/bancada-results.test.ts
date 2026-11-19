import { afterAll, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { join, judge, type Ending, type Verdict } from "../src/bancada/results"

const planned = (...ids: string[]) => ({ versao: 1, cenarios: ids.map((id) => ({ id, nome: `Exemplo › ${id}` })) })
const summary = (...items: { id: string; resultado: "passou" | "falhou" | "ignorado"; aparelho?: string }[]) => ({
  versao: 1,
  cenarios: items,
})
const passed = (id: string) => ({ id, resultado: "passou" as const })
const failed = (id: string, aparelho?: string) => ({
  id,
  resultado: "falhou" as const,
  mensagem: 'Esperava "ok"; achou "erro"',
  ...(aparelho ? { aparelho } : {}),
})
const run = (exit: number | undefined, rest: Omit<Ending, "stage" | "exit"> = {}): Ending => ({
  stage: "run",
  ...(exit === undefined ? {} : { exit }),
  planned: planned("c1", "c2"),
  ...rest,
})

describe("false green", () => {
  // The table of `docs/bancada.md` ("False green"), plus the exit codes of build and plan.
  test.each([
    ["exit 0, every planned scenario passed", run(0, { summary: summary(passed("c1"), passed("c2")) }), "aprovado", []],
    [
      "exit 0, a scenario ignored by the project",
      run(0, { summary: summary(passed("c1"), { id: "c2", resultado: "ignorado" }) }),
      "aprovado",
      [],
    ],
    ["exit 0 without planned.json", run(0, { planned: undefined, summary: summary(passed("c1")) }), "incompleto", []],
    ["exit 0 without summary.json", run(0), "incompleto", ["c1", "c2"]],
    [
      "exit 0 with an invalid summary.json",
      run(0, { summary: { versao: 2, cenarios: [] } }),
      "incompleto",
      ["c1", "c2"],
    ],
    ["exit 0 with a planned scenario without result", run(0, { summary: summary(passed("c1")) }), "incompleto", ["c2"]],
    ["exit 0 with nothing planned", run(0, { planned: planned(), summary: summary() }), "incompleto", []],
    [
      "exit 0 with a failure: the summary rules",
      run(0, { summary: summary(passed("c1"), failed("c2")) }),
      "falhou",
      [],
    ],
    ["exit 1 with a failure", run(1, { summary: summary(failed("c1")) }), "falhou", ["c2"]],
    [
      "exit 1 without any failure",
      run(1, { summary: summary(passed("c1")), logTail: "Unhandled exception" }),
      "sem_relatorio",
      ["c2"],
    ],
    [
      "a failure on a device that fell during the attempt is lost",
      run(1, { summary: summary(passed("c1"), failed("c2", "emu-3")), fell: ["emu-3"] }),
      "infraestrutura",
      ["c2"],
    ],
    [
      "a failure on a device that did not fall stays",
      run(1, { summary: summary(passed("c1"), failed("c2", "emu-2")), fell: ["emu-3"] }),
      "falhou",
      [],
    ],
    ["exit 75: lost = planned − answered", run(75, { summary: summary(passed("c1")) }), "infraestrutura", ["c2"]],
    ["exit 75 keeps the failures it reported", run(75, { summary: summary(failed("c1")) }), "infraestrutura", ["c2"]],
    ["another exit code is like 75", run(3), "infraestrutura", ["c1", "c2"]],
    ["deadline", run(undefined, { cause: "prazo", summary: summary(passed("c1")) }), "infraestrutura", ["c2"]],
    ["the runner died", run(undefined, { cause: "runner_morto" }), "infraestrutura", ["c1", "c2"]],
    ["cancelled", run(undefined, { cause: "cancelado" }), "cancelado", ["c1", "c2"]],
    ["exit 2: an invalid request", run(2, { logTail: "seleção vazia" }), "invalido", ["c1", "c2"]],
    ["build exit 1", { stage: "build", exit: 1 }, "compilacao", []],
    ["build exit 4 is like 1", { stage: "build", exit: 4 }, "compilacao", []],
    ["build exit 75", { stage: "build", exit: 75 }, "infraestrutura", []],
    ["build exit 2", { stage: "build", exit: 2 }, "invalido", []],
    ["plan exit 2: an empty selection", { stage: "plan", exit: 2 }, "invalido", []],
    ["plan exit 1 is like 75", { stage: "plan", exit: 1 }, "infraestrutura", []],
    [
      "a new attempt expects only the scenarios asked again",
      run(0, { only: ["c2"], summary: summary(passed("c2")) }),
      "aprovado",
      [],
    ],
  ] satisfies [string, Ending, Verdict, string[]][])("%s", (_name, ending, verdict, lost) => {
    const outcome = judge(ending)
    expect({ verdict: outcome.verdict, lost: outcome.lost, approved: outcome.approved }).toEqual({
      verdict,
      lost,
      approved: verdict === "aprovado",
    })
  })

  test("a scenario reported twice failed if any report says so; evidence outside the output folder is dropped", () => {
    const outcome = judge(
      run(0, {
        summary: {
          versao: 1,
          cenarios: [
            {
              id: "c1",
              resultado: "falhou",
              mensagem: "primeira",
              evidencias: ["c1.png", "../../etc/passwd", "/tmp/x"],
            },
            passed("c1"),
            passed("c2"),
          ],
        },
      }),
    )
    expect(outcome.verdict).toBe("falhou")
    expect(outcome.scenarios).toEqual([
      { id: "c1", name: "Exemplo › c1", result: "falhou", message: "primeira", evidence: ["c1.png"] },
      { id: "c2", name: "Exemplo › c2", result: "passou" },
    ])
  })

  test("a new attempt's results count for the scenarios it was asked again, the earlier ones for the rest", () => {
    const first = judge(run(75, { planned: planned("c1", "c2", "c3"), summary: summary(passed("c1")) }))
    expect(first.lost).toEqual(["c2", "c3"])
    const partly = judge(run(75, { only: first.lost, summary: summary(passed("c2")) }))
    expect(join(first, partly)).toMatchObject({ verdict: "infraestrutura", lost: ["c3"], approved: false })
    const all = judge(run(0, { only: first.lost, summary: summary(passed("c2"), passed("c3")) }))
    expect(join(first, all)).toMatchObject({
      verdict: "aprovado",
      planned: ["c1", "c2", "c3"],
      lost: [],
      approved: true,
    })
    // A real failure of the first attempt never turns green by a later attempt of other scenarios.
    const withFailure = judge(run(75, { planned: planned("c1", "c2"), summary: summary(failed("c1")) }))
    const retry = judge(run(0, { only: ["c2"], summary: summary(passed("c2")) }))
    expect(join(withFailure, retry)).toMatchObject({ verdict: "falhou", lost: [], approved: false })
  })
})

describe("the example project writes what results reads", () => {
  const scripts = path.join(import.meta.dir, "fixture/bancada-exemplo/scripts")
  const folders: string[] = []
  afterAll(() => Promise.all(folders.map((folder) => fs.rm(folder, { recursive: true, force: true }))))

  /** Runs one of the example's commands as the runner will, then judges what it left in BANCADA_OUT. */
  const execute = async (stage: "build" | "plan" | "run", args: string[], only?: string[]) => {
    const out = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-bancada-out-"))
    folders.push(out)
    if (only) await Bun.write(path.join(out, "apenas"), only.join("\n") + "\n")
    const child = Bun.spawn([path.join(scripts, stage), ...args], {
      cwd: out,
      env: { PATH: process.env.PATH, BANCADA_OUT: out, ...(only ? { BANCADA_APENAS: path.join(out, "apenas") } : {}) },
      stdout: "pipe",
      stderr: "pipe",
    })
    const [log, error, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ])
    const file = (name: string) =>
      Bun.file(path.join(out, name))
        .json()
        .catch(() => undefined)
    return judge({
      stage,
      exit,
      planned: await file("planned.json"),
      summary: await file("summary.json"),
      ...(only ? { only } : {}),
      logTail: (log + error).trim(),
    })
  }

  test.each([
    [
      "run passes",
      "run",
      ["--cenarios", "3"],
      undefined,
      { verdict: "aprovado", planned: ["c1", "c2", "c3"], lost: [] },
    ],
    ["run loses a scenario", "run", ["--perde", "c2"], undefined, { verdict: "incompleto", lost: ["c2"] }],
    ["run without summary", "run", ["--sem-summary"], undefined, { verdict: "incompleto", lost: ["c1", "c2"] }],
    ["run exits 75", "run", ["--sai", "75"], undefined, { verdict: "infraestrutura" }],
    ["run again, only some scenarios", "run", [], ["c2"], { verdict: "aprovado", planned: ["c2"] }],
    [
      "plan with an empty selection",
      "plan",
      ["--plan-vazio"],
      undefined,
      { verdict: "invalido", logTail: "nenhum cenário selecionado" },
    ],
    ["build that does not compile", "build", ["--falha-build"], undefined, { verdict: "compilacao" }],
  ] as const)("%s", async (_name, stage, args, only, expected) => {
    expect(await execute(stage, [...args], only ? [...only] : undefined)).toMatchObject(expected)
  })

  test("run with a failure reports its message, name and evidence, and exits 1", async () => {
    const outcome = await execute("run", ["--falha", "c2"])
    expect(outcome).toMatchObject({ exit: 1, verdict: "falhou", approved: false })
    expect(outcome.scenarios).toContainEqual({
      id: "c2",
      name: "Exemplo › cenário c2",
      result: "falhou",
      message: 'Esperava "ok"; achou "erro"',
      durationMs: 12,
      evidence: ["c2.txt"],
    })
  })
})
