import path from "node:path"
import { optional } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Tool } from "@opencode/schema/tool"
import { Effect, Schema } from "effect"
import type { Context } from "../context.js"
import { BancadaError, type BancadaClient } from "./client.js"
import { BancadaProtocol } from "./protocol.js"
import type { Bancada } from "./rpc.js"

/**
 * The agent's side of the Bancada (`docs/bancada.md`, "Tools"): ask for a run, see where requests stand, cancel one.
 * Descriptions are for the model (English); what the tools answer is for the agent and the owner (Portuguese).
 */

const RunInput = Schema.Struct({
  testes: Schema.Array(
    Schema.Struct({
      teste: Schema.String.annotate({ description: "A test name from the repository's .bancada.toml." }),
      args: optional(Schema.Array(Schema.String)).annotate({
        description: "Extra arguments for the test's run command (a filter, say).",
      }),
    }),
  )
    .check(Schema.isMinLength(1), Schema.isMaxLength(8))
    .annotate({ description: "The tests to run, each once." }),
  snapshot: optional(Schema.Boolean).annotate({
    description: "Freeze the working tree as it is now, uncommitted files included. Otherwise the commit runs.",
  }),
  commit: optional(Schema.String).annotate({ description: "The commit to run; HEAD by default." }),
  diretorio: optional(Schema.String).annotate({
    description: "A folder of the repository to test; the session's folder by default.",
  }),
  esperar: optional(Schema.Boolean).annotate({
    description:
      "Hold this call until the result and return it. Only for a subagent that must have the result before it ends.",
  }),
})
const StatusInput = Schema.Struct({
  job: optional(Schema.String).annotate({
    description: "A request id (j-…). Without it: every request of this session's family not delivered yet.",
  }),
})
const CancelInput = Schema.Struct({ job: Schema.String.annotate({ description: "The request id (j-…)." }) })

export const descriptions = {
  run: [
    "Run tests declared in the repository's .bancada.toml on devices the Bancada prepares, on whichever machine can run them (this one, the Mac or the host-6).",
    "The code is frozen now: the commit, or with snapshot the working tree as it is. The call returns at once with the request id and its place in the queue.",
    "The result arrives by itself, later, as a message in this session: do not wait in a loop, do not poll bancada_status.",
    "A subagent that needs the result before it ends uses esperar: true.",
    "Never run yourself the scripts the project reserves to the Bancada, nor boot an emulator or simulator for tests.",
  ].join(" "),
  status:
    "Where this session's Bancada requests stand: per test its state, machine, place in the queue, estimate and why it waits. Only when asked or when deciding something; the result arrives by itself.",
  cancel:
    "Cancel a Bancada request of this session: what waits closes now, what runs stops. The notice of the request says so.",
}

