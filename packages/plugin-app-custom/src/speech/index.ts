import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Plugin } from "@opencode/plugin/effect"
import { Clock, Config, Effect, Option, Schema } from "effect"
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/http"
import { Speech } from "./rpc.js"

/** The one place that names the speech model; `OPENCODE_SPEECH_MODEL` overrides it (e.g. `google/gemini-3.8-flash-tts`). */
export const defaults = {
  model: "google/gemini-3.8-flash-lite-tts",
  voice: "Kore",
  gateway: "https://ai-gateway.vercel.sh/v4/ai",
  // Gemini TTS follows a natural-language direction; it is not read aloud.
  instructions: "Leia em português do Brasil, com sotaque brasileiro natural, em ritmo calmo de narração.",
  // Starting rate before this server has generated audio (pt-BR prose measured at 11–15 characters per second).
  charactersPerSecond: 14,
  // Gemini audio output is 25 tokens per second at $6 per million output tokens.
  usdPerSecond: 0.00015,
} as const

const cacheDays = 30

export type Options = {
  readonly model: string
  readonly gateway: string
  readonly cache: string
}

export type SpeechContext = {
  integration: Pick<Plugin.Context["integration"], "connection">
  storage: Pick<Plugin.Context["storage"], "get" | "update">
}

/** The starting rate counts as this many characters, so the first pieces move the estimate without jolting it. */
const priorCharacters = 2_000
/** Above this many characters both sums halve, so the rate follows recent audio. */
const rateWindow = 200_000

export class Unavailable extends Schema.TaggedError<Unavailable>()("Speech.Unavailable", { message: Schema.String }) {}
export class SynthesisFailed extends Schema.TaggedError<SynthesisFailed>()("Speech.SynthesisFailed", {
  message: Schema.String,
}) {}

export const registerSpeech = Effect.fn("Speech.register")(function* (ctx: Plugin.Context) {
  const options = yield* readOptions
  yield* prune(options.cache).pipe(Effect.ignore, Effect.forkScoped)
  yield* ctx.rpc
    .register(Speech.Definition, {
      info: () => info(ctx, options),
      synthesize: (input, context) =>
        synthesize(options, gatewayKey(ctx), input, {
          rate: info(ctx, options).pipe(Effect.map((value) => value.charactersPerSecond)),
          learn: (seconds) => learn(ctx, options, input, seconds),
        }).pipe(
          Effect.provide(FetchHttpClient.layer),
          Effect.mapError((error) =>
            error._tag === "Speech.Unavailable"
              ? context.error("unavailable", error.message, { message: error.message })
              : context.error("synthesis_failed", error.message, { message: error.message }),
          ),
        ),
      getPosition: (input) => getPosition(ctx, input.path).pipe(Effect.map((position) => ({ position: position ?? null }))),
      setPosition: (input) => setPosition(ctx, input),
      clearPosition: (input) => clearPosition(ctx, input.path).pipe(Effect.as({})),
    })
    .pipe(Effect.orDie)
})

export const readOptions = Effect.gen(function* () {
  const model = yield* Config.String("OPENCODE_SPEECH_MODEL").pipe(Config.withDefault(defaults.model))
  const gateway = yield* Config.String("OPENCODE_SPEECH_GATEWAY_URL").pipe(Config.withDefault(defaults.gateway))
  const cache = yield* Config.String("XDG_CACHE_HOME").pipe(Config.withDefault(path.join(os.homedir(), ".cache")))
  return { model, gateway: gateway.replace(/\/+$/, ""), cache: path.join(cache, "opencode", "custom-speech") }
}).pipe(Effect.orDie)

export const info = Effect.fn("Speech.info")(function* (ctx: Pick<SpeechContext, "storage">, options: Options) {
  const sums = decodeRate(yield* ctx.storage.get(rateKey(options.model, defaults.voice)))
  return {
    model: options.model,
    voice: defaults.voice,
    maxCharacters: Speech.maxCharacters,
    charactersPerSecond: rate(sums),
    usdPerSecond: defaults.usdPerSecond,
  } satisfies Speech.Info
})

