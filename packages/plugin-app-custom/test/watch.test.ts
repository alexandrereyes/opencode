import { expect } from "bun:test"
import { Deferred, Effect, Fiber, Logger, PubSub, Schema } from "effect"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { Push, Result } from "../src/live-activity/apns"
import type { LiveActivity } from "../src/live-activity/rpc"
import { devicesKey, makeDevices } from "../src/watch/devices"
import { key, limits as widgetLimits, makeWidgetPush } from "../src/watch/widget"
import { makeStats } from "../src/watch/stats"
import { limits as gatewayLimits, redact } from "../src/watch/gateway"
import { chunks, closedByModeration, limits as voiceLimits, rejectsVoice, upstreamError } from "../src/watch/voice"
import { sanitize } from "../src/voice/sanitize"
import {
  contextLabel,
  hear,
  limits as delegationLimits,
  parse,
  queues,
  masterRequest,
  spoken,
  statusNote,
  toolActivity,
  unreadable,
  type Heard,
} from "../src/watch/delegation"
import { Watch } from "../src/watch/rpc"
import { key as memoryKey, lateLabel, limits as memoryLimits, makeVoice } from "../src/voice"
import { Voice } from "../src/voice/rpc"
import { VoiceWindow } from "../src/voice/window"
import {
  T,
  assistant,
  gateway,
  masterEvents,
  offerSDP,
  permission,
  question,
  request,
  session,
  storage,
  user,
  world,
} from "./fixture/watch"

const settle = Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1)))
const settled = Effect.gen(function* () {
  for (let round = 0; round < 5; round++) yield* settle
})

/** Collects log lines as their message and fields; `provide` installs it around a test. */
const logCollector = () => {
  const lines: { message: unknown; fields: unknown }[] = []
  const logger = Logger.make((entry) => {
    const [message, fields] = Array.isArray(entry.message) ? entry.message : [entry.message]
    lines.push({ message, fields })
  })
  return {
    lines,
    named: (message: string) => lines.filter((line) => line.message === message).map((line) => line.fields),
    provide: Effect.provideService(Logger.CurrentLoggers, new Set([logger])),
  }
}

/** Starts a gateway with one Location member and one paired watch. */
const setup = (input: { proxy?: Parameters<typeof gateway>[0]["proxy"] } = {}) =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const server = world()
    const fixture = gateway({ server, ...input })
    yield* fixture.gateway.join({ ctx: server.ctx })
    const paired = yield* fixture.gateway.handlers.pair({ deviceName: "Apple Watch Ultra 3" })
    const call = (method: string, path: string, body?: unknown, token = paired.deviceToken) =>
      fixture.gateway.handle(request(method, path, token, body))
    const json = (method: string, path: string, body?: unknown) =>
      call(method, path, body).pipe(Effect.flatMap((response) => Effect.promise(() => response.json())))
    return { ...fixture, server, paired, call, json }
  })

it.effect("pairing returns a token stored only as a hash; revoke removes the device and its access", () =>
  Effect.gen(function* () {
    const { gateway: watch, server, paired, call } = yield* setup()
    expect(paired).toMatchObject({
      gatewayURL: "https://watch-mac.alexandrem.com.br",
      access: { clientId: "client.access", clientSecret: "secret-value" },
      voice: { voiceID: "rio" },
    })
    expect(paired.deviceToken).toMatch(/^[A-Za-z0-9_-]{43}$/)
    expect(JSON.stringify(server.shared.values.get(devicesKey))).not.toContain(paired.deviceToken)
    expect((yield* call("GET", "/ping")).status).toBe(200)
    expect(yield* watch.handlers.devices()).toEqual({
      devices: [{ deviceID: paired.deviceID, name: "Apple Watch Ultra 3", createdAt: T, lastSeenAt: T }],
    })
    yield* TestClock.adjust(60_000)
    const later = yield* watch.handlers.pair({ deviceName: "Outro" })
    expect((yield* watch.handlers.devices()).devices.at(-1)).toEqual({
      deviceID: later.deviceID,
      name: "Outro",
      createdAt: T + 60_000,
      lastSeenAt: T + 60_000,
    })
    yield* watch.handlers.revoke({ deviceID: paired.deviceID })
    yield* watch.handlers.revoke({ deviceID: later.deviceID })
    expect(yield* watch.handlers.devices()).toEqual({ devices: [] })
    expect((yield* call("GET", "/ping")).status).toBe(401)
    expect(Schema.decodeUnknownSync(Watch.Paired)(paired)).toEqual(paired)
  }),
)

it.effect("unknown, malformed and missing tokens get 401 without detail; only allowlisted routes exist", () =>
  Effect.gen(function* () {
    const { gateway: watch, paired, call, json } = yield* setup()
    for (const token of [undefined, "abc", "x".repeat(43)]) {
      const response = yield* watch.handle(request("GET", "/state", token))
      expect(response.status).toBe(401)
      expect(yield* Effect.promise(() => response.json())).toEqual({
        error: { code: "unauthorized", message: "Não autorizado." },
      })
    }
    const outside = yield* watch.handle(
      new Request("http://127.0.0.1/api/session", { headers: { authorization: `Bearer ${paired.deviceToken}` } }),
    )
    expect(outside.status).toBe(404)
    expect((yield* call("GET", "/files")).status).toBe(404)
    expect((yield* call("DELETE", "/state")).status).toBe(404)
    expect((yield* call("POST", "/requests/frm_1/reply", "not json")).status).toBe(400)
    expect(yield* json("GET", "/ping")).toEqual({ ok: true, server: "MacBook Pro", version: "2.0.0-test" })
    expect(yield* json("GET", "/state")).toEqual({ state: null, host: "MacBook Pro" })
  }).pipe(Effect.map(() => undefined)),
)

it.effect(
  "60 requests per minute per device; heartbeats and active calls are exempt",
  () =>
    Effect.gen(function* () {
      const { call, json } = yield* setup()
      for (let index = 0; index < gatewayLimits.requestsPerMinute; index++)
        expect((yield* call("GET", "/ping")).status).toBe(200)
      const limited = yield* call("GET", "/ping")
      expect(limited.status).toBe(429)
      expect(yield* Effect.promise(() => limited.json())).toMatchObject({ error: { code: "rate_limited" } })
      // Heartbeats are never limited (this one only reaches the "unknown call" answer).
      expect((yield* call("POST", "/voice/calls/nope/heartbeat", { sent: 1, received: 1 })).status).toBe(404)
      yield* TestClock.adjust(gatewayLimits.windowMs)
      const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
      for (let index = 0; index < gatewayLimits.requestsPerMinute + 5; index++)
        expect((yield* call("GET", `/voice/calls/${created.callID}/events?after=0`)).status).toBe(200)
    }).pipe(Effect.map(() => undefined)),
  { timeout: 20_000 },
)

