import path from "node:path"
import { optional } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Tool } from "@opencode/schema/tool"
import { Effect, Schema } from "effect"
import type { Context } from "../context.js"
import { BancadaError, type BancadaClient } from "./client.js"
import { BancadaProtocol } from "./protocol.js"
import { targetText } from "./daemon/holds.js"
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
})
const StatusInput = Schema.Struct({
  job: optional(Schema.String).annotate({
    description: "A request id (j-…). Without it: every request of this session and its subagents not delivered yet.",
  }),
})
const CancelInput = Schema.Struct({ job: Schema.String.annotate({ description: "The request id (j-…)." }) })
const HoldInput = Schema.Struct({
  aparelho: optional(Schema.String).annotate({
    description: "A phone of the Bancada's catalog, by its alias. Leave tipo and nome unset.",
  }),
  tipo: optional(Schema.Literals(["android", "ios"])).annotate({
    description: "The kind of emulator or simulator you are going to start (with nome).",
  }),
  nome: optional(Schema.String).annotate({
    description: "The AVD or simulator name you are going to start (with tipo).",
  }),
  maquina: optional(Schema.Literal("mac")).annotate({
    description:
      'Set to "mac" when the device is on the Mac reached through the mac bridge (your commands on it start with `mac`). Default: the machine this session runs on.',
  }),
})
const ReleaseInput = Schema.Struct({
  reserva: Schema.String.annotate({ description: "The reservation id bancada_hold gave (r-…)." }),
})

/** For the model (English), as `docs/bancada.md` ("Tools") fixes them. */
export const descriptions = {
  run: `Run the project's device tests (Android emulator, iOS simulator, phone, or tests that need no device) through the
Bancada, the test bench that prepares the devices and runs each test on whichever machine can run it, which may be
another computer. Use it whenever you need these tests; never run them yourself.

- Tests are the names declared in the repository's .bancada.toml ([teste.<name>]); read that file to choose. A
  repository without that file cannot use this tool.
- What is tested is frozen when you call: the working tree exactly as it is now, uncommitted and new files included
  (ignored files stay out). With \`commit\`, that commit instead. Later edits do not change a request already made.
- The call waits until the tests end and returns their result. That takes minutes, longer when the queue is busy.
- Never run the scripts the project reserves to the Bancada, and never start an emulator or simulator for tests: the
  Bancada does both.`,
  status: `Show where the Bancada requests of this session and its subagents stand: queue place, estimate, machine, and why
one waits; and the family's device reservations.`,
  cancel: `Cancel a Bancada request of this session or its subagents: tests still waiting leave the queue, tests running are
stopped. Use it when the user asks or when the result is no longer needed. To test newer code you do not need to
cancel first: a new bancada_run replaces this session's earlier request for the same tests while it still waits.`,
  hold: `Reserve a Bancada device for this session and its subagents before using it yourself: a phone of the catalog
({ aparelho }), or room for an emulator or simulator you are going to start ({ tipo, nome }). Commands that use a
catalog phone without a reservation, or start an emulator or simulator without room, are refused. Using the device
renews the reservation; it expires when idle while someone waits. If it is busy you get a place in the queue and are
told by a message when it is yours. Release it with bancada_release when done. Not for running tests: bancada_run
prepares its own devices.`,
  release: `Release a Bancada reservation of this session or its subagents (the id bancada_hold gave) as soon as you no
longer need the device: whoever waits for it gets it. The Bancada does not stop an emulator or simulator you started.`,
}

/** The answers' fixed sentences (`docs/bancada.md`, "Tools"). */
export const sentences = {
  stopped: "A espera foi interrompida; o resultado chegará como mensagem nesta sessão.",
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
            const notice = yield* waitFor(client, submitted.job, context.cancel)
            // The notice is delivered once the call's result is the session's (`hook.ts`, after the call): a call
            // interrupted from here on (a restart, a cancel) leaves it to come as a message.
            if (notice) return { content: notice, metadata: { [noticeKey]: submitted.job } }
            const placed = yield* confirmed(client, submitted.job)
            return { content: `${submittedText(submitted, placed)}\n${sentences.stopped}` }
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
            // Without a job, the family's reservations too.
            const holds = input.job
              ? []
              : (yield* call(() => client.call<{ holds: Hold[] }>("holds", { rootSessionID: family.root }))).holds
            if (jobs.length === 0 && holds.length === 0)
              return {
                content: input.job
                  ? `Nenhum pedido ${input.job} nesta sessão.`
                  : "Nenhum pedido em aberto nesta sessão nem nos subagentes dela.",
              }
            return {
              content: [
                ...jobs.map(jobText),
                ...(holds.length ? [["Reservas:", ...holds.map((hold) => `  ${holdLine(hold)}`)].join("\n")] : []),
              ].join("\n\n"),
            }
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
      editor.add({
        name: "bancada_hold",
        description: descriptions.hold,
        input: standard(HoldInput),
        options: { codemode: false },
        execute: (input, context) =>
          Effect.gen(function* () {
            if (!input.aparelho && !(input.tipo && input.nome))
              return yield* new Tool.Error({
                message: "Diga o celular (aparelho) ou o emulador ou simulador que vai ligar (tipo e nome).",
              })
            const family = yield* familyOf(ctx, context.sessionID)
            const hold = BancadaProtocol.holdID(`${yield* Effect.promise(instanceID)}\n${context.id}`)
            const answer = yield* call(() =>
              client.call<{ hold: Hold | null }>(
                "hold",
                {
                  hold,
                  sessionID: context.sessionID,
                  rootSessionID: family.root,
                  ...(family.title ? { sessionTitle: family.title } : {}),
                  ...(family.rootTitle ? { rootTitle: family.rootTitle } : {}),
                  ...(input.aparelho ? { aparelho: input.aparelho } : { tipo: input.tipo, nome: input.nome }),
                  ...(input.maquina ? { maquina: input.maquina } : {}),
                },
                20_000,
              ),
            )
            if (!answer.hold) return yield* new Tool.Error({ message: sentences.unavailable })
            return { content: holdText(answer.hold) }
          }),
      })
      editor.add({
        name: "bancada_release",
        description: descriptions.release,
        input: standard(ReleaseInput),
        options: { codemode: false },
        execute: (input, context) =>
          Effect.gen(function* () {
            const family = yield* familyOf(ctx, context.sessionID)
            const answer = yield* call(() =>
              client.call<{ state: string }>("release", { hold: input.reserva, rootSessionID: family.root }),
            )
            return { content: releaseText(input.reserva, answer.state) }
          }),
      })
    })
    .pipe(Effect.orDie)
}