export function registerBancadaTools(
  ctx: Pick<Context, "tool" | "session">,
  client: BancadaClient,
  instanceID: () => Promise<string>,
) {
  return ctx.tool
    .transform((editor) => {
      editor.add({
        name: "bancada_run",
        description: descriptions.run,
        input: standard(RunInput),
        options: { codemode: false },
        execute: (input, context) =>
          Effect.gen(function* () {
            const family = yield* familyOf(ctx, context.sessionID)
            // The same call made again (the server restarted in the middle) is the same request.
            const id = BancadaProtocol.jobID(`${yield* Effect.promise(instanceID)}\n${context.id}`)
            const request: Bancada.Request = {
              id,
              sessionID: context.sessionID,
              rootSessionID: family.root,
              ...(family.title ? { sessionTitle: family.title } : {}),
              ...(family.rootTitle ? { rootTitle: family.rootTitle } : {}),
              toolCallID: context.id,
              diretorio: input.diretorio ?? family.directory,
              testes: input.testes.map((item) => ({ teste: item.teste, ...(item.args ? { args: item.args } : {}) })),
              ...(input.snapshot === undefined ? {} : { snapshot: input.snapshot }),
              ...(input.commit ? { commit: input.commit } : {}),
              ...(input.esperar ? { esperar: true } : {}),
            }
            const submitted = yield* call(() => client.call<Bancada.Submitted>("submit", request, 120_000))
            if (!input.esperar) return { output: submitted, content: submittedText(submitted) }
            const notice = yield* waitFor(client, submitted.job, context.cancel)
            return { output: submitted, content: notice ?? `${submittedText(submitted)}\n${stopped}` }
          }),
      })
      editor.add({
        name: "bancada_status",
        description: descriptions.status,
        input: standard(StatusInput),
        options: { codemode: false },
        execute: (input, context) =>
          Effect.gen(function* () {
            const family = yield* familyOf(ctx, context.sessionID)
            const answer = yield* call(() =>
              client.call<{ jobs: Bancada.JobView[] }>(
                "status",
                input.job ? { job: input.job } : { rootSessionID: family.root },
              ),
            )
            if (answer.jobs.length === 0)
              return { content: input.job ? `Nenhum pedido ${input.job} neste servidor.` : "Nenhum pedido em aberto." }
            return { content: answer.jobs.map(jobText).join("\n\n") }
          }),
      })
      editor.add({
        name: "bancada_cancel",
        description: descriptions.cancel,
        input: standard(CancelInput),
        options: { codemode: false },
        execute: (input) =>
          call(() => client.call<{ state: string }>("cancel", { job: input.job })).pipe(
            Effect.map((answer) => ({
              content:
                answer.state === "desconhecido"
                  ? `Nenhum pedido ${input.job} neste servidor.`
                  : answer.state === "concluido" || answer.state === "entregue" || answer.state === "recebido"
                    ? `${input.job} já tinha terminado; o aviso dele chega ou já chegou.`
                    : `${input.job}: cancelamento pedido. O aviso do pedido diz como cada teste terminou.`,
            })),
          ),
      })
    })
    .pipe(Effect.orDie)
}

const stopped = "A espera foi interrompida; o resultado chegará como mensagem nesta sessão."

/** Holds the tool until the notice is ready (25 s at a time); hands it back and marks it delivered. */
function waitFor(client: BancadaClient, job: string, cancel: Effect.Effect<void> | undefined) {
  const poll: Effect.Effect<string> = call(() =>
    client.call<{ jobs: Bancada.JobView[] }>("status", { job, waitMs: 25_000 }, 40_000),
  ).pipe(
    Effect.catch(() => Effect.succeed({ jobs: [] as Bancada.JobView[] })),
    Effect.flatMap((answer) => {
      const notice = answer.jobs[0]?.state === "concluido" ? answer.jobs[0].notice : undefined
      return notice ? Effect.succeed(notice) : Effect.sleep("1 second").pipe(Effect.andThen(poll))
    }),
  )
  const delivered = (notice: string) =>
    call(() => client.call("notice.ack", { job, inline: true })).pipe(
      Effect.catch(() => Effect.void),
      Effect.as(notice),
    )
  const waiting = poll.pipe(Effect.flatMap(delivered))
  // Cancelled by the user: the notice goes the normal way, as a message.
  return cancel
    ? Effect.raceFirst(waiting, cancel.pipe(Effect.as(undefined as string | undefined)))
    : waiting.pipe(Effect.map((notice): string | undefined => notice))
}

/** The `Submitted` answer as the agent reads it: id, commit, what the snapshot took, each test's place. */
export function submittedText(submitted: Bancada.Submitted) {
  const files = submitted.snapshot?.arquivos ?? []
  const shown = files.slice(0, 20).map((file) => `${file.caminho} (${file.mudanca})`)
  return [
    `Pedido ${submitted.job} enviado (commit ${submitted.commit.slice(0, 8)}).`,
    ...(files.length
      ? [
          `Snapshot com ${files.length} ${files.length === 1 ? "arquivo" : "arquivos"}: ${shown.join(", ")}${files.length > 20 ? ` e mais ${files.length - 20}` : ""}.`,
        ]
      : []),
    ...(submitted.snapshot?.naoIncluidos
      ? [
          `Ficaram de fora ${submitted.snapshot.naoIncluidos} ${submitted.snapshot.naoIncluidos === 1 ? "arquivo não commitado" : "arquivos não commitados"} (com snapshot: true eles entram).`,
        ]
      : []),
    ...submitted.partes.map((part) => `${part.teste}: ${place(part.posicao, part.etaMs, part.motivo?.text)}`),
    "O resultado chega sozinho como mensagem nesta sessão: não consulte em laço.",
  ].join("\n")
}

