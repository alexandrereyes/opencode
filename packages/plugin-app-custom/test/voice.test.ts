import { expect, test } from "bun:test"
import { Clock, Deferred, Effect, Fiber, Logger, Schema } from "effect"
import { TestClock } from "effect/testing"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { it } from "../../core/test/lib/effect"
import { Voice } from "../src/voice/rpc"
import {
  boundedContext,
  estimateTokens,
  key,
  lateLabel,
  limits,
  logDiagnostics,
  makeVoice,
  masterLabel,
  summaryLabel,
  summaryModel,
  tokens,
  turnText,
} from "../src/voice"
import type { VoiceContext } from "../src/voice"
import { Preferences } from "../src/preferences/rpc"
import { tmpdir } from "../../core/test/fixture/tmpdir"
import { loadInstructions } from "../src/voice/instructions"
import { VoiceWindow } from "../src/voice/window"

const decode = Schema.decodeUnknownSync(Voice.Record)
const encode = Schema.encodeSync(Voice.Record)
const turn = (id: string, text = "Fala sintética.", role: Voice.Turn["role"] = "user"): Voice.Turn => ({
  id,
  text,
  role,
  at: 123,
})
const turns = (count: number, text = "Fala sintética.") =>
  Array.from({ length: count }, (_, index) => turn(`item-${index}`, text, index % 2 ? "assistant" : "user"))
const record = (turns: readonly Voice.Turn[], summary = ""): Voice.Record => ({
  version: 1,
  summary,
  turns,
  approxTokens: tokens(summary, turns),
  updatedAt: 123,
  seenTurnIDs: turns.map((turn) => turn.id),
})

function fixture(initial?: Voice.Record) {
  const values = new Map<string, Schema.Json>(initial ? [[key("global"), encode(initial)]] : [])
  const generated: Array<Parameters<VoiceContext["generate"]["text"]>[0]> = []
  const state = { fail: false, text: "Alexandre prefere respostas curtas e café sem açúcar." }
  const ctx: VoiceContext = {
    storage: {
      get: (key) => Effect.sync(() => values.get(key)),
      update: (key, update) =>
        Effect.sync(() => {
          const [next, result] = update(values.get(key))
          values.set(key, next)
          return result
        }),
    },
    generate: {
      text: (input) =>
        Effect.suspend(() => {
          generated.push(input)
          return state.fail ? Effect.fail(new Error("generation unavailable")) : Effect.succeed({ text: state.text })
        }),
    },
    session: {
      get: () => Effect.fail(new Error("Voice must not create/read a recorder Session")),
      active: () => Effect.succeed({}),
    },
    message: { list: () => Effect.succeed({ data: [], cursor: {} }) },
  }
  return { ctx, values, generated, state, read: () => decode(values.get(key("global"))) }
}

test("KV protocol replaces the eco contract, validates batches and reserves future scopes", () => {
  expect(Voice.version).toBe(2)
  expect(Object.keys(Voice.Definition.methods)).toEqual([
    "info",
    "instructions",
    "append",
    "context",
    "end",
    "reset",
    "diagnostics",
  ])
  expect(key("global")).toBe("voice/transcript/global")
  for (const input of [
    { version: 1, scope: "global", turns: [turn("id")] },
    { version: 2, scope: "session/ses_future", turns: [turn("id")] },
    { version: 2, scope: "global", turns: [] },
    { version: 2, scope: "global", turns: [turn("")] },
    { version: 2, scope: "global", turns: [{ ...turn("id"), role: "system" }] },
    { version: 2, scope: "global", turns: [{ ...turn("id"), at: -1 }] },
    { version: 2, scope: "global", turns: [turn("id", "x".repeat(64_001))] },
  ])
    expect(() => Schema.decodeUnknownSync(Voice.Append)(input)).toThrow()
})

