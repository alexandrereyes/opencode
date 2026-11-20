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
        description: "Extra arguments for that test's run command, after the test's own (a filter, for example).",
      }),
    }),
  )
    .check(Schema.isMinLength(1), Schema.isMaxLength(8))
    .annotate({ description: "The tests to run, each once." }),
  commit: optional(Schema.String).annotate({
    description: "Test this commit (a SHA, branch or tag) instead of the working tree.",
  }),
  diretorio: optional(Schema.String).annotate({
    description: "A folder inside the repository to test, when it is not this session's folder.",
  }),
  esperar: optional(Schema.Boolean).annotate({
    description:
      "Whether this call waits for the result. Default: true in a subagent, false in a main session. Leave it unset unless you need the other behaviour; true in a main session blocks the conversation until the tests end.",
  }),
})
const StatusInput = Schema.Struct({
  job: optional(Schema.String).annotate({
    description: "A request id (j-…). Without it: every request of this session and its subagents not delivered yet.",
  }),
})
const CancelInput = Schema.Struct({ job: Schema.String.annotate({ description: "The request id (j-…)." }) })

/** For the model (English), as `docs/bancada.md` ("Tools") fixes them. */
export const descriptions = {
  run: `Run the project's device tests (Android emulator, iOS simulator, phone, or tests that need no device) through the
Bancada, the test bench that prepares the devices and runs each test on whichever machine can run it, which may be
another computer. Use it whenever you need these tests; never run them yourself.

- Tests are the names declared in the repository's .bancada.toml ([teste.<name>]); read that file to choose. A
  repository without that file cannot use this tool.
- What is tested is frozen when you call: the working tree exactly as it is now, uncommitted and new files included
  (ignored files stay out). With \`commit\`, that commit instead. Later edits do not change a request already made.
- A run takes minutes, longer when the queue is busy. In a main session this call returns at once with the request
  id and where each test stands. The result arrives later by itself, as a message that resumes this session. After
  calling, go on with other work or, if there is nothing else to do, end your response. Do not wait, sleep, call
  bancada_status to check, or call bancada_run again for the same tests.
- In a subagent this call waits and returns the result itself.
- Never run the scripts the project reserves to the Bancada, and never start an emulator or simulator for tests: the
  Bancada does both.`,
  status: `Show where the Bancada requests of this session and its subagents stand: queue place, estimate, machine, and why
one waits. Use it only when the user asks, or once to explain a delay. Never call it to wait for a result: results
arrive by themselves as a message (in a subagent, as the return of bancada_run), and asking again does not make them
come sooner.`,
  cancel: `Cancel a Bancada request of this session or its subagents: tests still waiting leave the queue, tests running are
stopped. Use it when the user asks or when the result is no longer needed. To test newer code you do not need to
cancel first: a new bancada_run replaces this session's earlier request for the same tests while it still waits.`,
}