/** Characters per second, weighted by characters: the sums of generated text and audio plus the starting prior. */
export function rate(sums: RateSums) {
  return (priorCharacters + sums.characters) / (priorCharacters / defaults.charactersPerSecond + sums.seconds)
}

const RateSums = Schema.Struct({ characters: Schema.Finite, seconds: Schema.Finite })
type RateSums = typeof RateSums.Type
const decodeRate = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(RateSums)(value), () => ({ characters: 0, seconds: 0 }))
const rateKey = (model: string, voice: string) => `speech:rate:${model}:${voice}`

/** Each generated piece adds its text length and audio length; cache hits add nothing. */
export function learn(ctx: Pick<SpeechContext, "storage">, options: Options, input: typeof Speech.SynthesizeInput.Type, seconds: number) {
  return ctx.storage.update(rateKey(options.model, input.voice ?? defaults.voice), (current) => {
    const sums = decodeRate(current)
    const next = { characters: sums.characters + input.text.length, seconds: sums.seconds + seconds }
    const scale = next.characters > rateWindow ? 0.5 : 1
    return [{ characters: next.characters * scale, seconds: next.seconds * scale }, undefined] as const
  })
}

const positionsKey = "speech:positions"
const Positions = Schema.Array(Speech.Position)
const decodePositions = (value: Schema.Json | undefined) =>
  Option.getOrElse(Schema.decodeUnknownOption(Positions)(value), (): ReadonlyArray<Speech.Position> => [])
const encodePositions = Schema.encodeSync(Positions)

export function getPosition(ctx: Pick<SpeechContext, "storage">, file: string) {
  return ctx.storage.get(positionsKey).pipe(Effect.map((value) => decodePositions(value).find((item) => item.path === file)))
}

/** Saving moves the document to the front; only the most recent `maxPositions` documents are kept. */
export const setPosition = Effect.fn("Speech.setPosition")(function* (
  ctx: Pick<SpeechContext, "storage">,
  input: typeof Speech.PositionInput.Type,
) {
  const now = yield* Clock.currentTimeMillis
  const position: Speech.Position = { ...input, offset: Math.min(input.offset, input.characters), updatedAt: now }
  return yield* ctx.storage.update(positionsKey, (current) => [
    encodePositions([position, ...decodePositions(current).filter((item) => item.path !== input.path)].slice(0, Speech.maxPositions)),
    position,
  ])
})

export function clearPosition(ctx: Pick<SpeechContext, "storage">, file: string) {
  return ctx.storage.update(positionsKey, (current) => [
    encodePositions(decodePositions(current).filter((item) => item.path !== file)),
    undefined,
  ])
}

/** Audio for one piece of text, from the cache when the same model, voice and text were generated before. */
export type Learning = {
  /** Characters per second expected from this model and voice. */
  readonly rate: Effect.Effect<number>
  /** Records a generated piece that was accepted. */
  readonly learn: (seconds: number) => Effect.Effect<unknown>
}

const fixedRate: Learning = { rate: Effect.succeed(defaults.charactersPerSecond), learn: () => Effect.void }

/** Below this share of the expected length (11–17 characters per second is normal), a piece stopped early. */
const truncated = 0.6
/** Short pieces vary too much to judge. */
const judgedCharacters = 300

/** Audio for one piece, from the cache when the same model, voice and text were generated before. Gemini TTS
 * sometimes stops early on long text, which would silently skip it: such audio (fresh or cached) is generated once
 * more, the longer result is kept, and only audio of plausible length teaches the speaking rate. */