test("voice instructions reload the editable Markdown and reject empty or unreadable overrides", async () => {
  await using dir = await tmpdir("opencode-voice-prompt-")
  const file = `${dir.path}/voice.md`
  const defaults = await Effect.runPromise(loadInstructions(file))
  // The default documents the screen parameter in each app's form, so neither app prepends its own rules.
  expect(defaults).toContain(`"screen":true`)
  expect(defaults).toContain(`"screen_app"`)
  expect(defaults.toLowerCase()).not.toContain("mestra")
  await Bun.write(file, "Primeiro prompt")
  expect(await Effect.runPromise(loadInstructions(file))).toBe("Primeiro prompt")
  await Bun.write(file, "Segundo prompt")
  expect(await Effect.runPromise(loadInstructions(file))).toBe("Segundo prompt")
  await Bun.write(file, " \n")
  expect(await Effect.runPromise(loadInstructions(file).pipe(Effect.isFailure))).toBe(true)
  expect(await Effect.runPromise(loadInstructions(dir.path).pipe(Effect.isFailure))).toBe(true)
})

test("Portuguese estimator counts UTF-8, item framing and interruption annotations", () => {
  expect(estimateTokens("ação")).toBe(10)
  expect(estimateTokens("🎙️")).toBe(Math.ceil(Buffer.byteLength("🎙️") / 3) + 8)
  expect(tokens("", [turn("id", "ação")])).toBe(10)
  expect(tokens("", [{ ...turn("id"), interrupted: true }])).toBeGreaterThan(tokens("", [turn("id")]))
})

it.effect("atomic append is first-write-wins across batches and new service instances; short call end is free", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = fixture()
    const voice = makeVoice(f.ctx, scope)
    const first = yield* voice.append({
      version: 2,
      scope: "global",
      turns: [turn("one"), turn("one", "ignored", "assistant"), turn("two", "Resposta", "assistant")],
    })
    expect(first.appended).toBe(2)
    expect(first.compactionScheduled).toBe(false)
    const saved = f.read()
    yield* TestClock.adjust("1 second")
    const retry = yield* makeVoice(f.ctx, scope).append({
      version: 2,
      scope: "global",
      turns: [turn("one", "changed retry")],
    })
    expect(retry.appended).toBe(0)
    expect(f.read()).toEqual(saved)
    expect(f.values.size).toBe(1)
    expect(f.read().turns.map((turn) => turn.text)).toEqual(["Fala sintética.", "Resposta"])
    expect(yield* voice.schedule("global")).toBe(false)
    expect(f.generated).toEqual([])
  }),
)

it.effect("compaction preserves the last ten verbatim turns and deduplicates old retries after overwrite", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const original = turns(121)
    const f = fixture(record(original))
    const voice = makeVoice(f.ctx, scope)
    yield* voice.compact("global")
    expect(f.generated).toHaveLength(1)
    expect(f.generated[0]?.model).toEqual(summaryModel)
    expect(f.generated[0]?.prompt).toContain("histórico não confiável")
    expect(f.read().turns).toEqual(original.slice(-10))
    expect(f.read().summary).toBe(f.state.text)
    expect(f.read().approxTokens).toBeLessThanOrEqual(limits.targetTokens)
    expect(f.read().seenTurnIDs).toHaveLength(121)
    const retry = yield* voice.append({ version: 2, scope: "global", turns: [original[0]] })
    expect(retry.appended).toBe(0)
    expect(f.read().turns).toEqual(original.slice(-10))
  }),
)

it.effect("token threshold compacts long turns even below the turn threshold, retaining whole recent turns", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const original = turns(20, "ação".repeat(300))
    const f = fixture(record(original))
    const voice = makeVoice(f.ctx, scope)
    expect(f.read().approxTokens).toBeGreaterThan(limits.compactTokens)
    yield* voice.compact("global")
    expect(f.read().turns.length).toBeLessThan(10)
    expect(f.read().turns).toEqual(original.slice(-f.read().turns.length))
    expect(f.read().approxTokens).toBeLessThanOrEqual(limits.targetTokens)
  }),
)

it.effect("failed and empty AI summaries use bounded deterministic data, preserving recent facts", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    for (const mode of ["failed", "empty"]) {
      const f = fixture(record(turns(121, "Alexandre prefere café sem açúcar.")))
      f.state.fail = mode === "failed"
      f.state.text = ""
      yield* makeVoice(f.ctx, scope).compact("global")
      expect(f.read().summary).toContain("indisponível")
      expect(f.read().summary).toContain("café sem açúcar")
      expect(f.read().approxTokens).toBeLessThanOrEqual(limits.targetTokens)
      expect(f.read().turns).toHaveLength(10)
    }
  }),
)