/** The answers' fixed sentences (`docs/bancada.md`, "Tools"). */
export const sentences = {
  later:
    "O resultado chega sozinho, como mensagem nesta sessão, e ela é retomada na hora. Siga com outro trabalho ou encerre sua resposta. Não espere, não consulte bancada_status e não peça de novo.",
  stopped: "A espera foi interrompida; o resultado chegará como mensagem nesta sessão.",
  reminder: "O resultado chega sozinho como mensagem nesta sessão; não é preciso consultar de novo.",
  unavailable:
    "O processo da Bancada desta máquina não está respondendo. Tente mais uma vez em instantes; se continuar, avise o usuário. Não rode os testes de outro jeito.",
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
              // Without a commit, the working tree as it is now (what the agent wants after an edit).
              ...(input.commit ? { commit: input.commit } : { snapshot: true }),
            }
            const submitted = yield* call(() => client.call<Bancada.Submitted>("submit", request, 120_000))
            // In a subagent the call waits for the result: its parent gets one report, with the result in it.
            const wait = input.esperar ?? family.subagent
            if (!wait) {
              const placed = yield* confirmed(client, submitted.job)
              return { output: submitted, content: submittedText(submitted, placed) }
            }
            const notice = yield* waitFor(client, submitted.job, context.cancel)
            if (notice) return { output: submitted, content: notice }
            const placed = yield* confirmed(client, submitted.job)
            return {
              output: submitted,
              content: `${submittedText(submitted, placed).replace(`\n${sentences.later}`, "")}\n${sentences.stopped}`,
            }
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
            const jobs = answer.jobs.filter((job) => !input.job || job.rootSessionID === family.root)
            if (jobs.length === 0)
              return {
                content: input.job
                  ? `Nenhum pedido ${input.job} nesta sessão.`
                  : "Nenhum pedido em aberto nesta sessão nem nos subagentes dela.",
              }
            const running = jobs.some((job) => job.state !== "concluido" && job.state !== "entregue")
            return { content: [...jobs.map(jobText), ...(running ? [sentences.reminder] : [])].join("\n\n") }
          }),
      })
      editor.add({
        name: "bancada_cancel",
        description: descriptions.cancel,
        input: standard(CancelInput),
        options: { codemode: false },
        execute: (input, context) =>
          Effect.gen(function* () {
            const family = yield* familyOf(ctx, context.sessionID)
            const answer = yield* call(() =>
              client.call<{ state: string }>("cancel", { job: input.job, rootSessionID: family.root }),
            )
            return { content: cancelText(input.job, answer.state) }
          }),
      })
    })
    .pipe(Effect.orDie)
}

/** `bancada_cancel`'s answer, by what the process said. */
export function cancelText(job: string, state: string) {
  if (state === "desconhecido") return `Nenhum pedido ${job} neste servidor.`
  if (state === "outra_familia")
    return `${job} é de outra sessão; esta tool só cancela pedidos desta sessão e dos subagentes dela.`
  if (state === "cancelado") return `${job} cancelado. O que esperava saiu da fila; o que rodava está sendo parado.`
  return `${job} já tinha terminado; nada a cancelar.`
}

/** Up to 3 s for the hub's confirmation, so the answer says each test's place in the queue. */
function confirmed(client: BancadaClient, job: string) {
  const look = Effect.tryPromise(() => client.call<{ jobs: Bancada.JobView[] }>("status", { job })).pipe(
    Effect.map((answer) => answer.jobs[0]),
    Effect.catch(() => Effect.succeed(undefined)),
  )
  const settled = (view: Bancada.JobView | undefined) =>
    view !== undefined &&
    (view.state !== "aguardando_confirmacao" ||
      Object.values(view.parts).some((part) => part.reason?.code === "aguardando_hub"))
  const poll = (deadline: number): Effect.Effect<Bancada.JobView | undefined> =>
    look.pipe(
      Effect.flatMap((view) =>
        settled(view) || Date.now() >= deadline
          ? Effect.succeed(view)
          : Effect.sleep("250 millis").pipe(Effect.andThen(poll(deadline))),
      ),
    )
  return Effect.suspend(() => poll(Date.now() + 3_000))
}

