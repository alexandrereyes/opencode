import type { Plugin } from "@opencode/plugin/effect"
import { Session } from "@opencode/schema/session"
import { Clock, Effect, Option, Schema, Scope, Semaphore, Stream } from "effect"
import { sessionTool } from "../sessions/index.js"

export const limits = {
  /** Progress narration is a latest-value mailbox spoken at most this often; results skip the wait. */
  narrationMs: 5_000,
  /**
   * The quiet state (`note`) is another latest-value box, sent at most this often and not this soon after a spoken
   * line: the iPhone's `VoiceMasterStatus.interval` and `afterSpeech`.
   */
  noteMs: 10_000,
  noteAfterSpeechMs: 3_000,
  /** What GPT Live says of a result (`spoken`), as the iPhone's `VoiceResult.limit`. */
  spokenChars: 1_500,
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
  /** Speakable text for one delegation item (`delegation.context.append`, `channel: speakable`). */
  readonly append: (itemID: string, text: string) => Effect.Effect<void>
  /**
   * Quiet state for one delegation item (`channel: commentary`), the route's form of OpenAI's `session.thinking.append`:
   * neutral facts stayed quiet there on 02/11, news was said anyway.
   */
  readonly note: (itemID: string, text: string) => Effect.Effect<void>
  /** Sessão mestra progress line for the watch (`master` event). */
  readonly master: (state: "running" | "idle", text: string) => Effect.Effect<void>
  /** When (epoch ms) neither Alexandre nor GPT Live is speaking, as far as the transcript shows. */
  readonly quietAt: () => number
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
 * mestra (steer, or queue when asked); its own text, what needs Alexandre and its result return as speakable appends
 * to the latest delegation item, and its activity as quiet state there. Admission is not completion; ending the call
 * never interrupts work already admitted.
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
    /** The quiet state box of the current delegation item, apart from the spoken one above. */
    note: { pending: undefined as string | undefined, last: undefined as string | undefined, sentAt: -Infinity },
    noting: false,
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
    state.note = { pending: undefined, last: undefined, sentAt: -Infinity }
    // A Mestra deleted during the call gets one replacement, as on the iPhone.
    const admitted = yield* prompt(masterID).pipe(
      Effect.catch(() => ensure().pipe(Effect.flatMap((replacement) => prompt(replacement)))),
    )
    state.promptID = admitted.id
    // Not spoken: GPT Live already acknowledges the request and would announce it again.
    yield* output.master(
      "running",
      request.delivery === "queue" ? "Pedido na fila da Sessão mestra." : "Pedido enviado à Sessão mestra.",
    )
    yield* note(admittedActivity(request.delivery))
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
    const line = yield* progress(event)
    if (!line) return
    // Tool activity and failures the Mestra recovers from are not news worth interrupting the conversation for:
    // shown, and GPT Live keeps them as quiet state. Only its own text is spoken.
    if (line.activity === undefined) return yield* say(itemID, line.text)
    yield* output.master("running", line.text)
    yield* note(line.activity)
  })

  /** The line shown for an event and, unless it is the Mestra's own text, its activity (`VoiceMasterProgress`). */
  const progress = Effect.fn("Watch.masterProgress")(function* (event: MasterEvent) {
    if (event.type === "session.tool.failed")
      return {
        text: "Uma ferramenta falhou. A mestra está verificando o resultado.",
        activity: "verificando o retorno de uma ferramenta que deu erro",
      }
    if (event.type === "session.step.failed")
      return {
        text: "Uma etapa da mestra falhou. Aguardando o resultado da execução.",
        activity: "aguardando a execução seguir depois de uma etapa com erro",
      }
    if (event.type === "session.text.ended")
      return event.data.text.trim()
        ? { text: "Atualização: " + event.data.text.slice(0, limits.textChars), activity: undefined }
        : undefined
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
    const title =
      ["read", "status", "wait"].includes(sessionTool(call.name) ?? "") && typeof sessionID === "string"
        ? yield* ctx.session.get({ sessionID: Session.ID.make(sessionID) }).pipe(
            Effect.map((session) => session.title),
            Effect.orElseSucceed(() => undefined),
          )
        : undefined
    const activity = title ? `conferindo a sessão “${title.slice(0, 120)}”` : toolActivity(call.name)
    return { text: `A mestra está ${activity}.`, activity }
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
    yield* say(itemID, spoken(reply), true)
  })

  /** Speaks now, or keeps only the latest progress line until the narration slot opens. */
  const say = (itemID: string, text: string, final = false): Effect.Effect<void> =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      yield* output.master(final ? "idle" : "running", text)
      // A result or failure ends the request: a state still waiting is stale.
      if (final) state.note.pending = undefined
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

  /**
   * Offers the Mestra's activity as GPT Live's quiet state (the iPhone's `VoiceMasterStatus`): the latest only, when
   * it differs from the last one sent, at most once every `limits.noteMs`, never while Alexandre or GPT Live speaks,
   * while a spoken line waits, or within `limits.noteAfterSpeechMs` of one.
   */
  const note = (activity: string): Effect.Effect<void> =>
    Effect.suspend(() => {
      const text = statusNote(activity)
      state.note.pending = text === state.note.last ? undefined : text
      if (!state.note.pending || state.noting) return Effect.void
      state.noting = true
      return flushNote().pipe(Effect.forkIn(scope, { startImmediately: true }), Effect.asVoid)
    })

  const flushNote = (): Effect.Effect<void> =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      const at = Math.max(
        state.note.sentAt + limits.noteMs,
        state.lastSpokenAt + limits.noteAfterSpeechMs,
        state.pending ? state.lastSpokenAt + limits.narrationMs + limits.noteAfterSpeechMs : -Infinity,
        output.quietAt(),
      )
      if (at > now) return yield* Effect.sleep(at - now).pipe(Effect.andThen(flushNote()))
      state.noting = false
      const pending = state.note.pending
      if (!pending || !state.itemID || !state.waiting) return
      state.note = { pending: undefined, last: pending, sentAt: now }
      yield* output.note(state.itemID, pending)
    })

  return { ask, state }
}