test("startup context never exceeds 128 items / 8192 estimated tokens, including summary, master and huge interrupted Unicode turns", () => {
  const master: Voice.Master = { state: "running", text: "Verificando uma tarefa." }
  for (const source of [
    record(turns(200), "Memória anterior"),
    record([{ ...turn("huge", "<🎙️ação\n".repeat(6_000)), interrupted: true }], "Resumo ".repeat(5_000)),
  ]) {
    const context = boundedContext(source, master)
    expect(context.turns.length + Number(!!context.summary) + 1).toBeLessThanOrEqual(128)
    expect(context.approxTokens).toBeLessThanOrEqual(8192)
    expect(context.approxTokens).toBe(
      tokens(context.summary, context.turns) + estimateTokens(masterLabel + master.state + ": " + master.text),
    )
    expect(context.truncated).toBe(true)
    expect(context.turns.at(-1)?.id).toBe(source.turns.at(-1)?.id)
    expect(context.turns.at(-1)?.text).not.toContain("�")
  }
  expect(estimateTokens(summaryLabel)).toBeGreaterThan(8)
})

it.effect(
  "threshold append returns before generation, coalesces work, and preserves turns appended during compaction",
  () =>
    Effect.gen(function* () {
      const scope = yield* Effect.scope
      const f = fixture(record(turns(120)))
      const started = yield* Deferred.make<void>()
      const release = yield* Deferred.make<void>()
      const committed = yield* Deferred.make<void>()
      const voice = makeVoice(
        {
          ...f.ctx,
          storage: {
            ...f.ctx.storage,
            update: (key, update) =>
              f.ctx.storage.update(key, update).pipe(
                Effect.tap(() =>
                  Effect.gen(function* () {
                    if (f.read().summary) yield* Deferred.succeed(committed, undefined)
                  }),
                ),
              ),
          },
          generate: {
            text: (input) =>
              Effect.gen(function* () {
                f.generated.push(input)
                yield* Deferred.succeed(started, undefined)
                yield* Deferred.await(release)
                return { text: f.state.text }
              }),
          },
        },
        scope,
      )
      const admission = yield* voice.append({ version: 2, scope: "global", turns: [turn("threshold")] })
      expect(admission.compactionScheduled).toBe(true)
      expect(f.read().turns).toHaveLength(121)
      yield* Deferred.await(started)
      const later = yield* voice.append({
        version: 2,
        scope: "global",
        turns: [turn("during-generation", "Não perder esta fala.")],
      })
      expect(later.compactionScheduled).toBe(false)
      yield* Deferred.succeed(release, undefined)
      yield* Deferred.await(committed)
      expect(f.read().turns.at(-1)?.id).toBe("during-generation")
      expect(f.read().turns).toHaveLength(11)
      expect(f.read().seenTurnIDs).toHaveLength(122)
      expect(f.generated).toHaveLength(1)
    }),
)

it.effect("concurrent compactions cannot replace a newer checkpoint or remove the retained tail twice", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = fixture(record(turns(121)))
    const started = yield* Deferred.make<void>()
    const release = yield* Deferred.make<void>()
    const count = { value: 0 }
    const voice = makeVoice(
      {
        ...f.ctx,
        generate: {
          text: () =>
            Effect.gen(function* () {
              count.value++
              if (count.value === 2) yield* Deferred.succeed(started, undefined)
              yield* Deferred.await(release)
              return { text: "Resumo concorrente." }
            }),
        },
      },
      scope,
    )
    const first = yield* voice.compact("global").pipe(Effect.forkChild({ startImmediately: true }))
    const second = yield* voice.compact("global").pipe(Effect.forkChild({ startImmediately: true }))
    yield* Deferred.await(started)
    yield* Deferred.succeed(release, undefined)
    yield* Fiber.join(first)
    yield* Fiber.join(second)
    expect(f.read().turns).toHaveLength(10)
    expect(f.read().seenTurnIDs).toHaveLength(121)
  }),
)

