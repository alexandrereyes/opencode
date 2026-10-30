import { Effect, PubSub, Schema, Stream } from "effect"
import type { Plugin } from "@opencode/plugin/effect"
import { Form } from "@opencode/schema/form"
import { Permission } from "@opencode/schema/permission"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { SessionEvent } from "@opencode/schema/session-event"
import { SessionInbox } from "@opencode/schema/session-inbox"
import { SessionMessage } from "@opencode/schema/session-message"
import type { LiveActivity } from "../../src/live-activity/rpc"
import { makeGateway, type GatewayOptions, type WatchContext } from "../../src/watch/gateway"
import type { Sideband, SidebandFactory } from "../../src/watch/voice"
import type { Voice } from "../../src/voice/rpc"

export const T = 1793104860000

type ServerEvent = Plugin.Context["event"]["subscribe"] extends () => Stream.Stream<infer A, infer _E, infer _R>
  ? A
  : never

export function storage() {
  const values = new Map<string, Schema.Json>()
  return {
    values,
    get: (key: string) => Effect.sync(() => values.get(key)),
    update: <A>(key: string, update: (current: Schema.Json | undefined) => readonly [Schema.Json, A]) =>
      Effect.sync(() => {
        const [next, result] = update(values.get(key))
        values.set(key, next)
        return result
      }),
  }
}

export function session(id: string, extra: Record<string, unknown> = {}) {
  return Schema.decodeUnknownSync(Session.Info)({
    id,
    projectID: "prj_global",
    location: { directory: "/Users/alexandremartins/Dev/opencode2" },
    subpath: "packages/core",
    title: "Escolher banco do cache",
    cost: 0,
    tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
    time: { created: T - 3_600_000, updated: T - 60_000 },
    ...extra,
  })
}

/** Pending requests as the plugin reads them, with the time `request-times.ts` recorded. */
export function question(id: string, sessionID: string, fields: unknown[], kind = "question") {
  const form = Schema.decodeUnknownSync(Form.Info)({ id, sessionID, title: "Questions", metadata: { kind }, fields })
  return { ...form, created: T - 120_000 }
}

export function permission(id: string, sessionID: string, action: string, resources: string[]) {
  return { ...Schema.decodeUnknownSync(Permission.Request)({ id, sessionID, action, resources }), created: T - 60_000 }
}

const envelope = (sessionID: string, type: string, version = 1) => ({
  id: `evt_${crypto.randomUUID().replaceAll("-", "")}`,
  created: T,
  type,
  durable: { aggregateID: sessionID, seq: 1, version },
})

/** Sessão mestra events as the bus publishes them. */
export const masterEvents = {
  toolStarted: (sessionID: string, id: string, name: string) =>
    Schema.decodeUnknownSync(SessionEvent.Tool.Input.Started)({
      ...envelope(sessionID, "session.tool.input.started"),
      data: { sessionID, assistantMessageID: "msg_step", id, name },
    }),
  toolCalled: (sessionID: string, id: string, input: Record<string, unknown>) =>
    Schema.decodeUnknownSync(SessionEvent.Tool.Called)({
      ...envelope(sessionID, "session.tool.called"),
      data: { sessionID, assistantMessageID: "msg_step", id, input, executed: true },
    }),
  succeeded: (sessionID: string) =>
    Schema.decodeUnknownSync(SessionEvent.Execution.Succeeded)({
      ...envelope(sessionID, "session.execution.succeeded"),
      data: { sessionID },
    }),
  text: (sessionID: string, text: string) =>
    Schema.decodeUnknownSync(SessionEvent.Text.Ended)({
      ...envelope(sessionID, "session.text.ended"),
      data: { sessionID, assistantMessageID: "msg_step", ordinal: 0, text },
    }),
}

