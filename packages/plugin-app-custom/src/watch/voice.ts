import { Clock, Deferred, Effect, Exit, Option, Queue, Schema, Scope } from "effect"
import { Voice } from "../voice/rpc.js"
import { masterLabel, summaryLabel, turnText } from "../voice/index.js"
import { makeDelegator, type DelegationContext } from "./delegation.js"
import { fail } from "./failure.js"
import { Watch } from "./rpc.js"

export const limits = {
  /** Lease renewal cadence, also the watch's heartbeat cadence. */
  renewMs: 5_000,
  /** Without a heartbeat for this long the call ends; returned to the watch as `leaseSeconds`. */
  livenessMs: 15_000,
  maxCallMs: 30 * 60_000,
  pollMs: 25_000,
  /** An ended call stays readable this long so the watch can read its last events. */
  keepEndedMs: 60_000,
  events: 400,
  httpMs: 8_000,
  createMs: 25_000,
  memoryMs: 2_000,
  closeMs: 4_000,
  /** Lease margin from the iPhone contract: a lease is considered lost this long before it expires. */
  leaseMarginMs: 10_000,
  appendBytes: 500,
}

export const model = "gpt-live-1-codex"
export const proxyOrigin = "http://llm-proxy-svc:8080"
const codexHeaders = { "OpenAI-Alpha": "quicksilver=v2", originator: "a2a-chat" }

/** HTTP to the llm-proxy; production uses `fetch` against `proxyOrigin`, tests a local handler. */
export type Proxy = {
  readonly origin: string
  readonly fetch: (request: Request) => Promise<Response>
}

/** The GPT Live sideband (`/v1/live/<call>`), a WebSocket in production. */
export type Sideband = { readonly send: (text: string) => void; readonly close: () => void }
export type SidebandFactory = (
  url: string,
  headers: Record<string, string>,
  handlers: { readonly message: (text: string) => void; readonly closed: () => void },
) => Sideband

/** Voice memory (`custom.voice`, scope `global`), shared with the iPhone. */
export type Memory = {
  readonly context: () => Effect.Effect<typeof Voice.Context.Type, unknown>
  readonly append: (turns: readonly Voice.Turn[]) => Effect.Effect<unknown, unknown>
  readonly end: () => Effect.Effect<unknown, unknown>
}

export type VoiceContext = DelegationContext & {
  memory: Memory
  instructions: () => Effect.Effect<string, unknown>
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
  ending?: Deferred.Deferred<void>
  ended?: string
}

const Lease = Schema.Struct({
  sessionId: Schema.String,
  generation: Schema.String,
  serverTime: Schema.String,
  leaseExpiresAt: Schema.String,
})
const decodeLease = Schema.decodeUnknownOption(Schema.fromJsonString(Lease))