it.effect("concurrent end checks coalesce even when both storage reads were already in flight", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = fixture(record(turns(121)))
    const reading = yield* Deferred.make<void>()
    const releaseReads = yield* Deferred.make<void>()
    const releaseSummary = yield* Deferred.make<void>()
    const reads = { count: 0 }
    const voice = makeVoice(
      {
        ...f.ctx,
        storage: {
          ...f.ctx.storage,
          get: (key) =>
            Effect.gen(function* () {
              reads.count++
              if (reads.count <= 2) {
                if (reads.count === 2) yield* Deferred.succeed(reading, undefined)
                yield* Deferred.await(releaseReads)
              }
              return yield* f.ctx.storage.get(key)
            }),
        },
        generate: {
          text: (input) =>
            Effect.gen(function* () {
              f.generated.push(input)
              yield* Deferred.await(releaseSummary)
              return { text: f.state.text }
            }),
        },
      },
      scope,
    )
    const first = yield* voice.schedule("global").pipe(Effect.forkChild({ startImmediately: true }))
    const second = yield* voice.schedule("global").pipe(Effect.forkChild({ startImmediately: true }))
    yield* Deferred.await(reading)
    yield* Deferred.succeed(releaseReads, undefined)
    const scheduled = [yield* Fiber.join(first), yield* Fiber.join(second)]
    expect(scheduled.filter(Boolean)).toHaveLength(1)
    yield* Deferred.succeed(releaseSummary, undefined)
  }),
)

it.effect("context reads do not create storage or invoke inference when memory is empty", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = fixture()
    const context = yield* makeVoice(f.ctx, scope).context("global")
    expect(context.summary).toBe("")
    expect(context.turns).toEqual([])
    expect(context.approxTokens).toBe(0)
    expect(f.values.size).toBe(0)
    expect(f.generated).toEqual([])
    expect(yield* Clock.currentTimeMillis).toBe(0)
  }),
)

it.effect("master status is read-only data, sent only while it runs, and excludes reasoning from startup history", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = fixture(record([turn("voice-user")]))
    const sessionID = Session.ID.make("ses_master")
    const profile = Schema.decodeUnknownSync(Preferences.Profile)({
      version: 1,
      revision: 1,
      imported: true,
      data: {
        projects: {},
        sidebarOrder: [],
        pinnedSessions: [],
        masterSessions: { local: sessionID },
        models: { user: [], variant: {} },
        settings: {
          followUpBehavior: "steer",
          autoApprove: false,
          autoSave: true,
          notifications: { agent: true, permissions: true, errors: false },
        },
      },
    })
    f.values.set("preferences:profile", Schema.encodeSync(Preferences.Profile)(profile))
    const active = { [sessionID]: { type: "running" as const } }
    const voice = makeVoice(
      {
        ...f.ctx,
        session: {
          get: () =>
            Effect.succeed(
              Schema.decodeUnknownSync(Session.Info)({
                id: sessionID,
                agent: "mestra",
                projectID: "prj_global",
                location: { directory: "/repo" },
                title: "Sessão mestra",
                cost: 0,
                tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
                time: { created: 1, updated: 1 },
              }),
            ),
          active: () => Effect.succeed(active),
        },
        message: {
          list: () =>
            Effect.succeed({
              data: [
                Schema.decodeUnknownSync(SessionMessage.Info)({
                  type: "assistant",
                  id: "msg_master",
                  agent: "mestra",
                  model: summaryModel,
                  time: { created: 1 },
                  content: [
                    { type: "reasoning", text: "PRIVATE" },
                    { type: "text", text: "Consultando as sessões." },
                  ],
                }),
              ],
              cursor: {},
            }),
        },
      },
      scope,
    )
    const context = yield* voice.context("global")
    expect(context.master).toEqual({ state: "running", text: "Consultando as sessões." })
    expect(JSON.stringify(context)).not.toContain("PRIVATE")
    expect(context.turns).toEqual([turn("voice-user")])
    // An idle master's last reply is from an earlier conversation, so a new call does not get it.
    delete active[sessionID]
    const idle = yield* voice.context("global")
    expect(idle.master).toBeUndefined()
    expect(idle.turns).toEqual([turn("voice-user")])
    expect(f.generated).toEqual([])
  }),
)

