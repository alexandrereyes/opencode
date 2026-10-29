import type { Plugin } from "@opencode/plugin/effect"
import { Cause, Clock, Effect, Exit, Option, Queue, Schema, Scope, Semaphore, Stream } from "effect"
import type { Client } from "../live-activity/apns.js"
import type { LiveActivity } from "../live-activity/rpc.js"
import { makeDevices, type Storage } from "./devices.js"
import { Failure, fail } from "./failure.js"
import { makeRequests, type RequestsContext } from "./requests.js"
import { Watch } from "./rpc.js"
import { makeStats, reader, type Stats } from "./stats.js"
import { makeVoice, type Proxy, type SidebandFactory, type VoiceCalls, type VoiceContext } from "./voice.js"
import { makeWidgetPush, type WidgetPush } from "./widget.js"

export const limits = {
  requestsPerMinute: 60,
  windowMs: 60_000,
  bodyBytes: 128 * 1024,
  /** A busy port (for example the spike relay on 4192) is retried this often. */
  retryMs: 30_000,
}

export type WatchContext = RequestsContext &
  VoiceContext & {
    storage: Storage
    event: Pick<Plugin.Context["event"], "subscribe">
    app: Pick<Plugin.Context["app"], "version">
  }

export type Member = { readonly ctx: WatchContext }

export type Access = { readonly clientId: string; readonly clientSecret: string }

export type GatewayOptions = {
  readonly port: Effect.Effect<number>
  readonly access: Effect.Effect<Access, unknown>
  readonly apns: Effect.Effect<Client | undefined>
  readonly widgetBundleID: Effect.Effect<string>
  readonly proxy: Proxy
  readonly sideband: SidebandFactory
  /** The Live Activity hub's state and host (`sharedHub().view`). */
  readonly view: Effect.Effect<
    {
      readonly state: LiveActivity.AgentsState | null
      readonly host: string
      readonly requests: ReadonlyMap<string, string>
    },
    unknown
  >
}

type Running = {
  readonly scope: Scope.Closeable
  readonly voice: VoiceCalls
  readonly signal: Queue.Queue<void>
  readonly stats: Stats
  /** The newest hub state the gateway saw, from `changed` events or a `/state` read; WidgetKit pushes follow it. */
  readonly latest: { state: LiveActivity.AgentsState | null }
  widget?: WidgetPush
  server?: ReturnType<typeof Bun.serve>
}

/**
 * The watch gateway: one HTTP listener per server process, shared by every Location's plugin instance like the
 * Live Activity hub. Only the allowlisted `/watch/v1` routes exist; every one needs a paired device token.
 */