/** A request as `bancada_status` tells it: one line for it, one per test. */
export function jobText(job: Bancada.JobView) {
  const header = `${job.job} (commit ${job.commit.slice(0, 8)}): ${jobState(job.state)}`
  if (job.notice) return `${header}\n${job.notice}`
  return [
    header,
    ...Object.entries(job.parts).map(([part, view]) => `  ${job.labels[part] ?? part}: ${partText(view)}`),
  ].join("\n")
}

function jobState(state: string) {
  if (state === "aguardando_confirmacao") return "aguardando confirmação do hub"
  if (state === "na_fila") return "em andamento"
  if (state === "recebido") return "terminou; o aviso está sendo montado"
  if (state === "concluido") return "terminou"
  return state.replaceAll("_", " ")
}

function partText(view: Bancada.JobView["parts"][string]) {
  const at = view.machine ? ` em ${view.machine.name}` : ""
  if (view.state === "na_fila") return place(view.position, view.etaMs, view.reason?.text)
  if (view.state === "rodando" || view.state === "compilando") return `${view.state}${at}`
  if (view.state === "incerto") return `incerto${at} (a máquina não responde)`
  return `${view.state.replaceAll("_", " ")}${at}${view.reason ? ` (${view.reason.text})` : ""}`
}

/** `2º na fila, ~4 min (aguardando um Mac)`. */
function place(position: number | undefined, etaMs: number | undefined, reason: string | undefined) {
  const where = position === undefined ? undefined : `${position}º na fila`
  const when = etaMs === undefined ? undefined : `~${Math.max(1, Math.round(etaMs / 60_000))} min`
  const head = [where, when].filter((item): item is string => item !== undefined).join(", ")
  if (!head) return reason ?? "na fila"
  return reason && reason !== "na fila" ? `${head} (${reason})` : head
}

/** The session's family as the request carries it: its root, the titles, the folder it works in. */
const familyOf = Effect.fnUntraced(function* (ctx: Pick<Context, "session">, sessionID: Session.ID) {
  const session = yield* ctx.session.get({ sessionID }).pipe(Effect.orDie)
  const chain = [session]
  for (let depth = 0; chain.at(-1)!.parentID && depth < 32; depth++)
    chain.push(yield* ctx.session.get({ sessionID: chain.at(-1)!.parentID! }).pipe(Effect.orDie))
  const root = chain.at(-1)!
  return {
    root: root.id,
    directory: path.join(session.location.directory, session.subpath ?? ""),
    ...(session.title ? { title: session.title } : {}),
    ...(root.title ? { rootTitle: root.title } : {}),
  }
})

/** A call to this machine's process; its refusal as the tool's error, in Portuguese. */
function call<A>(run: () => Promise<A>) {
  return Effect.tryPromise({ try: run, catch: (error) => error }).pipe(
    Effect.mapError(
      (error) =>
        new Tool.Error({
          message:
            error instanceof BancadaError && error.reason === "invalid" && error.problems?.length
              ? `Pedido recusado:\n${error.problems.map((problem) => `- ${problem}`).join("\n")}`
              : error instanceof BancadaError
                ? error.message
                : "O processo da Bancada desta máquina não está respondendo.",
        }),
    ),
  )
}

function standard<A>(schema: Schema.Codec<A, unknown>) {
  return {
    "~standard": {
      ...Schema.toStandardSchemaV1(schema)["~standard"],
      ...Schema.toStandardJSONSchemaV1(schema)["~standard"],
    },
  }
}