/** Holds the tool until the notice is ready (25 s at a time); hands it back and marks it delivered. */
function waitFor(client: BancadaClient, job: string, cancel: Effect.Effect<void> | undefined) {
  // `inline`: this is the tool that waits; the notice does not go as a message while it asks.
  const poll: Effect.Effect<string> = call(() =>
    client.call<{ jobs: Bancada.JobView[] }>("status", { job, waitMs: 25_000, inline: true }, 40_000),
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

/** `bancada_run`'s answer in a main session: the request, its code, each test's place, what it replaced. */
export function submittedText(submitted: Bancada.Submitted, view?: Bancada.JobView) {
  const parts = submitted.partes.map((part) => {
    const current = view?.parts[part.teste]
    return `${part.rotulo}: ${current ? standing(view!, current) : unconfirmed}`
  })
  const replaced = view?.replaced ?? submitted.substituiu ?? []
  return [
    `Pedido ${submitted.job} enviado. Código: ${codeText(submitted)}`,
    ...parts,
    ...replaced.map((job) => `Substituiu ${job}, que ainda esperava na fila.`),
    sentences.later,
  ].join("\n")
}

const unconfirmed = "aguardando confirmação do hub"

/** `commit 3417b7e3 mais 3 arquivos não commitados (src/Checkout.cs alterado, …).` */
function codeText(submitted: Bancada.Submitted) {
  const commit = `commit ${submitted.base.slice(0, 8)}`
  const files = submitted.snapshot?.arquivos ?? []
  const left = submitted.snapshot?.naoIncluidos ?? 0
  if (files.length > 0) {
    const shown = files.slice(0, 20).map((file) => `${file.caminho} ${file.mudanca}`)
    const more = files.length > 20 ? ` e mais ${files.length - 20}` : ""
    return `${commit} mais ${count(files.length, "arquivo não commitado", "arquivos não commitados")} (${shown.join(", ")}${more}).`
  }
  if (left > 0)
    return `${commit}, como pedido; ${count(left, "arquivo não commitado", "arquivos não commitados")} da árvore de trabalho ${left === 1 ? "ficou" : "ficaram"} de fora.`
  return `${commit}.`
}

/** A request as `bancada_status` tells it: its id (and who asked, for a subagent's), one line per test. */
export function jobText(job: Bancada.JobView) {
  if (job.notice) return job.notice
  return [
    `${job.job}${job.sessionTitle ? ` (pedido por ${job.sessionTitle})` : ""}:`,
    ...Object.entries(job.parts).map(([part, view]) => `  ${job.labels[part] ?? part}: ${standing(job, view)}`),
  ].join("\n")
}

/** Where a test stands, in plain Portuguese (`docs/bancada.md`, "Tools"). */
function standing(job: Bancada.JobView, view: Bancada.JobView["parts"][string]) {
  const machine = view.machine?.name ?? "outra máquina"
  if (view.reason?.code === "aguardando_hub")
    return "aguardando o hub (o pedido fica guardado e segue quando ele voltar)"
  if (job.state === "aguardando_confirmacao") return unconfirmed
  if (view.state === "na_fila") return place(view.position, view.etaMs, view.reason)
  if (view.state === "oferecido" || view.state === "aceito") return `preparando em ${machine}`
  if (view.state === "compilando" || view.state === "rodando") return `${view.state} em ${machine}`
  if (view.state === "incerto") return `sem notícia de ${machine} (ela não responde; a Bancada espera até 15 min)`
  if (view.state === "concluido") return "terminou"
  if (view.state === "cancelado") return "cancelado"
  return view.reason ? `sem resultado (${view.reason.text})` : "sem resultado"
}

/** `2º na fila, ~4 min (aguardando um Mac)`: the reason only when it is not "na fila". */
function place(position: number | undefined, etaMs: number | undefined, reason: BancadaProtocol.Reason | undefined) {
  const where = position === undefined ? undefined : `${position}º na fila`
  const when = etaMs === undefined ? undefined : `~${Math.max(1, Math.round(etaMs / 60_000))} min`
  const head = [where, when].filter((item): item is string => item !== undefined).join(", ")
  const why = reason && reason.code !== "fila" ? reason.text : undefined
  if (!head) return why ?? "na fila"
  return why ? `${head} (${why})` : head
}

function count(n: number, one: string, many: string) {
  return `${n} ${n === 1 ? one : many}`
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
    /** A subagent's session (it has a parent): its call waits for the result by default. */
    subagent: session.parentID !== undefined,
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
              : error instanceof BancadaError && error.reason !== "process"
                ? error.message
                : sentences.unavailable,
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
