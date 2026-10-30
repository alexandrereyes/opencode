import type { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Clock, Effect, Option, Schema, Scope, Semaphore, Stream } from "effect"
import { sessionTool } from "../sessions/index.js"

export const limits = {
  /** Progress narration is a latest-value mailbox spoken at most this often; results skip the wait. */
  narrationMs: 5_000,
  resultChars: 5_000,
  textChars: 700,
  /** How long and how often the result waits for the Mestra to leave the running set after `succeeded`. */
  settleMs: 1_000,
  settleAttempts: 15,
}

export type DelegationContext = {
  /** `custom.master` → `ensure`: the current Sessão mestra, created when missing, deleted or archived. */
  ensureMaster: () => Effect.Effect<string, unknown>
  session: Pick<Plugin.Context["session"], "get" | "prompt" | "active">
  message: Pick<Plugin.Context["message"], "list">
  event: Pick<Plugin.Context["event"], "subscribe">
}

export type DelegationOutput = {
  /** Speakable text for one delegation item (`delegation.context.append`). */
  readonly append: (itemID: string, text: string) => Effect.Effect<void>
  /** Sessão mestra progress line for the watch (`master` event). */
  readonly master: (state: "running" | "idle", text: string) => Effect.Effect<void>
}

/** The events of the Sessão mestra that drive narration; a structural subset of the server events. */
type MasterEvent =
  | {
      readonly type: "session.tool.input.started"
      readonly data: { readonly sessionID: string; readonly id: string; readonly name: string }
    }
  | {
      readonly type: "session.tool.called"
      readonly data: {
        readonly sessionID: string
        readonly id: string
        readonly input: Readonly<Record<string, unknown>>
      }
    }
  | {
      readonly type: "session.tool.progress"
      readonly data: { readonly sessionID: string; readonly metadata: Readonly<Record<string, unknown>> }
    }
  | { readonly type: "session.text.ended"; readonly data: { readonly sessionID: string; readonly text: string } }
  | {
      readonly type:
        | "session.tool.failed"
        | "session.step.failed"
        | "session.execution.succeeded"
        | "session.execution.failed"
        | "session.execution.interrupted"
      readonly data: { readonly sessionID: string }
    }
  | { readonly type: "form.created"; readonly data: { readonly form: { readonly sessionID: string } } }
  | { readonly type: "permission.asked"; readonly data: { readonly sessionID: string } }

const masterTypes: ReadonlySet<string> = new Set<MasterEvent["type"]>([
  "session.tool.input.started",
  "session.tool.called",
  "session.tool.progress",
  "session.text.ended",
  "session.tool.failed",
  "session.step.failed",
  "session.execution.succeeded",
  "session.execution.failed",
  "session.execution.interrupted",
  "form.created",
  "permission.asked",
])

const ToolCalls = Schema.Struct({
  toolCalls: Schema.Array(
    Schema.Struct({ tool: Schema.String, status: Schema.String, input: Schema.optionalKey(Schema.Unknown) }),
  ),
})
const decodeToolCalls = Schema.decodeUnknownOption(ToolCalls)
const Request = Schema.fromJsonString(
  Schema.Struct({ text: Schema.String, delivery: Schema.optionalKey(Schema.String) }),
)
const decodeRequest = Schema.decodeUnknownOption(Request)

/**
 * Server-side counterpart of the iPhone's `VoiceMaster`: each GPT Live delegation becomes a prompt to the Sessão
 * mestra (steer, or queue when asked), and its progress and result return as speakable appends to the latest
 * delegation item. Admission is not completion; ending the call never interrupts work already admitted.
 */
