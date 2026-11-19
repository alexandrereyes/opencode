export * as BancadaResults from "./results.js"

import { Option, Schema } from "effect"
import type { BancadaProtocol } from "./protocol.js"

/**
 * How a part's attempt ended, judged against false green (`docs/bancada.md`, "False green"): a part is approved only
 * with exit 0, a valid `planned.json` and `summary.json`, a result for every scenario planned (or asked again) and none
 * failed. The project writes those files with Portuguese keys; everything else is this package's.
 */

/** `planned.json`, written before any device is touched. */
const Planned = Schema.Struct({
  versao: Schema.Literal(1),
  aparelhos: Schema.optional(Schema.Int),
  cenarios: Schema.Array(Schema.Struct({ id: Schema.String, nome: Schema.optional(Schema.String) })),
})
/** `summary.json`, written at the end. */
const Summary = Schema.Struct({
  versao: Schema.Literal(1),
  cenarios: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      resultado: Schema.Literals(["passou", "falhou", "ignorado"]),
      duracao_ms: Schema.optional(Schema.Number),
      aparelho: Schema.optional(Schema.NullOr(Schema.String)),
      mensagem: Schema.optional(Schema.NullOr(Schema.String)),
      evidencias: Schema.optional(Schema.Array(Schema.String)),
    }),
  ),
})
const decodePlanned = Schema.decodeUnknownOption(Planned)
const decodeSummary = Schema.decodeUnknownOption(Summary)

export type Verdict = BancadaProtocol.Outcome["verdict"]

/**
 * What the runner knows when a command stops: which stage, its exit code (absent when it never ended by itself) or the
 * cause, the project's two files as parsed JSON (undefined when missing), the scenarios asked again on a new attempt,
 * the devices the Bancada saw fall during the attempt and the end of the command's log.
 */
export type Ending = {
  readonly stage: "build" | "plan" | "run"
  readonly exit?: number
  readonly cause?: "prazo" | "runner_morto" | "cancelado"
  readonly planned?: unknown
  readonly summary?: unknown
  readonly only?: ReadonlyArray<string>
  readonly fell?: ReadonlyArray<string>
  readonly logTail?: string
}

/** Judges one attempt of a part. */
export function judge(ending: Ending): BancadaProtocol.Outcome {
  const planned = Option.getOrUndefined(decodePlanned(ending.planned))
  const summary = Option.getOrUndefined(decodeSummary(ending.summary))
  const names = new Map(planned?.cenarios.flatMap((item) => (item.nome ? [[item.id, item.nome] as const] : [])))
  const fell = new Set(ending.fell ?? [])
  const scenarios = merged(summary?.cenarios ?? [])
    // A failure on a device that fell during the attempt says nothing about the app: the scenario is lost instead.
    .filter((item) => !(item.resultado === "falhou" && item.aparelho && fell.has(item.aparelho)))
    .map((item) => scenario(item, names.get(item.id)))
  const expected = ending.only ? [...ending.only] : (planned?.cenarios.map((item) => item.id) ?? [])
  const answered = new Set(scenarios.map((item) => item.id))
  const lost = expected.filter((id) => !answered.has(id))
  const failed = scenarios.some((item) => item.result === "falhou")
  const base = {
    ...(ending.exit === undefined ? {} : { exit: ending.exit }),
    planned: expected,
    scenarios,
    lost,
    ...(ending.logTail ? { logTail: ending.logTail } : {}),
  }
  const outcome = (verdict: Verdict, reason?: string): BancadaProtocol.Outcome => ({
    ...base,
    verdict,
    ...(reason ? { reason } : {}),
    approved: verdict === "aprovado",
  })

  if (ending.cause === "cancelado") return outcome("cancelado", "cancelado")
  if (ending.cause === "prazo") return outcome("infraestrutura", "prazo estourado")
  if (ending.cause === "runner_morto") return outcome("infraestrutura", "a execução morreu")
  const exit = ending.exit ?? 75
  if (exit === 2) return outcome("invalido", `pedido inválido (saída 2 no ${ending.stage})`)
  if (ending.stage === "build")
    return exit === 75
      ? outcome("infraestrutura", "infraestrutura (saída 75 no build)")
      : outcome("compilacao", "a compilação falhou")
  if (ending.stage === "plan") return outcome("infraestrutura", `infraestrutura (saída ${exit} no plan)`)
  // A run that did not finish is infrastructure even with failures inside: those stay failed, the rest is lost.
  if (exit !== 0 && exit !== 1) return outcome("infraestrutura", `infraestrutura (saída ${exit})`)
  if (failed) return outcome("falhou")
  if (fell.size > 0 && lost.length > 0) return outcome("infraestrutura", "um aparelho caiu durante a execução")
  if (exit === 1) return outcome("sem_relatorio", "falhou sem relatório (saída 1)")
  if (!planned && !ending.only) return outcome("incompleto", "faltou o planned.json")
  if (!summary) return outcome("incompleto", "faltou o summary.json")
  if (expected.length === 0) return outcome("incompleto", "nenhum cenário planejado")
  if (lost.length) return outcome("incompleto", `${lost.length} cenário(s) sem resultado`)
  return outcome("aprovado")
}

/**
 * The result of a part after a new attempt (`docs/bancada.md`, "State machine"): the new attempt's results count for
 * the scenarios it was asked again (`retry.planned`), the earlier one's for the rest.
 */
export function join(previous: BancadaProtocol.Outcome, retry: BancadaProtocol.Outcome): BancadaProtocol.Outcome {
  const again = new Set(retry.planned)
  const scenarios = [...previous.scenarios.filter((item) => !again.has(item.id)), ...retry.scenarios]
  const answered = new Set(scenarios.map((item) => item.id))
  const lost = previous.planned.filter((id) => !answered.has(id))
  const failed = scenarios.some((item) => item.result === "falhou")
  const verdict: Verdict = failed ? "falhou" : lost.length === 0 ? "aprovado" : retry.verdict
  return {
    ...(retry.exit === undefined ? {} : { exit: retry.exit }),
    planned: previous.planned,
    scenarios,
    lost,
    ...(retry.logTail ? { logTail: retry.logTail } : {}),
    verdict,
    // Why scenarios still lack a result: the new attempt's reason, when it is the one that left them without.
    ...(verdict === retry.verdict && retry.reason ? { reason: retry.reason } : {}),
    approved: verdict === "aprovado",
  }
}

type Reported = (typeof Summary.Type)["cenarios"][number]

/** One result per scenario; a scenario reported twice failed if any report says so (never a green by the last word). */
function merged(items: ReadonlyArray<Reported>) {
  const byID = new Map<string, Reported>()
  for (const item of items) {
    const known = byID.get(item.id)
    if (!known || item.resultado === "falhou" || (known.resultado === "ignorado" && item.resultado === "passou"))
      byID.set(item.id, item)
  }
  return [...byID.values()]
}

function scenario(item: Reported, name: string | undefined): BancadaProtocol.Scenario {
  // Evidence is read later from the part's output folder: only paths inside it.
  const evidence = (item.evidencias ?? []).filter(
    (file) => !file.startsWith("/") && !file.split(/[\\/]/).includes(".."),
  )
  return {
    id: item.id,
    ...(name ? { name } : {}),
    result: item.resultado,
    ...(item.mensagem ? { message: item.mensagem } : {}),
    ...(item.duracao_ms === undefined ? {} : { durationMs: item.duracao_ms }),
    ...(item.aparelho ? { device: item.aparelho } : {}),
    ...(evidence.length ? { evidence } : {}),
  }
}