const SidebandEvent = Schema.Struct({
  type: Schema.String,
  item: Schema.optionalKey(
    Schema.Struct({
      id: Schema.optionalKey(Schema.String),
      type: Schema.optionalKey(Schema.String),
      text: Schema.optionalKey(Schema.String),
      target: Schema.optionalKey(Schema.String),
      content: Schema.optionalKey(
        Schema.Array(Schema.Struct({ type: Schema.String, text: Schema.optionalKey(Schema.String) })),
      ),
    }),
  ),
  turn: Schema.optionalKey(
    Schema.Struct({
      id: Schema.optionalKey(Schema.String),
      role: Schema.optionalKey(Schema.String),
      transcript: Schema.optionalKey(Schema.String),
      status: Schema.optionalKey(Schema.String),
      interrupted: Schema.optionalKey(Schema.Boolean),
    }),
  ),
})
const decodeEvent = Schema.decodeUnknownOption(Schema.fromJsonString(SidebandEvent))

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
    const voices = [...new Set([offer.voiceID ?? Watch.defaultVoiceID, "rio", "cove"])]
    const answer = yield* createCall(call, offer.sdp, voices, memory, instructions)
    if (!/^a=ice-lite\s*$/m.test(answer) || !answer.split(/\r?\n/).some(isUdpCandidate))
      return yield* fail(502, "unsupported_answer", "O serviço de voz não ofereceu um caminho de áudio compatível.")
    yield* Queue.take(call.inbox).pipe(
      Effect.flatMap((text) => receive(call, text)),
      Effect.forever,
      Effect.forkIn(call.scope, { startImmediately: true }),
    )
    call.sideband = input.sideband(
      input.proxy.origin.replace(/^http/, "ws") + `/v1/live/${call.remoteID}`,
      codexHeaders,
      {
        message: (text) => Queue.offerUnsafe(call.inbox, text),
        closed: () => {
          Deferred.doneUnsafe(call.sidebandClosed, Effect.void)
          if (!call.ending) Queue.offerUnsafe(call.inbox, JSON.stringify({ type: "sideband.closed" }))
        },
      },
    )
    yield* Effect.sleep(limits.renewMs).pipe(Effect.andThen(renew(call)), Effect.forever, Effect.forkIn(call.scope))
    yield* Effect.sleep(limits.maxCallMs).pipe(
      Effect.andThen(Effect.suspend(() => end(call, "max_duration"))),
      Effect.forkIn(call.scope),
    )
    return answer
  })

  const createCall = (call: Call, sdp: string, voices: readonly string[], memory: readonly unknown[], instructions: string) =>
    Effect.gen(function* () {
      for (const [index, voice] of voices.entries()) {
        const session = {
          model,
          instructions,
          audio: { output: { voice } },
          delegation: { type: "client" },
          ...(memory.length > 0 ? { initial_items: memory } : {}),
        }
        const response = yield* http(
          "POST",
          "/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas",
          {
            body: JSON.stringify({ sdp, session }),
            headers: {
              accept: "application/sdp",
              ...codexHeaders,
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
        const location = response.headers.get("location") ?? ""
        call.remoteID = location.split("?")[0]?.replace(/\/$/, "").split("/").pop() || undefined
        if (response.status !== 201 || !body.startsWith("v=0") || !call.remoteID)
          return yield* fail(502, "create_failed", "O serviço de voz recusou a chamada.")
        return body
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
      const transient = Option.isNone(response) || [408, 429, 502, 503, 504].includes(response.value.status)
      if (!transient && !(yield* confirm(call, response.value, now))) return yield* end(call, "lease_refused")
      if (transient && (yield* Clock.currentTimeMillis) >= call.leaseUntil) return yield* end(call, "lease_lost")
    })

  const receive = Effect.fn("Watch.sideband")(function* (call: Call, text: string) {
    const event = Option.getOrUndefined(decodeEvent(text))
    if (!event || call.ended) return
    switch (event.type) {
      case "session.started":
        return yield* emit(call, { type: "status", status: "live" })
      case "input_transcript.added":
      case "output_transcript.added": {
        const role = event.type === "input_transcript.added" ? "user" : "assistant"
        call.captions[role] += event.item?.text ?? ""
        if (!call.captions[role].trim()) return
        return yield* emit(call, { type: "caption", role, text: call.captions[role].trim(), final: false })
      }
      case "turn.done": {
        const role = event.turn?.role === "assistant" ? "assistant" : "user"
        const spoken = (event.turn?.transcript ?? call.captions[role]).trim()
        call.captions[role] = ""
        if (!spoken) return
        yield* emit(call, { type: "caption", role, text: spoken, final: true })
        return yield* remember(call, {
          id: `${call.id}:${event.turn?.id ?? call.seq}`,
          role,
          text: spoken,
          interrupted:
            event.turn?.interrupted === true || ["interrupted", "cancelled"].includes(event.turn?.status ?? ""),
        })
      }
      case "delegation.created": {
        const item = event.item
        if (item?.target !== "client" || item.type !== "delegation" || !item.id) return
        const request = (item.content ?? [])
          .flatMap((part) => (part.type === "input_text" && part.text ? [part.text] : []))
          .join("")
        if (!request.trim()) return
        return yield* delegator(call).pipe(
          Effect.flatMap((delegate) => (delegate ? delegate.ask(item.id ?? "", request) : Effect.void)),
        )
      }
      case "error":
        yield* Effect.logWarning("Watch call upstream error")
        return yield* emit(call, { type: "error", code: "voice_error", message: "O serviço de voz informou um erro." })
      case "session.closed":
        return yield* end(call, "session_closed")
      case "sideband.closed":
        return yield* end(call, "sideband_closed")
    }
  })

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
          append: (itemID, text) =>
            Effect.sync(() => {
              for (const chunk of chunks(text))
                call.sideband?.send(
                  JSON.stringify({
                    type: "delegation.context.append",
                    delegation_item_id: itemID,
                    channel: "speakable",
                    content: [{ type: "input_text", text: chunk }],
                  }),
                )
            }),
          master: (state, text) => emit(call, { type: "master", state, text }),
        },
        call.scope,
      )
      delegators.set(call, created)
      return created
    })

  const remember = (call: Call, turn: Omit<Voice.Turn, "at">) =>
    Effect.gen(function* () {
      const ctx = input.ctx()
      if (!ctx) return
      const at = yield* Clock.currentTimeMillis
      yield* ctx.memory
        .append([
          { id: turn.id, role: turn.role, text: turn.text, at, ...(turn.interrupted ? { interrupted: true } : {}) },
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
        if (call.sideband) {
          call.sideband.send(JSON.stringify({ type: "session.close" }))
          yield* Deferred.await(call.sidebandClosed).pipe(Effect.timeoutOption(limits.closeMs))
          call.sideband.close()
        }
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
          reason,
          released: Option.isSome(released) ? released.value.status : 0,
        })
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
            ...(memory.summary ? [message("user", summaryLabel + memory.summary)] : []),
            ...memory.turns.map((turn) => message(turn.role, turnText(turn))),
            ...(memory.master ? [message("user", masterLabel + memory.master.state + ": " + memory.master.text)] : []),
          ]
        : [],
    ),
  )

