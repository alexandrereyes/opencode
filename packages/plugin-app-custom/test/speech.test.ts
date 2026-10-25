import { afterEach, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Effect, Exit, Schema } from "effect"
import { FetchHttpClient } from "effect/http"
import {
  clearPosition,
  defaults,
  duration,
  getPosition,
  info,
  learn,
  rate,
  setPosition,
  synthesize,
  type Options,
  type SpeechContext,
} from "../src/speech"
import { Speech } from "../src/speech/rpc"

const directories: string[] = []
afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

/** 24 kHz 16-bit mono silence (0.1 s by default), the gateway's WAV shape for Gemini TTS. */
function wav(seconds = 0.1) {
  const samples = Math.round(24_000 * seconds)
  const bytes = new Uint8Array(44 + samples * 2)
  const view = new DataView(bytes.buffer)
  const text = (offset: number, value: string) => [...value].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)))
  text(0, "RIFF")
  view.setUint32(4, 36 + samples * 2, true)
  text(8, "WAVEfmt ")
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, 24_000, true)
  view.setUint32(28, 48_000, true)
  view.setUint16(32, 2, true)
  view.setUint16(34, 16, true)
  text(36, "data")
  view.setUint32(40, samples * 2, true)
  return bytes
}

async function gateway(respond: (request: Request) => Response | Promise<Response>) {
  const requests: Array<{ headers: Headers; body: Record<string, unknown>; path: string }> = []
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      requests.push({ headers: request.headers, body: await request.clone().json(), path: new URL(request.url).pathname })
      return respond(request)
    },
  })
  const cache = await fs.mkdtemp(path.join(os.tmpdir(), "speech-test-"))
  directories.push(cache)
  const options: Options = { model: defaults.model, gateway: `http://127.0.0.1:${server.port}/v4/ai`, cache }
  return { requests, options, stop: () => server.stop(true) }
}

const run = (options: Options, key: string | undefined, input: { text: string; voice?: string }) =>
  Effect.runPromiseExit(synthesize(options, Effect.succeed(key), input).pipe(Effect.provide(FetchHttpClient.layer)))

test("calls the gateway speech protocol once and serves the same text from the cache", async () => {
  const fixture = await gateway(() => Response.json({ audio: wav().toBase64(), warnings: [] }))
  try {
    const first = await run(fixture.options, "gateway-key", { text: "Olá, mundo." })
    const second = await run(fixture.options, "gateway-key", { text: "Olá, mundo." })
    expect(Exit.isSuccess(first) && Exit.isSuccess(second)).toBe(true)
    if (!Exit.isSuccess(first) || !Exit.isSuccess(second)) return
    expect(fixture.requests).toHaveLength(1)
    const request = fixture.requests[0]!
    expect(request.path).toBe("/v4/ai/speech-model")
    expect(request.headers.get("authorization")).toBe("Bearer gateway-key")
    expect(request.headers.get("ai-model-id")).toBe("google/gemini-3.8-flash-lite-tts")
    expect(request.headers.get("ai-gateway-protocol-version")).toBe("0.0.1")
    expect(request.headers.get("ai-speech-model-specification-version")).toBe("4")
    expect(request.body).toEqual({
      text: "Olá, mundo.",
      voice: defaults.voice,
      outputFormat: "wav",
      instructions: defaults.instructions,
    })
    // macOS stores AAC through afconvert; other hosts keep the gateway's WAV.
    expect(first.value.mime).toBe(process.platform === "darwin" ? "audio/mp4" : "audio/wav")
    expect(first.value.cached).toBe(false)
    expect(second.value).toEqual({ ...first.value, cached: true })
    expect(await fs.readdir(fixture.options.cache)).toHaveLength(1)
  } finally {
    fixture.stop()
  }
})

test("keys the cache by voice and model", async () => {
  const fixture = await gateway(() => Response.json({ audio: wav().toBase64() }))
  try {
    await run(fixture.options, "key", { text: "Mesmo texto." })
    await run(fixture.options, "key", { text: "Mesmo texto.", voice: "Charon" })
    await run({ ...fixture.options, model: "google/gemini-3.8-flash-tts" }, "key", { text: "Mesmo texto." })
    expect(fixture.requests.map((request) => [request.headers.get("ai-model-id"), request.body.voice])).toEqual([
      ["google/gemini-3.8-flash-lite-tts", "Kore"],
      ["google/gemini-3.8-flash-lite-tts", "Charon"],
      ["google/gemini-3.8-flash-tts", "Kore"],
    ])
  } finally {
    fixture.stop()
  }
})

test("reports a missing Vercel credential without calling the gateway", async () => {
  const fixture = await gateway(() => Response.json({ audio: wav().toBase64() }))
  try {
    const exit = await run(fixture.options, undefined, { text: "Sem chave." })
    expect(Exit.isFailure(exit) && JSON.stringify(exit.cause)).toContain("Speech.Unavailable")
    expect(fixture.requests).toHaveLength(0)
  } finally {
    fixture.stop()
  }
})

