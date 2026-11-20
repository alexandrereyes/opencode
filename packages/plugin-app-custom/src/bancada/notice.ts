export * as BancadaNotice from "./notice.js"

import type { BancadaProtocol } from "./protocol.js"

/**
 * The notice a session receives when its request ends (`docs/bancada.md`, "Notice"): one line for the request, one per
 * part, then each failure with its message, history and evidence; the log's end for a failure the scenarios do not
 * explain. Pure: the origin gives what the hub said and where it put the evidence. Never the number of offers
 * (`attempts`): a part tells how many scenarios ran again, not how many times it was offered.
 */

export type Input = {
  readonly job: string
  readonly commit: string
  /** The snapshot of the working tree, when one was frozen: how many files it took beyond the commit. */
  readonly snapshot?: { readonly files: number }
  readonly parts: ReadonlyArray<{
    readonly label: string
    readonly result: BancadaProtocol.PartResult
    /** Where the origin put its evidence, by file name; how many files did not arrive. */
    readonly delivered?: { readonly files: Readonly<Record<string, string>>; readonly missing: number }
  }>
  /** Where the full list goes when there are more failures than the notice shows. */
  readonly failuresFile?: string
}

export const limits = {
  /** Failures shown; the rest are in `falhas.json`. */
  failures: 20,
  /** Lines of a log shown for a failure the scenarios do not explain. */
  logLines: 30,
}

export function text(input: Input) {
  const failures = input.parts.flatMap((part) =>
    (part.result.outcome?.scenarios ?? [])
      .filter((scenario) => scenario.result === "falhou")
      .map((scenario) => ({ part, scenario })),
  )
  const cancelled = input.parts.every((part) => part.result.state === "cancelado")
  return [
    `[Bancada] ${input.job} ${cancelled ? "foi cancelado" : "terminou"} (${code(input)})`,
    ...input.parts.map((part) => line(part)),
    ...failures.slice(0, limits.failures).flatMap(({ part, scenario }) => failure(part, scenario)),
    ...(failures.length > limits.failures
      ? [
          `… e mais ${failures.length - limits.failures} falhas${input.failuresFile ? `: a lista inteira está em ${input.failuresFile}` : ""}`,
        ]
      : []),
    ...input.parts.flatMap((part) => log(part)),
  ].join("\n")
}

function code(input: Input) {
  const commit = `commit ${input.commit.slice(0, 8)}`
  if (!input.snapshot || input.snapshot.files === 0) return commit
  return `${commit}, snapshot com ${count(input.snapshot.files, "arquivo não commitado", "arquivos não commitados")}`
}

/** `Android: 112 aprovados, 1 falhou, 2 ignorados; 7 refeitos (um aparelho caiu). Mac de Alexandre, 6 min.` */
function line(part: Input["parts"][number]) {
  const result = part.result
  const outcome = result.outcome
  if (result.state === "cancelado") return `${part.label}: cancelado.`
  const scenarios = outcome?.scenarios ?? []
  const tally = [
    tallied(scenarios, "passou", "aprovado", "aprovados"),
    tallied(scenarios, "falhou", "falhou", "falharam"),
    tallied(scenarios, "ignorado", "ignorado", "ignorados"),
    outcome?.lost.length ? count(outcome.lost.length, "sem resultado", "sem resultado") : undefined,
  ].filter((item): item is string => item !== undefined)
  const retried = outcome?.retried
    ? `; ${count(outcome.retried.count, "refeito", "refeitos")}${because(outcome.retried.reason)}`
    : ""
  const problem = trouble(result)
  const where = [result.machine?.name, result.ms === undefined ? undefined : minutes(result.ms)]
    .filter((item): item is string => item !== undefined)
    .join(", ")
  const missing = part.delivered?.missing
    ? ` ${count(part.delivered.missing, "arquivo de evidência não chegou", "arquivos de evidência não chegaram")}.`
    : ""
  return `${part.label}: ${tally.length ? tally.join(", ") : "nenhum cenário"}${retried}.${problem ? ` ${problem}.` : ""}${where ? ` ${where}.` : ""}${missing}`
}

/** Why a part did not end as its scenarios say: a failed build, infrastructure, a failure without report… */
function trouble(result: BancadaProtocol.PartResult) {
  const outcome = result.outcome
  if (!outcome) return result.state === "perdido" ? "Sem resultado" : undefined
  if (outcome.verdict === "aprovado" || outcome.verdict === "falhou") return undefined
  // "N sem resultado" is in the tally already.
  if (outcome.verdict === "incompleto" && outcome.lost.length > 0) return undefined
  if (outcome.verdict === "compilacao") return "A compilação falhou"
  if (outcome.verdict === "invalido") return capital(outcome.reason ?? "pedido inválido")
  return capital(outcome.reason ?? outcome.verdict)
}

/** `✗ ReadVoice › Ouvir uma mensagem de voz que chegou`, its message, history and evidence. */
function failure(part: Input["parts"][number], scenario: BancadaProtocol.Scenario) {
  const history = part.result.history?.[scenario.id]
  const evidence = (scenario.evidence ?? [])
    .map((file) => part.delivered?.files[file.split(/[\\/]/).join("-")] ?? part.delivered?.files[file])
    .filter((file): file is string => file !== undefined)
  return [
    `✗ ${scenario.name ?? scenario.id}`,
    ...(scenario.message ? [`  ${scenario.message}`] : []),
    ...(history && history.of > 1 ? [`  Histórico: falhou ${history.failed} das últimas ${history.of} vezes`] : []),
    ...(evidence.length ? [`  Evidências: ${evidence.join(", ")}`] : []),
  ]
}

/** The log's end for a failure the scenarios do not explain, with where the whole log is. */
function log(part: Input["parts"][number]) {
  const outcome = part.result.outcome
  if (!outcome?.logTail) return []
  if (!["compilacao", "infraestrutura", "sem_relatorio", "invalido"].includes(outcome.verdict)) return []
  const file = Object.entries(part.delivered?.files ?? {}).find(([name]) => name.endsWith(".log"))?.[1]
  const lines = outcome.logTail.split("\n").slice(-limits.logLines)
  return [`${part.label}, fim do log${file ? ` (inteiro em ${file})` : ""}:`, ...lines.map((item) => `  ${item}`)]
}

/** Why scenarios ran again: a device that fell is the common case, said short. */
function because(reason: string | undefined) {
  if (!reason) return ""
  if (reason.startsWith("um aparelho caiu")) return " por queda de aparelho"
  return ` (${reason})`
}

function tallied(
  scenarios: ReadonlyArray<BancadaProtocol.Scenario>,
  result: BancadaProtocol.Scenario["result"],
  one: string,
  many: string,
) {
  const n = scenarios.filter((scenario) => scenario.result === result).length
  return n === 0 ? undefined : count(n, one, many)
}

function count(n: number, one: string, many: string) {
  return `${n} ${n === 1 ? one : many}`
}

function minutes(ms: number) {
  return `${Math.max(1, Math.round(ms / 60_000))} min`
}

function capital(text: string) {
  return text.charAt(0).toUpperCase() + text.slice(1)
}
