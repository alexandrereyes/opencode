import { Clock, Deferred, Effect, Exit, Fiber, Option, Queue, Schema, Scope } from "effect"
import { Voice } from "../voice/rpc.js"
import { masterLabel, summaryLabel, turnText } from "../voice/index.js"
import { sanitize } from "../voice/sanitize.js"
import { hear, makeDelegator, masterRequest, parse, queues, type DelegationContext, type Heard } from "./delegation.js"
import { fail } from "./failure.js"
import {
  alphaHeaders,
  append,
  callID,
  close,
  closed,
  closedByModeration,
  createPath,
  creation,
  decodeEvent,
  decodeType,
  message,
  moderated,
  rejectsVoice,
  sidebandPath,
  started,
  upstreamError,
  type Command,
} from "./protocol.js"
import { Watch } from "./rpc.js"

export const limits = {
  /** Lease renewal cadence, also the watch's heartbeat cadence. */
  renewMs: 5_000,
  /**
   * Without a heartbeat for this long the call ends; returned to the watch as `leaseSeconds`. The watch sends one
   * every 5 s after the previous one settles (8 s timeout), so a network blip can hold two of them; 30 s rides it out.
   */
  livenessMs: 30_000,
  maxCallMs: 30 * 60_000,
  pollMs: 25_000,
  /** An ended call stays readable this long so the watch can read its last events. */
  keepEndedMs: 60_000,
  events: 400,
  httpMs: 8_000,
  createMs: 25_000,
  memoryMs: 2_000,
  closeMs: 4_000,
  /**
   * After a moderation `error`, how long the session has to end for the moderation to count as the kind that ends it
   * (voice memory cleared); a session still alive after it goes on with its memory. Same as the iPhone's
   * `VoiceRecoveryPolicy.moderationWindow`.
   */
  moderationMs: 5_000,
  /** An ending call still lets delegations it received reach the Mestra (a cold Mestra took ~6 s), at most this long. */
  admissionMs: 20_000,
  /** Event types kept, newest last, to correlate an upstream error or close with what led to it. */
  recentEvents: 12,
  /** Lease margin from the iPhone contract: a lease is considered lost this long before it expires. */
  leaseMarginMs: 10_000,
  /** Commands kept by `event_id`, newest last, to name the one an upstream error is about. */
  commands: 64,
  /**
   * Alexandre or GPT Live counts as speaking this long after a transcript piece of theirs (the iPhone's `userUntil`);
   * GPT Live's own `turn.done` ends it. The Mestra's quiet state waits for both.
   */
  speakingMs: 2_000,
}

export const proxyOrigin = "http://llm-proxy-svc:8080"

/** HTTP to the llm-proxy; production uses `fetch` against `proxyOrigin`, tests a local handler. */
export type Proxy = {
  readonly origin: string
  readonly fetch: (request: Request) => Promise<Response>
}

/** The GPT Live sideband (`/v1/live/<call>`), a WebSocket in production. */
export type Sideband = { readonly send: (text: string) => void; readonly close: () => void }
/** How the sideband closed: the WebSocket close code and reason, and whether a transport error preceded it. */
export type SidebandClose = {
  readonly code: number
  readonly reason: string
  readonly clean: boolean
  readonly transportError: boolean
}
export type SidebandFactory = (
  url: string,
  headers: Record<string, string>,
  handlers: { readonly message: (text: string) => void; readonly closed: (close: SidebandClose) => void },
) => Sideband

/** Voice memory (`custom.voice`, scope `global`), shared with the iPhone. */
export type Memory = {
  readonly context: () => Effect.Effect<typeof Voice.Context.Type, unknown>
  readonly append: (turns: readonly Voice.Turn[]) => Effect.Effect<unknown, unknown>
  readonly end: () => Effect.Effect<unknown, unknown>
  /** Clears what GPT Live is given back (`custom.voice` → `reset`), after the service moderated a call. */
  readonly reset: () => Effect.Effect<unknown, unknown>
}

export type VoiceContext = DelegationContext & {
  memory: Memory
  instructions: () => Effect.Effect<string, unknown>
  /** Boots an existing Mestra's Location before the first delegation needs it; never creates a session. */
  warmMaster?: () => Effect.Effect<void, unknown>
}