const settled = Effect.forEach(
  Array.from({ length: 5 }),
  () => Effect.promise(() => new Promise((resolve) => setTimeout(resolve, 1))),
  { discard: true },
)

const mestraUser = (id: string, text: string, created: number) =>
  Schema.decodeUnknownSync(SessionMessage.Info)({ type: "user", id, text, time: { created } })
const mestraReply = (id: string, text: string, completed?: number) =>
  Schema.decodeUnknownSync(SessionMessage.Info)({
    type: "assistant",
    id,
    agent: "mestra",
    model: summaryModel,
    time: { created: completed ?? 9_600, ...(completed === undefined ? {} : { completed }) },
    content: text ? [{ type: "text", text }] : [],
  })

/** A Mestra transcript (newest first, as `order: "desc"` returns it) behind real voice memory. */
function lateFixture(initial: Voice.Record, messages: SessionMessage.Info[]) {
  const f = fixture(initial)
  const active: Record<string, { type: "running" }> = {}
  const ctx: VoiceContext = {
    ...f.ctx,
    session: { ...f.ctx.session, active: () => Effect.sync(() => ({ ...active })) },
    message: { list: () => Effect.succeed({ data: messages, cursor: {} }) },
  }
  return { ...f, ctx, active }
}

it.effect("late replies: requests inside the call, replies no spoken turn followed, each once", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = lateFixture(record([{ ...turn("spoken", "A resposta A é sim.", "assistant"), at: 3_600 }]), [
      mestraUser("msg_after", "Pedido de outra conversa", 10_000),
      mestraReply("msg_running", "", undefined),
      mestraReply("msg_tools", "", 9_500),
      mestraReply("msg_b", "Resposta B", 9_000),
      mestraUser("msg_req_b", "Pedido B", 4_000),
      mestraReply("msg_a_final", "Resposta A final", 3_500),
      mestraReply("msg_a_partial", "Resposta A parcial", 3_000),
      mestraUser("msg_req_a", "Pedido A", 2_000),
      mestraReply("msg_old", "Resposta antiga", 600),
      mestraUser("msg_req_old", "Pedido antigo", 500),
    ])
    const voice = makeVoice(f.ctx, scope)
    const window = { sessionID: "ses_m", since: 1_000 }
    // A was voiced (a spoken turn at 3600 follows its reply at 3500); B was not; the rest lie outside the call.
    expect(yield* voice.recordLate(window, 5_000)).toBe(1)
    expect(f.read().turns.at(-1)).toMatchObject({
      id: "agent:msg_b",
      role: "user",
      text: lateLabel + "Pedido: Pedido B\nResposta: Resposta B",
    })
    expect(yield* voice.recordLate(window, 5_000)).toBe(0)
    expect(f.read().turns).toHaveLength(2)
  }),
)

it.effect("the call's end takes its window once and records after the Mestra goes idle, for at most lateMs", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const messages = [mestraReply("msg_reply", "Pronto.", 50_000), mestraUser("msg_req", "Faça isso.", 0)]
    const f = lateFixture(record([]), messages)
    const voice = makeVoice(f.ctx, scope)
    const open = () => Effect.sync(() => f.values.set(VoiceWindow.key, { sessionID: "ses_m", since: 0 }))
    yield* open()
    f.active["ses_m"] = { type: "running" }
    yield* voice.settle()
    yield* voice.settle()
    expect(f.values.get(VoiceWindow.key)).toBeNull()
    yield* TestClock.adjust(limits.latePollMs)
    expect(f.read().turns).toEqual([])
    delete f.active["ses_m"]
    yield* TestClock.adjust(limits.latePollMs)
    yield* settled
    expect(f.read().turns.map((item) => item.id)).toEqual(["agent:msg_reply"])
    // A Mestra still busy after `lateMs` is left alone.
    const busy = lateFixture(record([]), messages)
    const late = makeVoice(busy.ctx, scope)
    busy.values.set(VoiceWindow.key, { sessionID: "ses_m", since: 0 })
    busy.active["ses_m"] = { type: "running" }
    yield* late.settle()
    yield* TestClock.adjust(limits.lateMs + limits.latePollMs)
    delete busy.active["ses_m"]
    yield* TestClock.adjust(limits.latePollMs)
    yield* settled
    expect(busy.read().turns).toEqual([])
  }),
)