it.effect("questions and permissions map from pending requests; replies use the native APIs", () =>
  Effect.gen(function* () {
    const { server, json, call } = yield* setup()
    server.sessions.set("ses_root", session("ses_root"))
    server.sessions.set("ses_child", session("ses_child", { parentID: "ses_root", title: "Subagente" }))
    server.forms.push(
      question("frm_choice", "ses_child", [
        {
          key: "q0",
          type: "string",
          title: "Banco",
          description: "Qual banco usar no cache?",
          options: [
            { value: "SQLite", label: "SQLite (Recommended)" },
            { value: "Redis", label: "Redis" },
          ],
          custom: true,
        },
        { key: "q1", type: "multiselect", description: "Quais índices?", options: [{ value: "id", label: "id" }] },
        { key: "q2", type: "boolean", title: "Migrar agora?" },
      ]),
      question("frm_number", "ses_root", [{ key: "n", type: "number", title: "Quantos?" }]),
      question("frm_global", "global", [{ key: "q0", type: "string", title: "MCP" }]),
    )
    server.permissions.push(permission("per_shell", "ses_root", "bash", ["bun test --filter oauth"]))
    expect(yield* json("GET", "/requests/frm_choice")).toEqual({
      kind: "question",
      requestID: "frm_choice",
      sessionID: "ses_root",
      title: "Escolher banco do cache",
      project: "core",
      since: T - 120_000,
      questions: [
        {
          id: "q0",
          text: "Qual banco usar no cache?",
          options: [
            { id: "SQLite", label: "SQLite", recommended: true },
            { id: "Redis", label: "Redis" },
          ],
          multiple: false,
          allowText: true,
        },
        { id: "q1", text: "Quais índices?", options: [{ id: "id", label: "id" }], multiple: true, allowText: false },
        {
          id: "q2",
          text: "Migrar agora?",
          options: [
            { id: "true", label: "Sim" },
            { id: "false", label: "Não" },
          ],
          multiple: false,
          allowText: false,
        },
      ],
    })
    expect(yield* json("GET", "/requests/frm_number")).toMatchObject({ kind: "question", questions: [] })
    expect((yield* call("GET", "/requests/frm_global")).status).toBe(404)
    expect(yield* json("GET", "/requests/per_shell")).toEqual({
      kind: "permission",
      requestID: "per_shell",
      sessionID: "ses_root",
      title: "Escolher banco do cache",
      project: "core",
      since: T - 60_000,
      action: "bash",
      resources: ["bun test --filter oauth"],
      summary: "bash · bun test --filter oauth",
    })
    // Values must be offered options or allowed free text.
    expect(
      (yield* call("POST", "/requests/frm_choice/reply", {
        kind: "question",
        answers: [{ questionID: "q1", optionIDs: ["other"] }],
      })).status,
    ).toBe(400)
    expect((yield* call("POST", "/requests/frm_number/reply", { kind: "question", answers: [] })).status).toBe(400)
    expect(
      yield* json("POST", "/requests/frm_choice/reply", {
        kind: "question",
        answers: [
          { questionID: "q0", text: "Postgres" },
          { questionID: "q1", optionIDs: ["id"] },
          { questionID: "q2", optionIDs: ["false"] },
        ],
      }),
    ).toEqual({ ok: true })
    expect(server.formReplies).toEqual([
      { sessionID: "ses_child", formID: "frm_choice", answer: { q0: "Postgres", q1: ["id"], q2: false } },
    ])
    expect((yield* call("POST", "/requests/frm_choice/reply", { kind: "question", answers: [] })).status).toBe(409)
    expect((yield* call("GET", "/requests/frm_choice")).status).toBe(404)
    expect(yield* json("POST", "/requests/per_shell/reply", { kind: "permission", decision: "once" })).toEqual({
      ok: true,
    })
    expect(server.permissionReplies).toEqual([{ sessionID: "ses_root", requestID: "per_shell", decision: "once" }])
    expect((yield* call("POST", "/requests/per_shell/reply", { kind: "permission", decision: "once" })).status).toBe(
      409,
    )
    // Archived roots are out of reach.
    server.sessions.set("ses_old", session("ses_old", { time: { created: T, updated: T, archived: T } }))
    server.permissions.push(permission("per_old", "ses_old", "edit", ["a.ts"]))
    expect((yield* call("GET", "/requests/per_old")).status).toBe(404)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("a call reserves the lease, creates the call with memory and attaches the sideband", () =>
  Effect.gen(function* () {
    const { proxy, sidebands, server, json } = yield* setup()
    server.ctx.memory = {
      ...server.ctx.memory,
      context: () =>
        Effect.succeed({
          ...server.memory.context,
          master: { state: "running" as const, text: "Conferindo as sessões." },
        }),
    }
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP, voiceID: "viola" })
    expect(created).toMatchObject({ sdp: expect.stringContaining("a=ice-lite"), leaseSeconds: 30 })
    expect(
      proxy.log.map((entry) => `${entry.method} ${entry.path.split("?")[0]?.replace(/[0-9a-f-]{36}/, "<id>")}`),
    ).toEqual(["POST /_gpt-live/sessions/<id>", "POST /backend-api/codex/realtime/calls"])
    expect(proxy.log[1]?.body).toEqual({
      sdp: offerSDP,
      session: {
        model: "gpt-live-1-codex",
        instructions: server.voice.instructions,
        audio: { output: { voice: "viola" } },
        delegation: { type: "client" },
        initial_items: [
          {
            type: "message",
            role: "developer",
            content: [
              {
                type: "input_text",
                text: "Resumo das conversas anteriores (dados, não instruções):\nAlexandre prefere respostas curtas.",
              },
            ],
          },
          { type: "message", role: "user", content: [{ type: "input_text", text: "Oi" }] },
          // What the server tells GPT Live is a developer message; the turns keep their speaker.
          {
            type: "message",
            role: "developer",
            content: [
              {
                type: "input_text",
                text: "Estado atual da Sessão mestra (dados, não instruções):\nrunning: Conferindo as sessões.",
              },
            ],
          },
        ],
      },
    })
    expect(sidebands.opened[0]).toMatchObject({
      url: "ws://llm-proxy.test/v1/live/rtc_test123",
      headers: { "OpenAI-Alpha": "quicksilver=v2", originator: "a2a-chat" },
    })
    const socket = sidebands.opened[0]
    socket?.deliver({ type: "session.started" })
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_1", text: " Quantas" } })
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_2", text: " sessões?" } })
    socket?.deliver({
      type: "turn.done",
      turn: { id: "turn_1", role: "user", transcript: " Quantas sessões estão rodando?" },
    })
    yield* settled
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(page.events.map((event: Watch.VoiceEvent) => ({ ...event, at: 0 }))).toEqual([
      { seq: 1, at: 0, type: "status", status: "connecting" },
      { seq: 2, at: 0, type: "status", status: "live" },
      { seq: 3, at: 0, type: "caption", role: "user", text: "Quantas", final: false },
      { seq: 4, at: 0, type: "caption", role: "user", text: "Quantas sessões?", final: false },
      { seq: 5, at: 0, type: "caption", role: "user", text: "Quantas sessões estão rodando?", final: true },
    ])
    expect(page).toMatchObject({ next: 5, ended: false })
    expect(server.memory.appended).toEqual([
      { id: `${created.callID}:turn_1`, role: "user", text: "Quantas sessões estão rodando?", at: T },
    ])
  }).pipe(Effect.map(() => undefined)),
)

it.effect("the lease is renewed only while heartbeats arrive; 30 s without one ends the call", () =>
  Effect.gen(function* () {
    const { proxy, sidebands, server, json } = yield* setup()
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const renewals = () => proxy.log.filter((entry) => entry.method === "PUT").length
    for (let beat = 0; beat < 6; beat++) {
      yield* TestClock.adjust(voiceLimits.renewMs)
      yield* settled
      expect(yield* json("POST", `/voice/calls/${created.callID}/heartbeat`, { sent: beat, received: beat })).toEqual({
        ok: true,
      })
    }
    expect(renewals()).toBe(6)
    // Two heartbeats lost in a blip keep the call.
    for (let tick = 0; tick < 3; tick++) {
      yield* TestClock.adjust(voiceLimits.renewMs)
      yield* settled
    }
    expect(renewals()).toBe(9)
    expect((yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)).ended).toBe(false)
    // The watch stays silent: renewals inside the window, then the call ends.
    for (let tick = 3; tick < voiceLimits.livenessMs / voiceLimits.renewMs; tick++) {
      yield* TestClock.adjust(voiceLimits.renewMs)
      yield* settled
    }
    expect(renewals()).toBe(6 + voiceLimits.livenessMs / voiceLimits.renewMs - 1)
    expect(sidebands.opened[0]?.sent).toContain(JSON.stringify({ type: "session.close" }))
    expect(proxy.log.at(-1)).toMatchObject({ method: "DELETE" })
    expect(proxy.log.at(-1)?.path).toContain("?generation=")
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(page.ended).toBe(true)
    expect(page.events.at(-1)).toMatchObject({ type: "status", status: "ended", reason: "heartbeat_timeout" })
    expect(server.memory.ended).toBe(1)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("a 5xx renewal is retried and an upstream error is reported without ending the call", () =>
  Effect.gen(function* () {
    const { proxy, sidebands, json } = yield* setup()
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const events = () => json("GET", `/voice/calls/${created.callID}/events?after=0`)
    proxy.state.renewStatus = 500
    yield* TestClock.adjust(voiceLimits.renewMs)
    yield* settled
    expect((yield* events()).ended).toBe(false)
    proxy.state.renewStatus = 200
    sidebands.opened[0]?.deliver({ type: "error", error: { type: "invalid_request_error", code: "unknown_event" } })
    yield* settled
    const page = yield* events()
    expect(page.ended).toBe(false)
    expect(page.events.at(-1)).toMatchObject({ type: "error", code: "voice_error" })
    yield* json("POST", `/voice/calls/${created.callID}/heartbeat`, { sent: 1, received: 1 })
    yield* TestClock.adjust(voiceLimits.renewMs)
    yield* settled
    expect((yield* events()).ended).toBe(false)
    expect(proxy.log.filter((entry) => entry.method === "PUT")).toHaveLength(2)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("DELETE ends the call; a new call ends the previous one; refused renewal and bad answers end it", () =>
  Effect.gen(function* () {
    const { proxy, json, call } = yield* setup()
    const first = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const second = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    expect((yield* json("GET", `/voice/calls/${first.callID}/events?after=0`)).events.at(-1)).toMatchObject({
      status: "ended",
      reason: "replaced",
    })
    expect(proxy.log.filter((entry) => entry.method === "DELETE")).toHaveLength(1)
    expect(yield* json("DELETE", `/voice/calls/${second.callID}`)).toEqual({ ok: true })
    expect((yield* json("GET", `/voice/calls/${second.callID}/events?after=0`)).events.at(-1)).toMatchObject({
      reason: "client_end",
    })
    expect((yield* call("POST", `/voice/calls/${second.callID}/heartbeat`, { sent: 0, received: 0 })).status).toBe(410)
    // A refused renewal (not transient) ends at once.
    const third = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    proxy.state.renewStatus = 403
    yield* TestClock.adjust(voiceLimits.renewMs)
    yield* settled
    expect((yield* json("GET", `/voice/calls/${third.callID}/events?after=0`)).events.at(-1)).toMatchObject({
      reason: "lease_refused",
    })
    // An answer without ICE-lite and UDP candidates is unusable on the watch.
    proxy.state.answer = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
    const rejected = yield* call("POST", "/voice/calls", { sdp: offerSDP })
    expect(rejected.status).toBe(502)
    expect(yield* Effect.promise(() => rejected.json())).toMatchObject({ error: { code: "unsupported_answer" } })
    expect(proxy.log.at(-1)).toMatchObject({ method: "DELETE" })
    expect((yield* call("POST", "/voice/calls", { sdp: "hello" })).status).toBe(400)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("events long-poll waits for the next event, at most 25 seconds", () =>
  Effect.gen(function* () {
    const { sidebands, json } = yield* setup()
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const waiting = yield* json("GET", `/voice/calls/${created.callID}/events?after=1`).pipe(
      Effect.forkChild({ startImmediately: true }),
    )
    yield* settled
    sidebands.opened[0]?.deliver({ type: "session.started" })
    yield* settled
    expect((yield* Fiber.join(waiting)).events).toMatchObject([{ seq: 2, type: "status", status: "live" }])
    const idle = yield* json("GET", `/voice/calls/${created.callID}/events?after=2`).pipe(
      Effect.forkChild({ startImmediately: true }),
    )
    yield* settled
    yield* TestClock.adjust(voiceLimits.pollMs)
    yield* settled
    expect(yield* Fiber.join(idle)).toEqual({ events: [], next: 2, ended: false })
  }).pipe(Effect.map(() => undefined)),
)

it.effect("new watch calls reload server instructions and fail before reserving when they cannot be read", () =>
  Effect.gen(function* () {
    const { proxy, server, json, call } = yield* setup()
    yield* json("POST", "/voice/calls", { sdp: offerSDP })
    expect(proxy.log.at(-1)?.body).toMatchObject({ session: { instructions: server.voice.instructions } })
    server.voice.instructions = "Prompt alterado sem reiniciar o servidor."
    yield* json("POST", "/voice/calls", { sdp: offerSDP })
    expect(proxy.log.at(-1)?.body).toMatchObject({ session: { instructions: server.voice.instructions } })
    server.ctx.instructions = () => Effect.fail(new Error("unreadable"))
    const reservations = proxy.log.filter((entry) => entry.method === "POST").length
    expect((yield* call("POST", "/voice/calls", { sdp: offerSDP })).status).toBe(503)
    expect(proxy.log.filter((entry) => entry.method === "POST")).toHaveLength(reservations)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("delegations keep tool activity off speech and send only updates and results to be spoken", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    const delegation = (id: string, text: string) =>
      socket?.deliver({
        type: "delegation.created",
        item: { id, type: "delegation", target: "client", content: [{ type: "input_text", text }] },
      })
    delegation("item_d1", "Quantas sessões estão rodando agora?")
    delegation("item_d1", "Quantas sessões estão rodando agora?")
    yield* settled
    expect(server.masters.ensured).toBe(1)
    expect(server.prompts).toEqual([
      { sessionID: "ses_master", text: "Quantas sessões estão rodando agora?", delivery: "steer" },
    ])
    const appends = () => contextAppends(socket, "speakable")
    // Admission is not spoken (GPT Live acknowledges the request itself); GPT Live only keeps it as quiet state.
    expect(appends()).toEqual([])
    expect(contextAppends(socket, "commentary")).toEqual([
      {
        type: "delegation.context.append",
        delegation_item_id: "item_d1",
        channel: "commentary",
        content: [{ type: "input_text", text: statusNote("começando o pedido") }],
      },
    ])
    // Routine tools update the screen, never the speech mailbox, even after its throttle expires.
    yield* PubSub.publish(server.bus, masterEvents.toolStarted("ses_master", "call_1", "sessions.list"))
    yield* PubSub.publish(server.bus, masterEvents.toolCalled("ses_master", "call_1", {}))
    yield* PubSub.publish(server.bus, masterEvents.toolStarted("ses_other", "call_x", "read"))
    yield* settled
    expect(appends()).toEqual([])
    yield* TestClock.adjust(delegationLimits.narrationMs)
    yield* settled
    expect(appends()).toEqual([])
    yield* PubSub.publish(server.bus, masterEvents.text("ses_master", "Uma sessão precisa da sua resposta."))
    yield* settled
    expect(appends()).toEqual([
      {
        type: "delegation.context.append",
        delegation_item_id: "item_d1",
        channel: "speakable",
        content: [{ type: "input_text", text: "Atualização: Uma sessão precisa da sua resposta." }],
      },
    ])
    // The result follows the prompt in the Mestra's transcript; it skips the wait and is chunked.
    const reply = "Há três sessões rodando: " + "á".repeat(400)
    server.messages.set("ses_master", [assistant("msg_reply", reply), assistant("msg_prompt1", "")])
    // Published while the drain still lists the Mestra as running: the result waits for it to settle.
    server.active.add("ses_master")
    yield* PubSub.publish(server.bus, masterEvents.succeeded("ses_master"))
    yield* settled
    expect(appends()).toHaveLength(1)
    server.active.delete("ses_master")
    yield* TestClock.adjust(delegationLimits.settleMs)
    yield* settled
    const final = appends().slice(1)
    expect(final.map((event) => event.content[0].text).join("")).toBe(reply)
    expect(final.every((event) => Buffer.byteLength(event.content[0].text) <= 500)).toBe(true)
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(
      page.events
        .filter((event: Watch.VoiceEvent) => event.type === "master")
        .map((event: Watch.VoiceEvent) => event.type === "master" && event.state),
    ).toEqual(["running", "running", "running", "idle"])
    expect(page.events.map((event: Watch.VoiceEvent) => event.type === "master" && event.text)).toContain(
      "A mestra está consultando suas sessões.",
    )
    // Queue requests keep their delivery.
    delegation("item_d2", JSON.stringify({ text: "Depois veja os pedidos", delivery: "queue" }))
    yield* settled
    expect(server.prompts.at(-1)).toEqual({
      sessionID: "ses_master",
      text: "Depois veja os pedidos",
      delivery: "queue",
    })
  }).pipe(Effect.map(() => undefined)),
)

const delegate = (socket: { deliver: (event: object) => void } | undefined, id: string, text: string) =>
  socket?.deliver({
    type: "delegation.created",
    item: { id, type: "delegation", target: "client", content: [{ type: "input_text", text }] },
  })

it.effect("the app builds the request from the transcripts; a delegation without text keeps what he said", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    // As the route sends it (02/11): the text is the transcript of the turn it names, whose `turn.done` comes after.
    const delegation = (id: string, text: string, turn: string) =>
      socket?.deliver({
        type: "delegation.created",
        item: {
          id,
          type: "delegation",
          target: "client",
          content: text ? [{ type: "input_text", text }] : [],
          handoff_id: "handoff_1",
          user_bidi_turn_id: turn,
        },
        offset_ms: 15_000,
      })
    const done = (id: string, role: "user" | "assistant", transcript: string) =>
      socket?.deliver({ type: "turn.done", turn: { id, role, transcript } })
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_1", text: " Quantas sessões estão abertas?" } })
    delegation("item_d1", "Quantas sessões estão abertas?", "turn_1")
    done("turn_1", "user", " Quantas sessões estão abertas?")
    done("turn_2", "assistant", " Vou verificar.")
    done("turn_3", "assistant", " Há duas: Abacato e Misty.")
    delegation("item_d2", "E a outra?", "turn_4")
    yield* settled
    expect(server.prompts.map((prompt) => prompt.text)).toEqual([
      "Quantas sessões estão abertas?",
      [
        "E a outra?",
        "",
        "Conversa por voz desde o pedido anterior (transcrição, pode ter erros):",
        "Voz: Vou verificar.",
        "Voz: Há duas: Abacato e Misty.",
      ].join("\n"),
    ])
    // Without text, what he is saying; his words, not a JSON field, queue it.
    done("turn_4", "user", " E a outra?")
    socket?.deliver({
      type: "input_transcript.added",
      item: { id: "item_2", text: " Coloca na fila os testes do Mac" },
    })
    delegation("item_d3", "", "turn_5")
    yield* settled
    expect(server.prompts.at(-1)).toEqual({
      sessionID: "ses_master",
      text: "Coloca na fila os testes do Mac",
      delivery: "queue",
    })
    // With nothing at all, GPT Live hears to have him repeat it, once, and nothing reaches the Mestra.
    done("turn_5", "user", " Coloca na fila os testes do Mac")
    delegation("item_d4", "", "turn_6")
    delegation("item_d4", "", "turn_6")
    yield* settled
    expect(server.prompts).toHaveLength(3)
    expect(
      contextAppends(socket, "speakable")
        .filter((event) => event.delegation_item_id === "item_d4")
        .map((event) => event.content[0].text),
    ).toEqual([unreadable])
  }).pipe(Effect.map(() => undefined)),
)

it.effect("a repeated delegation is admitted once and leaves the context to the next request", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    delegate(socket, "item_r1", "Quantas sessões estão abertas?")
    socket?.deliver({
      type: "turn.done",
      turn: { id: "turn_a", role: "assistant", transcript: " Há duas: Abacato e Misty." },
    })
    delegate(socket, "item_r1", "Quantas sessões estão abertas?")
    delegate(socket, "item_r2", "E a outra?")
    yield* settled
    expect(server.prompts.map((prompt) => prompt.text)).toEqual([
      "Quantas sessões estão abertas?",
      ["E a outra?", "", contextLabel, "Voz: Há duas: Abacato e Misty."].join("\n"),
    ])
  }).pipe(Effect.map(() => undefined)),
)

/** The `delegation.context.append` commands sent on one channel. */
const contextAppends = (socket: { sent: string[] } | undefined, channel: "speakable" | "commentary") =>
  (socket?.sent ?? [])
    .map((text) => JSON.parse(text))
    .filter((event) => event.type === "delegation.context.append" && event.channel === channel)

it.effect("the Mestra's activity reaches GPT Live as quiet state: latest only, spaced, never over speech", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    const notes = () => contextAppends(socket, "commentary").map((event) => event.content[0].text)
    const tool = (id: string, name: string) =>
      Effect.all([
        PubSub.publish(server.bus, masterEvents.toolStarted("ses_master", id, name)),
        PubSub.publish(server.bus, masterEvents.toolCalled("ses_master", id, {})),
      ]).pipe(Effect.andThen(settled))
    delegate(socket, "item_n1", "Quais arquivos mudaram?")
    yield* settled
    expect(notes()).toEqual([statusNote("começando o pedido")])
    // Within the interval only the latest state waits.
    yield* tool("call_1", "sessions.list")
    yield* tool("call_2", "read")
    yield* TestClock.adjust(delegationLimits.noteMs - 1_000)
    yield* settled
    expect(notes()).toHaveLength(1)
    // Alexandre speaks as the interval ends: the state waits for him.
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_u", text: " Espera" } })
    yield* settled
    yield* TestClock.adjust(1_000)
    yield* settled
    expect(notes()).toHaveLength(1)
    yield* TestClock.adjust(voiceLimits.speakingMs - 1_000)
    yield* settled
    expect(notes()).toEqual([statusNote("começando o pedido"), statusNote("consultando os arquivos")])
    // The same state is not sent again; a new one waits for the interval.
    yield* tool("call_3", "grep")
    yield* tool("call_4", "execute")
    yield* TestClock.adjust(delegationLimits.noteMs - 1_000)
    // A spoken line just before the interval ends holds the state a little longer.
    yield* PubSub.publish(server.bus, masterEvents.text("ses_master", "Achei três arquivos."))
    yield* settled
    expect(contextAppends(socket, "speakable")).toHaveLength(1)
    yield* TestClock.adjust(1_000)
    yield* settled
    expect(notes()).toHaveLength(2)
    yield* TestClock.adjust(delegationLimits.noteAfterSpeechMs - 1_000)
    yield* settled
    expect(notes().at(-1)).toBe(statusNote("consultando as ferramentas"))
    expect(notes()).toHaveLength(3)
    // The result ends the request: a state still waiting is dropped.
    yield* tool("call_5", "glob")
    server.messages.set("ses_master", [assistant("msg_reply", "Mudaram dois arquivos."), assistant("msg_prompt1", "")])
    yield* PubSub.publish(server.bus, masterEvents.succeeded("ses_master"))
    yield* settled
    yield* TestClock.adjust(delegationLimits.noteMs)
    yield* settled
    expect(notes()).toHaveLength(3)
    expect(contextAppends(socket, "speakable").at(-1)?.content[0].text).toBe("Mudaram dois arquivos.")
  }).pipe(Effect.map(() => undefined)),
)

it.effect("an upstream error is logged with its fields, nested or top level, sanitized and correlated", () => {
  const logs = logCollector()
  return Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    socket?.deliver({ type: "session.started" })
    yield* TestClock.adjust(2_000)
    socket?.deliver({
      type: "error",
      error: {
        type: "invalid_request_error",
        code: "invalid_value",
        param: "item.content[0].text",
        message: 'Invalid value: "Alexandre pediu para pesquisar o preço do voo amanhã".\nRetry\u0007 later.',
        event_id: "evt_42",
      },
    })
    yield* settled
    delegate(socket, "item_d1", "Quais sessões estão rodando?")
    yield* settled
    yield* PubSub.publish(server.bus, masterEvents.text("ses_master", "Duas sessões estão rodando."))
    yield* settled
    yield* TestClock.adjust(1_500)
    // The same fields at the top level; the event's own `type` is not the error type.
    socket?.deliver({ type: "error", code: "server_error", message: "The server had an error.", param: null })
    yield* settled
    expect(logs.named("Watch call upstream error")).toEqual([
      {
        call: created.callID,
        type: "invalid_request_error",
        code: "invalid_value",
        param: "item.content[0].text",
        // Control characters and a long quoted span (possibly speech) never reach the log.
        message: 'Invalid value: "…". Retry later.',
        eventID: "evt_42",
        elapsedMs: 2_000,
        lastSent: "none",
        recent: "session.started,error",
      },
      {
        call: created.callID,
        code: "server_error",
        message: "The server had an error.",
        elapsedMs: 3_500,
        lastSent: "delegation.context.append",
        lastSentAgoMs: 1_500,
        recent: "session.started,error,delegation.created,error",
      },
    ])
    // The watch only gets the generic notice, and the call goes on.
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(page.ended).toBe(false)
    expect(page.events.filter((event: Watch.VoiceEvent) => event.type === "error")).toHaveLength(2)
  }).pipe(
    logs.provide,
    Effect.map(() => undefined),
  )
})

it.effect("a sideband close is logged with its code, reason and side, and ends the call with its reason", () => {
  const logs = logCollector()
  return Effect.gen(function* () {
    const { sidebands, json } = yield* setup()
    const events = (callID: string) => json("GET", `/voice/calls/${callID}/events?after=0`)
    // The service closes abnormally: no session.close of ours, and the watch learns why.
    const first = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    sidebands.opened[0]?.deliver({ type: "session.started" })
    yield* TestClock.adjust(7_000)
    sidebands.opened[0]?.remoteClose({ code: 1011, reason: "Internal error\nkeepalive" })
    yield* settled
    expect((yield* events(first.callID)).events.at(-1)).toMatchObject({ status: "ended", reason: "sideband_closed" })
    expect(sidebands.opened[0]?.sent).not.toContain(JSON.stringify({ type: "session.close" }))
    // A transport failure before the close is flagged.
    const second = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    sidebands.opened[1]?.remoteClose({ code: 1006, transportError: true })
    yield* settled
    expect((yield* events(second.callID)).events.at(-1)).toMatchObject({ reason: "sideband_closed" })
    // Our own end closes normally.
    const third = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    yield* TestClock.adjust(1_000)
    yield* json("DELETE", `/voice/calls/${third.callID}`)
    expect(logs.named("Watch call sideband closed")).toEqual([
      {
        call: first.callID,
        by: "remote",
        code: 1011,
        reason: "Internal error keepalive",
        clean: false,
        elapsedMs: 7_000,
        lastSent: "none",
        recent: "session.started,sideband.closed",
      },
      {
        call: second.callID,
        by: "remote",
        code: 1006,
        reason: "",
        clean: false,
        transportError: true,
        elapsedMs: 0,
        lastSent: "none",
        recent: "sideband.closed",
      },
      {
        call: third.callID,
        by: "local",
        code: 1000,
        reason: "",
        clean: true,
        elapsedMs: 1_000,
        lastSent: "session.close",
        lastSentAgoMs: 0,
        recent: "",
      },
    ])
    expect(logs.named("Watch call ended")).toMatchObject([
      { call: first.callID, reason: "sideband_closed", elapsedMs: 7_000 },
      { call: second.callID, reason: "sideband_closed", elapsedMs: 0 },
      { call: third.callID, reason: "client_end", elapsedMs: 1_000 },
    ])
  }).pipe(
    logs.provide,
    Effect.map(() => undefined),
  )
})

it.effect("a cold Mestra never holds the sideband reader; admissions and memory keep their order, once each", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    const gate = yield* Deferred.make<void>()
    server.masters.gate = gate
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    yield* settled
    // Warmed at the start of the call, without ensuring (creating) a Mestra.
    expect(server.masters).toMatchObject({ warmed: 1, ensured: 0 })
    const socket = sidebands.opened[0]
    socket?.deliver({ type: "session.started" })
    delegate(socket, "item_a", "Quais sessões estão rodando?")
    // The delegating turn, as on the route (its transcript is the delegation's text): not context for the next one.
    socket?.deliver({
      type: "turn.done",
      turn: { id: "turn_1", role: "user", transcript: "Quais sessões estão rodando?" },
    })
    delegate(socket, "item_b", "E quais precisam de mim?")
    delegate(socket, "item_a", "Quais sessões estão rodando?")
    socket?.deliver({ type: "error", error: { type: "server_error", code: "internal" } })
    socket?.deliver({ type: "turn.done", turn: { id: "turn_2", role: "assistant", transcript: "Já pedi à mestra." } })
    yield* settled
    // The Mestra is still waking up, but the reader went on: the error and both turns are through.
    expect(server.prompts).toEqual([])
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(page.events.map((event: Watch.VoiceEvent) => event.type)).toEqual([
      "status",
      "status",
      "caption",
      "error",
      "caption",
    ])
    expect(server.memory.appended.map((turn) => turn.id)).toEqual([
      `${created.callID}:turn_1`,
      `${created.callID}:turn_2`,
    ])
    yield* Deferred.succeed(gate, undefined)
    yield* settled
    expect(server.prompts.map((prompt) => prompt.text)).toEqual([
      "Quais sessões estão rodando?",
      "E quais precisam de mim?",
    ])
    expect(server.masters.ensured).toBe(1)
    // A call that ends while the Mestra wakes still hands over its request, then ends its memory.
    const next = yield* Deferred.make<void>()
    server.masters.gate = next
    const second = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    delegate(sidebands.opened[1], "item_c", "Pesquisa o preço do voo.")
    sidebands.opened[1]?.remoteClose()
    yield* settled
    expect((yield* json("GET", `/voice/calls/${second.callID}/events?after=0`)).events.at(-1)).toMatchObject({
      reason: "sideband_closed",
    })
    const endedBefore = server.memory.ended
    yield* Deferred.succeed(next, undefined)
    yield* settled
    expect(server.prompts.at(-1)?.text).toBe("Pesquisa o preço do voo.")
    expect(server.memory.ended).toBe(endedBefore + 1)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("a moderation the session ends with clears voice memory once and keeps the cleared conversation out", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    const sessionsBefore = [...server.sessions.keys()]
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const events = () => json("GET", `/voice/calls/${created.callID}/events?after=0`)
    const socket = sidebands.opened[0]
    socket?.deliver({ type: "session.started" })
    socket?.deliver({ type: "turn.done", turn: { id: "turn_1", role: "user", transcript: "Antes do erro." } })
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_cut", text: " Fala cortada" } })
    socket?.deliver({ type: "error", error: { type: "content_filter", code: "content_filter", message: "Stopped." } })
    yield* settled
    // Only pending until the session ends: the call goes on.
    expect((yield* events()).ended).toBe(false)
    yield* TestClock.adjust(voiceLimits.moderationMs - 1)
    socket?.deliver({ type: "session.closed" })
    // After the end: a turn and a request of the cleared conversation.
    socket?.deliver({ type: "turn.done", turn: { id: "turn_2", role: "assistant", transcript: "Fala moderada." } })
    delegate(socket, "item_late", "Pedido depois do fim.")
    socket?.remoteClose({ code: 1000, clean: true })
    yield* settled
    expect((yield* events()).events.at(-1)).toMatchObject({ type: "status", status: "ended", reason: "context_reset" })
    expect(server.memory.resets).toBe(1)
    // Neither the later turn nor what was being said when it was moderated.
    expect(server.memory.appended.map((turn) => turn.id)).toEqual([`${created.callID}:turn_1`])
    expect(server.prompts).toEqual([])
    expect(server.masters.ensured).toBe(0)
    expect([...server.sessions.keys()]).toEqual(sessionsBefore)
    // The service ended the session: nothing was asked of it.
    expect(sidebands.opened[0]?.sent).not.toContain(JSON.stringify({ type: "session.close" }))
  }).pipe(Effect.map(() => undefined)),
)

it.effect(
  "a moderation that only cuts the speech keeps the call and its memory; a later close is an ordinary end",
  () => {
    const logs = logCollector()
    return Effect.gen(function* () {
      const { sidebands, server, json } = yield* setup()
      const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
      const events = () => json("GET", `/voice/calls/${created.callID}/events?after=0`)
      const socket = sidebands.opened[0]
      socket?.deliver({ type: "session.started" })
      socket?.deliver({ type: "error", error: { type: "content_filter", code: "content_filter" } })
      yield* settled
      yield* TestClock.adjust(voiceLimits.moderationMs)
      yield* settled
      expect(logs.named("Watch call moderation was not fatal")).toMatchObject([
        { call: created.callID, code: "content_filter/content_filter", recent: "session.started,error" },
      ])
      // The call goes on: it still delegates and remembers.
      delegate(socket, "item_after", "Quantas sessões estão rodando?")
      socket?.deliver({ type: "turn.done", turn: { id: "turn_1", role: "user", transcript: "Quantas sessões?" } })
      yield* settled
      expect((yield* events()).ended).toBe(false)
      expect(server.prompts.map((prompt) => prompt.text)).toEqual(["Quantas sessões estão rodando?"])
      // The session ends after the window: an ordinary end, with the service's reason in the log.
      socket?.deliver({ type: "session.closed", reason: "expired", usage: { audio_duration_ms: 86_800 } })
      socket?.remoteClose({ code: 1000, clean: true })
      yield* settled
      expect((yield* events()).events.at(-1)).toMatchObject({ status: "ended", reason: "session_closed" })
      expect(server.memory.resets).toBe(0)
      expect(server.memory.appended.map((turn) => turn.id)).toEqual([`${created.callID}:turn_1`])
      expect(logs.named("Watch call ended")).toMatchObject([
        { call: created.callID, reason: "session_closed", closedReason: "expired", audioDurationMs: 86_800 },
      ])
      expect(sidebands.opened[0]?.sent).not.toContain(JSON.stringify({ type: "session.close" }))
    }).pipe(
      logs.provide,
      Effect.map(() => undefined),
    )
  },
)

it.effect("a close that names moderation clears memory; a call that started empty does not clear again", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    const events = (callID: string) => json("GET", `/voice/calls/${callID}/events?after=0`)
    const first = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    // Not moderation: by type/code only, never by the message text.
    for (const error of [
      { type: "server_error", code: "internal" },
      { type: "invalid_request_error", code: "invalid_value", message: "content_filter" },
    ])
      sidebands.opened[0]?.deliver({ type: "error", error })
    yield* settled
    expect((yield* events(first.callID)).ended).toBe(false)
    expect(server.memory.resets).toBe(0)
    // A close whose reason names moderation, without an error before it.
    sidebands.opened[0]?.deliver({ type: "session.closed", reason: "content" })
    sidebands.opened[0]?.remoteClose({ code: 1000, clean: true })
    yield* settled
    expect((yield* events(first.callID)).events.at(-1)).toMatchObject({ status: "ended", reason: "context_reset" })
    expect(server.memory.resets).toBe(1)
    server.memory.context = { ...server.memory.context, summary: "", turns: [] }
    const empty = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    // The sideband closing right after the error ends the session as `session.closed` does.
    sidebands.opened[1]?.deliver({ type: "error", code: "content_filter", message: "Stopped." })
    sidebands.opened[1]?.remoteClose()
    yield* settled
    expect((yield* events(empty.callID)).events.at(-1)).toMatchObject({ status: "ended", reason: "moderation" })
    expect(server.memory.resets).toBe(1)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("ending keeps what was said since each role's last turn in memory, once and as interrupted", () =>
  Effect.gen(function* () {
    const { sidebands, server, json } = yield* setup()
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    socket?.deliver({ type: "session.started" })
    socket?.deliver({ type: "output_transcript.added", item: { id: "item_1", text: "Resposta" } })
    socket?.deliver({ type: "turn.done", turn: { id: "turn_a", role: "assistant", transcript: "Resposta completa." } })
    socket?.deliver({ type: "output_transcript.added", item: { id: "item_2", text: "Estou" } })
    socket?.deliver({ type: "output_transcript.added", item: { id: "item_2", text: " conferindo" } })
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_3", text: " Espera," } })
    socket?.deliver({ type: "input_transcript.added", item: { id: "item_3", text: " outra coisa" } })
    yield* settled
    yield* json("DELETE", `/voice/calls/${created.callID}`)
    expect(sidebands.opened[0]?.sent).toContain(JSON.stringify({ type: "session.close" }))
    expect(server.memory.appended).toEqual([
      { id: `${created.callID}:turn_a`, role: "assistant", text: "Resposta completa.", at: T },
      {
        id: `${created.callID}:partial-assistant`,
        role: "assistant",
        text: "Estou conferindo",
        at: T,
        interrupted: true,
      },
      { id: `${created.callID}:partial-user`, role: "user", text: "Espera, outra coisa", at: T, interrupted: true },
    ])
    expect(server.memory.ended).toBe(1)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("a Mestra reply that arrives after the call ends reaches voice memory once and is not asked again", () =>
  Effect.gen(function* () {
    const { sidebands, server, proxy, json } = yield* setup()
    const voice = makeVoice(
      {
        storage: server.shared,
        generate: { text: () => Effect.fail(new Error("no compaction here")) },
        session: server.ctx.session,
        message: server.ctx.message,
      },
      yield* Effect.scope,
    )
    // Real voice memory, and the window `custom.master/ensure` opens for a voice request.
    server.ctx.memory = {
      context: () => voice.context("global"),
      append: (turns) => voice.append({ version: Voice.version, scope: "global", turns }),
      end: () => voice.settle(),
      reset: () => voice.reset("global"),
    }
    server.ctx.ensureMaster = () =>
      VoiceWindow.open(server.shared, server.masters.id).pipe(Effect.as(server.masters.id))
    const first = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    const socket = sidebands.opened[0]
    delegate(socket, "item_web", "Pesquisa na web o preço do voo.")
    socket?.deliver({ type: "turn.done", turn: { id: "turn_1", role: "user", transcript: "Pesquisa o voo." } })
    socket?.deliver({ type: "turn.done", turn: { id: "turn_2", role: "assistant", transcript: "Pedi à mestra." } })
    yield* settled
    server.active.add("ses_master")
    yield* TestClock.adjust(10_000)
    // The service drops the call while the Mestra still works on the request.
    socket?.remoteClose()
    yield* settled
    expect((yield* json("GET", `/voice/calls/${first.callID}/events?after=0`)).ended).toBe(true)
    expect(server.shared.values.get(VoiceWindow.key)).toBeNull()
    yield* TestClock.adjust(10_000)
    server.messages.set("ses_master", [
      assistant("msg_reply", "O voo mais barato custa R$ 820.", T + 20_000),
      user("msg_prompt1", "Pesquisa na web o preço do voo.", T),
    ])
    server.active.delete("ses_master")
    yield* TestClock.adjust(memoryLimits.latePollMs)
    yield* settled
    const late = {
      id: "agent:msg_reply",
      role: "user",
      text: lateLabel + "Pedido: Pesquisa na web o preço do voo.\nResposta: O voo mais barato custa R$ 820.",
    }
    const stored = () => Schema.decodeUnknownSync(Voice.Record)(server.shared.values.get(memoryKey("global")))
    expect(stored().turns.at(-1)).toMatchObject(late)
    // The next call starts knowing the answer, and ending it adds nothing.
    const second = yield* json("POST", "/voice/calls", { sdp: offerSDP })
    expect(JSON.stringify(proxy.log.at(-1)?.body)).toContain("O voo mais barato custa R$ 820.")
    yield* json("DELETE", `/voice/calls/${second.callID}`)
    yield* TestClock.adjust(memoryLimits.latePollMs)
    yield* settled
    expect(yield* voice.recordLate({ sessionID: "ses_master", since: T }, T + 10_000)).toBe(0)
    expect(stored().turns.filter((turn) => turn.id === late.id)).toHaveLength(1)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("delegation narration knows the session tools by their current and former names", () =>
  Effect.sync(() => {
    for (const name of ["sessions.read", "sessions_read", "opencode.session_read", "session_read", "sessions.status"])
      expect(toolActivity(name)).toBe("conferindo uma sessão")
    for (const name of ["sessions.list", "mestra.sessions_list", "opencode.sessions_list"])
      expect(toolActivity(name)).toBe("consultando suas sessões")
    for (const [current, former, text] of [
      ["sessions.send", "mestra.session_send", "encaminhando seu pedido"],
      ["sessions.create", "mestra.session_create", "criando a sessão solicitada"],
      ["sessions.wait", "mestra.session_wait", "acompanhando o trabalho da sessão"],
      ["sessions.requests", "mestra.requests_list", "verificando os pedidos pendentes"],
      ["sessions.answer", "mestra.request_answer", "respondendo ao pedido autorizado"],
    ]) {
      expect(toolActivity(current)).toBe(text)
      expect(toolActivity(former)).toBe(text)
    }
    // Short session tool names never shadow the native tools that share them.
    expect(toolActivity("read")).toBe("consultando os arquivos")
    expect(toolActivity("search")).toBe("usando uma ferramenta")
    expect(toolActivity("sessions.unknown")).toBe("usando uma ferramenta")
    expect(toolActivity("execute")).toBe("consultando as ferramentas")
    // GPT Live's quiet state is a standing fact, never news.
    expect(statusNote("consultando os arquivos")).toBe(
      "Estado do agente (para consulta; não é novidade para anunciar): consultando os arquivos. Pedido em andamento, ainda sem resultado.",
    )
  }),
)

/** The iPhone's `VoiceResultTests` use the same cases: one rule on both platforms. */
it.effect("a result is spoken without display Markdown and cut at a sentence end with a pointer to the rest", () =>
  Effect.sync(() => {
    expect(
      spoken(
        [
          "## Resumo",
          "",
          "- **Sessão A**: rodando, veja [o PR](https://github.com/x/y/pull/1).",
          "- [x] `bun test` passou",
          "1. __Primeiro__ passo",
          "",
          "> Nota: cuidado",
          "",
          "| Sessão | Estado |",
          "|:---|---:|",
          "| A | rodando |",
          "",
          "```ts",
          "const x = 1",
          "```",
          "~~~",
          "echo oi",
          "~~~",
          "",
          "---",
          "Fim. ![diagrama](d.png)",
        ].join("\r\n"),
      ),
    ).toBe(
      [
        "Resumo",
        "",
        "Sessão A: rodando, veja o PR.",
        "bun test passou",
        "Primeiro passo",
        "",
        "Nota: cuidado",
        "",
        "Sessão, Estado",
        "A, rodando",
        "",
        "(há código na resposta; veja na conversa)",
        "",
        "Fim. diagrama",
      ].join("\n"),
    )
    // An unclosed block runs to the end; a fence with an info string does not close it.
    expect(spoken("Rode:\n```sh\nbun test\n```js\nainda código")).toBe(
      "Rode:\n(há código na resposta; veja na conversa)",
    )
    // Short text goes as is.
    expect(spoken("Duas sessões estão rodando.")).toBe("Duas sessões estão rodando.")
    // Long text: cut at the last sentence or line end within the limit, in its second half.
    const sentence = "A sessão do Abacato terminou os testes e abriu o PR. "
    const long = sentence.repeat(40)
    const cut = spoken(long)
    expect(cut.endsWith("\n\nO restante da resposta está na conversa.")).toBe(true)
    const body = cut.slice(0, -"\n\nO restante da resposta está na conversa.".length)
    expect(body.length).toBeLessThanOrEqual(delegationLimits.spokenChars)
    expect(body.length).toBeGreaterThan(delegationLimits.spokenChars - sentence.length)
    expect(long.startsWith(body) && body.endsWith("PR.")).toBe(true)
    // Without a sentence end, at the last space; without spaces, a hard cut.
    expect(spoken("palavra ".repeat(300)).split("\n\n")[0]).toBe("palavra ".repeat(187).trim())
    expect(spoken("a".repeat(2_000)).split("\n\n")[0]).toBe("a".repeat(delegationLimits.spokenChars))
  }),
)

it.effect("helpers: delegation parsing, append chunks, close reasons, voice rejection and diagnostics redaction", () =>
  Effect.sync(() => {
    expect(parse("Olá")).toEqual({ text: "Olá", delivery: "steer" })
    expect(parse('{"text":"x","delivery":"queue"}')).toEqual({ text: "x", delivery: "queue" })
    expect(parse('{"text":"  "}')).toEqual({ text: '{"text":"  "}', delivery: "steer" })
    // The iPhone's `VoiceRequestContext`: the newest six turns, within 1,200 characters, the delegating turn left out.
    const heard: Heard = { turns: [] }
    expect(masterRequest(heard, " Pedido ")).toBe("Pedido")
    for (const index of [1, 2, 3, 4, 5, 6, 7, 8, 9])
      hear(heard, { id: `t${index}`, role: index % 2 === 0 ? "assistant" : "user", text: ` Fala ${index}` })
    hear(heard, { id: "t9", role: "user", text: "Repetida" })
    hear(heard, { role: "assistant", text: "  " })
    hear(heard, { role: "user", text: "pedido!" })
    expect(heard.turns).toHaveLength(6)
    expect(masterRequest(heard, "Pedido", "t10")).toBe(
      [
        "Pedido",
        "",
        contextLabel,
        "Voz: Fala 4",
        "Alexandre: Fala 5",
        "Voz: Fala 6",
        "Alexandre: Fala 7",
        "Voz: Fala 8",
        "Alexandre: Fala 9",
      ].join("\n"),
    )
    hear(heard, { id: "t10", role: "user", text: "Pedido e mais" })
    expect(heard.turns).toEqual([])
    const long = "a".repeat(700)
    hear(heard, { id: "o", role: "assistant", text: "início " + long })
    hear(heard, { id: "p", role: "user", text: long })
    hear(heard, { id: "q", role: "assistant", text: "curta" })
    expect(masterRequest(heard, "Outro").endsWith(`\nAlexandre: ${long}\nVoz: curta`)).toBe(true)
    hear(heard, { id: "r", role: "assistant", text: "início " + "b".repeat(2_000) })
    const clipped = masterRequest(heard, "Outro").split("\n").at(-1) ?? ""
    expect(clipped.startsWith("Voz: …b") && clipped.length === delegationLimits.contextChars).toBe(true)
    // The iPhone's `VoiceQueueIntent`.
    for (const text of [
      "Enfileira isso: roda os testes do Mac",
      "pode enfileirar depois",
      "Enfileire o pedido",
      "Coloca na fila",
      "coloca isso na fila",
      "põe essa tarefa na fila",
      "POE NA FILA",
      "sem interromper, vê o PR",
      "Faz isso sem  interromper o que ele está fazendo",
    ])
      expect(queues(text)).toBe(true)
    for (const text of [
      "Roda os testes",
      "quantas sessões tem na fila?",
      "a fila do banco tá enorme",
      "interrompe a sessão",
      "não interrompe",
      "coloca o arquivo na pasta",
      "o pedido foi enfileirado?",
      "fila",
    ])
      expect(queues(text)).toBe(false)
    expect(chunks("é".repeat(300)).map((part) => Buffer.byteLength(part))).toEqual([500, 100])
    // The iPhone's rule for a `session.closed` reason that names moderation.
    for (const reason of ["content", "content_filter", "moderation", "Moderated"])
      expect(closedByModeration(reason)).toBe(true)
    for (const reason of [
      undefined,
      "client_request",
      "close_requested",
      "expired",
      "remote_hangup",
      "connection_lost",
    ])
      expect(closedByModeration(reason)).toBe(false)
    expect(rejectsVoice(400, JSON.stringify({ error: { code: "invalid_voice" } }))).toBe(true)
    expect(rejectsVoice(500, JSON.stringify({ error: { code: "invalid_voice" } }))).toBe(false)
    expect(
      rejectsVoice(
        422,
        JSON.stringify({ detail: [{ loc: ["body", "session", "audio", "output", "voice"], type: "enum" }] }),
      ),
    ).toBe(true)
    // Error fields: a string `error` is the message; objects and empty values are left out; everything is bounded.
    expect(upstreamError({ error: "Something failed" })).toEqual({ message: "Something failed" })
    expect(upstreamError({ error: { type: "", code: 4001, param: { a: 1 } }, message: "Top" })).toEqual({
      code: "4001",
      message: "Top",
    })
    expect(sanitize("x".repeat(300), 240)).toBe("x".repeat(239) + "…")
    expect(sanitize("Fala: “uma frase longa que alguém disse durante a chamada” e 'outra'", 240)).toBe(
      "Fala: \"…\" e 'outra'",
    )
    expect(redact({ deviceToken: "abc", nested: { sdp: "v=0", ok: "x".repeat(600) }, list: [1, 2] })).toEqual({
      deviceToken: "[redacted]",
      nested: { sdp: "[redacted]", ok: "x".repeat(500) + "…" },
      list: [1, 2],
    })
  }),
)

const agents = (active: number, attention: number, failed: number): LiveActivity.AgentsState => ({
  v: 1,
  updatedAt: T,
  host: "MacBook Pro",
  counts: { working: active - attention, question: attention, permission: 0, failed, idle: 0 },
  activeTotal: active,
  attention: [],
  attentionTotal: attention,
  sessions: [],
})

/** A widget push planner for one paired watch with a widget token, recording what it hands to APNs. */
const widgetSetup = Effect.fn("test.widgetSetup")(function* () {
  const devices = makeDevices(storage())
  const paired = yield* devices.pair("Apple Watch")
  yield* devices.widget(paired.deviceID, { token: "ab12", environment: "production" })
  const sent: Push[] = []
  const answer: { value: Result } = { value: { status: "sent" } }
  const stats = makeStats()
  const widget = makeWidgetPush({
    devices,
    bundleID: "br.com.alexandrem.opencode.watchkitapp",
    stats,
    send: (push) =>
      Effect.sync(() => {
        sent.push(push)
        return answer.value
      }),
  })
  const run = (state: LiveActivity.AgentsState | null, now: number) =>
    widget.evaluate(state, now).pipe(
      Effect.tap((plan) => plan.deliver),
      Effect.map((plan) => plan.wakeAt),
    )
  return { devices, paired, sent, answer, stats, widget, run }
})

/** `agents` with some counts replaced: permissions, unread answers, a Progresso or other work. */
const counted = (counts: Partial<LiveActivity.AgentsState["counts"]>, base = agents(2, 0, 0)) => ({
  ...base,
  counts: { ...base.counts, ...counts },
})

it.effect("WidgetKit pushes: only a kind of attention appearing or clearing, at once, at most one a minute", () =>
  Effect.gen(function* () {
    const { sent, run, stats, paired } = yield* widgetSetup()
    const minute = widgetLimits.spacingMs
    // The first state after start is only recorded.
    yield* run(agents(1, 0, 0), T)
    expect(sent).toEqual([])
    // Work, unread answers, a Progresso and the active total reaching or leaving zero are not drawn: no push, no wait.
    const quiet = [
      agents(3, 0, 0),
      counted({ working: 0, unread: 2 }),
      {
        ...agents(2, 0, 0),
        focus: {
          sessionID: "s1",
          title: "Live Activity",
          project: "ios",
          directory: "/r/ios",
          startedAt: T,
          progress: { done: 3, total: 7, unit: "todos" as const, current: "Atualizar o relógio" },
        },
      },
      agents(0, 0, 0),
      agents(4, 0, 0),
    ]
    for (const [index, state] of quiet.entries()) expect(yield* run(state, T + 1000 * (index + 1))).toBeUndefined()
    expect(sent).toEqual([])
    // A question appears: at once, priority 10.
    const at = T + 10_000
    expect(yield* run(agents(3, 1, 0), at)).toBe(at + widgetLimits.retryMs)
    expect(sent).toEqual([
      {
        token: "ab12",
        environment: "production",
        priority: 10,
        expiration: Math.floor(at / 1000) + widgetLimits.expirationSeconds,
        body: { aps: { "content-changed": true } },
        type: "widgets",
        bundleID: "br.com.alexandrem.opencode.watchkitapp",
      },
    ])
    // More questions of the same kind, and work around them, draw the same.
    yield* run(agents(5, 3, 0), at + 2000)
    yield* run(counted({ unread: 1 }, agents(5, 3, 0)), at + 3000)
    expect(sent).toHaveLength(1)
    // A failure joins inside the minute: it waits for the minute's end and goes with the kinds then.
    expect(yield* run(agents(5, 3, 1), at + 4000)).toBe(at + minute)
    expect(sent).toHaveLength(1)
    yield* run(agents(5, 3, 1), at + minute)
    expect(sent).toHaveLength(2)
    // The question is answered and the permission arrives: both change the kinds.
    yield* run(counted({ question: 0, permission: 1 }, agents(5, 0, 1)), at + 2 * minute)
    // Back to nothing waiting: the alert leaves the wrist at once too.
    yield* run(agents(2, 0, 0), at + 3 * minute)
    expect(sent).toHaveLength(4)
    // A question answered and another asked inside the same minute end where the watch already is: nothing.
    expect(yield* run(agents(2, 1, 0), at + 3 * minute + 1000)).toBe(at + 4 * minute)
    yield* run(agents(2, 0, 0), at + 3 * minute + 2000)
    expect(yield* run(agents(2, 0, 0), at + 4 * minute)).toBeUndefined()
    expect(sent).toHaveLength(4)
    expect(sent.map((push) => push.priority)).toEqual([10, 10, 10, 10])
    expect(stats.snapshot(at + 5 * minute).devices).toEqual([
      expect.objectContaining({
        deviceID: paired.deviceID,
        day: expect.objectContaining({ pushes: { urgent: 4, coalesced: 0, failed: 0 }, capped: 0 }),
      }),
    ])
  }),
)

it.effect("WidgetKit pushes: the key holds only the kinds, and a state the watch already read is not pushed", () =>
  Effect.gen(function* () {
    const { sent, run, widget, paired } = yield* widgetSetup()
    const minute = widgetLimits.spacingMs
    expect(key(null)).toEqual({ question: false, permission: false, failed: false })
    expect(key(counted({ question: 2, permission: 1, failed: 3, working: 9, unread: 4 }))).toEqual({
      question: true,
      permission: true,
      failed: true,
    })
    expect(key(counted({ working: 0, idle: 3, unread: 3 }))).toEqual(key(null))
    yield* run(agents(2, 0, 0), T)
    // The watch reloaded on its own and read the new question before the server looked: no push for it.
    widget.seen(paired.deviceID, agents(2, 1, 0))
    expect(yield* run(agents(2, 1, 0), T + 1000)).toBeUndefined()
    expect(sent).toEqual([])
    // Resolved on another device: the clearing goes at once.
    yield* run(agents(2, 0, 0), T + 2000)
    expect(sent).toHaveLength(1)
    // What the watch read is also the base of the next check, even inside the minute.
    widget.seen(paired.deviceID, agents(2, 0, 1))
    expect(yield* run(agents(2, 0, 1), T + 3000)).toBeUndefined()
    expect(yield* run(agents(2, 0, 0), T + 4000)).toBe(T + 2000 + minute)
    yield* run(agents(2, 0, 0), T + 2000 + minute)
    expect(sent).toHaveLength(2)
  }),
)

it.effect("WidgetKit pushes: 50 a day, resumed when the day's first push leaves", () =>
  Effect.gen(function* () {
    const { sent, run, stats } = yield* widgetSetup()
    const minute = widgetLimits.spacingMs
    yield* run(agents(1, 0, 0), T)
    // A question appearing and clearing every minute, 50 times.
    const first = T + minute
    for (let index = 0; index < widgetLimits.dailyCap; index++)
      yield* run(agents(1, (index + 1) % 2, 0), first + index * minute)
    expect(sent).toHaveLength(widgetLimits.dailyCap)
    // The 51st change waits for the day's first push to leave the window.
    const after = first + widgetLimits.dailyCap * minute
    expect(yield* run(agents(1, 1, 0), after)).toBe(first + widgetLimits.dayMs)
    yield* run(agents(1, 1, 1), after + minute)
    expect(sent).toHaveLength(widgetLimits.dailyCap)
    // Once the first push is a day old, the kinds current then go.
    yield* run(agents(1, 1, 1), first + widgetLimits.dayMs)
    expect(sent).toHaveLength(widgetLimits.dailyCap + 1)
    expect(stats.snapshot(after + 2 * minute).devices[0]?.day.capped).toBe(1)
  }),
)

it.effect("WidgetKit pushes: a failed push does not count and is retried; an invalid token is dropped", () =>
  Effect.gen(function* () {
    const { sent, run, answer, devices, stats } = yield* widgetSetup()
    yield* run(agents(1, 0, 0), T)
    answer.value = { status: "failed", reason: "HTTP 500" }
    // Retried after `retryMs` even when nothing else changes.
    expect(yield* run(agents(1, 1, 0), T + 1000)).toBe(T + 1000 + widgetLimits.retryMs)
    expect(sent).toHaveLength(1)
    answer.value = { status: "sent" }
    yield* run(agents(1, 1, 0), T + 1000 + widgetLimits.retryMs)
    expect(sent).toHaveLength(2)
    expect(stats.snapshot(T + 1000 + widgetLimits.retryMs).devices[0]?.day.pushes).toEqual({
      urgent: 1,
      coalesced: 0,
      failed: 1,
    })
    answer.value = { status: "invalid", reason: "BadDeviceToken" }
    yield* run(null, T + 10 * widgetLimits.retryMs)
    expect((yield* devices.list())[0]?.widget).toBeUndefined()
  }),
)

it.effect("/state counts each reader and tells the widget pushes what the watch has", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const sent: Push[] = []
    const server = world()
    const fixture = gateway({
      server,
      options: {
        apns: Effect.succeed({
          send: (push: Push) =>
            Effect.sync((): Result => {
              sent.push(push)
              return { status: "sent" }
            }),
          close: Effect.void,
        }),
      },
    })
    fixture.state.value = agents(1, 0, 0)
    yield* fixture.gateway.join({ ctx: server.ctx })
    const paired = yield* fixture.gateway.handlers.pair({ deviceName: "Apple Watch" })
    const read = (client?: string) =>
      fixture.gateway.handle(
        new Request("http://127.0.0.1/watch/v1/state", {
          headers: {
            authorization: `Bearer ${paired.deviceToken}`,
            ...(client ? { "x-watch-client": client } : {}),
          },
        }),
      )
    const register = fixture.gateway.handle(
      request("POST", "/widget-token", paired.deviceToken, { token: "abcd01", environment: "sandbox" }),
    )
    yield* register
    yield* settled
    // A new question the widget already read when it reloaded on its own: no push for it.
    fixture.state.value = agents(2, 1, 0)
    expect((yield* read("widget")).status).toBe(200)
    yield* register
    yield* settled
    expect(sent).toEqual([])
    expect(fixture.gateway.runtime.current?.widget?.memo.get(paired.deviceID)?.known).toEqual(key(agents(2, 1, 0)))
    for (const client of ["app", "app", "background", undefined, "other"]) yield* read(client)
    const stats = yield* fixture.gateway.handlers.stats()
    expect(Schema.decodeUnknownSync(Watch.Stats)(stats)).toEqual(stats)
    expect(stats.devices).toEqual([
      {
        deviceID: paired.deviceID,
        day: {
          state: { app: 2, background: 1, widget: 1, unknown: 2 },
          pushes: { urgent: 0, coalesced: 0, failed: 0 },
          capped: 0,
        },
        hours: [
          {
            hour: Math.floor(T / 3_600_000) * 3_600_000,
            state: { app: 2, background: 1, widget: 1, unknown: 2 },
            pushes: { urgent: 0, coalesced: 0, failed: 0 },
            capped: 0,
          },
        ],
      },
    ])
  }),
)

it.effect("POST /widget-token stores the device's widget token", () =>
  Effect.gen(function* () {
    const { server, json, call } = yield* setup()
    expect(yield* json("POST", "/widget-token", { token: "abcd01", environment: "sandbox" })).toEqual({ ok: true })
    expect(JSON.stringify(server.shared.values.get(devicesKey))).toContain(
      '"widget":{"token":"abcd01","environment":"sandbox"}',
    )
    expect((yield* call("POST", "/widget-token", { token: "XYZ", environment: "sandbox" })).status).toBe(400)
  }).pipe(Effect.map(() => undefined)),
)

it.effect("a busy port is retried every 30 seconds without failing the plugin", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const blocker = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response("relay") })
    const port = blocker.port ?? 0
    const server = world()
    const fixture = gateway({ server, options: { port: Effect.succeed(port) } })
    yield* fixture.gateway.join({ ctx: server.ctx })
    yield* settled
    expect(fixture.gateway.runtime.current?.server).toBeUndefined()
    yield* Effect.promise(() => blocker.stop(true))
    yield* TestClock.adjust(gatewayLimits.retryMs)
    yield* settled
    expect(fixture.gateway.runtime.current?.server?.port).toBe(port)
    const response = yield* Effect.promise(() => fetch(`http://127.0.0.1:${port}/watch/v1/state`))
    expect(response.status).toBe(401)
  }),
)
