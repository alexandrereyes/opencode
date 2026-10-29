import { expect, test } from "bun:test"
import { Clock, Deferred, Effect, Fiber, Schema } from "effect"
import { TestClock } from "effect/testing"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { it } from "../../core/test/lib/effect"
import { Voice } from "../src/voice/rpc"
import {
  boundedContext,
  estimateTokens,
  key,
  limits,
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
  expect(Object.keys(Voice.Definition.methods)).toEqual(["info", "instructions", "append", "context", "end"])
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
  expect(defaults).toContain("Silêncio durante")
  expect(defaults).toContain(`{"text":"pedido","screen":true}`)
  expect(defaults).toContain("nunca a de outros apps")
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

it.effect("master status is read-only data and excludes reasoning from startup history", () =>
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
    const context = yield* makeVoice(
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
          active: () => Effect.succeed({ [sessionID]: { type: "running" } }),
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
    ).context("global")
    expect(context.master).toEqual({ state: "running", text: "Consultando as sessões." })
    expect(JSON.stringify(context)).not.toContain("PRIVATE")
    expect(context.turns).toEqual([turn("voice-user")])
    expect(f.generated).toEqual([])
  }),
)