export const synthesize = Effect.fn("Speech.synthesize")(function* (
  options: Options,
  key: Effect.Effect<string | undefined>,
  input: typeof Speech.SynthesizeInput.Type,
  learning: Learning = fixedRate,
) {
  const voice = input.voice ?? defaults.voice
  const hash = new Bun.CryptoHasher("sha256")
    .update(JSON.stringify([options.model, voice, defaults.instructions, input.text]))
    .digest("hex")
  const expected = input.text.length / (yield* learning.rate)
  const short = (seconds: number | undefined) =>
    input.text.length >= judgedCharacters && seconds !== undefined && seconds < expected * truncated
  const hit = yield* cached(options.cache, hash)
  if (hit && !short(yield* stored(hit))) return { audio: hit.audio.toBase64(), mime: hit.mime, cached: true }
  const apiKey = yield* key
  if (!apiKey)
    return yield* new Unavailable({ message: "Conecte o Vercel AI Gateway com uma chave de API no servidor." })
  const first = yield* generate(options, apiKey, input.text, voice)
  const second = short(duration(first)) ? yield* generate(options, apiKey, input.text, voice) : undefined
  const wav = second && (duration(second) ?? 0) > (duration(first) ?? 0) ? second : first
  const seconds = duration(wav)
  if (seconds && !short(seconds)) yield* learning.learn(seconds)
  if (seconds && short(seconds)) yield* Effect.logWarning("speech stayed short after a retry", { seconds, expected })
  const saved = yield* store(options.cache, hash, wav)
  return { audio: saved.audio.toBase64(), mime: saved.mime, cached: false }
})

/** Seconds of cached audio: WAV from its header, AAC through `afinfo` on macOS. */
function stored(audio: { audio: Uint8Array; mime: string; file: string }) {
  if (audio.mime === "audio/wav") return Effect.succeed(duration(audio.audio))
  return Effect.promise(async () => {
    if (process.platform !== "darwin") return undefined
    const child = Bun.spawn(["/usr/bin/afinfo", audio.file], { stdin: "ignore", stdout: "pipe", stderr: "ignore" })
    const output = await new Response(child.stdout).text()
    await child.exited
    const match = /estimated duration: ([\d.]+) sec/.exec(output)
    return match ? Number(match[1]) : undefined
  })
}

const GatewayAudio = Schema.Struct({ audio: Schema.String, warnings: Schema.optional(Schema.Array(Schema.Unknown)) })
const GatewayError = Schema.Struct({ error: Schema.Struct({ message: Schema.String }) })

const generate = Effect.fn("Speech.generate")(function* (options: Options, apiKey: string, text: string, voice: string) {
  const http = yield* HttpClient.HttpClient
  const response = yield* http
    .execute(
      HttpClientRequest.post(`${options.gateway}/speech-model`).pipe(
        HttpClientRequest.setHeaders({
          authorization: `Bearer ${apiKey}`,
          "ai-gateway-auth-method": "api-key",
          "ai-gateway-protocol-version": "0.0.1",
          "ai-speech-model-specification-version": "4",
          "ai-model-id": options.model,
        }),
        HttpClientRequest.bodyJsonUnsafe({ text, voice, outputFormat: "wav", instructions: defaults.instructions }),
      ),
    )
    .pipe(
      Effect.timeout("90 seconds"),
      Effect.mapError(() => new SynthesisFailed({ message: "O AI Gateway não respondeu." })),
    )
  const body = yield* response.json.pipe(Effect.orElseSucceed(() => undefined))
  if (response.status !== 200) {
    const detail = Schema.decodeUnknownOption(GatewayError)(body)
    const message = detail._tag === "Some" ? detail.value.error.message : `HTTP ${response.status}`
    return yield* response.status === 401 || response.status === 403
      ? new Unavailable({ message: `O AI Gateway recusou a chave: ${message}` })
      : new SynthesisFailed({ message: `O AI Gateway não gerou a fala: ${message}` })
  }
  const decoded = yield* Schema.decodeUnknownEffect(GatewayAudio)(body).pipe(
    Effect.mapError(() => new SynthesisFailed({ message: "O AI Gateway devolveu uma resposta inesperada." })),
  )
  if (decoded.warnings?.length) yield* Effect.logWarning("speech gateway warnings", { warnings: decoded.warnings })
  return Uint8Array.fromBase64(decoded.audio)
})

