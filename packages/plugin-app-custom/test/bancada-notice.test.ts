import { describe, expect, test } from "bun:test"
import { BancadaNotice } from "../src/bancada/notice"
import type { BancadaProtocol } from "../src/bancada/protocol"

// The notice's text (`docs/bancada.md`, "Notice"): these fixtures are the norm.
const passed = (n: number, prefix = "c") =>
  Array.from({ length: n }, (_, index) => ({ id: `${prefix}${index + 1}`, result: "passou" as const }))
const ignored = (n: number) =>
  Array.from({ length: n }, (_, index) => ({ id: `i${index + 1}`, result: "ignorado" as const }))
const outcome = (more: Partial<BancadaProtocol.Outcome>): BancadaProtocol.Outcome => ({
  verdict: "aprovado",
  planned: [],
  scenarios: [],
  lost: [],
  approved: true,
  ...more,
})
const mac = { machineID: "m-mac", name: "Mac de Alexandre" }
const base = { job: "j-7qk2m9xa", commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d" }

describe("notice", () => {
  test("the plan's example: two parts, a failure with its message, history and evidence", () => {
    const voice = {
      id: "read-voice",
      name: "ReadVoice › Ouvir uma mensagem de voz que chegou",
      result: "falhou" as const,
      message: 'Esperava "Transcrevendo…"; achou "0:07"',
      evidence: ["read-voice.png"],
    }
    expect(
      BancadaNotice.text({
        ...base,
        snapshot: { files: 3 },
        parts: [
          {
            label: "Android",
            result: {
              part: "android",
              state: "concluido",
              attempts: 2,
              machine: mac,
              ms: 6 * 60_000,
              outcome: outcome({
                verdict: "falhou",
                approved: false,
                scenarios: [...passed(112), voice, ...ignored(2)],
                retried: { count: 7, reason: "um aparelho caiu durante a execução" },
              }),
              history: { "read-voice": { failed: 1, of: 12 } },
            },
            delivered: {
              files: { "read-voice.png": "/tmp/opencode/bancada/j-7qk2m9xa/android/read-voice.png" },
              missing: 0,
            },
          },
          {
            label: "iOS",
            result: {
              part: "ios",
              state: "concluido",
              attempts: 1,
              machine: mac,
              ms: 4 * 60_000,
              outcome: outcome({ scenarios: passed(23) }),
            },
          },
        ],
      }),
    ).toBe(
      [
        "[Bancada] j-7qk2m9xa terminou: falhou (commit 3417b7e3 mais 3 arquivos não commitados)",
        "Android: 112 aprovados, 1 falhou, 2 ignorados; 7 refeitos por queda de aparelho. Mac de Alexandre, 6 min.",
        "iOS: 23 aprovados. Mac de Alexandre, 4 min.",
        "✗ Android · ReadVoice › Ouvir uma mensagem de voz que chegou",
        '  Esperava "Transcrevendo…"; achou "0:07"',
        "  Histórico: falhou 1 das últimas 12 vezes",
        "  Evidências: /tmp/opencode/bancada/j-7qk2m9xa/android/read-voice.png",
      ].join("\n"),
    )
  })

  test("all approved: two lines; never the number of offers", () => {
    expect(
      BancadaNotice.text({
        ...base,
        parts: [
          {
            label: "Simples",
            result: {
              part: "simples",
              state: "concluido",
              attempts: 3,
              machine: { machineID: "m", name: "Linux BRS" },
              ms: 40_000,
              outcome: outcome({ scenarios: passed(2) }),
            },
          },
        ],
      }),
    ).toBe(
      ["[Bancada] j-7qk2m9xa terminou: aprovado (commit 3417b7e3)", "Simples: 2 aprovados. Linux BRS, 1 min."].join(
        "\n",
      ),
    )
  })

  test("a failed build: the log's last lines and where the whole log is", () => {
    const tail = Array.from({ length: 40 }, (_, index) => `linha ${index + 1}`).join("\n")
    const text = BancadaNotice.text({
      ...base,
      parts: [
        {
          label: "Android",
          result: {
            part: "android",
            state: "concluido",
            attempts: 1,
            machine: mac,
            ms: 2 * 60_000,
            outcome: outcome({ verdict: "compilacao", approved: false, reason: "a compilação falhou", logTail: tail }),
          },
          delivered: { files: { "build.log": "/tmp/opencode/bancada/j-7qk2m9xa/android/build.log" }, missing: 0 },
        },
      ],
    })
    const lines = text.split("\n")
    expect(lines.slice(0, 3)).toEqual([
      "[Bancada] j-7qk2m9xa terminou: falhou (commit 3417b7e3)",
      "Android: nenhum cenário. A compilação falhou. Mac de Alexandre, 2 min.",
      "Android, fim do log (inteiro em /tmp/opencode/bancada/j-7qk2m9xa/android/build.log):",
    ])
    expect(lines.slice(3)).toHaveLength(30)
    expect(lines.at(-1)).toBe("  linha 40")
  })

  test("invalid, lost after a new attempt, a machine that never answered, cancelled", () => {
    const part = (label: string, result: Partial<BancadaProtocol.PartResult>) => ({
      label,
      result: { part: label.toLowerCase(), state: "concluido" as const, attempts: 1, ...result },
    })
    expect(
      BancadaNotice.text({
        ...base,
        parts: [
          part("Invalido", {
            machine: mac,
            outcome: outcome({ verdict: "invalido", approved: false, reason: "pedido inválido (saída 2 no run)" }),
          }),
          part("Perdidos", {
            machine: mac,
            ms: 9 * 60_000,
            outcome: outcome({
              verdict: "incompleto",
              approved: false,
              reason: "2 cenário(s) sem resultado",
              scenarios: passed(10),
              lost: ["x", "y"],
              retried: { count: 2, reason: "a máquina dormiu 12 min durante o run" },
            }),
          }),
          part("Fora", {
            state: "perdido",
            machine: { machineID: "m", name: "Mac" },
            outcome: outcome({
              verdict: "infraestrutura",
              approved: false,
              reason: "a máquina Mac não respondeu",
              scenarios: passed(3),
              lost: ["a", "b", "c", "d", "e"],
            }),
          }),
        ],
      }),
    ).toBe(
      [
        "[Bancada] j-7qk2m9xa terminou: incompleto, não é aprovação (commit 3417b7e3)",
        "Invalido: nenhum cenário. Pedido inválido (saída 2 no run). Mac de Alexandre.",
        "Perdidos: 10 aprovados, 2 sem resultado; 2 refeitos (a máquina dormiu 12 min durante o run). Mac de Alexandre, 9 min.",
        "Fora: 3 aprovados, 5 sem resultado. A máquina Mac não respondeu. Mac.",
      ].join("\n"),
    )
    expect(
      BancadaNotice.text({
        ...base,
        parts: [part("Android", { state: "cancelado", outcome: outcome({ verdict: "cancelado" }) })],
      }),
    ).toBe(["[Bancada] j-7qk2m9xa foi cancelado (commit 3417b7e3)", "Android: cancelado."].join("\n"))
  })

  test("the plan's approved example, and the verdict of each kind of request", () => {
    const part = (label: string, result: Partial<BancadaProtocol.PartResult>) => ({
      label,
      result: { part: label.toLowerCase(), state: "concluido" as const, attempts: 1, machine: mac, ...result },
    })
    expect(
      BancadaNotice.text({
        ...base,
        parts: [
          part("Android", { ms: 6 * 60_000, outcome: outcome({ scenarios: [...passed(112), ...ignored(2)] }) }),
          part("iOS", { ms: 4 * 60_000, outcome: outcome({ scenarios: passed(23) }) }),
        ],
      }),
    ).toBe(
      [
        "[Bancada] j-7qk2m9xa terminou: aprovado (commit 3417b7e3)",
        "Android: 112 aprovados, 2 ignorados. Mac de Alexandre, 6 min.",
        "iOS: 23 aprovados. Mac de Alexandre, 4 min.",
      ].join("\n"),
    )
    const approved = part("A", { outcome: outcome({ scenarios: passed(1) }) })
    const lost = part("B", {
      outcome: outcome({ verdict: "incompleto", approved: false, scenarios: passed(10), lost: ["x", "y"] }),
    })
    const silent = part("C", {
      outcome: outcome({ verdict: "sem_relatorio", approved: false, reason: "falhou sem relatório (saída 1)" }),
    })
    const cancelled = part("D", { state: "cancelado", outcome: outcome({ verdict: "cancelado", approved: false }) })
    expect(
      [[approved], [approved, lost], [approved, silent], [approved, cancelled], [cancelled]].map((parts) =>
        BancadaNotice.verdict({ parts }),
      ),
    ).toEqual(["aprovado", "incompleto", "falhou", "incompleto", "cancelado"])
  })

  test("more than 20 failures: the first 20, and where the whole list is; evidence that did not arrive is said", () => {
    const failures = Array.from({ length: 23 }, (_, index) => ({
      id: `f${index + 1}`,
      result: "falhou" as const,
      message: "achou outra coisa",
    }))
    const text = BancadaNotice.text({
      ...base,
      failuresFile: "/tmp/opencode/bancada/j-7qk2m9xa/falhas.json",
      parts: [
        {
          label: "Android",
          result: {
            part: "android",
            state: "concluido",
            attempts: 1,
            machine: mac,
            outcome: outcome({ verdict: "falhou", approved: false, scenarios: failures }),
          },
          delivered: { files: {}, missing: 2 },
        },
      ],
    })
    const lines = text.split("\n")
    expect(lines[1]).toBe("Android: 23 falharam. Mac de Alexandre. 2 arquivos de evidência não chegaram.")
    expect(lines.filter((line) => line.startsWith("✗ "))).toHaveLength(20)
    expect(lines.at(-1)).toBe("… e mais 3 falhas: a lista inteira está em /tmp/opencode/bancada/j-7qk2m9xa/falhas.json")
  })
})
