export * as BancadaResults from "./results.js"

import os from "node:os"
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
 * What the runner knows when a command stops: which stage, its exit code (absent when it never ended by itself) and the
 * signal that killed it, or the cause, with the runner's reason; the project's two files as parsed JSON (undefined when
 * missing), the scenarios asked again on a new attempt, the devices the Bancada saw fall during the attempt and the end
 * of the command's log.
 */
export type Ending = {
  readonly stage: "build" | "plan" | "run"
  readonly exit?: number
  readonly signal?: string
  readonly cause?: "prazo" | "runner_morto" | "runner_erro" | "cancelado"
  readonly reason?: string
  readonly planned?: unknown
  readonly summary?: unknown
  readonly only?: ReadonlyArray<string>
  readonly fell?: ReadonlyArray<string>
  /** How long the machine slept while the command that ended it ran. */
  readonly sleptMs?: number
  readonly logTail?: string
}

/** Judges one attempt of a part. */
export function judge(ending: Ending): BancadaProtocol.Outcome {
  const planned = Option.getOrUndefined(decodePlanned(ending.planned))
  const summary = Option.getOrUndefined(decodeSummary(ending.summary))
  const names = new Map(planned?.cenarios.flatMap((item) => (item.nome ? [[item.id, item.nome] as const] : [])))
  const fell = new Set(ending.fell ?? [])
  const slept = ending.sleptMs ?? 0
  // A failure on a device that fell, or after the machine slept (the test's own clocks ran on), says nothing about the
  // app: the scenario is lost instead.
  const unreliable = (item: Reported) =>
    item.resultado === "falhou" && (slept > 0 || Boolean(item.aparelho && fell.has(item.aparelho)))
  const scenarios = merged(summary?.cenarios ?? [])
    .filter((item) => !unreliable(item))
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
  // Any other error after a sleep, at any stage, is the machine's: never "a compilação falhou", which is final.
  if (slept > 0 && (ending.cause !== undefined || (ending.exit ?? 75) !== 0))
    return outcome(
      "infraestrutura",
      `a máquina dormiu ${Math.max(1, Math.round(slept / 60_000))} min durante o ${ending.stage}`,
    )
  if (ending.cause === "prazo")
    return outcome("infraestrutura", ending.reason ? `prazo estourado: ${ending.reason}` : "prazo estourado")
  if (ending.cause === "runner_morto") return outcome("infraestrutura", "a execução morreu")
  if (ending.cause === "runner_erro")
    return outcome("infraestrutura", `o runner falhou: ${ending.reason ?? "sem motivo"}`)
  const exit = ending.exit ?? 75
  // Killed by a signal (seen by the runner, or passed on by a shell as 128 + the signal): the system ended it (memory,
  // most often), which says nothing about the code. The same for a command that never started.
  const killed = ending.signal ?? (exit > 128 && exit < 256 ? signalName(exit - 128) : undefined)
  if (killed) return outcome("infraestrutura", `o comando morreu pelo sinal ${killed} (no ${ending.stage})`)
  if (exit === 126) return outcome("infraestrutura", ending.reason ?? `o comando não partiu (no ${ending.stage})`)
  if (exit === 2) return outcome("invalido", `pedido inválido (saída 2 no ${ending.stage})`)
  if (ending.stage === "build")
    return exit === 75
      ? outcome("infraestrutura", ending.reason ?? "infraestrutura (saída 75 no build)")
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
  // Only ignored scenarios proved nothing (a filter that matched none, most often).
  if (!scenarios.some((item) => item.result === "passou")) return outcome("incompleto", "nenhum cenário rodou")
  return outcome("aprovado")
}

/**
 * The result of a part after a new attempt (`docs/bancada.md`, "State machine"): the new attempt's results count for
 * the scenarios it was asked again (`retry.planned`), the earlier one's for the rest. Its verdict, in this order: a
 * scenario failed → `falhou`; the new attempt alone was not approved → its verdict and reason (one that exited 1,
 * missed its deadline or died approves nothing, even with every scenario answered); a scenario still without result →
 * `incompleto`; otherwise `aprovado`.
 */
export function join(previous: BancadaProtocol.Outcome, retry: BancadaProtocol.Outcome): BancadaProtocol.Outcome {
  const again = new Set(retry.planned)
  const scenarios = [...previous.scenarios.filter((item) => !again.has(item.id)), ...retry.scenarios]
  const answered = new Set(scenarios.map((item) => item.id))
  const lost = previous.planned.filter((id) => !answered.has(id))
  const failed = scenarios.some((item) => item.result === "falhou")
  const [verdict, reason]: [Verdict, string | undefined] = failed
    ? ["falhou", undefined]
    : retry.verdict !== "aprovado"
      ? [retry.verdict, retry.reason]
      : lost.length > 0
        ? ["incompleto", `${lost.length} cenário(s) sem resultado`]
        : ["aprovado", undefined]
  return {
    ...(retry.exit === undefined ? {} : { exit: retry.exit }),
    planned: previous.planned,
    scenarios,
    lost,
    ...(retry.logTail ? { logTail: retry.logTail } : {}),
    verdict,
    ...(reason ? { reason } : {}),
    approved: verdict === "aprovado",
  }
}

/** `SIGKILL` for 9: the name of a signal number, as the shell's `128 + n` exit gives it. */
function signalName(number: number) {
  return Object.entries(os.constants.signals).find(([, value]) => value === number)?.[0] ?? `número ${number}`
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