type Call = {
  readonly id: string
  readonly deviceID: string
  readonly sessionId: string
  readonly generation: string
  readonly startedAt: number
  readonly scope: Scope.Closeable
  readonly inbox: Queue.Queue<string>
  remoteID?: string
  sideband?: Sideband
  sidebandClosed: Deferred.Deferred<void>
  lastHeartbeat: number
  /** Confirmed lease deadline (server time mapped to the request start), minus the safety margin. */
  leaseUntil: number
  events: Watch.VoiceEvent[]
  seq: number
  changed: Deferred.Deferred<void>
  captions: { user: string; assistant: string }
  /** The completed turns the Mestra has not seen, sent with the next request (`masterRequest`); never stored. */
  heard: Heard
  /** Delegation items already admitted: a repeated `delegation.created` is ignored. */
  delegated: Set<string>
  /** Until when (epoch ms) each side counts as speaking (`limits.speakingMs`). */
  speaking: { user: number; assistant: number }
  ending?: Deferred.Deferred<void>
  ended?: string
  /** Serial work off the sideband reader, in order: memory appends and delegation admissions. */
  memoryTail?: Fiber.Fiber<void>
  delegationTail?: Fiber.Fiber<void>
  /** Correlation for diagnostics: the last command sent (type only) and the latest received event types. */
  lastSent?: { readonly type: string; readonly at: number }
  recent: string[]
  /** The commands sent, by the `event_id` each carries (the newest `limits.commands`). */
  sent: Map<string, { readonly type: string; readonly at: number; readonly purpose: "narration" | "status" | "close" }>
  /** How many memory items the call started with: with none, clearing memory cannot help a moderated call. */
  contextItems: number
  /** A moderation `error` waiting `limits.moderationMs` to see whether the session ends; `code` is its `type/code`. */
  moderation?: { readonly at: number; readonly code: string }
  /** The service moderated the call and ended its session: later events are ignored while it clears memory and ends. */
  moderated?: boolean
  /** The service sent `session.closed`, with its reason and the audio it counted: ending asks for nothing more. */
  closed?: { readonly reason?: string; readonly audioMs?: number }
  /** Set when this server asked the sideband to close; a close without it came from the other side. */
  closingAt?: number
  sidebandClose?: SidebandClose & { readonly by: "local" | "remote" }
}

const Lease = Schema.Struct({
  sessionId: Schema.String,
  generation: Schema.String,
  serverTime: Schema.String,
  leaseExpiresAt: Schema.String,
})
const decodeLease = Schema.decodeUnknownOption(Schema.fromJsonString(Lease))

/**
 * GPT Live calls for paired watches: the gateway reserves the llm-proxy lease, creates the call, attaches the
 * sideband and keeps the call alive only while the watch's heartbeats arrive. Media flows watch ⇄ OpenAI directly.
 */