/** A reservation as the process keeps it for this server's sessions (`grant_mirror`). */
export type Hold = {
  readonly hold: string
  readonly target: string
  readonly state: "pedida" | "concedida" | "esperando" | "negada" | "vencida" | "solta"
  readonly machine_name: string | null
  readonly device: string | null
  readonly expires_at: number | null
  readonly position: number | null
  readonly reason: string | null
}

/** `bancada_hold`'s answer: granted, waiting with its place, refused, or not answered yet. */
export function holdText(hold: Hold, now = Date.now()) {
  const what = `${targetText(JSON.parse(hold.target))} em ${hold.machine_name ?? "outra máquina"}`
  const ends =
    hold.expires_at === null ? undefined : `~${Math.max(1, Math.round((hold.expires_at - now) / 60_000))} min`
  if (hold.state === "concedida")
    return [
      `Reserva ${hold.hold} concedida: ${what}${deviceText(hold)}.`,
      `Se alguém esperar, ela vence no pior caso em ${ends ?? "pouco tempo"}; cada comando que usa o aparelho a renova. Solte com bancada_release quando terminar.`,
    ].join("\n")
  if (hold.state === "esperando")
    return [
      `Reserva ${hold.hold} na fila: ${what}, ${hold.position ?? 1}º na fila (${hold.reason ?? "ocupado"}).`,
      `${ends ? `A reserva atual vence no pior caso em ${ends}. ` : ""}Você será avisado por mensagem quando sair; ${
        JSON.parse(hold.target).kind === "fisico"
          ? "o lugar fica guardado até lá."
          : "o lugar dura 15 min, e pedir de novo antes disso o mantém."
      }`,
    ].join("\n")
  if (hold.state === "pedida")
    return `Reserva ${hold.hold} pedida: ${what}; a resposta ainda não chegou. Você será avisado por mensagem quando sair.`
  return `Sem reserva: ${what} (${hold.reason ?? hold.state}).`
}

/** A reservation in `bancada_status`. */
export function holdLine(hold: Hold, now = Date.now()) {
  const what = `${targetText(JSON.parse(hold.target))} em ${hold.machine_name ?? "outra máquina"}`
  if (hold.state === "concedida") {
    const ends =
      hold.expires_at === null
        ? ""
        : `; vence no pior caso em ~${Math.max(1, Math.round((hold.expires_at - now) / 60_000))} min`
    return `${hold.hold}: ${what}, concedida${deviceText(hold)}${ends}`
  }
  if (hold.state === "esperando")
    return `${hold.hold}: ${what}, ${hold.position ?? 1}º na fila (${hold.reason ?? "ocupado"})`
  return `${hold.hold}: ${what}, aguardando resposta`
}

/** `bancada_release`'s answer. */
export function releaseText(hold: string, state: string) {
  if (state === "desconhecida") return `Nenhuma reserva ${hold} neste servidor.`
  if (state === "outra_familia")
    return `${hold} é de outra sessão; esta tool só solta reservas desta sessão e dos subagentes dela.`
  if (state === "solta") return `Reserva ${hold} solta.`
  return `${hold} já tinha terminado; nada a soltar.`
}

/** The phone's id as the session uses it (` (id R58M123)`); nothing for a slot. */
function deviceText(hold: Hold) {
  const device: Record<string, string> = hold.device ? JSON.parse(hold.device) : {}
  return device.serial ? ` (serial ${device.serial})` : device.id ? ` (id ${device.id})` : ""
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

/**
 * `bancada_run`'s result carries the notice it waited for under this key: the hook acknowledges it once the call
 * completed (`hook.ts`).
 */
export const noticeKey = "bancadaAviso"

/**
 * Holds the tool until the notice is ready (25 s at a time) and hands it back. While it asks, the notice does not go as
 * a message; it is marked delivered only after the call completed (`hook.ts`), and goes as a message a minute after
 * the last ask otherwise.
 */
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
  const waiting = poll
  // Cancelled by the user: the notice goes the normal way, as a message.
  return cancel
    ? Effect.raceFirst(waiting, cancel.pipe(Effect.as(undefined as string | undefined)))
    : waiting.pipe(Effect.map((notice): string | undefined => notice))
}

/** The request as `bancada_run` sent it, when its wait was interrupted: its code, each test's place, what it replaced. */
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
export const familyOf = Effect.fnUntraced(function* (ctx: Pick<Context, "session">, sessionID: Session.ID) {
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
