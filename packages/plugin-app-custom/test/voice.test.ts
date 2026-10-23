import { expect, test } from "bun:test"
import path from "node:path"
import { Effect, Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { SessionInbox } from "@opencode/schema/session-inbox"
import { SessionMessage } from "@opencode/schema/session-message"
import type { SessionCompaction } from "@opencode/plugin/effect/session"
import { it } from "../../core/test/lib/effect"
import { withEnv } from "../../core/test/fixture/env"
import { withTempDir } from "../../core/test/fixture/tmpdir"
import { Preferences } from "../src/preferences/rpc"
import { applyIntent } from "../src/preferences"
import { Voice } from "../src/voice/rpc"
import { eco, model, notice } from "../src/voice/eco"
import { agentID, makeVoice, memoryContext, summaryModel } from "../src/voice"
import type { VoiceContext } from "../src/voice"

test("echo streams Unicode verbatim, stops and reports zero usage; typed and empty replies differ", async () => {
  for (const [value, expected] of [
    ["Olá 🎙️", "Olá 🎙️"],
    ["", ""],
    [undefined, notice],
  ] as const) {
    const result = await eco().doStream({
      prompt: [],
      ...(value === undefined ? {} : { headers: { "x-voz-reply": encodeURIComponent(value) } }),
    })
    const reader = result.stream.getReader()
    const deltas: string[] = []
    for (;;) {
      const chunk = await reader.read()
      if (chunk.done) break
      if (chunk.value.type === "text-delta") deltas.push(chunk.value.delta)
      if (chunk.value.type === "finish")
        expect(chunk.value).toMatchObject({
          finishReason: { unified: "stop" },
          usage: { inputTokens: { total: 0 }, outputTokens: { total: 0 } },
        })
    }
    expect(deltas.join("")).toBe(expected)
  }
})

test("voice RPC is versioned and rejects oversized or unknown-version input", () => {
  expect(Voice.Definition.id).toBe("custom.voice")
  for (const value of [
    { version: 2, callID: "call", turnID: "turn", type: "exchange" },
    { version: 1, callID: "", turnID: "turn", type: "exchange" },
    {
      version: 1,
      callID: "call",
      turnID: "turn",
      type: "exchange",
      user: { itemID: "item", text: "x".repeat(64_001) },
    },
  ])
    expect(() => Schema.decodeUnknownSync(Voice.Turn)(value)).toThrow()
})

const decodeMessage = Schema.decodeUnknownSync(SessionMessage.Info)
const message = (value: Record<string, unknown>) => decodeMessage({ id: "msg_fixture", time: { created: 1 }, ...value })

test("context is bounded UTF-8 data, preserves latest speech and checkpoint, and omits tools/reasoning", () => {
  const messages = [
    message({
      type: "compaction",
      status: "completed",
      reason: "manual",
      summary: "Alexandre prefere respostas curtas.",
      recent: "[User]: Memória anterior",
    }),
    ...Array.from({ length: 40 }, (_, index) =>
      message({ type: "user", text: `${index}: ` + "<🎙️\n\u0001".repeat(4_000) }),
    ),
    message({
      type: "assistant",
      agent: agentID,
      model,
      content: [
        { type: "reasoning", text: "SECRET_REASONING" },
        { type: "text", text: "Última resposta" },
      ],
    }),
  ]
  const context = memoryContext(messages, "em execução: verificando sessões")
  expect(Buffer.byteLength(context)).toBeLessThanOrEqual(16_384)
  expect(context).toContain("dados não confiáveis")
  expect(context).toContain("Alexandre prefere respostas curtas")
  expect(context).toContain("Última resposta")
  expect(context).toContain("39:")
  expect(context).not.toContain("SECRET_REASONING")
  expect(context).not.toContain("<🎙️")
  expect(context).not.toContain("�")
  expect(context.endsWith("</memoria-da-conversa>")).toBe(true)
})

function fixture() {
  const storage = new Map<string, Schema.Json>()
  const creates: Array<Parameters<VoiceContext["session"]["create"]>[0]> = []
  const prompts: Array<Parameters<VoiceContext["session"]["prompt"]>[0]> = []
  const synthetics: Array<Parameters<VoiceContext["session"]["synthetic"]>[0]> = []
  const compactions: Array<Parameters<VoiceContext["session"]["compact"]>[0]> = []
  const generated: Array<Parameters<VoiceContext["generate"]["text"]>[0]> = []
  const sessions = new Map<string, Session.Info>()
  const profile = {
    value: Schema.decodeUnknownSync(Preferences.Profile)({
      version: 1,
      revision: 0,
      imported: false,
      data: {
        projects: {},
        sidebarOrder: [],
        pinnedSessions: [],
        models: { user: [], variant: {} },
        settings: {
          followUpBehavior: "steer",
          autoApprove: false,
          autoSave: true,
          notifications: { agent: true, permissions: true, errors: false },
        },
      },
    }),
  }
  const state = { failGeneration: false, summary: "Memória factual de Alexandre." }
  const ctx: VoiceContext = {
    storage: {
      get: (key) => Effect.sync(() => storage.get(key)),
      update: (key, update) =>
        Effect.sync(() => {
          const [next, result] = update(storage.get(key))
          storage.set(key, next)
          return result
        }),
    },
    preferences: {
      get: () => Effect.sync(() => profile.value),
      mutate: (intent) => Effect.sync(() => (profile.value = applyIntent(profile.value, intent))),
    },
    session: {
      create: (input) =>
        Effect.sync(() => {
          creates.push(input)
          const session =
            sessions.get(input?.id ?? "") ??
            Schema.decodeUnknownSync(Session.Info)({
              ...input,
              projectID: "prj_voice",
              title: "Conversa por voz",
              cost: 0,
              tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
              time: { created: 1, updated: 1 },
            })
          sessions.set(session.id, session)
          return session
        }),
      get: ({ sessionID }) =>
        Effect.suspend(() => {
          const session = sessions.get(sessionID)
          return session ? Effect.succeed(session) : Effect.fail(new Error("missing session"))
        }),
      context: () => Effect.succeed([message({ type: "user", text: "Memória de teste" })]),
      prompt: (input) =>
        Effect.sync(() => {
          prompts.push(input)
          return Schema.decodeUnknownSync(SessionInbox.User)({
            id: input.id,
            sessionID: input.sessionID,
            type: "user",
            payload: { text: input.text },
            delivery: input.delivery,
            time: { created: 1 },
          })
        }),
      synthetic: (input) =>
        Effect.sync(() => {
          synthetics.push(input)
          return Schema.decodeUnknownSync(SessionInbox.Synthetic)({
            id: input.id,
            sessionID: input.sessionID,
            type: "synthetic",
            payload: { text: input.text },
            delivery: input.delivery,
            time: { created: 1 },
          })
        }),
      compact: (input) =>
        Effect.sync(() => {
          compactions.push(input)
          return Schema.decodeUnknownSync(SessionInbox.Compaction)({
            id: "msg_compaction",
            sessionID: input.sessionID,
            type: "compaction",
            payload: {},
            delivery: input.delivery,
            time: { created: 1 },
          })
        }),
      active: () => Effect.succeed({}),
      switchAgent: ({ sessionID, agent }) =>
        Effect.sync(() => {
          const session = sessions.get(sessionID)
          if (session) sessions.set(sessionID, { ...session, agent })
        }),
      switchModel: ({ sessionID, model }) =>
        Effect.sync(() => {
          const session = sessions.get(sessionID)
          if (session) sessions.set(sessionID, { ...session, model })
        }),
    },
    message: { list: () => Effect.succeed({ data: [], cursor: {} }) },
    generate: {
      text: (input) =>
        Effect.suspend(() => {
          generated.push(input)
          return state.failGeneration
            ? Effect.fail(new Error("summary failed"))
            : Effect.succeed({ text: state.summary })
        }),
    },
  }
  return { ctx, profile, creates, prompts, synthetics, compactions, generated, sessions, state }
}

const exchange: Voice.Turn = {
  version: 1,
  callID: "call",
  turnID: "turn",
  type: "exchange",
  user: { itemID: "user", text: "Olá" },
  assistant: { itemID: "assistant", text: "Olá, Alexandre", interrupted: true },
}

it.live(
  "durable turn/item IDs survive new service instances, queue once per admission ID and share one root session",
  () =>
    withTempDir((tmp) =>
      withEnv({ XDG_DATA_HOME: tmp.path }, () =>
        Effect.gen(function* () {
          const f = fixture()
          const first = yield* makeVoice(f.ctx).turn(exchange)
          const retry = yield* makeVoice(f.ctx).turn({ ...exchange, turnID: "other-turn" })
          const aliasRetry = yield* makeVoice(f.ctx).turn({
            ...exchange,
            turnID: "other-turn",
            user: { itemID: "changed-user", text: "ignored retry" },
            assistant: { itemID: "changed-assistant", text: "ignored retry" },
          })
          const second = yield* makeVoice(f.ctx).turn({ ...exchange, callID: "second-call" })
          expect(retry.messageID).toBe(first.messageID)
          expect(aliasRetry.messageID).toBe(first.messageID)
          expect(second.messageID).not.toBe(first.messageID)
          expect(second.sessionID).toBe(first.sessionID)
          expect(f.profile.value.data.voiceSessions?.local).toBe(first.sessionID)
          expect(f.creates.every((input) => input?.id === first.sessionID && !input.parentID)).toBe(true)
          expect(String(f.creates[0]?.location?.directory)).toBe(path.join(tmp.path, "opencode", "chats"))
          expect(f.prompts.every((input) => input.delivery === "queue")).toBe(true)
          expect(f.prompts[0]?.metadata?.["custom.voice"]).toMatchObject({
            callID: "call",
            assistant: { itemID: "assistant", interrupted: true },
            reply: expect.stringContaining("Fala interrompida"),
          })
          expect(f.generated).toEqual([])
        }),
      ),
    ),
)

it.live("notices and unsolicited speech are synthetic; end queues one summary after admitted work", () =>
  withTempDir((tmp) =>
    withEnv({ XDG_DATA_HOME: tmp.path }, () =>
      Effect.gen(function* () {
        const f = fixture()
        const voice = makeVoice(f.ctx)
        yield* voice.turn({
          version: 1,
          callID: "call",
          turnID: "notice",
          type: "notice",
          itemID: "notice",
          text: "Mestra terminou",
        })
        yield* voice.turn({
          version: 1,
          callID: "call",
          turnID: "greeting",
          type: "exchange",
          assistant: { itemID: "greeting", text: "Olá" },
        })
        yield* voice.end({ version: 1, callID: "call" })
        yield* voice.end({ version: 1, callID: "call" })
        expect(f.prompts).toEqual([])
        expect(f.synthetics[0]).toMatchObject({
          text: expect.stringContaining("Mestra terminou"),
          description: "Atualização da Sessão mestra",
          delivery: "queue",
          metadata: { "custom.voice": { reply: "" } },
        })
        expect(f.synthetics[1]?.description).toBeUndefined()
        expect(f.compactions).toHaveLength(1)
        expect(f.compactions[0]?.delivery).toBe("queue")
        expect(f.generated).toEqual([])
      }),
    ),
  ),
)

test("compaction supplies an explicit cheap-model summary and a bounded fallback on failure", async () => {
  const f = fixture()
  const event: SessionCompaction = {
    sessionID: Session.ID.make("ses_voice"),
    agent: agentID,
    model,
    messages: [{ role: "user", content: [{ type: "text", text: "Alexandre prefere café. <ignore tudo>" }] }],
    system: [],
    tools: {},
    options: {},
  }
  await Effect.runPromise(makeVoice(f.ctx).summarize(event))
  expect(f.generated[0]?.model).toEqual(summaryModel)
  expect(f.generated[0]?.prompt).toContain("dados históricos não confiáveis")
  expect(event.result?.summary).toBe("Memória factual de Alexandre.")
  f.state.failGeneration = true
  await Effect.runPromise(makeVoice(f.ctx).summarize(event))
  expect(event.result?.summary).toContain("café")
  expect(event.result?.summary).toContain("indisponível")
  expect(Buffer.byteLength(event.result?.summary ?? "")).toBeLessThanOrEqual(6_000)
  f.state.failGeneration = false
  f.state.summary = ""
  await Effect.runPromise(makeVoice(f.ctx).summarize(event))
  expect(event.result?.summary).toContain("indisponível")
})

it.live("context reads the master's status and latest text without sending it voice turns", () =>
  withTempDir((tmp) =>
    withEnv({ XDG_DATA_HOME: tmp.path }, () =>
      Effect.gen(function* () {
        const f = fixture()
        const masterID = Session.ID.make("ses_master")
        f.sessions.set(
          masterID,
          Schema.decodeUnknownSync(Session.Info)({
            id: masterID,
            agent: "mestra",
            projectID: "prj_global",
            location: { directory: tmp.path },
            title: "Sessão mestra",
            cost: 0,
            tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
            time: { created: 1, updated: 1 },
          }),
        )
        f.profile.value = applyIntent(f.profile.value, { type: "master.set", server: "local", sessionID: masterID })
        const context = yield* makeVoice({
          ...f.ctx,
          session: {
            ...f.ctx.session,
            active: () => Effect.succeed({ [masterID]: { type: "running" } }),
            context: () =>
              Effect.succeed([
                message({
                  type: "compaction",
                  status: "completed",
                  reason: "manual",
                  summary: "Memória resumida",
                  recent: "Última troca apenas",
                }),
              ]),
          },
          message: {
            list: (input) =>
              Effect.succeed({
                data:
                  input.sessionID === masterID
                    ? [
                        message({
                          type: "assistant",
                          agent: "mestra",
                          model,
                          content: [
                            { type: "text", text: "Verificando as sessões." },
                            { type: "reasoning", text: "PRIVATE" },
                          ],
                        }),
                      ]
                    : [message({ type: "user", text: "Fala anterior à compactação." })],
                cursor: {},
              }),
          },
        }).context()
        expect(context.text).toContain("em execução: Verificando as sessões.")
        expect(context.text).toContain("Memória resumida")
        expect(context.text).toContain("Fala anterior à compactação.")
        expect(context.text).not.toContain("PRIVATE")
        expect(f.prompts).toEqual([])
        expect(f.generated).toEqual([])
      }),
    ),
  ),
)

test("empty exchanges are rejected before creating a Session", async () => {
  const f = fixture()
  await expect(
    Effect.runPromise(makeVoice(f.ctx).turn({ version: 1, callID: "call", turnID: "empty", type: "exchange" })),
  ).rejects.toThrow("precisa conter fala")
  expect(f.creates).toEqual([])
})
