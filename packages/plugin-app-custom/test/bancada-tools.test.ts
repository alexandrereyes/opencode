import { describe, expect, test } from "bun:test"
import type { Bancada } from "../src/bancada/rpc"
import { cancelText, jobText, sentences, submittedText } from "../src/bancada/tools"

// The tools' answers (`docs/bancada.md`, "Tools"): these texts are the norm.
const submitted = (more: Partial<Bancada.Submitted> = {}): Bancada.Submitted => ({
  job: "j-7qk2m9xa",
  state: "aguardando_confirmacao",
  commit: "9999999999999999999999999999999999999999",
  base: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d",
  partes: [
    { teste: "android", rotulo: "Android" },
    { teste: "ios", rotulo: "iOS" },
  ],
  ...more,
})
const view = (parts: Bancada.JobView["parts"], more: Partial<Bancada.JobView> = {}): Bancada.JobView => ({
  job: "j-7qk2m9xa",
  state: "na_fila",
  sessionID: "ses_a",
  rootSessionID: "ses_a",
  commit: "9999999999999999999999999999999999999999",
  base: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d",
  labels: { android: "Android", ios: "iOS" },
  parts,
  ...more,
})

describe("bancada_run's answer", () => {
  test("the plan's example: the owner's commit with what the working tree added, each test's place", () => {
    const files = [
      { caminho: "src/Checkout.cs", mudanca: "alterado" as const },
      { caminho: "tests/CheckoutTests.cs", mudanca: "novo" as const },
      { caminho: "README.md", mudanca: "alterado" as const },
    ]
    expect(
      submittedText(
        submitted({ snapshot: { arquivos: files } }),
        view({
          android: {
            state: "na_fila",
            attempt: 0,
            position: 2,
            etaMs: 4 * 60_000,
            reason: { code: "fila", text: "na fila" },
          },
          ios: {
            state: "na_fila",
            attempt: 0,
            position: 3,
            etaMs: 7 * 60_000,
            reason: { code: "orcamento", text: "aguardando um Mac" },
          },
        }),
      ),
    ).toBe(
      [
        "Pedido j-7qk2m9xa enviado. Código: commit 3417b7e3 mais 3 arquivos não commitados (src/Checkout.cs alterado, tests/CheckoutTests.cs novo, README.md alterado).",
        "Android: 2º na fila, ~4 min",
        "iOS: 3º na fila, ~7 min (aguardando um Mac)",
        sentences.later,
      ].join("\n"),
    )
  })

  test("a commit asked, more than 20 files, no confirmation, the hub out, accepted, a request replaced", () => {
    expect(
      submittedText(submitted({ snapshot: { arquivos: [], naoIncluidos: 2 } }))
        .split("\n")
        .slice(0, 3),
    ).toEqual([
      "Pedido j-7qk2m9xa enviado. Código: commit 3417b7e3, como pedido; 2 arquivos não commitados da árvore de trabalho ficaram de fora.",
      "Android: aguardando confirmação do hub",
      "iOS: aguardando confirmação do hub",
    ])
    const many = Array.from({ length: 23 }, (_, index) => ({ caminho: `f${index}.txt`, mudanca: "novo" as const }))
    expect(submittedText(submitted({ snapshot: { arquivos: many } })).split("\n")[0]).toEndWith(
      "f19.txt novo e mais 3).",
    )
    const away = { code: "aguardando_hub" as const, text: "aguardando o hub" }
    expect(
      submittedText(
        submitted(),
        view(
          {
            android: { state: "na_fila", attempt: 0, reason: away },
            ios: { state: "aceito", attempt: 1, machine: { machineID: "m", name: "Mac de Alexandre" } },
          },
          { state: "na_fila", replaced: ["j-aaaaaaaa"] },
        ),
      ).split("\n"),
    ).toEqual([
      "Pedido j-7qk2m9xa enviado. Código: commit 3417b7e3.",
      "Android: aguardando o hub (o pedido fica guardado e segue quando ele voltar)",
      "iOS: preparando em Mac de Alexandre",
      "Substituiu j-aaaaaaaa, que ainda esperava na fila.",
      sentences.later,
    ])
  })
})

describe("bancada_status and bancada_cancel", () => {
  test("each state in plain Portuguese, by label; a subagent's request says who asked; a finished one, its notice", () => {
    const mac = { machineID: "m", name: "Mac de Alexandre" }
    expect(
      jobText(
        view(
          {
            android: { state: "incerto", attempt: 1, machine: mac },
            ios: {
              state: "perdido",
              attempt: 2,
              machine: mac,
              reason: { code: "sem_maquina", text: "nenhuma máquina oferece ios" },
            },
          },
          { sessionID: "ses_b", sessionTitle: "Testar o checkout" },
        ),
      ),
    ).toBe(
      [
        "j-7qk2m9xa (pedido por Testar o checkout):",
        "  Android: sem notícia de Mac de Alexandre (ela não responde; a Bancada espera até 15 min)",
        "  iOS: sem resultado (nenhuma máquina oferece ios)",
      ].join("\n"),
    )
    expect(
      jobText(
        view({
          android: { state: "compilando", attempt: 1, machine: mac },
          ios: { state: "concluido", attempt: 1, machine: mac },
        }),
      ).split("\n"),
    ).toEqual(["j-7qk2m9xa:", "  Android: compilando em Mac de Alexandre", "  iOS: terminou"])
    expect(
      jobText(view({}, { state: "concluido", notice: "[Bancada] j-7qk2m9xa terminou: aprovado (commit 3417b7e3)" })),
    ).toBe("[Bancada] j-7qk2m9xa terminou: aprovado (commit 3417b7e3)")
  })

  test("cancel's four answers", () => {
    expect(
      ["cancelado", "concluido", "desconhecido", "outra_familia"].map((state) => cancelText("j-7qk2m9xa", state)),
    ).toEqual([
      "j-7qk2m9xa cancelado. O que esperava saiu da fila; o que rodava está sendo parado.",
      "j-7qk2m9xa já tinha terminado; nada a cancelar.",
      "Nenhum pedido j-7qk2m9xa neste servidor.",
      "j-7qk2m9xa é de outra sessão; esta tool só cancela pedidos desta sessão e dos subagentes dela.",
    ])
  })
})
