import { describe, expect, test } from "bun:test"
import type { Bancada } from "../src/bancada/rpc"
import {
  cancelText,
  holdLine,
  holdText,
  jobText,
  releaseText,
  sentences,
  submittedText,
  type Hold,
} from "../src/bancada/tools"

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

describe("bancada_run's answer when its wait was interrupted", () => {
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

describe("bancada_hold and bancada_release", () => {
  const now = 1_000_000
  const hold = (more: Partial<Hold>): Hold => ({
    hold: "r-7qk2m9xa",
    target: JSON.stringify({ kind: "fisico", device: "poco" }),
    state: "concedida",
    machine_name: "Mac de Alexandre",
    device: JSON.stringify({ id: "IBHUYT85ZTYH5XDM" }),
    expires_at: now + 10 * 60_000,
    position: null,
    reason: null,
    ...more,
  })

  test("granted, waiting, asked of a machine that did not answer yet, refused", () => {
    expect(holdText(hold({}), now)).toBe(
      [
        "Reserva r-7qk2m9xa concedida: o celular poco em Mac de Alexandre (id IBHUYT85ZTYH5XDM).",
        "Se alguém esperar, ela vence no pior caso em ~10 min; cada comando que usa o aparelho a renova. Solte com bancada_release quando terminar.",
      ].join("\n"),
    )
    expect(
      holdText(
        hold({
          target: JSON.stringify({ kind: "vaga", platform: "android", name: "Pixel_9" }),
          state: "esperando",
          device: null,
          expires_at: null,
          position: 2,
          reason: "sem folga para mais um aparelho agora",
        }),
        now,
      ),
    ).toBe(
      [
        "Reserva r-7qk2m9xa na fila: a vaga para Pixel_9 (Android) em Mac de Alexandre, 2º na fila (sem folga para mais um aparelho agora).",
        "Você será avisado por mensagem quando sair; o lugar dura 15 min, e pedir de novo antes disso o mantém.",
      ].join("\n"),
    )
    expect(
      holdText(hold({ state: "esperando", position: 1, reason: "aguardando poco" }), now).split("\n")[1],
    ).toStartWith("A reserva atual vence no pior caso em ~10 min. ")
    expect(holdText(hold({ state: "pedida", machine_name: null, device: null }), now)).toBe(
      "Reserva r-7qk2m9xa pedida: o celular poco em outra máquina; a resposta ainda não chegou. Você será avisado por mensagem quando sair.",
    )
    expect(holdText(hold({ state: "negada", reason: "o hub está fora" }), now)).toBe(
      "Sem reserva: o celular poco em Mac de Alexandre (o hub está fora).",
    )
    expect(holdLine(hold({}), now)).toBe(
      "r-7qk2m9xa: o celular poco em Mac de Alexandre, concedida (id IBHUYT85ZTYH5XDM); vence no pior caso em ~10 min",
    )
  })

  test("release's four answers", () => {
    expect(
      ["solta", "vencida", "desconhecida", "outra_familia"].map((state) => releaseText("r-7qk2m9xa", state)),
    ).toEqual([
      "Reserva r-7qk2m9xa solta.",
      "r-7qk2m9xa já tinha terminado; nada a soltar.",
      "Nenhuma reserva r-7qk2m9xa neste servidor.",
      "r-7qk2m9xa é de outra sessão; esta tool só solta reservas desta sessão e dos subagentes dela.",
    ])
  })
})