export function makeVoice(input: {
  readonly ctx: () => VoiceContext | undefined
  readonly proxy: Proxy
  readonly sideband: SidebandFactory
  readonly scope: Scope.Scope
}) {
  const calls = new Map<string, Call>()
  const active = new Map<string, string>()

  const http = (method: string, path: string, init: { body?: string; headers?: Record<string, string> }, ms: number) =>
    Effect.tryPromise({
      try: (signal) =>
        input.proxy.fetch(
          new Request(input.proxy.origin + path, {
            method,
            headers: { "content-type": "application/json", ...init.headers },
            body: init.body,
            signal: AbortSignal.any([signal, AbortSignal.timeout(ms)]),
          }),
        ),
      catch: () => "network" as const,
    })

  const emit = (call: Call, body: Watch.VoiceEventBody) =>
    Effect.gen(function* () {
      const at = yield* Clock.currentTimeMillis
      call.seq += 1
      call.events.push({ seq: call.seq, at, ...body })
      if (call.events.length > limits.events) call.events.splice(0, call.events.length - limits.events)
      const changed = call.changed
      call.changed = Deferred.makeUnsafe<void>()
      yield* Deferred.succeed(changed, undefined)
    })

  const start = Effect.fn("Watch.callStart")(function* (deviceID: string, offer: typeof Watch.CallInput.Type) {
    if (!offer.sdp.startsWith("v=0") || !/^m=audio /m.test(offer.sdp) || !/opus\/48000/i.test(offer.sdp))
      return yield* fail(400, "invalid_offer", "Oferta de áudio inválida.")
    const previous = active.get(deviceID)
    const replaced = previous ? calls.get(previous) : undefined
    if (replaced) yield* end(replaced, "replaced")
    const now = yield* Clock.currentTimeMillis
    const call: Call = {
      id: crypto.randomUUID(),
      deviceID,
      sessionId: crypto.randomUUID(),
      generation: crypto.randomUUID(),
      startedAt: now,
      scope: yield* Scope.fork(input.scope),
      inbox: yield* Queue.unbounded<string>(),
      sidebandClosed: Deferred.makeUnsafe<void>(),
      lastHeartbeat: now,
      leaseUntil: now,
      events: [],
      seq: 0,
      changed: Deferred.makeUnsafe<void>(),
      captions: { user: "", assistant: "" },
      heard: { turns: [] },
      delegated: new Set(),
      speaking: { user: 0, assistant: 0 },
      recent: [],
      sent: new Map(),
      contextItems: 0,
    }
    calls.set(call.id, call)
    active.set(deviceID, call.id)
    yield* emit(call, { type: "status", status: "connecting" })
    const created = yield* create(call, offer).pipe(
      Effect.tapError((failure) =>
        Effect.logWarning("Watch call failed", { code: failure.code }).pipe(Effect.andThen(end(call, failure.code))),
      ),
    )
    yield* Effect.logInfo("Watch call created", { deviceID })
    return { callID: call.id, sdp: created, leaseSeconds: limits.livenessMs / 1000 }
  })

  const create = Effect.fn("Watch.callCreate")(function* (call: Call, offer: typeof Watch.CallInput.Type) {
    const ctx = input.ctx()
    if (!ctx) return yield* fail(503, "unavailable", "O servidor de voz não está disponível.")
    const instructions = yield* ctx.instructions().pipe(
      Effect.mapError(() => fail(503, "instructions_failed", "Não foi possível carregar o prompt de voz.")),
    )
    const reserved = yield* Clock.currentTimeMillis
    const lease = yield* http(
      "POST",
      `/_gpt-live/sessions/${call.sessionId}`,
      { body: JSON.stringify({ generation: call.generation }) },
      limits.httpMs,
    ).pipe(Effect.mapError(() => fail(502, "lease_failed", "O serviço de voz não respondeu.")))
    const confirmed = yield* confirm(call, lease, reserved)
    if (!confirmed) return yield* fail(502, "lease_failed", "O serviço de voz recusou a chamada.")
    const memory = yield* initialItems(ctx)
    call.contextItems = memory.length
    const voices = [...new Set([offer.voiceID ?? Watch.defaultVoiceID, "rio", "cove"])]
    const created = yield* createCall(call, offer.sdp, voices, memory, instructions)
    const answer = created.sdp
    call.remoteID = created.remoteID
    if (!/^a=ice-lite\s*$/m.test(answer) || !answer.split(/\r?\n/).some(isUdpCandidate))
      return yield* fail(502, "unsupported_answer", "O serviço de voz não ofereceu um caminho de áudio compatível.")
    yield* Queue.take(call.inbox).pipe(
      Effect.flatMap((text) => receive(call, text)),
      Effect.forever,
      Effect.forkIn(call.scope, { startImmediately: true }),
    )
    call.sideband = input.sideband(
      input.proxy.origin.replace(/^http/, "ws") + sidebandPath(created.remoteID),
      alphaHeaders,
      {
        message: (text) => Queue.offerUnsafe(call.inbox, text),
        closed: (close) => {
          call.sidebandClose = { ...close, by: call.closingAt === undefined ? "remote" : "local" }
          Deferred.doneUnsafe(call.sidebandClosed, Effect.void)
          if (!call.ending) Queue.offerUnsafe(call.inbox, JSON.stringify({ type: "sideband.closed" }))
        },
      },
    )
    // A cold Mestra took ~6 s to take the first delegation; booting it now overlaps the greeting.
    if (ctx.warmMaster)
      yield* ctx.warmMaster().pipe(
        Effect.catchCause((cause) => Effect.logWarning("Watch call could not warm the Mestra", { cause })),
        Effect.forkIn(call.scope),
      )
    yield* Effect.sleep(limits.renewMs).pipe(Effect.andThen(renew(call)), Effect.forever, Effect.forkIn(call.scope))
    yield* Effect.sleep(limits.maxCallMs).pipe(
      Effect.andThen(Effect.suspend(() => end(call, "max_duration"))),
      Effect.forkIn(call.scope),
    )
    return answer
  })

  const createCall = (
    call: Call,
    sdp: string,
    voices: readonly string[],
    items: readonly ReturnType<typeof message>[],
    instructions: string,
  ) =>
    Effect.gen(function* () {
      for (const [index, voice] of voices.entries()) {
        const response = yield* http(
          "POST",
          createPath,
          {
            body: JSON.stringify(creation({ sdp, instructions, voice, items })),
            headers: {
              accept: "application/sdp",
              ...alphaHeaders,
              "user-agent": "OpenCode-Watch/1.0",
              "session-id": call.sessionId,
              "thread-id": call.sessionId,
              "x-session-id": call.sessionId,
              "x-gpt-live-generation": call.generation,
            },
          },
          limits.createMs,
        ).pipe(Effect.mapError(() => fail(502, "create_failed", "O serviço de voz não respondeu.")))
        const body = yield* Effect.promise(() => response.text())
        // Only an explicit voice rejection proves the call was not created; anything else is never retried.
        if (index < voices.length - 1 && rejectsVoice(response.status, body)) continue
        const remoteID = callID(response.headers.get("location") ?? "")
        if (response.status !== 201 || !body.startsWith("v=0") || !remoteID)
          return yield* fail(502, "create_failed", "O serviço de voz recusou a chamada.")
        return { sdp: body, remoteID }
      }
      return yield* fail(502, "create_failed", "O serviço de voz recusou a chamada.")
    })

  /** Records a confirmed lease; `false` means an explicit refusal or a lease for another call. */
  const confirm = (call: Call, response: Response, requestedAt: number) =>
    Effect.gen(function* () {
      if (response.status !== 200) return false
      const lease = Option.getOrUndefined(decodeLease(yield* Effect.promise(() => response.text())))
      if (!lease || lease.sessionId !== call.sessionId || lease.generation !== call.generation) return false
      const remaining = Date.parse(lease.leaseExpiresAt) - Date.parse(lease.serverTime)
      if (!(remaining > limits.leaseMarginMs)) return false
      call.leaseUntil = requestedAt + remaining - limits.leaseMarginMs
      return true
    })

  const renew = (call: Call) =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      if (call.ending) return
      if (now - call.lastHeartbeat >= limits.livenessMs) return yield* end(call, "heartbeat_timeout")
      const response = yield* http(
        "PUT",
        `/_gpt-live/sessions/${call.sessionId}`,
        { body: JSON.stringify({ generation: call.generation }) },
        limits.httpMs,
      ).pipe(Effect.option)
      const transient = Option.isNone(response) || transientStatus(response.value.status)
      if (!transient && !(yield* confirm(call, response.value, now))) return yield* end(call, "lease_refused")
      if (transient && (yield* Clock.currentTimeMillis) >= call.leaseUntil) return yield* end(call, "lease_lost")
    })

  /**
   * The sideband reader. It never waits for slow work: memory appends and Mestra admissions go to the call's lanes,
   * so an error or a close is read (and logged) the moment it arrives, even while a cold Mestra wakes up.
   */
  const receive = Effect.fn("Watch.sideband")(function* (call: Call, text: string) {
    const event = Option.getOrUndefined(decodeEvent(text))
    call.recent.push(event?.type ?? Option.getOrUndefined(decodeType(text))?.type ?? "unreadable")
    if (call.recent.length > limits.recentEvents) call.recent.splice(0, call.recent.length - limits.recentEvents)
    if (!event || call.ended || call.moderated) return
    switch (event.type) {
      case "session.started": {
        const session = started(event)
        yield* Effect.logInfo("Watch call session started", {
          call: call.id,
          remoteID: call.remoteID,
          ...(session.id === undefined ? {} : { sessionID: sanitize(session.id, 64) }),
          ...(session.expiresAt === undefined ? {} : { expiresAt: session.expiresAt }),
        })
        return yield* emit(call, { type: "status", status: "live" })
      }
      case "input_transcript.added":
      case "output_transcript.added": {
        const role = event.type === "input_transcript.added" ? "user" : "assistant"
        call.captions[role] += event.item?.text ?? ""
        call.speaking[role] = (yield* Clock.currentTimeMillis) + limits.speakingMs
        if (!call.captions[role].trim()) return
        return yield* emit(call, { type: "caption", role, text: call.captions[role].trim(), final: false })
      }
      case "turn.done": {
        const role = event.turn?.role === "assistant" ? "assistant" : "user"
        const spoken = (event.turn?.transcript ?? call.captions[role]).trim()
        call.captions[role] = ""
        // The user's `turn.done` only comes when GPT Live answers, so only GPT Live's ends a speaking window.
        if (role === "assistant") call.speaking.assistant = 0
        if (!spoken) return
        hear(call.heard, { id: event.turn?.id, role, text: spoken })
        yield* emit(call, { type: "caption", role, text: spoken, final: true })
        return yield* lane(
          call,
          "memoryTail",
          remember(call, {
            id: `${call.id}:${event.turn?.id ?? call.seq}`,
            role,
            text: spoken,
            // When it was said, not when the lane gets to it: a reset in between keeps it out.
            at: yield* Clock.currentTimeMillis,
            interrupted:
              event.turn?.interrupted === true || ["interrupted", "cancelled"].includes(event.turn?.status ?? ""),
          }),
        )
      }
      case "delegation.created": {
        const item = event.item
        if (item?.target !== "client" || item.type !== "delegation" || !item.id) return
        const id = item.id
        // Each item once, before the request is built: building it consumes the turns heard since the previous one.
        if (call.delegated.has(id)) return
        call.delegated.add(id)
        const text = (item.content ?? [])
          .flatMap((part) => (part.type === "input_text" && part.text ? [part.text] : []))
          .join("")
        // GPT Live writes no request: the text is the transcript of the turn that delegated (02/11). Without one, it is
        // what Alexandre is saying (his `turn.done` follows the delegation) or last said; with nothing, GPT Live is
        // asked to have him repeat it.
        const said =
          text.trim() || call.captions.user.trim() || call.heard.turns.findLast((turn) => turn.role === "user")?.text
        const asked = said ? parse(said) : undefined
        // His words since the previous delegation decide the queue, as on the iPhone.
        const words = [
          ...call.heard.turns.flatMap((turn) => (turn.role === "user" ? [turn.text] : [])),
          call.captions.user,
          asked?.text ?? "",
        ].join(" ")
        const prompt = asked
          ? {
              text: masterRequest(call.heard, asked.text, item.user_bidi_turn_id),
              delivery: asked.delivery === "queue" || queues(words) ? ("queue" as const) : ("steer" as const),
            }
          : undefined
        // Admissions stay in order.
        return yield* lane(
          call,
          "delegationTail",
          // A request still waiting when the call was moderated belongs to the cleared conversation.
          delegator(call).pipe(
            Effect.flatMap((delegate) => (delegate && !call.moderated ? delegate.ask(id, prompt) : Effect.void)),
          ),
        )
      }
      case "error": {
        // Most errors leave the session open; it ends when the service closes the sideband.
        const error = upstreamError(event)
        // The command the error is about, when it names one of ours.
        const failed = call.sent.get(error.clientEventID)
        yield* Effect.logWarning("Watch call upstream error", {
          call: call.id,
          ...error,
          ...(failed
            ? {
                failedCommand: failed.type,
                failedPurpose: failed.purpose,
                failedAgoMs: (yield* Clock.currentTimeMillis) - failed.at,
              }
            : {}),
          ...(yield* correlation(call)),
        })
        if (moderated(error)) return yield* pendModeration(call, [error.type, error.code].filter(Boolean).join("/"))
        return yield* emit(call, { type: "error", code: "voice_error", message: "O serviço de voz informou um erro." })
      }
      case "session.closed": {
        call.closed = closed(event)
        // The answer to our own `session.close`: the end already running finishes.
        if (call.ending) return
        if ((yield* moderationEnded(call)) || closedByModeration(call.closed.reason)) return yield* moderate(call)
        return yield* end(call, "session_closed")
      }
      case "sideband.closed":
        if (yield* moderationEnded(call)) return yield* moderate(call)
        return yield* end(call, "sideband_closed")
    }
  })

  /**
   * A moderation `error`. Some moderations end the session and others only cut the current speech (OpenAI's live
   * conversations guide), so it only marks the call: a session that ends within `limits.moderationMs` was moderated
   * (`moderate`); after it, the call goes on with its memory and the moderation is logged as not fatal.
   */
  const pendModeration = (call: Call, code: string) =>
    Effect.gen(function* () {
      const at = yield* Clock.currentTimeMillis
      call.moderation = { at, code }
      yield* Effect.sleep(limits.moderationMs).pipe(
        Effect.andThen(
          Effect.suspend(() => {
            if (call.moderation?.at !== at) return Effect.void
            call.moderation = undefined
            return correlation(call).pipe(
              Effect.flatMap((fields) =>
                Effect.logInfo("Watch call moderation was not fatal", { call: call.id, code, ...fields }),
              ),
            )
          }),
        ),
        Effect.forkIn(call.scope),
      )
    })

  /** Whether the session ends right after a moderation error: the kind of moderation that ends it. */
  const moderationEnded = (call: Call) =>
    Clock.currentTimeMillis.pipe(
      Effect.map((now) => call.moderation !== undefined && now - call.moderation.at <= limits.moderationMs),
    )

  /**
   * The service moderated the call and ended its session: `session.closed` or the sideband closing within
   * `limits.moderationMs` of a `content_filter` error, or a `session.closed` whose reason names moderation. A call that
   * started with memory clears it, as the iPhone and the Mac do, and ends as `context_reset`: the watch says so and its
   * retry starts an empty call. A call that started empty has nothing to clear and ends as `moderation`. What was said
   * since the last `turn.done` is not kept. Off the reader: an admission in flight finishes first, so its late-reply
   * window is opened before the reset takes it.
   */
  const moderate = (call: Call) =>
    Effect.gen(function* () {
      call.moderated = true
      call.moderation = undefined
      yield* Effect.gen(function* () {
        yield* settleLane(call.delegationTail, limits.admissionMs)
        const ctx = input.ctx()
        const clear = call.contextItems > 0 && ctx !== undefined
        if (clear)
          yield* ctx.memory
            .reset()
            .pipe(Effect.catchCause((cause) => Effect.logWarning("Watch call could not clear voice memory", { cause })))
        yield* end(call, clear ? "context_reset" : "moderation")
      }).pipe(Effect.forkIn(input.scope, { startImmediately: true }))
    })

  /** Runs `work` after the lane's previous job, in the gateway scope: ending the call never cuts it midway. */
  const lane = (call: Call, name: "memoryTail" | "delegationTail", work: Effect.Effect<void>) =>
    Effect.gen(function* () {
      const previous = call[name]
      call[name] = yield* (previous ? Fiber.await(previous) : Effect.void).pipe(
        Effect.andThen(work),
        Effect.forkIn(input.scope, { startImmediately: true }),
      )
    })

  const settleLane = (fiber: Fiber.Fiber<void> | undefined, ms: number) =>
    fiber ? Fiber.await(fiber).pipe(Effect.timeoutOption(ms), Effect.asVoid) : Effect.void

  /**
   * Sends commands in order on the sideband, each kept by its `event_id` for an upstream error that names it, and
   * remembers the last one's type for the next diagnostic.
   */
  const send = (call: Call, commands: readonly Command[], purpose: "narration" | "status" | "close") =>
    Effect.gen(function* () {
      for (const command of commands) {
        const at = yield* Clock.currentTimeMillis
        call.lastSent = { type: command.type, at }
        call.sent.set(command.event_id, { type: command.type, at, purpose })
        if (call.sent.size > limits.commands) call.sent.delete(call.sent.keys().next().value ?? "")
        call.sideband?.send(JSON.stringify(command))
      }
    })

  /** When in the call it happened, and what preceded it: the last command sent and the latest events received. */
  const correlation = (call: Call) =>
    Clock.currentTimeMillis.pipe(
      Effect.map((now) => ({
        elapsedMs: now - call.startedAt,
        lastSent: call.lastSent?.type ?? "none",
        ...(call.lastSent ? { lastSentAgoMs: now - call.lastSent.at } : {}),
        recent: call.recent.join(","),
      })),
    )

  const delegators = new WeakMap<Call, ReturnType<typeof makeDelegator>>()
  const delegator = (call: Call) =>
    Effect.sync(() => {
      const existing = delegators.get(call)
      if (existing) return existing
      const ctx = input.ctx()
      if (!ctx) return undefined
      const created = makeDelegator(
        ctx,
        {
          append: (itemID, text) => send(call, append(itemID, text, "speakable"), "narration"),
          note: (itemID, text) => send(call, append(itemID, text, "commentary"), "status"),
          master: (state, text) => emit(call, { type: "master", state, text }),
          quietAt: () => Math.max(call.speaking.user, call.speaking.assistant),
        },
        call.scope,
      )
      delegators.set(call, created)
      return created
    })

  const remember = (call: Call, turn: Voice.Turn) =>
    Effect.gen(function* () {
      const ctx = input.ctx()
      if (!ctx) return
      yield* ctx.memory
        .append([
          {
            id: turn.id,
            role: turn.role,
            text: turn.text,
            at: turn.at,
            ...(turn.interrupted ? { interrupted: true } : {}),
          },
        ])
        .pipe(Effect.catchCause(() => Effect.logWarning("Watch voice memory append failed")))
    })

  /** Idempotent teardown: close the sideband, release the lease, report `ended`, keep events briefly. */
  const end = (call: Call, reason: string, inline = false): Effect.Effect<void> =>
    Effect.suspend(() => {
      if (call.ending) return Deferred.await(call.ending)
      const ending = Deferred.makeUnsafe<void>()
      call.ending = ending
      const teardown = Effect.gen(function* () {
        if (call.sideband && !call.sidebandClose) {
          // After the service's own `session.closed` its socket follows: there is nothing to ask.
          if (!call.closed) {
            call.closingAt = yield* Clock.currentTimeMillis
            yield* send(call, [close()], "close")
          }
          yield* Deferred.await(call.sidebandClosed).pipe(Effect.timeoutOption(limits.closeMs))
          call.sideband.close()
        }
        if (call.sideband)
          yield* Effect.logInfo("Watch call sideband closed", {
            call: call.id,
            by: call.sidebandClose?.by ?? "local",
            ...(call.sidebandClose
              ? {
                  code: call.sidebandClose.code,
                  reason: sanitize(call.sidebandClose.reason, 120),
                  clean: call.sidebandClose.clean,
                  ...(call.sidebandClose.transportError ? { transportError: true } : {}),
                }
              : { code: "none" }),
            ...(yield* correlation(call)),
          })
        const released = yield* http(
          "DELETE",
          `/_gpt-live/sessions/${call.sessionId}?generation=${call.generation}`,
          {},
          limits.httpMs,
        ).pipe(Effect.option)
        if (active.get(call.deviceID) === call.id) active.delete(call.deviceID)
        yield* emit(call, { type: "status", status: "ended", reason })
        call.ended = reason
        yield* Effect.logInfo("Watch call ended", {
          deviceID: call.deviceID,
          call: call.id,
          reason,
          released: Option.isSome(released) ? released.value.status : 0,
          elapsedMs: (yield* Clock.currentTimeMillis) - call.startedAt,
          ...(call.closed?.reason ? { closedReason: sanitize(call.closed.reason, 64) } : {}),
          ...(call.closed?.audioMs === undefined ? {} : { audioDurationMs: call.closed.audioMs }),
        })
        // The memory `end` looks for Mestra replies to this call's requests: they and its turns go in first.
        yield* settleLane(call.delegationTail, limits.admissionMs)
        // What each role said since its last `turn.done` (the reader has stopped): nothing arrives after
        // `session.close`, and the user's `turn.done` waits for the assistant's next turn. An assistant cut off by
        // Alexandre spoke first. A moderated conversation keeps none of it.
        if (!call.moderated)
          for (const role of ["assistant", "user"] as const) {
            const spoken = call.captions[role].trim()
            if (spoken)
              yield* lane(
                call,
                "memoryTail",
                remember(call, {
                  id: `${call.id}:partial-${role}`,
                  role,
                  text: spoken,
                  at: yield* Clock.currentTimeMillis,
                  interrupted: true,
                }),
              )
          }
        yield* settleLane(call.memoryTail, limits.memoryMs)
        const ctx = input.ctx()
        if (ctx)
          yield* ctx.memory.end().pipe(
            Effect.timeoutOption(limits.memoryMs),
            Effect.catchCause(() => Effect.void),
          )
        yield* Scope.close(call.scope, Exit.void)
        yield* Effect.sleep(limits.keepEndedMs).pipe(
          Effect.andThen(Effect.sync(() => calls.delete(call.id))),
          Effect.forkIn(input.scope),
        )
        yield* Deferred.succeed(ending, undefined)
      })
      // A call's own fibers end it through a fiber of the gateway: closing the call scope would interrupt them.
      // Shutdown runs inline, since the gateway scope is already closing.
      if (inline) return teardown
      return teardown.pipe(
        Effect.forkIn(input.scope, { startImmediately: true }),
        Effect.andThen(Deferred.await(ending)),
      )
    })

  const owned = (deviceID: string, callID: string) => {
    const call = calls.get(callID)
    return call && call.deviceID === deviceID
      ? Effect.succeed(call)
      : Effect.fail(fail(404, "not_found", "Chamada não encontrada."))
  }

  return {
    start,
    heartbeat: Effect.fn("Watch.heartbeat")(function* (deviceID: string, callID: string) {
      const call = yield* owned(deviceID, callID)
      if (call.ended || call.ending) return yield* fail(410, "ended", "A chamada terminou.")
      call.lastHeartbeat = yield* Clock.currentTimeMillis
      return { ok: true as const }
    }),
    events: Effect.fn("Watch.callEvents")(function* (deviceID: string, callID: string, after: number) {
      const call = yield* owned(deviceID, callID)
      const pending = () => call.events.filter((event) => event.seq > after)
      if (pending().length === 0 && !call.ended)
        yield* Deferred.await(call.changed).pipe(Effect.timeoutOption(limits.pollMs))
      const events = pending()
      return { events, next: events.at(-1)?.seq ?? Math.max(after, 0), ended: call.ended !== undefined }
    }),
    stop: Effect.fn("Watch.callStop")(function* (deviceID: string, callID: string) {
      const call = yield* owned(deviceID, callID)
      yield* end(call, "client_end")
      return { ok: true as const }
    }),
    active: (deviceID: string) => active.has(deviceID),
    shutdown: Effect.suspend(() =>
      Effect.forEach(
        [...calls.values()].filter((call) => !call.ending),
        (call) => end(call, "shutdown", true),
        { discard: true, concurrency: "unbounded" },
      ),
    ),
    calls,
  }
}