it.effect("reset clears what GPT Live gets back and keeps the old conversation from coming back", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    yield* TestClock.setTime(10_000)
    const messages = [
      mestraReply("msg_reply", "Resposta antiga.", 20_000),
      mestraUser("msg_req", "Pedido antigo.", 9_000),
    ]
    const f = lateFixture(
      record([turn("old-1"), { ...turn("old-2", "Fala antiga.", "assistant"), at: 9_500 }], "Resumo antigo."),
      messages,
    )
    f.values.set(VoiceWindow.key, { sessionID: "ses_m", since: 8_000 })
    // Everything else in the plugin's storage (the Mestra pointer, drafts…) stays as it was.
    f.values.set("preferences:profile", { data: { masterSessions: { local: "ses_m" } } })
    f.values.set("question-drafts:ses_x", { answers: ["rascunho"] })
    const voice = makeVoice(f.ctx, scope)
    expect(yield* voice.reset("global")).toBe(10_000)
    expect(f.values.get("preferences:profile")).toEqual({ data: { masterSessions: { local: "ses_m" } } })
    expect(f.values.get("question-drafts:ses_x")).toEqual({ answers: ["rascunho"] })
    expect(f.read()).toMatchObject({ summary: "", turns: [], approxTokens: 0, resetAt: 10_000 })
    // Retry identities stay: the cleared conversation is still a duplicate.
    expect(f.read().seenTurnIDs).toEqual(["old-1", "old-2"])
    // The late-reply window of the cleared call is gone, and an older one cannot record either.
    expect(f.values.get(VoiceWindow.key)).toBeNull()
    expect(yield* voice.recordLate({ sessionID: "ses_m", since: 8_000 }, 10_000)).toBe(0)
    // A straggler of the old call (spoken before the reset) stays out; the new call's speech goes in.
    const late = yield* voice.append({ version: 2, scope: "global", turns: [{ ...turn("straggler"), at: 9_900 }] })
    expect(late.appended).toBe(0)
    yield* TestClock.adjust(5_000)
    const fresh = yield* voice.append({ version: 2, scope: "global", turns: [{ ...turn("new-1", "Oi."), at: 15_000 }] })
    expect(fresh.appended).toBe(1)
    expect(f.read().turns.map((item) => item.id)).toEqual(["new-1"])
  }),
)

it.effect("a summary computed from the old turns is dropped when a reset happened meanwhile", () =>
  Effect.gen(function* () {
    const scope = yield* Effect.scope
    const f = fixture(record(turns(121)))
    const generating = yield* Deferred.make<void>()
    const release = yield* Deferred.make<void>()
    const voice = makeVoice(
      {
        ...f.ctx,
        generate: {
          text: () =>
            Deferred.succeed(generating, undefined).pipe(
              Effect.andThen(Deferred.await(release)),
              Effect.as({ text: "Resumo da conversa apagada." }),
            ),
        },
      },
      scope,
    )
    const compaction = yield* voice.compact("global").pipe(Effect.forkChild({ startImmediately: true }))
    yield* Deferred.await(generating)
    yield* voice.reset("global")
    yield* Deferred.succeed(release, undefined)
    yield* Fiber.join(compaction)
    expect(f.read()).toMatchObject({ summary: "", turns: [] })
  }),
)

it.effect("the voice window keeps a call's start, and restarts for a replaced Mestra or a stale window", () =>
  Effect.gen(function* () {
    const values = new Map<string, Schema.Json>()
    const storage = {
      get: (key: string) => Effect.sync(() => values.get(key)),
      set: (key: string, value: Schema.Json) => Effect.sync(() => void values.set(key, value)),
    }
    yield* TestClock.setTime(10_000)
    yield* VoiceWindow.open(storage, "ses_m")
    yield* TestClock.adjust(60_000)
    yield* VoiceWindow.open(storage, "ses_m")
    expect(values.get(VoiceWindow.key)).toEqual({ sessionID: "ses_m", since: 10_000 })
    yield* VoiceWindow.open(storage, "ses_new")
    expect(values.get(VoiceWindow.key)).toEqual({ sessionID: "ses_new", since: 70_000 })
    yield* TestClock.adjust(VoiceWindow.staleMs)
    yield* VoiceWindow.open(storage, "ses_new")
    expect(values.get(VoiceWindow.key)).toEqual({ sessionID: "ses_new", since: 70_000 + VoiceWindow.staleMs })
  }),
)

