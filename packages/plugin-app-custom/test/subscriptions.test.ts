import { expect, test } from "bun:test"
import { ConfigProvider, Effect } from "effect"
import { read } from "../src/subscriptions"

const withProxy = <A>(url: string, effect: Effect.Effect<A>) =>
  effect.pipe(Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnv({ env: { OPENCODE_LLM_PROXY_URL: url } }))))

test("normalizes quota metadata without returning account secrets and preserves unknown usage", async () => {
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      expect(new URL(request.url).pathname).toBe("/_admin/status")
      return Response.json({
        oauth: { accessToken: "oauth-private" },
        accounts: [
          {
            account: {
              id: "one",
              name: "Subscription",
              email: "one@example.test",
              enabled: true,
              token: "private",
              planType: "plus",
              authenticationState: "Authenticated",
            },
            cooldownSeconds: 12,
            usage: {
              weeklyPercent: 125,
              weeklyResetAt: "2026-09-15T02:15:47Z",
              observedAt: "2026-09-09T20:00:00Z",
              hasCapacity: false,
              planType: "pro",
              credential: "usage-private",
            },
            usageAgeSeconds: 4000,
            bankedResets: {
              available: 3,
              earliestExpiresAt: "2026-10-01T12:00:00Z",
              latestExpiresAt: null,
              nonExpiring: 1,
              token: "bank-private",
            },
          },
          {
            account: {
              id: "two",
              name: null,
              email: "two@example.test",
              enabled: false,
              planType: "pro",
              authenticationState: "ReauthenticationRequired",
            },
            cooldownSeconds: 0,
            usage: null,
            usageAgeSeconds: null,
          },
        ],
      })
    },
  })
  const result = await Effect.runPromise(
    withProxy(server.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => server.stop(true)))),
  )
  expect(result).toEqual({
    status: "ok",
    accounts: [
      {
        id: "one",
        name: "Subscription",
        enabled: true,
        plan: "pro",
        authenticated: true,
        cooldownSeconds: 12,
        bankedResets: {
          available: 3,
          earliestExpiresAt: "2026-10-01T12:00:00Z",
          latestExpiresAt: null,
          nonExpiring: 1,
        },
        remaining: 0,
        resetAt: "2026-09-15T02:15:47Z",
        observedAt: "2026-09-09T20:00:00Z",
        stale: true,
        hasCapacity: false,
      },
      {
        id: "two",
        name: "two@example.test",
        enabled: false,
        plan: "pro",
        authenticated: false,
        cooldownSeconds: 0,
        bankedResets: null,
        remaining: null,
        resetAt: null,
        observedAt: null,
        stale: true,
        hasCapacity: null,
      },
    ],
  })
  expect(JSON.stringify(result)).not.toContain("private")
})

test("returns explicit states for missing configuration and failed or malformed responses", async () => {
  expect(await Effect.runPromise(withProxy("", read()))).toEqual({ status: "unconfigured", accounts: [] })
  const failed = Bun.serve({ port: 0, fetch: () => new Response("no", { status: 503 }) })
  expect(
    await Effect.runPromise(
      withProxy(failed.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => failed.stop(true)))),
    ),
  ).toEqual({ status: "unavailable", accounts: [] })
  const malformed = Bun.serve({ port: 0, fetch: () => Response.json({ unexpected: true }) })
  expect(
    await Effect.runPromise(
      withProxy(malformed.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => malformed.stop(true)))),
    ),
  ).toEqual({ status: "unavailable", accounts: [] })
})

test("times out an unresponsive proxy after eight seconds", async () => {
  const server = Bun.serve({ port: 0, fetch: () => new Promise<Response>(() => {}) })
  const started = performance.now()
  const result = await Effect.runPromise(
    withProxy(server.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => server.stop(true)))),
  )
  expect(result).toEqual({ status: "unavailable", accounts: [] })
  expect(performance.now() - started).toBeGreaterThanOrEqual(7_500)
}, 10_000)

test("cancels the upstream request when the RPC work is interrupted", async () => {
  const requested = Promise.withResolvers<Request>()
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      requested.resolve(request)
      return new Promise<Response>(() => {})
    },
  })
  const controller = new AbortController()
  const pending = Effect.runPromise(withProxy(server.url.toString(), read()), { signal: controller.signal })
  const request = await requested.promise
  const aborted = Promise.withResolvers<void>()
  request.signal.addEventListener("abort", () => aborted.resolve(), { once: true })
  controller.abort()
  await expect(pending).rejects.toThrow()
  await aborted.promise
  server.stop(true)
})