/** An in-memory OpenCode server for the gateway: sessions, requests, the Mestra and voice memory. */
export function world() {
  const shared = storage()
  const sessions = new Map<string, Session.Info>()
  const forms: Form.Info[] = []
  const permissions: Permission.Request[] = []
  const formReplies: { sessionID: string; formID: string; answer: Form.Answer }[] = []
  const permissionReplies: { sessionID: string; requestID: string; decision: string }[] = []
  const prompts: { sessionID: string; text: string; delivery?: string }[] = []
  const active = new Set<string>()
  const messages = new Map<string, SessionMessage.Info[]>()
  const memory = {
    appended: [] as Voice.Turn[],
    ended: 0,
    context: {
      version: 2 as const,
      scope: "global" as const,
      summary: "Alexandre prefere respostas curtas.",
      turns: [{ id: "old:1", role: "user" as const, text: "Oi", at: T - 86_400_000 }],
      approxTokens: 30,
      updatedAt: T - 86_400_000,
      truncated: false,
    },
  }
  const masters = { ensured: 0, id: "ses_master" }
  const voice = { instructions: "Prompt de voz do servidor de teste." }
  const bus = Effect.runSync(PubSub.unbounded<ServerEvent>())
  const ctx: WatchContext = {
    app: { version: "2.0.0-test" },
    instructions: () => Effect.sync(() => voice.instructions),
    storage: shared,
    request: {
      pending: () =>
        Effect.sync(() => [
          { location: { directory: AbsolutePath.make("/repo") }, forms: [...forms], permissions: [...permissions] },
        ]),
    },
    session: {
      get: ({ sessionID }) => {
        const found = sessions.get(sessionID)
        return found ? Effect.succeed(found) : Effect.fail(new Error("missing"))
      },
      form: {
        reply: (input) =>
          Effect.suspend(() => {
            const index = forms.findIndex((form) => form.id === input.formID)
            if (index < 0) return Effect.fail(new Error("Form not found"))
            forms.splice(index, 1)
            formReplies.push(input)
            return Effect.void
          }),
      },
      prompt: (input) =>
        Effect.sync(() => {
          prompts.push({
            sessionID: input.sessionID,
            text: input.text,
            ...(input.delivery ? { delivery: input.delivery } : {}),
          })
          return Schema.decodeUnknownSync(SessionInbox.User)({
            id: `msg_prompt${prompts.length}`,
            sessionID: input.sessionID,
            time: { created: T },
            type: "user",
            payload: { text: input.text },
            delivery: input.delivery ?? "steer",
          })
        }),
      active: () => Effect.sync(() => Object.fromEntries([...active].map((id) => [id, { type: "running" as const }]))),
    },
    permission: {
      reply: (input) =>
        Effect.suspend(() => {
          const index = permissions.findIndex((request) => request.id === input.requestID)
          if (index < 0) return Effect.fail(new Error("Permission not found"))
          permissions.splice(index, 1)
          permissionReplies.push(input)
          return Effect.void
        }),
    },
    message: {
      list: ({ sessionID }) => Effect.sync(() => ({ data: messages.get(sessionID) ?? [], cursor: {} })),
    },
    event: {
      // The real domain narrows the stream to the requested types; the fixture filters the same way.
      subscribe: ((input?: { readonly types?: ReadonlyArray<string> }) =>
        Stream.fromPubSub(bus).pipe(
          Stream.filter((event) => !input?.types?.length || input.types.includes(event.type)),
        )) as WatchContext["event"]["subscribe"],
    },
    ensureMaster: () =>
      Effect.sync(() => {
        masters.ensured += 1
        return masters.id
      }),
    memory: {
      context: () => Effect.succeed(memory.context),
      append: (turns) => Effect.sync(() => memory.appended.push(...turns)),
      end: () => Effect.sync(() => (memory.ended += 1)),
    },
  }
  return {
    ctx,
    shared,
    sessions,
    forms,
    permissions,
    formReplies,
    permissionReplies,
    prompts,
    active,
    messages,
    memory,
    masters,
    voice,
    bus,
  }
}

export function assistant(id: string, text: string) {
  return Schema.decodeUnknownSync(SessionMessage.Assistant)({
    id,
    type: "assistant",
    agent: "mestra",
    model: { providerID: "llm-proxy", id: "gpt-6.1-sol-ultrafast" },
    time: { created: T, completed: T },
    content: [{ type: "text", text }],
  })
}

