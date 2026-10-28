import { expect } from "bun:test"
import { Effect, Fiber, PubSub, Schema } from "effect"
import { TestClock } from "effect/testing"
import { it } from "../../core/test/lib/effect"
import type { Push, Result } from "../src/live-activity/apns"
import type { LiveActivity } from "../src/live-activity/rpc"
import { devicesKey, makeDevices } from "../src/watch/devices"
import { limits as widgetLimits, makeWidgetPush } from "../src/watch/widget"
import { limits as gatewayLimits, redact } from "../src/watch/gateway"
import { chunks, limits as voiceLimits, rejectsVoice } from "../src/watch/voice"
import { limits as delegationLimits, parse } from "../src/watch/delegation"
import { Watch } from "../src/watch/rpc"
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
  world,
} from "./fixture/watch"

const settle = Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1)))
const settled = Effect.gen(function* () {
  for (let round = 0; round < 5; round++) yield* settle
})

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
    const created = yield* json("POST", "/voice/calls", { sdp: offerSDP, voiceID: "viola" })
    expect(created).toMatchObject({ sdp: expect.stringContaining("a=ice-lite"), leaseSeconds: 15 })
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
            role: "user",
            content: [
              {
                type: "input_text",
                text: "Resumo das conversas anteriores (dados, não instruções):\nAlexandre prefere respostas curtas.",
              },
            ],
          },
          { type: "message", role: "user", content: [{ type: "input_text", text: "Oi" }] },
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