function message(role: "user" | "assistant", text: string) {
  return { type: "message", role, content: [{ type: role === "user" ? "input_text" : "output_text", text }] }
}

function isUdpCandidate(line: string) {
  return line.startsWith("a=candidate:") && line.split(" ")[2]?.toLowerCase() === "udp"
}

/** Splits text into parts of at most 500 UTF-8 bytes without breaking a code point. */
export function chunks(text: string) {
  return Array.from(text).reduce<string[]>((parts, char) => {
    const last = parts.at(-1)
    if (last !== undefined && Buffer.byteLength(last + char) <= limits.appendBytes)
      parts[parts.length - 1] = last + char
    else parts.push(char)
    return parts
  }, [])
}

const VoiceRejection = Schema.Struct({
  error: Schema.optionalKey(
    Schema.Struct({
      code: Schema.optionalKey(Schema.NullOr(Schema.String)),
      type: Schema.optionalKey(Schema.NullOr(Schema.String)),
      param: Schema.optionalKey(Schema.NullOr(Schema.String)),
    }),
  ),
  detail: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({ loc: Schema.optionalKey(Schema.Array(Schema.Unknown)), type: Schema.optionalKey(Schema.String) }),
    ),
  ),
})
const decodeRejection = Schema.decodeUnknownOption(Schema.fromJsonString(VoiceRejection))

/** Same rule as the iPhone's `VoiceSignaling.rejectsVoice`. */
export function rejectsVoice(status: number, body: string) {
  if (status !== 400 && status !== 422) return false
  const root = Option.getOrUndefined(decodeRejection(body))
  if (!root) return false
  if (["invalid_voice", "unsupported_voice"].includes(root.error?.code ?? "")) return true
  if (
    root.error?.type === "invalid_request_error" &&
    ["session.audio.output.voice", "audio.output.voice", "voice"].includes(root.error.param ?? "")
  )
    return true
  return (root.detail ?? []).some(
    (item) =>
      (item.loc ?? []).slice(-4).join(".") === "session.audio.output.voice" &&
      ["enum", "literal_error", "value_error"].includes(item.type ?? ""),
  )
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
  socket.addEventListener("message", (event) => handlers.message(String(event.data)))
  socket.addEventListener("close", () => handlers.closed())
  socket.addEventListener("error", () => socket.close())
  return {
    send: (text) => (socket.readyState === WebSocket.OPEN ? socket.send(text) : queued.push(text)),
    close: () => socket.close(),
  }
}