export const answerSDP = [
  "v=0",
  "o=- 1 2 IN IP4 127.0.0.1",
  "s=-",
  "t=0 0",
  "a=ice-lite",
  "m=audio 3478 UDP/TLS/RTP/SAVPF 111",
  "a=rtpmap:111 opus/48000/2",
  "a=candidate:1 1 udp 2130706431 203.0.113.10 3478 typ host",
  "",
].join("\r\n")

export const offerSDP = [
  "v=0",
  "o=- 1 2 IN IP4 0.0.0.0",
  "s=-",
  "t=0 0",
  "m=audio 9 UDP/TLS/RTP/SAVPF 111",
  "a=rtpmap:111 opus/48000/2",
  "",
].join("\r\n")

/** A fake llm-proxy: leases, call creation and their counts. */
export function proxy() {
  const log: { method: string; path: string; body?: unknown }[] = []
  const state = { renewStatus: 200, answer: answerSDP, createStatus: 201, createBody: undefined as string | undefined }
  const lease = (path: string, body: { generation: string }) =>
    Response.json({
      sessionId: path.split("/").at(-1),
      generation: body.generation,
      serverTime: new Date(T).toISOString(),
      leaseExpiresAt: new Date(T + 60_000).toISOString(),
    })
  return {
    log,
    state,
    proxy: {
      origin: "http://llm-proxy.test",
      fetch: async (request: Request) => {
        const url = new URL(request.url)
        const text = request.method === "DELETE" ? "" : await request.text()
        const body = text ? JSON.parse(text) : undefined
        log.push({ method: request.method, path: url.pathname + url.search, body })
        if (url.pathname.startsWith("/_gpt-live/sessions/")) {
          if (request.method === "DELETE") return new Response(null, { status: 204 })
          if (request.method === "PUT" && state.renewStatus !== 200)
            return new Response(null, { status: state.renewStatus })
          return lease(url.pathname, body)
        }
        if (url.pathname === "/backend-api/codex/realtime/calls") {
          if (state.createStatus !== 201) return new Response(state.createBody ?? "{}", { status: state.createStatus })
          return new Response(state.answer, { status: 201, headers: { location: "/v1/realtime/calls/rtc_test123" } })
        }
        return new Response("not found", { status: 404 })
      },
    },
  }
}

/** Fake sidebands: what the gateway sent and a way to deliver GPT Live events. */
export function sidebands() {
  const opened: {
    url: string
    headers: Record<string, string>
    sent: string[]
    deliver: (event: object) => void
    closed: boolean
  }[] = []
  const factory: SidebandFactory = (url, headers, handlers) => {
    const entry = {
      url,
      headers,
      sent: [] as string[],
      closed: false,
      deliver: (event: object) => handlers.message(JSON.stringify(event)),
    }
    opened.push(entry)
    const socket: Sideband = {
      send: (text) => {
        entry.sent.push(text)
        // The real service answers session.close with session.closed and closes the socket.
        if (text.includes('"session.close"')) {
          entry.closed = true
          handlers.closed()
        }
      },
      close: () => {
        entry.closed = true
      },
    }
    return socket
  }
  return { opened, factory }
}

export function gateway(input: {
  server: ReturnType<typeof world>
  proxy?: ReturnType<typeof proxy>
  sidebands?: ReturnType<typeof sidebands>
  options?: Partial<GatewayOptions>
}) {
  const state = { value: null as LiveActivity.AgentsState | null, requests: new Map<string, string>() }
  const fakeProxy = input.proxy ?? proxy()
  const fakeSidebands = input.sidebands ?? sidebands()
  const value = makeGateway({
    port: Effect.succeed(0),
    access: Effect.succeed({ clientId: "client.access", clientSecret: "secret-value" }),
    apns: Effect.succeed(undefined),
    widgetBundleID: Effect.succeed("br.com.alexandrem.opencode.watchkitapp"),
    proxy: fakeProxy.proxy,
    sideband: fakeSidebands.factory,
    view: Effect.sync(() => ({ state: state.value, host: "MacBook Pro", requests: state.requests })),
    ...input.options,
  })
  return { gateway: value, state, proxy: fakeProxy, sidebands: fakeSidebands }
}

export function request(method: string, path: string, token?: string, body?: unknown) {
  return new Request(`http://127.0.0.1/watch/v1${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
}