/** The admitted request, before any tool (the iPhone's `VoiceMasterProgress.admitted`). */
function admittedActivity(delivery: "steer" | "queue") {
  return delivery === "queue" ? "com o pedido na fila, esperando o trabalho atual" : "começando o pedido"
}

/**
 * GPT Live's quiet state for an activity, the iPhone's `VoiceMasterProgress.note`: a standing fact for when Alexandre
 * asks, never news, which is what stayed quiet on `commentary` on 02/11.
 */
export function statusNote(activity: string) {
  return `Estado do agente (para consulta; não é novidade para anunciar): ${activity}. Pedido em andamento, ainda sem resultado.`
}

const codeNote = "(há código na resposta; veja na conversa)"
const restNote = "O restante da resposta está na conversa."

/**
 * What GPT Live says of a result, the iPhone's `VoiceResult.spoken`. OpenAI's live delegation guide: return the relevant
 * facts and the status, and keep long output and Markdown meant for display in the backend. Markdown that should not
 * be read aloud is removed (a fenced code block becomes `codeNote`, tables plain lines, links their text), and the text
 * is cut to `limits.spokenChars` at a sentence or line end in its second half (else at a space), followed by `restNote`.
 * The start is kept: the Mestra is asked to lead with the result, status and next step.
 */
export function spoken(text: string) {
  const lines: string[] = []
  const block = { fence: "" }
  for (const line of text.replace(/\r\n?/g, "\n").split("\n")) {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
    if (block.fence) {
      // Closed by a bare fence of the same character, at least as long; an unclosed block runs to the end.
      const fence = marker?.[1] ?? ""
      if (fence[0] === block.fence[0] && fence.length >= block.fence.length && !marker?.[2]?.trim()) block.fence = ""
      continue
    }
    if (marker) {
      block.fence = marker[1] ?? ""
      if (lines.findLast((previous) => previous !== "") !== codeNote) lines.push(codeNote)
      continue
    }
    const plainLine = plain(line)
    if (plainLine !== undefined) lines.push(plainLine)
  }
  const clean = lines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
  const chars = Array.from(clean)
  if (chars.length <= limits.spokenChars) return clean
  const ends = Array.from(
    { length: Math.floor(limits.spokenChars / 2) + 1 },
    (_, offset) => limits.spokenChars - offset,
  )
  const space = (index: number) => /\s/.test(chars[index] ?? "")
  const cut =
    ends.find((index) => space(index) && (chars[index] === "\n" || ".!?…".includes(chars[index - 1] ?? "x"))) ??
    ends.find(space) ??
    limits.spokenChars
  return chars.slice(0, cut).join("").trim() + "\n\n" + restNote
}

/** A line as spoken; a table's divider row is dropped and a rule becomes a paragraph break. */
function plain(line: string) {
  const text = line.trim()
  if (/^([-*_])(\s*\1){2,}$/.test(text)) return ""
  const unquoted = text.replace(/^(>\s?)+/, "")
  if (/^\|[\s|:-]*$/.test(unquoted)) return undefined
  return (
    unquoted.startsWith("|")
      ? unquoted
          .split("|")
          .map((cell) => cell.trim())
          .filter(Boolean)
          .join(", ")
      : unquoted
  )
    .replace(/^#{1,6}\s+/, "")
    .replace(/\s+#+$/, "")
    .replace(/^(?:[-*+]|\d{1,3}[.)])\s+/, "")
    .replace(/^\[[ xX]\]\s+/, "")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/\*\*|__|`/g, "")
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

/**
 * What a tool call has the Mestra doing, in the present: the watch line after "A mestra está" and GPT Live's quiet
 * state (the iPhone's `VoiceMasterProgress.activity`).
 */
export function toolActivity(name: string) {
  const session = sessionTool(name)
  switch (session ? `sessions.${session}` : (name.split(".").at(-1) ?? name)) {
    case "sessions.read":
    case "sessions.status":
      return "conferindo uma sessão"
    case "sessions.list":
      return "consultando suas sessões"
    case "sessions.send":
      return "encaminhando seu pedido"
    case "sessions.create":
      return "criando a sessão solicitada"
    case "sessions.wait":
      return "acompanhando o trabalho da sessão"
    case "sessions.requests":
      return "verificando os pedidos pendentes"
    case "sessions.answer":
      return "respondendo ao pedido autorizado"
    case "read":
    case "grep":
    case "glob":
      return "consultando os arquivos"
    case "execute":
      return "consultando as ferramentas"
    case "iphone_query":
    case "iphone_status":
      return "consultando seu iPhone"
    default:
      return "usando uma ferramenta"
  }
}

function owner(event: MasterEvent) {
  return event.type === "form.created" ? event.data.form.sessionID : event.data.sessionID
}