export type VoiceCalls = ReturnType<typeof makeVoice>

/** Memory (`custom.voice`, scope `global`) as GPT Live `initial_items`, as `voice-session.md` describes. */
const initialItems = (ctx: VoiceContext) =>
  ctx.memory.context().pipe(
    Effect.timeoutOption(limits.memoryMs),
    Effect.map(Option.getOrUndefined),
    Effect.orElseSucceed(() => undefined),
    Effect.map((memory) =>
      memory
        ? [
            ...(memory.summary ? [message("developer", summaryLabel + memory.summary)] : []),
            ...memory.turns.map((turn) => message(turn.role, turnText(turn))),
            ...(memory.master
              ? [message("developer", masterLabel + memory.master.state + ": " + memory.master.text)]
              : []),
          ]
        : [],
    ),
  )

/** Same rule as the iPhone's `VoiceLeaseClock.isTransient`: 408, 429 and any 5xx are retried. */
function transientStatus(status: number) {
  return status === 408 || status === 429 || status >= 500
}

function isUdpCandidate(line: string) {
  return line.startsWith("a=candidate:") && line.split(" ")[2]?.toLowerCase() === "udp"
}

/** Bun's WebSocket client, which accepts headers; the sideband needs the Codex alpha headers. */
export const bunSideband: SidebandFactory = (url, headers, handlers) => {
  // oxlint-disable-next-line typescript-eslint/no-unsafe-type-assertion -- Bun extends the browser constructor with handshake headers (as in core's websocket-constructor).
  const BunWebSocket = globalThis.WebSocket as unknown as new (url: string, options: Bun.WebSocketOptions) => WebSocket
  const socket = new BunWebSocket(url, { headers })
  const queued: string[] = []
  socket.addEventListener("open", () => {
    for (const text of queued.splice(0)) socket.send(text)
  })
  const failed = { transport: false }
  socket.addEventListener("message", (event) => handlers.message(String(event.data)))
  socket.addEventListener("close", (event) =>
    handlers.closed({
      code: event.code,
      reason: event.reason,
      clean: event.wasClean,
      transportError: failed.transport,
    }),
  )
  socket.addEventListener("error", () => {
    failed.transport = true
    socket.close()
  })
  return {
    send: (text) => (socket.readyState === WebSocket.OPEN ? socket.send(text) : queued.push(text)),
    close: () => socket.close(),
  }
}