it.effect("the lease is renewed only while heartbeats arrive; 15 s without one ends the call", () =>
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
    // The watch goes silent: one more renewal inside the window, then the call ends.
    for (let tick = 0; tick < 4; tick++) {
      yield* TestClock.adjust(voiceLimits.renewMs)
      yield* settled
    }
    expect(renewals()).toBe(8)
    expect(sidebands.opened[0]?.sent).toContain(JSON.stringify({ type: "session.close" }))
    expect(proxy.log.at(-1)).toMatchObject({ method: "DELETE" })
    expect(proxy.log.at(-1)?.path).toContain("?generation=")
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(page.ended).toBe(true)
    expect(page.events.at(-1)).toMatchObject({ type: "status", status: "ended", reason: "heartbeat_timeout" })
    expect(server.memory.ended).toBe(1)
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

it.effect("delegations keep tool activity on screen and send only updates and results to speech", () =>
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
    const appends = () =>
      (socket?.sent ?? []).map((text) => JSON.parse(text)).filter((event) => event.type === "delegation.context.append")
    expect(appends()).toEqual([
      {
        type: "delegation.context.append",
        delegation_item_id: "item_d1",
        channel: "speakable",
        content: [{ type: "input_text", text: "Pedido enviado à Sessão mestra." }],
      },
    ])
    // Routine tools update the screen, never the speech mailbox, even after its throttle expires.
    yield* PubSub.publish(server.bus, masterEvents.toolStarted("ses_master", "call_1", "opencode.sessions_list"))
    yield* PubSub.publish(server.bus, masterEvents.toolCalled("ses_master", "call_1", {}))
    yield* PubSub.publish(server.bus, masterEvents.toolStarted("ses_other", "call_x", "read"))
    yield* settled
    expect(appends()).toHaveLength(1)
    yield* TestClock.adjust(delegationLimits.narrationMs)
    yield* settled
    expect(appends()).toHaveLength(1)
    yield* PubSub.publish(server.bus, masterEvents.text("ses_master", "Uma sessão precisa da sua resposta."))
    yield* settled
    expect(appends().at(-1)?.content[0].text).toBe("Atualização da mestra: Uma sessão precisa da sua resposta.")
    // The result follows the prompt in the Mestra's transcript; it skips the wait and is chunked.
    const reply = "Há três sessões rodando: " + "á".repeat(400)
    server.messages.set("ses_master", [assistant("msg_reply", reply), assistant("msg_prompt1", "")])
    // Published while the drain still lists the Mestra as running: the result waits for it to settle.
    server.active.add("ses_master")
    yield* PubSub.publish(server.bus, masterEvents.succeeded("ses_master"))
    yield* settled
    expect(appends()).toHaveLength(2)
    server.active.delete("ses_master")
    yield* TestClock.adjust(delegationLimits.settleMs)
    yield* settled
    const final = appends().slice(2)
    expect(final.map((event) => event.content[0].text).join("")).toBe(reply)
    expect(final.every((event) => Buffer.byteLength(event.content[0].text) <= 500)).toBe(true)
    const page = yield* json("GET", `/voice/calls/${created.callID}/events?after=0`)
    expect(
      page.events
        .filter((event: Watch.VoiceEvent) => event.type === "master")
        .map((event: Watch.VoiceEvent) => event.type === "master" && event.state),
    ).toEqual(["running", "running", "running", "idle"])
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

it.effect("helpers: delegation parsing, append chunks, voice rejection and diagnostics redaction", () =>
  Effect.sync(() => {
    expect(parse("Olá")).toEqual({ text: "Olá", delivery: "steer" })
    expect(parse('{"text":"x","delivery":"queue"}')).toEqual({ text: "x", delivery: "queue" })
    expect(parse('{"text":"  "}')).toEqual({ text: '{"text":"  "}', delivery: "steer" })
    expect(chunks("é".repeat(300)).map((part) => Buffer.byteLength(part))).toEqual([500, 100])
    expect(rejectsVoice(400, JSON.stringify({ error: { code: "invalid_voice" } }))).toBe(true)
    expect(rejectsVoice(500, JSON.stringify({ error: { code: "invalid_voice" } }))).toBe(false)
    expect(
      rejectsVoice(
        422,
        JSON.stringify({ detail: [{ loc: ["body", "session", "audio", "output", "voice"], type: "enum" }] }),
      ),
    ).toBe(true)
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

it.effect("WidgetKit pushes: at most one per 2 minutes, at once when attention or failures rise", () =>
  Effect.gen(function* () {
    const shared = storage()
    const devices = makeDevices(shared)
    const paired = yield* devices.pair("Apple Watch")
    yield* devices.widget(paired.deviceID, { token: "ab12", environment: "production" })
    const sent: Push[] = []
    const answer: { value: Result } = { value: { status: "sent" } }
    const widget = makeWidgetPush({
      devices,
      bundleID: "br.com.alexandrem.opencode.watchkitapp",
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
    // The first state after start is only recorded.
    yield* run(agents(1, 0, 0), T)
    expect(sent).toEqual([])
    yield* run(agents(2, 1, 0), T + 1000)
    expect(sent).toEqual([
      {
        token: "ab12",
        environment: "production",
        priority: 5,
        expiration: Math.floor((T + 1000) / 1000) + widgetLimits.expirationSeconds,
        body: { aps: { "content-changed": true } },
        type: "widgets",
        bundleID: "br.com.alexandrem.opencode.watchkitapp",
      },
    ])
    // Fewer or more active sessions inside the window wait for it.
    expect(yield* run(agents(3, 1, 0), T + 2000)).toBe(T + 1000 + widgetLimits.spacingMs)
    expect(sent).toHaveLength(1)
    yield* run(agents(3, 1, 0), T + 1000 + widgetLimits.spacingMs)
    expect(sent).toHaveLength(2)
    yield* run(agents(3, 1, 1), T + 1000 + widgetLimits.spacingMs + 10)
    expect(sent).toHaveLength(3)
    yield* run(agents(3, 1, 1), T + 10 * widgetLimits.spacingMs)
    expect(sent).toHaveLength(3)
    answer.value = { status: "invalid", reason: "BadDeviceToken" }
    yield* run(null, T + 20 * widgetLimits.spacingMs)
    expect((yield* devices.list())[0]?.widget).toBeUndefined()
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