test("maps gateway refusals and failures and caches nothing", async () => {
  const status = { value: 403 }
  const fixture = await gateway(() =>
    Response.json({ error: { message: "Speech is not enabled for this team" } }, { status: status.value }),
  )
  try {
    const refused = await run(fixture.options, "key", { text: "Recusado." })
    expect(JSON.stringify(Exit.isFailure(refused) && refused.cause)).toContain("Speech.Unavailable")
    expect(JSON.stringify(Exit.isFailure(refused) && refused.cause)).toContain("Speech is not enabled for this team")
    status.value = 500
    const failed = await run(fixture.options, "key", { text: "Falhou." })
    expect(JSON.stringify(Exit.isFailure(failed) && failed.cause)).toContain("Speech.SynthesisFailed")
    expect(await fs.readdir(fixture.options.cache).catch(() => [])).toHaveLength(0)
  } finally {
    fixture.stop()
  }
})

function storage() {
  const values = new Map<string, Schema.Json>()
  const ctx: Pick<SpeechContext, "storage"> = {
    storage: {
      get: (key) => Effect.sync(() => values.get(key)),
      update: (key, update) =>
        Effect.sync(() => {
          const [next, result] = update(values.get(key))
          values.set(key, next)
          return result
        }),
    },
  }
  return { ctx, values }
}

test("measures WAV durations from the format and data chunks", () => {
  expect(duration(wav(1.5))).toBeCloseTo(1.5, 5)
  expect(duration(new TextEncoder().encode("not a wav file"))).toBeUndefined()
})

test("learns the speaking rate from generated audio, not from cache hits", async () => {
  const fixture = await gateway(() => Response.json({ audio: wav(2).toBase64() }))
  const memory = storage()
  const read = () => Effect.runPromise(info(memory.ctx, fixture.options))
  try {
    expect(await read()).toEqual({
      model: defaults.model,
      voice: "Kore",
      maxCharacters: 2_000,
      charactersPerSecond: defaults.charactersPerSecond,
      usdPerSecond: defaults.usdPerSecond,
    })
    const input = { text: "Trinta caracteres exatos aqui." }
    const generate = () =>
      Effect.runPromise(
        synthesize(fixture.options, Effect.succeed("key"), input, {
          rate: Effect.succeed(defaults.charactersPerSecond),
          learn: (seconds) => learn(memory.ctx, fixture.options, input, seconds),
        }).pipe(Effect.provide(FetchHttpClient.layer)),
      )
    await generate()
    await generate()
    expect(fixture.requests).toHaveLength(1)
    expect((await read()).charactersPerSecond).toBe(rate({ characters: 30, seconds: 2 }))
  } finally {
    fixture.stop()
  }
  // The prior fades as audio accumulates: 20,000 characters in 2,000 s settle near 10 per second.
  expect(rate({ characters: 0, seconds: 0 })).toBe(defaults.charactersPerSecond)
  expect(rate({ characters: 20_000, seconds: 2_000 })).toBeGreaterThan(10)
  expect(rate({ characters: 20_000, seconds: 2_000 })).toBeLessThan(10.5)
})

test("generates again audio that stopped early, cached or fresh, and learns only from plausible audio", async () => {
  // 300 characters at 14 per second need about 21 s; 1 s means the model stopped early.
  const lengths = [1, 20, 1, 1, 18]
  const fixture = await gateway(() => Response.json({ audio: wav(lengths.shift() ?? 18).toBase64() }))
  const learned: number[] = []
  const input = { text: "Uma frase comprida o bastante para ser julgada. ".repeat(7).slice(0, 300) }
  const call = () =>
    Effect.runPromise(
      synthesize(fixture.options, Effect.succeed("key"), input, {
        rate: Effect.succeed(14),
        learn: (seconds) => Effect.sync(() => learned.push(seconds)),
      }).pipe(Effect.provide(FetchHttpClient.layer)),
    )
  try {
    expect((await call()).cached).toBe(false)
    expect(fixture.requests).toHaveLength(2)
    expect(learned).toEqual([20])
    // Served from the cache while it is plausible.
    expect((await call()).cached).toBe(true)
    expect(fixture.requests).toHaveLength(2)
    // A retry that stays short keeps the longer audio and teaches nothing.
    const other = { text: input.text.replace("Uma", "Outra") }
    await Effect.runPromise(
      synthesize(fixture.options, Effect.succeed("key"), other, {
        rate: Effect.succeed(14),
        learn: (seconds) => Effect.sync(() => learned.push(seconds)),
      }).pipe(Effect.provide(FetchHttpClient.layer)),
    )
    expect(fixture.requests).toHaveLength(4)
    expect(learned).toEqual([20])
    // That short audio is not trusted from the cache either: the next request generates it again.
    const again = await Effect.runPromise(
      synthesize(fixture.options, Effect.succeed("key"), other, {
        rate: Effect.succeed(14),
        learn: (seconds) => Effect.sync(() => learned.push(seconds)),
      }).pipe(Effect.provide(FetchHttpClient.layer)),
    )
    expect(again.cached).toBe(false)
    expect(fixture.requests).toHaveLength(5)
    expect(learned).toEqual([20, 18])
  } finally {
    fixture.stop()
  }
})