export function makeGateway(options: GatewayOptions) {
  const members: Member[] = []
  const runtime = { current: undefined as Running | undefined }
  const lock = Semaphore.makeUnsafe(1)
  const windows = new Map<string, number[]>()
  const ctx = () => members[0]?.ctx

  const start = Effect.fn("Watch.gatewayStart")(function* () {
    const scope = yield* Scope.make()
    const running: Running = {
      scope,
      signal: yield* Queue.sliding<void>(1),
      voice: makeVoice({ ctx, proxy: options.proxy, sideband: options.sideband, scope }),
      stats: makeStats(),
      latest: { state: null },
    }
    runtime.current = running
    yield* Scope.addFinalizer(scope, running.voice.shutdown)
    yield* listen(running).pipe(Effect.forkIn(scope, { startImmediately: true }))
    yield* widgets(running).pipe(Effect.forkIn(scope, { startImmediately: true }))
  })

  const listen = (running: Running) =>
    Effect.gen(function* () {
      const port = yield* options.port
      const context = yield* Effect.context<never>()
      const warned = { at: false }
      for (;;) {
        const served = yield* Effect.try(() =>
          Bun.serve({
            hostname: "127.0.0.1",
            port,
            // Event long-polls hold a request for up to 25 s.
            idleTimeout: 60,
            fetch: (request) => Effect.runPromiseWith(context)(handle(request)),
          }),
        ).pipe(Effect.option)
        if (Option.isSome(served)) {
          running.server = served.value
          yield* Scope.addFinalizer(
            running.scope,
            Effect.promise(() => served.value.stop(true)),
          )
          return yield* Effect.logInfo("Watch gateway listening", { port: served.value.port })
        }
        if (!warned.at) yield* Effect.logWarning("Watch gateway port is busy; retrying", { port })
        warned.at = true
        yield* Effect.sleep(limits.retryMs)
      }
    })

  /** WidgetKit pushes follow the Live Activity state, read from its `changed` events. */
  const widgets = (running: Running) =>
    Effect.gen(function* () {
      const client = yield* options.apns
      const member = ctx()
      if (!client || !member) return
      const widget = makeWidgetPush({
        devices: makeDevices(member.storage),
        send: client.send,
        bundleID: yield* options.widgetBundleID,
        stats: running.stats,
      })
      running.widget = widget
      yield* Scope.addFinalizer(running.scope, client.close)
      running.latest.state = (yield* options.view.pipe(Effect.option)).pipe(
        Option.map((view) => view.state),
        Option.getOrNull,
      )
      yield* member.event.subscribe().pipe(
        Stream.filter((event) => event.type === "rpc.custom.live-activity.changed"),
        Stream.runForEach(() =>
          options.view.pipe(
            Effect.tap((view) => Effect.sync(() => (running.latest.state = view.state))),
            Effect.andThen(Queue.offer(running.signal, undefined)),
            Effect.catchCause(() => Effect.void),
          ),
        ),
        Effect.forkIn(running.scope, { startImmediately: true }),
      )
      for (;;) {
        const now = yield* Clock.currentTimeMillis
        const plan = yield* widget.evaluate(running.latest.state, now)
        yield* plan.deliver.pipe(Effect.forkIn(running.scope))
        const wait = Queue.take(running.signal)
        yield* plan.wakeAt === undefined ? wait : wait.pipe(Effect.timeoutOption(Math.max(plan.wakeAt - now, 1)))
      }
    }).pipe(
      Effect.catchCause((cause) =>
        Cause.hasInterruptsOnly(cause)
          ? Effect.failCause(cause)
          : Effect.logWarning("Watch widget push stopped", { cause }),
      ),
    )

  const handle = (request: Request): Effect.Effect<Response> =>
    route(request).pipe(
      Effect.catch((error) =>
        Effect.succeed(
          error instanceof Failure
            ? json({ error: { code: error.code, message: error.message } }, error.status)
            : json({ error: { code: "internal", message: "Erro interno." } }, 500),
        ),
      ),
      Effect.catchCause((cause) =>
        Effect.logWarning("Watch gateway request failed", { cause }).pipe(
          Effect.as(json({ error: { code: "internal", message: "Erro interno." } }, 500)),
        ),
      ),
    )

  const route = Effect.fn("Watch.route")(function* (request: Request) {
    const url = new URL(request.url)
    if (!url.pathname.startsWith("/watch/v1/")) return yield* fail(404, "not_found", "Rota inexistente.")
    const running = runtime.current
    const member = ctx()
    if (!running || !member) return yield* fail(503, "unavailable", "Servidor indisponível.")
    const device = yield* makeDevices(member.storage).authenticate(request.headers.get("authorization"))
    if (!device) return yield* fail(401, "unauthorized", "Não autorizado.")
    const path = url.pathname.slice("/watch/v1".length)
    const method = request.method
    const heartbeat = method === "POST" && /^\/voice\/calls\/[^/]+\/heartbeat$/.test(path)
    if (!heartbeat && !running.voice.active(device.deviceID)) yield* limit(device.deviceID)
    const requests = makeRequests(member)
    const segments = path.split("/").slice(1).map(decodeURIComponent)

    if (method === "GET" && path === "/ping")
      return json({
        ok: true,
        server: (yield* options.view.pipe(Effect.option)).pipe(
          Option.map((view) => view.host),
          Option.getOrElse(() => ""),
        ),
        version: member.app.version,
      })
    if (method === "GET" && path === "/state") {
      const view = yield* options.view.pipe(Effect.mapError(() => fail(503, "unavailable", "Estado indisponível.")))
      // Every reader caches what it gets for the complication: no push is needed for this state any more.
      running.latest.state = view.state
      running.widget?.seen(device.deviceID, view.state)
      yield* running.stats.state(
        device.deviceID,
        reader(request.headers.get("x-watch-client")),
        yield* Clock.currentTimeMillis,
      )
      // The watch opens Responder from an attention row, so each item carries its oldest pending request.
      const state = view.state && {
        ...view.state,
        attention: view.state.attention.map((item) => {
          const requestID = view.requests.get(item.sessionID)
          return requestID ? { ...item, requestID } : item
        }),
      }
      return json({ state, host: view.host })
    }
    if (segments[0] === "requests" && segments.length === 2 && method === "GET")
      return json(yield* requests.get(segments[1] ?? ""))
    if (segments[0] === "requests" && segments.length === 3 && segments[2] === "reply" && method === "POST")
      return json(yield* requests.reply(segments[1] ?? "", yield* body(request, Watch.WatchReply)))
    if (method === "POST" && path === "/widget-token") {
      const input = yield* body(request, Watch.WidgetToken)
      yield* makeDevices(member.storage).widget(device.deviceID, input)
      yield* Queue.offer(running.signal, undefined)
      return json({ ok: true })
    }
    if (segments[0] === "voice" && segments[1] === "calls") {
      const callID = segments[2]
      if (segments.length === 2 && method === "POST")
        return json(yield* running.voice.start(device.deviceID, yield* body(request, Watch.CallInput)), 201)
      if (callID && segments.length === 4 && segments[3] === "heartbeat" && method === "POST") {
        yield* body(request, Watch.Heartbeat)
        return json(yield* running.voice.heartbeat(device.deviceID, callID))
      }
      if (callID && segments.length === 4 && segments[3] === "events" && method === "GET") {
        const after = Number(url.searchParams.get("after") ?? "0")
        return json(yield* running.voice.events(device.deviceID, callID, Number.isFinite(after) ? after : 0))
      }
      if (callID && segments.length === 3 && method === "DELETE")
        return json(yield* running.voice.stop(device.deviceID, callID))
    }
    if (method === "POST" && path === "/diagnostics") {
      const input = yield* body(request, Watch.Diagnostics)
      yield* Effect.logInfo("Watch diagnostics", { deviceID: device.deviceID, events: input.events.map(redact) })
      return json({ ok: true })
    }
    return yield* fail(404, "not_found", "Rota inexistente.")
  })

  /** 60 requests per minute per device outside an active call; heartbeats never count. */
  const limit = (deviceID: string) =>
    Effect.gen(function* () {
      const now = yield* Clock.currentTimeMillis
      const recent = (windows.get(deviceID) ?? []).filter((at) => now - at < limits.windowMs)
      if (recent.length >= limits.requestsPerMinute) {
        windows.set(deviceID, recent)
        return yield* fail(429, "rate_limited", "Muitas requisições. Tente de novo em instantes.")
      }
      windows.set(deviceID, [...recent, now])
    })

  const handlers = {
    pair: (input: { readonly deviceName: string }) =>
      Effect.gen(function* () {
        const member = ctx()
        if (!member) return yield* Effect.fail(new Error("Watch gateway is not running"))
        const access = yield* options.access
        const paired = yield* makeDevices(member.storage).pair(input.deviceName)
        yield* Effect.logInfo("Watch paired", { deviceID: paired.deviceID })
        return { ...paired, gatewayURL: Watch.gatewayURL, access, voice: { voiceID: Watch.defaultVoiceID } }
      }),
    devices: () =>
      Effect.gen(function* () {
        const member = ctx()
        if (!member) return { devices: [] }
        const devices = yield* makeDevices(member.storage).list()
        return {
          devices: devices.map((device) => ({
            deviceID: device.deviceID,
            name: device.name,
            createdAt: device.createdAt,
            // The contract always lists it; a watch that never called the gateway was last seen at pairing.
            lastSeenAt: device.lastSeenAt ?? device.createdAt,
          })),
        }
      }),
    stats: () =>
      Effect.gen(function* () {
        const now = yield* Clock.currentTimeMillis
        return { at: now, ...(runtime.current?.stats.snapshot(now) ?? { devices: [] }) }
      }),
    revoke: (input: { readonly deviceID: string }) =>
      Effect.gen(function* () {
        const member = ctx()
        if (!member) return {}
        yield* makeDevices(member.storage).revoke(input.deviceID)
        const running = runtime.current
        const callID = [...(running?.voice.calls.values() ?? [])].find(
          (call) => call.deviceID === input.deviceID && !call.ended,
        )?.id
        if (running && callID) yield* running.voice.stop(input.deviceID, callID).pipe(Effect.ignore)
        windows.delete(input.deviceID)
        yield* Effect.logInfo("Watch revoked", { deviceID: input.deviceID })
        return {}
      }),
  }

  const attach = (member: Member) =>
    lock.withPermit(
      Effect.gen(function* () {
        members.push(member)
        if (!runtime.current) yield* start()
      }),
    )

  const detach = (member: Member) =>
    lock.withPermit(
      Effect.gen(function* () {
        const index = members.indexOf(member)
        if (index >= 0) members.splice(index, 1)
        const running = runtime.current
        if (members.length > 0 || !running) return
        runtime.current = undefined
        yield* Scope.close(running.scope, Exit.void)
      }),
    )

  return {
    join: (member: Member) => Effect.acquireRelease(attach(member), () => detach(member)),
    handle,
    handlers,
    members,
    runtime,
  }
}

