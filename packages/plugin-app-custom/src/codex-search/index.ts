import type { Plugin, WebSearch } from "@opencode/plugin/effect"
import { Config, Effect, Schema } from "effect"
import { FetchHttpClient, HttpClient, HttpClientRequest } from "effect/http"

const SearchResponse = Schema.Struct({
  output: Schema.String,
  results: Schema.optional(
    Schema.NullOr(
      Schema.Array(
        Schema.Struct({
          url: Schema.optional(Schema.String),
          title: Schema.optional(Schema.NullOr(Schema.String)),
          snippet: Schema.optional(Schema.NullOr(Schema.String)),
        }),
      ),
    ),
  ),
})

export const registerCodexSearch = Effect.fn("CodexSearch.register")(function* (ctx: {
  websearch: Pick<Plugin.Context["websearch"], "transform">
}) {
  const url = yield* Config.String("OPENCODE_LLM_PROXY_URL").pipe(Config.withDefault(""), Effect.orDie)
  if (!url.trim()) return
  const model = yield* Config.String("OPENCODE_CODEX_SEARCH_MODEL").pipe(
    Config.withDefault("gpt-6-astra"),
    Effect.orDie,
  )
  yield* ctx.websearch.transform((editor) => {
    editor.add({
      id: "codex",
      name: "Codex Search",
      execute: ({ query }) => search(url, query, model),
    })
  })
})

export const search = Effect.fn("CodexSearch.search")(function* (
  baseURL: string,
  query: string,
  model = "gpt-6-astra",
) {
  return yield* Effect.gen(function* () {
    const http = yield* HttpClient.HttpClient
    const response = yield* HttpClient.withScope(HttpClient.filterStatusOk(http)).execute(
      HttpClientRequest.post(`${baseURL.trim().replace(/\/+$/, "")}/backend-api/codex/alpha/search`).pipe(
        HttpClientRequest.acceptJson,
        HttpClientRequest.bodyJsonUnsafe({
          // Standalone searches do not reuse account-scoped references across requests.
          id: crypto.randomUUID(),
          model,
          commands: { search_query: [{ q: query }], response_length: "medium" },
          settings: { external_web_access: true },
          max_output_tokens: 6000,
        }),
      ),
    )
    const data = yield* Schema.decodeUnknownEffect(SearchResponse)(yield* response.json)
    const results = sources(data)
    if (!results.length && data.output.trim() && !/^no (?:web |search )?results\b/i.test(data.output.trim()))
      return yield* Effect.fail(new Error("Codex search returned content without usable source URLs"))
    // Preserve the complete tool output once, including citations and sources omitted from results[].
    return results.map((result, index) =>
      index === 0 && data.output.trim() ? { ...result, content: data.output } : result,
    )
  }).pipe(Effect.scoped, Effect.timeout("30 seconds"), Effect.provide(FetchHttpClient.layer))
})

function sources(data: typeof SearchResponse.Type) {
  const results = new Map<string, WebSearch.Result>()
  for (const result of data.results ?? []) {
    if (!result.url || !webURL(result.url) || results.has(result.url)) continue
    results.set(result.url, {
      url: result.url,
      ...(result.title ? { title: result.title } : {}),
      ...(result.snippet ? { content: result.snippet } : {}),
      time: {},
    })
  }
  // The Codex text format includes source headers even when structured results are absent/incomplete.
  for (const match of data.output.matchAll(/^([^\r\n]+) \((https?:\/\/[^\s]+)\)\r?$/gm)) {
    if (!webURL(match[2]) || results.has(match[2])) continue
    results.set(match[2], { url: match[2], title: match[1], time: {} })
  }
  return Array.from(results.values())
}

function webURL(value: string) {
  return /^https?:\/\//i.test(value) && URL.canParse(value)
}
