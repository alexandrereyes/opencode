import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { Plugin } from "@opencode/plugin/effect"
import { Config, Effect, Schema } from "effect"
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/http"
import { Speech } from "./rpc.js"

/** The one place that names the speech model; `OPENCODE_SPEECH_MODEL` overrides it (e.g. `google/gemini-3.8-flash-tts`). */
export const defaults = {
  model: "google/gemini-3.8-flash-lite-tts",
  voice: "Kore",
  gateway: "https://ai-gateway.vercel.sh/v4/ai",
  // Gemini TTS follows a natural-language direction; it is not read aloud.
  instructions: "Leia em português do Brasil, com sotaque brasileiro natural, em ritmo calmo de narração.",
  // Measured on pt-BR prose with this model and voice (11–14 characters per second).
  charactersPerSecond: 12,
  // Gemini audio output is 25 tokens per second at $6 per million output tokens.
  usdPerSecond: 0.00015,
} as const

const cacheDays = 30

export type Options = {
  readonly model: string
  readonly gateway: string
  readonly cache: string
}

export type SpeechContext = { integration: Pick<Plugin.Context["integration"], "connection"> }

export class Unavailable extends Schema.TaggedError<Unavailable>()("Speech.Unavailable", { message: Schema.String }) {}
export class SynthesisFailed extends Schema.TaggedError<SynthesisFailed>()("Speech.SynthesisFailed", {
  message: Schema.String,
}) {}

export const registerSpeech = Effect.fn("Speech.register")(function* (ctx: Plugin.Context) {
  const options = yield* readOptions
  yield* prune(options.cache).pipe(Effect.ignore, Effect.forkScoped)
  yield* ctx.rpc
    .register(Speech.Definition, {
      info: () => Effect.succeed(info(options)),
      synthesize: (input, context) =>
        synthesize(options, gatewayKey(ctx), input).pipe(
          Effect.provide(FetchHttpClient.layer),
          Effect.mapError((error) =>
            error._tag === "Speech.Unavailable"
              ? context.error("unavailable", error.message, { message: error.message })
              : context.error("synthesis_failed", error.message, { message: error.message }),
          ),
        ),
    })
    .pipe(Effect.orDie)
})

export const readOptions = Effect.gen(function* () {
  const model = yield* Config.String("OPENCODE_SPEECH_MODEL").pipe(Config.withDefault(defaults.model))
  const gateway = yield* Config.String("OPENCODE_SPEECH_GATEWAY_URL").pipe(Config.withDefault(defaults.gateway))
  const cache = yield* Config.String("XDG_CACHE_HOME").pipe(Config.withDefault(path.join(os.homedir(), ".cache")))
  return { model, gateway: gateway.replace(/\/+$/, ""), cache: path.join(cache, "opencode", "custom-speech") }
}).pipe(Effect.orDie)

export function info(options: Options): Speech.Info {
  return {
    model: options.model,
    voice: defaults.voice,
    maxCharacters: Speech.maxCharacters,
    charactersPerSecond: defaults.charactersPerSecond,
    usdPerSecond: defaults.usdPerSecond,
  }
}

/** Audio for one piece of text, from the cache when the same model, voice and text were generated before. */
export const synthesize = Effect.fn("Speech.synthesize")(function* (
  options: Options,
  key: Effect.Effect<string | undefined>,
  input: typeof Speech.SynthesizeInput.Type,
) {
  const voice = input.voice ?? defaults.voice
  const hash = new Bun.CryptoHasher("sha256")
    .update(JSON.stringify([options.model, voice, defaults.instructions, input.text]))
    .digest("hex")
  const hit = yield* cached(options.cache, hash)
  if (hit) return { audio: hit.audio.toBase64(), mime: hit.mime, cached: true }
  const apiKey = yield* key
  if (!apiKey)
    return yield* new Unavailable({ message: "Conecte o Vercel AI Gateway com uma chave de API no servidor." })
  const wav = yield* generate(options, apiKey, input.text, voice)
  const stored = yield* store(options.cache, hash, wav)
  return { audio: stored.audio.toBase64(), mime: stored.mime, cached: false }
})

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

function gatewayKey(ctx: SpeechContext) {
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
      return { audio: await file.bytes(), mime: format.mime }
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