const diagnostic = {
  kind: "failed",
  reason: "service_error",
  code: "invalid_request_error/unknown_event",
  platform: "ios",
  build: "0.1.0 (202610311200)",
  at: Date.UTC(2026, 9, 31, 11, 48, 55),
  call: "855CA9AC-0000-4000-8000-000000000000",
  connectedSeconds: 168.4,
  phase: "listening",
  recovering: false,
  events: ["delegation.created", "transport.connected", "error"],
  app: { state: "background", locked: true },
  audio: { category: "PlayAndRecord", mode: "VoiceChat", inputs: ["MicrophoneBuiltIn"], outputs: ["Speaker"] },
  network: "wifi",
} as const

test("voice diagnostics carry categories and names only and log one line each", async () => {
  const decodeDiagnostics = Schema.decodeUnknownSync(Voice.Diagnostics)
  for (const events of [
    [],
    Array.from({ length: 21 }, () => diagnostic),
    [{ ...diagnostic, kind: "crashed" }],
    [{ ...diagnostic, reason: "" }],
    // Free text does not fit in names; only `detail` carries an error message, bounded and sanitized.
    [{ ...diagnostic, code: "x".repeat(121) }],
    [{ ...diagnostic, detail: "x".repeat(301) }],
    [{ ...diagnostic, lastSent: "tipo com espaço".repeat(5) }],
    [{ ...diagnostic, events: [...diagnostic.events, "y".repeat(65)] }],
    [{ ...diagnostic, events: Array.from({ length: 25 }, () => "error") }],
    [{ ...diagnostic, app: { state: "suspended", locked: true } }],
  ])
    expect(() => decodeDiagnostics({ events })).toThrow()
  const logged: { message: unknown }[] = []
  const result = await Effect.runPromise(
    logDiagnostics(
      decodeDiagnostics({
        events: [
          {
            ...diagnostic,
            // An app that did not sanitize still cannot put a quoted span or control characters in the log.
            detail: "Unknown event 'x'.\n\"Alexandre disse uma frase bem longa aqui na chamada\"",
            lastSent: "delegation.context.append",
            lastSentSeconds: 1.26,
          },
          { ...diagnostic, kind: "ended", reason: "user_end" },
          // The service's `session.closed` reason as the code and the audio it counted as the detail (02/11).
          { ...diagnostic, kind: "lost", reason: "session_closed", code: "expired", detail: "audio_duration_ms=86800" },
          { ...diagnostic, kind: "tolerated", reason: "moderation_nonfatal", code: "content_filter/content_filter" },
        ],
      }),
    ).pipe(
      Effect.provideService(Logger.CurrentLoggers, new Set([Logger.make((entry) => logged.push({ message: entry.message }))])),
    ),
  )
  expect(result).toEqual({ accepted: 4 })
  expect(logged.map((entry) => (entry.message as unknown[])[0])).toEqual(Array(4).fill("Voice diagnostics"))
  expect((logged[2]?.message as unknown[])[1]).toMatchObject({
    kind: "lost",
    reason: "session_closed",
    code: "expired",
    detail: "audio_duration_ms=86800",
  })
  expect((logged[0]?.message as unknown[])[1]).toEqual({
    kind: "failed",
    reason: "service_error",
    code: "invalid_request_error/unknown_event",
    platform: "ios",
    build: "0.1.0 (202610311200)",
    at: "2026-10-31T11:48:55.000Z",
    call: "855CA9AC-0000-4000-8000-000000000000",
    connectedSeconds: 168,
    phase: "listening",
    recovering: false,
    app: "background",
    locked: true,
    audio: "PlayAndRecord/VoiceChat",
    route: "out=Speaker in=MicrophoneBuiltIn",
    network: "wifi",
    detail: "Unknown event 'x'. \"…\"",
    lastSent: "delegation.context.append",
    lastSentAgoSeconds: 1.3,
    events: "delegation.created,transport.connected,error",
  })
})