test("saves, reads and clears a reading position per file", async () => {
  const memory = storage()
  const position = {
    path: "/repo/docs/guia.md",
    hash: "a".repeat(64),
    offset: 140,
    characters: 3_000,
    sentence: "Enquanto um trecho toca, os dois seguintes já estão sendo preparados.",
    seconds: 10,
  }
  expect(await Effect.runPromise(getPosition(memory.ctx, position.path))).toBeUndefined()
  const saved = await Effect.runPromise(setPosition(memory.ctx, position))
  expect(saved).toMatchObject(position)
  expect(await Effect.runPromise(getPosition(memory.ctx, position.path))).toEqual(saved)
  // An offset past the end is kept at the end.
  expect((await Effect.runPromise(setPosition(memory.ctx, { ...position, offset: 9_999 }))).offset).toBe(3_000)
  // A changed document saves its new hash over the old entry; the app relocates by sentence (OpenCodeKit ReadAloud).
  await Effect.runPromise(setPosition(memory.ctx, { ...position, hash: "c".repeat(64), offset: 90 }))
  expect(await Effect.runPromise(getPosition(memory.ctx, position.path))).toMatchObject({ hash: "c".repeat(64), offset: 90 })
  await Effect.runPromise(clearPosition(memory.ctx, position.path))
  expect(await Effect.runPromise(getPosition(memory.ctx, position.path))).toBeUndefined()
})

test("keeps chat response places by session and message, apart from files", async () => {
  const memory = storage()
  const key = Speech.messageKey("ses_conversa", "msg_resposta")
  expect(key).toBe("message:ses_conversa/msg_resposta")
  const position = { path: key, hash: "d".repeat(64), offset: 50, characters: 400, sentence: "Uma frase.", seconds: 4 }
  await Effect.runPromise(setPosition(memory.ctx, position))
  // Many listened responses never push out a file's place.
  await Effect.runPromise(
    setPosition(memory.ctx, { path: "/docs/guia.md", hash: "e".repeat(64), offset: 10, characters: 90, sentence: "" }),
  )
  for (const index of Array.from({ length: Speech.maxPositions + 3 }, (_, index) => index))
    await Effect.runPromise(setPosition(memory.ctx, { ...position, path: Speech.messageKey("ses_outra", `msg_${index}`) }))
  expect(await Effect.runPromise(getPosition(memory.ctx, "/docs/guia.md"))).toMatchObject({ offset: 10 })
  expect(await Effect.runPromise(getPosition(memory.ctx, key))).toBeUndefined()
  const kept = memory.values.get("speech:positions") as Array<{ path: string }>
  expect(kept.filter((item) => item.path.startsWith("message:"))).toHaveLength(Speech.maxPositions)
  expect(kept[0]?.path).toBe(Speech.messageKey("ses_outra", `msg_${Speech.maxPositions + 2}`))
  await Effect.runPromise(clearPosition(memory.ctx, kept[0]!.path))
  expect(await Effect.runPromise(getPosition(memory.ctx, kept[0]!.path))).toBeUndefined()
})

test("keeps only the most recently saved positions", async () => {
  const memory = storage()
  const save = (index: number) =>
    Effect.runPromise(
      setPosition(memory.ctx, { path: `/docs/${index}.md`, hash: "b".repeat(64), offset: index, characters: 500, sentence: "" }),
    )
  for (const index of Array.from({ length: Speech.maxPositions + 5 }, (_, index) => index)) await save(index)
  // Saving an old one again moves it to the front instead of duplicating it.
  await save(10)
  const kept = memory.values.get("speech:positions") as Array<{ path: string }>
  expect(kept).toHaveLength(Speech.maxPositions)
  expect(kept[0]?.path).toBe("/docs/10.md")
  expect(kept.filter((item) => item.path === "/docs/10.md")).toHaveLength(1)
  expect(await Effect.runPromise(getPosition(memory.ctx, "/docs/0.md"))).toBeUndefined()
  expect(await Effect.runPromise(getPosition(memory.ctx, "/docs/204.md"))).toBeDefined()
})

// Opt-in, paid (a fraction of a cent): OPENCODE_SPEECH_LIVE=1 AI_GATEWAY_API_KEY=… bun test test/speech.test.ts
test.skipIf(!process.env.OPENCODE_SPEECH_LIVE || !process.env.AI_GATEWAY_API_KEY)(
  "generates Brazilian Portuguese speech through the real gateway",
  async () => {
    const cache = await fs.mkdtemp(path.join(os.tmpdir(), "speech-live-"))
    directories.push(cache)
    const exit = await run({ model: defaults.model, gateway: defaults.gateway, cache }, process.env.AI_GATEWAY_API_KEY, {
      text: "Teste curto.",
    })
    expect(Exit.isSuccess(exit)).toBe(true)
    if (Exit.isSuccess(exit)) expect(Uint8Array.fromBase64(exit.value.audio).length).toBeGreaterThan(1_000)
  },
  60_000,
)
