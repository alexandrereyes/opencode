import { describe, expect, test } from "bun:test"
import type { WebSearchDefinition } from "@opencode/plugin/effect/websearch"
import { ConfigProvider, Effect, Fiber } from "effect"
import { HttpClientError } from "effect/unstable/http"
import { registerCodexSearch, search } from "../src/codex-search"

async function registered(env: Record<string, string>) {
  const providers: WebSearchDefinition[] = []
  const defaults: (string | false)[] = []
  await Effect.runPromise(
    registerCodexSearch({
      websearch: {
        transform: (callback) =>
          Effect.sync(() => {
            callback({
              add: (provider) => providers.push(provider),
              default: { get: () => undefined, set: (value) => defaults.push(value) },
            })
            return { dispose: Effect.void }
          }),
      },
    }).pipe(Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnv({ env }))), Effect.scoped),
  )
  return { providers, defaults }
}

describe("Codex Search", () => {
  test("is opt-in through the existing proxy environment and does not override the selected provider", async () => {
    expect(await registered({})).toEqual({ providers: [], defaults: [] })
    expect(await registered({ OPENCODE_LLM_PROXY_URL: "  " })).toEqual({ providers: [], defaults: [] })
    const result = await registered({ OPENCODE_LLM_PROXY_URL: "http://proxy.test" })
    expect(result.providers.map(({ id, name }) => ({ id, name }))).toEqual([{ id: "codex", name: "Codex Search" }])
    expect(result.defaults).toEqual([])
  })

  test("sends only the query in live mode, uses the configured model, and gives each request a fresh ID", async () => {
    const requests: Record<string, unknown>[] = []
    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        expect(new URL(request.url).pathname).toBe("/backend-api/codex/alpha/search")
        expect(request.method).toBe("POST")
        expect(request.headers.get("authorization")).toBeNull()
        expect(request.headers.get("cookie")).toBeNull()
        requests.push(await request.json())
        return Response.json({ output: "", results: [] })
      },
    })
    try {
      const { providers } = await registered({
        OPENCODE_LLM_PROXY_URL: `${server.url}//`,
        OPENCODE_CODEX_SEARCH_MODEL: "search-model",
      })
      await Effect.runPromise(providers[0].execute({ query: "Effect docs" }))
      await Effect.runPromise(providers[0].execute({ query: "Effect docs" }))
      expect(requests).toHaveLength(2)
      expect(requests[0]).toEqual({
        id: expect.stringMatching(/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/),
        model: "search-model",
        commands: { search_query: [{ q: "Effect docs" }], response_length: "medium" },
        settings: { external_web_access: true },
        max_output_tokens: 6000,
      })
      expect(requests[0].id).not.toBe(requests[1].id)
    } finally {
      server.stop(true)
    }
  })

  test("preserves full text and citations, adds text-only sources, and never returns encrypted data", async () => {
    const output = [
      "Effect (https://effect.website)",
      "citeturn0search0 Full article text, longer than the snippet.",
      "-".repeat(80),
      "Other source (https://example.com/other)",
      "citeturn0search1 Another article.",
    ].join("\n")
    const server = Bun.serve({
      port: 0,
      fetch: () =>
        Response.json({
          output,
          encrypted_output: "private-ciphertext",
          results: [
            { type: "text_result", url: "https://effect.website", title: "Effect docs", snippet: "Short snippet" },
            { type: "text_result", url: "https://effect.website", title: "Duplicate" },
            { type: "future_result", opaque: "private-value" },
            { url: "javascript:alert(1)" },
            { url: "file:///private/file" },
            { url: "https://" },
          ],
        }),
    })
    try {
      const result = await Effect.runPromise(search(server.url.toString(), "Effect"))
      expect(result).toEqual([
        { url: "https://effect.website", title: "Effect docs", content: output, time: {} },
        { url: "https://example.com/other", title: "Other source", time: {} },
      ])
      expect(JSON.stringify(result)).not.toContain("private-")
    } finally {
      server.stop(true)
    }
  })

  test.each([{ results: undefined }, { results: null }, { results: [] }])(
    "supports output-only responses with results %p",
    async ({ results }) => {
      const output = "Official docs (https://example.com/docs)\r\nFull document"
      const server = Bun.serve({ port: 0, fetch: () => Response.json({ output, results }) })
      try {
        expect(await Effect.runPromise(search(server.url.toString(), "docs"))).toEqual([
          { url: "https://example.com/docs", title: "Official docs", content: output, time: {} },
        ])
      } finally {
        server.stop(true)
      }
    },
  )

  test("keeps structured snippets when no text output is returned", async () => {
    const server = Bun.serve({
      port: 0,
      fetch: () => Response.json({ output: "", results: [{ url: "https://example.com", snippet: "Excerpt" }] }),
    })
    try {
      expect(await Effect.runPromise(search(server.url.toString(), "docs"))).toEqual([
        { url: "https://example.com", content: "Excerpt", time: {} },
      ])
    } finally {
      server.stop(true)
    }
  })

  test.each(["", "No results found."])("returns an empty list for genuine empty results: %p", async (output) => {
    const server = Bun.serve({ port: 0, fetch: () => Response.json({ output, results: [] }) })
    try {
      expect(await Effect.runPromise(search(server.url.toString(), "unmatched"))).toEqual([])
    } finally {
      server.stop(true)
    }
  })

  test.each([
    { output: "Error parsing function call: invalid commands", results: [] },
    { output: "Unexpected upstream response", results: [] },
    { output: 12, results: [] },
    { output: "", results: "malformed" },
  ])("does not mistake malformed or error payloads for empty results: %p", async (data) => {
    const server = Bun.serve({ port: 0, fetch: () => Response.json(data) })
    try {
      const result = await Effect.runPromise(search(server.url.toString(), "docs").pipe(Effect.result))
      expect(result._tag).toBe("Failure")
    } finally {
      server.stop(true)
    }
  })

  test.each([401, 429, 500])(
    "preserves HTTP %i for the native provider selection and does not retry",
    async (status) => {
      const requests: string[] = []
      const server = Bun.serve({
        port: 0,
        fetch(request) {
          requests.push(request.url)
          return new Response("private upstream error", { status, headers: { "Retry-After": "10" } })
        },
      })
      try {
        const result = await Effect.runPromise(search(server.url.toString(), "docs").pipe(Effect.flip))
        expect(HttpClientError.isHttpClientError(result)).toBe(true)
        if (HttpClientError.isHttpClientError(result)) {
          expect(result.response?.status).toBe(status)
          expect(result.response?.headers["retry-after"]).toBe("10")
        }
        expect(requests).toHaveLength(1)
      } finally {
        server.stop(true)
      }
    },
  )

  test("reports invalid JSON as a failure", async () => {
    const server = Bun.serve({ port: 0, fetch: () => new Response("not JSON") })
    try {
      expect((await Effect.runPromise(search(server.url.toString(), "docs").pipe(Effect.result)))._tag).toBe("Failure")
    } finally {
      server.stop(true)
    }
  })

  test("reports an unavailable proxy without returning empty results", async () => {
    const server = Bun.serve({ port: 0, fetch: () => new Response() })
    const url = server.url.toString()
    server.stop(true)
    const result = await Effect.runPromise(search(url, "docs").pipe(Effect.flip))
    expect(HttpClientError.isHttpClientError(result)).toBe(true)
  })

  test("interrupting a search cancels the in-flight HTTP body", async () => {
    const started = Promise.withResolvers<void>()
    const aborted = Promise.withResolvers<void>()
    const server = Bun.serve({
      port: 0,
      fetch(request) {
        request.signal.addEventListener("abort", () => aborted.resolve(), { once: true })
        return new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new TextEncoder().encode('{"output":"'))
              started.resolve()
            },
            cancel: () => aborted.resolve(),
          }),
        )
      },
    })
    try {
      const fiber = Effect.runFork(search(server.url.toString(), "slow"))
      await started.promise
      await Effect.runPromise(Fiber.interrupt(fiber))
      await aborted.promise
    } finally {
      server.stop(true)
    }
  })
})