/** Seconds of a PCM WAV from its `fmt ` byte rate and `data` size; undefined for anything else. */
export function duration(wav: Uint8Array) {
  const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength)
  const tag = (offset: number) => String.fromCharCode(...wav.subarray(offset, offset + 4))
  if (wav.length < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return undefined
  const chunks = (offset: number, byteRate?: number): number | undefined => {
    if (offset + 8 > wav.length) return undefined
    const size = view.getUint32(offset + 4, true)
    if (tag(offset) === "fmt ") return chunks(offset + 8 + size + (size % 2), view.getUint32(offset + 16, true))
    // Streamed WAVs may leave the data size at its maximum; the bytes present are what plays.
    if (tag(offset) === "data") return byteRate ? Math.min(size, wav.length - offset - 8) / byteRate : undefined
    return chunks(offset + 8 + size + (size % 2), byteRate)
  }
  return chunks(12)
}

function gatewayKey(ctx: Pick<SpeechContext, "integration">) {
  return Effect.gen(function* () {
    const connection = yield* ctx.integration.connection.active("vercel")
    if (!connection) return undefined
    const credential = yield* ctx.integration.connection.resolve(connection).pipe(Effect.orElseSucceed(() => undefined))
    return credential?.type === "key" ? credential.key : undefined
  })
}

const formats = [
  { extension: "m4a", mime: "audio/mp4" },
  { extension: "wav", mime: "audio/wav" },
] as const

function cached(directory: string, hash: string) {
  return Effect.promise(async () => {
    for (const format of formats) {
      const name = path.join(directory, `${hash}.${format.extension}`)
      const file = Bun.file(name)
      if (!(await file.exists())) continue
      const now = new Date()
      await fs.utimes(name, now, now)
      return { audio: await file.bytes(), mime: format.mime, file: name }
    }
    return undefined
  })
}

/** AAC is about a tenth of the gateway's WAV, which matters on a phone; WAV is kept when `afconvert` is missing. */
function store(directory: string, hash: string, wav: Uint8Array) {
  return Effect.promise(async () => {
    await fs.mkdir(directory, { recursive: true, mode: 0o700 })
    const pending = path.join(directory, `${hash}.${crypto.randomUUID()}`)
    await Bun.write(`${pending}.wav`, wav)
    const converted = await transcode(`${pending}.wav`, `${pending}.m4a`)
    const format = converted ? formats[0] : formats[1]
    await fs.rename(`${pending}.${format.extension}`, path.join(directory, `${hash}.${format.extension}`))
    await fs.rm(`${pending}.wav`, { force: true })
    return { audio: await Bun.file(path.join(directory, `${hash}.${format.extension}`)).bytes(), mime: format.mime }
  })
}

async function transcode(from: string, to: string) {
  if (process.platform !== "darwin") return false
  const child = Bun.spawn(["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", "-b", "48000", from, to], {
    stdin: "ignore",
    stdout: "ignore",
    stderr: "ignore",
  })
  if ((await child.exited) === 0) return true
  await fs.rm(to, { force: true })
  return false
}

/** Pieces not played in the last month are dropped at startup; each one is cheap to regenerate. */
function prune(directory: string) {
  return Effect.tryPromise(async () => {
    const limit = Date.now() - cacheDays * 24 * 60 * 60 * 1000
    const entries = await fs.readdir(directory)
    await Promise.all(
      entries.map(async (name) => {
        const file = path.join(directory, name)
        if ((await fs.stat(file)).mtimeMs < limit) await fs.rm(file, { force: true })
      }),
    )
  })
}