export function makeDelegator(ctx: DelegationContext, output: DelegationOutput, scope: Scope.Scope) {
  const seen = new Set<string>()
  const tools = new Map<string, string>()
  const admission = Semaphore.makeUnsafe(1)
  const state = {
    masterID: undefined as string | undefined,
    itemID: undefined as string | undefined,
    promptID: undefined as string | undefined,
    waiting: false,
    subscribed: false,
    lastSpokenAt: -Infinity,
    pending: undefined as string | undefined,
    flushing: false,
  }

  const ask = Effect.fn("Watch.delegate")(function* (itemID: string, raw: string) {
    if (seen.has(itemID)) return
    seen.add(itemID)
    const request = parse(raw)
    yield* admission.withPermit(
      send(itemID, request).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("Watch delegation failed", { cause }).pipe(
            Effect.andThen(say(itemID, "Não consegui enviar o pedido à Sessão mestra.", true)),
          ),
        ),
      ),
    )
  })

  const send = Effect.fn("Watch.delegateSend")(function* (
    itemID: string,
    request: { readonly text: string; readonly delivery: "steer" | "queue" },
  ) {
    const prompt = (sessionID: string) =>
      ctx.session.prompt({ sessionID: Session.ID.make(sessionID), text: request.text, delivery: request.delivery })
    const masterID = state.masterID ?? (yield* ensure())
    if (!state.subscribed) yield* subscribe()
    state.itemID = itemID
    state.waiting = true
    state.pending = undefined
    // A Mestra deleted during the call gets one replacement, as on the iPhone.
    const admitted = yield* prompt(masterID).pipe(
      Effect.catch(() => ensure().pipe(Effect.flatMap((replacement) => prompt(replacement)))),
    )
    state.promptID = admitted.id
    yield* say(
      itemID,
      request.delivery === "queue" ? "Pedido na fila da Sessão mestra." : "Pedido enviado à Sessão mestra.",
    )
  })

  const ensure = () =>
    ctx.ensureMaster().pipe(
      Effect.map((sessionID) => {
        state.masterID = sessionID
        return sessionID
      }),
    )

  const subscribe = () =>
    Effect.gen(function* () {
      state.subscribed = true
      yield* ctx.event.subscribe().pipe(
        Stream.filter((event): event is Extract<typeof event, MasterEvent> => masterTypes.has(event.type)),
        Stream.filter((event) => owner(event) === state.masterID),
        Stream.runForEach((event) =>
          receive(event).pipe(
            Effect.catchCause((cause) => Effect.logWarning("Watch master progress failed", { cause })),
          ),
        ),
        Effect.forkIn(scope, { startImmediately: true }),
      )
    })

  const receive = Effect.fn("Watch.masterEvent")(function* (event: MasterEvent) {
    if (event.type === "session.tool.input.started") {
      tools.set(event.data.id, event.data.name)
      return
    }
    if (!state.waiting || !state.itemID) return
    const itemID = state.itemID
    if (event.type === "session.execution.succeeded") return yield* reconcile(itemID)
    if (event.type === "session.execution.failed" || event.type === "session.execution.interrupted") {
      state.waiting = false
      return yield* say(
        itemID,
        event.type === "session.execution.interrupted"
          ? "A execução da mestra foi interrompida."
          : "A Sessão mestra encontrou uma falha. Confira a conversa.",
        true,
      )
    }
    if (event.type === "form.created" || event.type === "permission.asked")
      return yield* say(itemID, "A mestra precisa da sua resposta. Abra a Sessão mestra para conferir.")
    const text = yield* progress(event)
    if (!text) return
    // Tool activity is useful on screen, but is not news worth interrupting the conversation for.
    if (event.type === "session.tool.called" || event.type === "session.tool.progress")
      return yield* output.master("running", text)
    yield* say(itemID, text)
  })

  const progress = Effect.fn("Watch.masterProgress")(function* (event: MasterEvent) {
    if (event.type === "session.tool.failed") return "Uma ferramenta falhou. A mestra está verificando o resultado."
    if (event.type === "session.step.failed") return "Uma etapa da mestra falhou. Aguardando o resultado da execução."
    if (event.type === "session.text.ended")
      return event.data.text.trim() ? "Atualização da mestra: " + event.data.text.slice(0, limits.textChars) : undefined
    const call =
      event.type === "session.tool.called"
        ? { name: tools.get(event.data.id), input: event.data.input }
        : event.type === "session.tool.progress"
          ? Option.match(decodeToolCalls(event.data.metadata), {
              onNone: () => undefined,
              onSome: (value) => {
                const running = value.toolCalls.findLast((item) => item.status === "running")
                return running ? { name: running.tool, input: running.input } : undefined
              },
            })
          : undefined
    if (!call?.name) return undefined
    const sessionID =
      typeof call.input === "object" && call.input !== null && "sessionID" in call.input
        ? call.input.sessionID
        : undefined
    if (["read", "status", "wait"].includes(sessionTool(call.name) ?? "") && typeof sessionID === "string") {
      const title = yield* ctx.session.get({ sessionID: Session.ID.make(sessionID) }).pipe(
        Effect.map((session) => session.title),
        Effect.orElseSucceed(() => undefined),
      )
      if (title) return `A mestra está conferindo a sessão “${title.slice(0, 120)}”.`
    }
    return describeTool(call.name)
  })

  /** The result is final only once the Mestra is idle; then the latest reply after the prompt is spoken. */
  const reconcile = Effect.fn("Watch.masterResult")(function* (
    itemID: string,
    attempt = 0,
  ): Effect.fn.Return<void, unknown> {
    const masterID = state.masterID
    const promptID = state.promptID
    if (!masterID || !promptID || !state.waiting || state.itemID !== itemID) return
    const active = yield* ctx.session.active()
    // `succeeded` can be published while the drain still holds the session; look again shortly.
    if (Object.hasOwn(active, masterID)) {
      if (attempt >= limits.settleAttempts) return
      yield* Effect.sleep(limits.settleMs).pipe(
        Effect.andThen(reconcile(itemID, attempt + 1)),
        Effect.catchCause(() => Effect.void),
        Effect.forkIn(scope),
      )
      return
    }
    const page = yield* ctx.message.list({ sessionID: Session.ID.make(masterID), limit: 50 })
    const boundary = page.data.findIndex((message) => message.id === promptID)
    if (boundary < 0) {
      state.waiting = false
      return yield* say(itemID, "Não consegui recuperar toda a resposta. Confira a Sessão mestra.", true)
    }
    const reply = page.data
      .slice(0, boundary)
      .flatMap((message) =>
        message.type === "assistant"
          ? [
              message.content
                .flatMap((part) => (part.type === "text" ? [part.text] : []))
                .join("\n")
                .trim(),
            ]
          : [],
      )
      .find((text) => text.length > 0)
    if (!reply) return
    state.waiting = false
    yield* say(
      itemID,
      reply.length > limits.resultChars
        ? "A resposta é longa. Segue o trecho final; confira a resposta completa na conversa. " +
            reply.slice(-limits.resultChars)
        : reply,
      true,
    )
  })

  /** Speaks now, or keeps only the latest progress line until the narration slot opens. */
  const say = (itemID: string, text: string, final = false): Effect.Effect<void> =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      yield* output.master(final ? "idle" : "running", text)
      if (final || now - state.lastSpokenAt >= limits.narrationMs) {
        state.pending = undefined
        state.lastSpokenAt = now
        return yield* output.append(itemID, text)
      }
      state.pending = text
      if (state.flushing) return
      state.flushing = true
      yield* Effect.sleep(state.lastSpokenAt + limits.narrationMs - now).pipe(
        Effect.andThen(
          Effect.suspend(() => {
            state.flushing = false
            const pending = state.pending
            if (!pending || !state.itemID) return Effect.void
            state.pending = undefined
            return Clock.currentTimeMillis.pipe(
              Effect.tap((at) => Effect.sync(() => (state.lastSpokenAt = at))),
              Effect.andThen(output.append(state.itemID, pending)),
            )
          }),
        ),
        Effect.forkIn(scope, { startImmediately: true }),
      )
    })

  return { ask, state }
}