export type Gateway = ReturnType<typeof makeGateway>

function json(value: unknown, status = 200) {
  return Response.json(value, { status })
}

const body = <A>(request: Request, schema: Schema.Codec<A, unknown>) =>
  Effect.gen(function* () {
    const text = yield* Effect.promise(() => request.text())
    if (Buffer.byteLength(text) > limits.bodyBytes) return yield* fail(413, "too_large", "Requisição grande demais.")
    return yield* Schema.decodeUnknownEffect(Schema.fromJsonString(schema))(text).pipe(
      Effect.mapError(() => fail(400, "invalid_body", "Requisição inválida.")),
    )
  })

const secretKey = /token|secret|password|authorization|cookie|sdp|key|bearer/i

/** Diagnostics keep their shape but never secrets: sensitive keys are masked and strings clipped. */
export function redact(value: unknown, depth = 0): unknown {
  if (typeof value === "string") return value.length > 500 ? value.slice(0, 500) + "…" : value
  if (typeof value !== "object" || value === null || depth > 4) return typeof value === "object" ? "[…]" : value
  if (Array.isArray(value)) return value.slice(0, 20).map((item) => redact(item, depth + 1))
  return Object.fromEntries(
    Object.entries(value)
      .slice(0, 40)
      .map(([key, item]) => [key.slice(0, 40), secretKey.test(key) ? "[redacted]" : redact(item, depth + 1)]),
  )
}
