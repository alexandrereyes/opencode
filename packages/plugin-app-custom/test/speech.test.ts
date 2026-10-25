import { afterEach, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Effect, Exit } from "effect"
import { FetchHttpClient } from "effect/http"
import { defaults, info, synthesize, type Options } from "../src/speech"

const directories: string[] = []
afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

/** 0.1 s of 24 kHz 16-bit mono silence, the gateway's WAV shape for Gemini TTS. */
function wav() {
  const samples = 2_400
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

test("info exposes the configured model and the estimate inputs", () => {
  expect(info({ model: "google/gemini-3.8-flash-tts", gateway: "", cache: "" })).toEqual({
    model: "google/gemini-3.8-flash-tts",
    voice: "Kore",
    maxCharacters: 2_000,
    charactersPerSecond: defaults.charactersPerSecond,
    usdPerSecond: defaults.usdPerSecond,
  })
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