export function parse(raw: string) {
  return Option.match(decodeRequest(raw), {
    onNone: () => ({ text: raw, delivery: "steer" as const }),
    onSome: (value) =>
      value.text.trim()
        ? { text: value.text, delivery: value.delivery === "queue" ? ("queue" as const) : ("steer" as const) }
        : { text: raw, delivery: "steer" as const },
  })
}

export function describeTool(name: string) {
  const session = sessionTool(name)
  switch (session ? `sessions.${session}` : (name.split(".").at(-1) ?? name)) {
    case "sessions.read":
    case "sessions.status":
      return "A mestra está conferindo uma sessão."
    case "sessions.list":
      return "A mestra está consultando suas sessões."
    case "sessions.send":
      return "A mestra está encaminhando seu pedido."
    case "sessions.create":
      return "A mestra está criando a sessão solicitada."
    case "sessions.wait":
      return "A mestra está acompanhando o trabalho da sessão."
    case "sessions.requests":
      return "A mestra está verificando os pedidos pendentes."
    case "sessions.answer":
      return "A mestra está respondendo ao pedido autorizado."
    case "read":
    case "grep":
    case "glob":
      return "A mestra está consultando os arquivos."
    case "execute":
      return "A mestra está consultando as ferramentas."
    case "iphone_query":
    case "iphone_status":
      return "A mestra está consultando seu iPhone."
    default:
      return "A mestra está usando uma ferramenta."
  }
}

function owner(event: MasterEvent) {
  return event.type === "form.created" ? event.data.form.sessionID : event.data.sessionID
}
