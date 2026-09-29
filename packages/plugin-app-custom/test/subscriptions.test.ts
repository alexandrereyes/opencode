import { expect, test } from "bun:test"
import { ConfigProvider, Effect } from "effect"
import { consumeReset, read, writeAutomation } from "../src/subscriptions"

const withProxy = <A>(url: string, effect: Effect.Effect<A>) =>
  effect.pipe(Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnv({ env: { OPENCODE_LLM_PROXY_URL: url } }))))

test("normalizes quota metadata without returning account secrets and preserves unknown usage", async () => {
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      if (new URL(request.url).pathname === "/_admin/anthropic/status") return new Response("missing", { status: 404 })
      expect(new URL(request.url).pathname).toBe("/_admin/status")
      return Response.json({
        mode: "Enabled",
        resetAutomation: { enabled: false, paused: true, issue: null, authorization: "private" },
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
              fiveHourPercent: 40,
              fiveHourResetAt: "2026-09-10T22:00:00Z",
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
        fiveHourRemaining: 60,
        fiveHourResetAt: "2026-09-10T22:00:00Z",
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
        fiveHourRemaining: null,
        fiveHourResetAt: null,
        remaining: null,
        resetAt: null,
        observedAt: null,
        stale: true,
        hasCapacity: null,
      },
    ],
    automation: { enabled: false },
    anthropic: { status: "disabled", accounts: [], automation: null },
  })
  expect(JSON.stringify(result)).not.toContain("private")
})

test("normalizes the Anthropic pool with tiers, both quota windows and active grants", async () => {
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      if (new URL(request.url).pathname === "/_admin/status") return Response.json({ accounts: [] })
      expect(new URL(request.url).pathname).toBe("/_admin/anthropic/status")
      return Response.json({
        provider: "anthropic",
        mode: "DryRun",
        resetAutomation: { enabled: true, paused: false },
        accounts: [
          {
            account: {
              id: "claude",
              email: "claude@example.test",
              organizationId: "org-private",
              subscriptionTier: "default_claude_max_5x",
              name: null,
              enabled: true,
              authenticationState: "Authenticated",
            },
            cooldownSeconds: 0,
            usage: {
              observedAt: "2026-09-26T22:41:16Z",
              fiveHourPercent: 1,
              weeklyPercent: 69,
              hasCapacity: true,
              planType: "default_claude_max_20x",
              weeklyResetAt: "2026-09-29T11:59:59Z",
              fiveHourResetAt: "2026-09-27T03:09:59Z",
            },
            usageAgeSeconds: 60,
            inventory: {
              observedAt: "2026-09-26T22:41:17Z",
              available: [],
              grants: [
                { id: "later", resetsLeft: 2, resetsTotal: 2, endsAt: "2026-11-01T00:00:00Z", paused: false },
                { id: "first", resetsLeft: 1, resetsTotal: 1, endsAt: "2026-10-22T16:00:00Z", paused: false },
                { id: "open", resetsLeft: 1, resetsTotal: 1, endsAt: null, paused: false },
                { id: "used", resetsLeft: 0, resetsTotal: 1, endsAt: "2026-10-01T00:00:00Z", paused: false },
                { id: "paused", resetsLeft: 1, resetsTotal: 1, endsAt: "2026-10-02T00:00:00Z", paused: true },
              ],
              eligible: true,
            },
          },
          {
            account: {
              id: "unknown",
              email: "unknown@example.test",
              subscriptionTier: null,
              name: "Unknown",
              enabled: true,
              authenticationState: "Authenticated",
            },
            cooldownSeconds: 0,
            usage: null,
            usageAgeSeconds: null,
            inventory: null,
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
    accounts: [],
    automation: null,
    anthropic: {
      status: "ok",
      accounts: [
        {
          id: "claude",
          name: "claude@example.test",
          enabled: true,
          plan: "max20x",
          authenticated: true,
          cooldownSeconds: 0,
          bankedResets: {
            available: 4,
            earliestExpiresAt: "2026-10-22T16:00:00Z",
            latestExpiresAt: "2026-11-01T00:00:00Z",
            nonExpiring: 1,
          },
          fiveHourRemaining: 99,
          fiveHourResetAt: "2026-09-27T03:09:59Z",
          remaining: 31,
          resetAt: "2026-09-29T11:59:59Z",
          observedAt: "2026-09-26T22:41:16Z",
          stale: false,
          hasCapacity: true,
        },
        {
          id: "unknown",
          name: "Unknown",
          enabled: true,
          plan: null,
          authenticated: true,
          cooldownSeconds: 0,
          bankedResets: null,
          fiveHourRemaining: null,
          fiveHourResetAt: null,
          remaining: null,
          resetAt: null,
          observedAt: null,
          stale: true,
          hasCapacity: null,
        },
      ],
      automation: { enabled: true },
    },
  })
  expect(JSON.stringify(result)).not.toContain("private")
})

test("returns explicit states for missing configuration and failed or malformed responses", async () => {
  expect(await Effect.runPromise(withProxy("", read()))).toEqual({
    status: "unconfigured",
    accounts: [],
    automation: null,
    anthropic: { status: "disabled", accounts: [], automation: null },
  })
  const failed = Bun.serve({ port: 0, fetch: () => new Response("no", { status: 500 }) })
  expect(
    await Effect.runPromise(
      withProxy(failed.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => failed.stop(true)))),
    ),
  ).toEqual({
    status: "unavailable",
    accounts: [],
    automation: null,
    anthropic: { status: "unavailable", accounts: [], automation: null },
  })
  const disabled = Bun.serve({ port: 0, fetch: () => new Response("no", { status: 503 }) })
  expect(
    await Effect.runPromise(
      withProxy(disabled.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => disabled.stop(true)))),
    ),
  ).toEqual({
    status: "unavailable",
    accounts: [],
    automation: null,
    anthropic: { status: "disabled", accounts: [], automation: null },
  })
  const malformed = Bun.serve({ port: 0, fetch: () => Response.json({ unexpected: true }) })
  expect(
    await Effect.runPromise(
      withProxy(malformed.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => malformed.stop(true)))),
    ),
  ).toEqual({
    status: "unavailable",
    accounts: [],
    automation: null,
    anthropic: { status: "unavailable", accounts: [], automation: null },
  })
})

test("writes the automation switch to the provider-specific proxy route", async () => {
  const requests: { path: string; method: string; body: unknown }[] = []
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      const path = new URL(request.url).pathname
      requests.push({ path, method: request.method, body: await request.json() })
      if (path === "/_admin/anthropic/banked-resets") return new Response("conflict", { status: 409 })
      return Response.json({ enabled: true, paused: false, mode: "Enabled", loaded: true, blocked: false, issue: null })
    },
  })
  const [codex, anthropic] = await Effect.runPromise(
    withProxy(
      server.url.toString(),
      Effect.all([
        writeAutomation({ provider: "codex", enabled: true }),
        writeAutomation({ provider: "anthropic", enabled: false }),
      ]),
    ).pipe(Effect.ensuring(Effect.sync(() => server.stop(true)))),
  )
  expect(codex).toEqual({ enabled: true })
  expect(anthropic).toBeNull()
  expect(requests).toEqual([
    { path: "/_admin/banked-resets", method: "PUT", body: { enabled: true } },
    { path: "/_admin/anthropic/banked-resets", method: "PUT", body: { enabled: false } },
  ])
  expect(await Effect.runPromise(withProxy("", writeAutomation({ provider: "codex", enabled: false })))).toBeNull()
})

test("consumes a banked reset through the provider-specific proxy route and maps failures", async () => {
  const requests: { path: string; method: string }[] = []
  const server = Bun.serve({
    port: 0,
    fetch(request) {
      const path = new URL(request.url).pathname
      requests.push({ path, method: request.method })
      if (path === "/_admin/accounts/one/banked-resets/consume")
        return Response.json({ code: "reset", windowsReset: 2, httpStatus: 200, succeeded: true, token: "private" })
      if (path === "/_admin/anthropic/accounts/one/banked-resets/consume")
        return Response.json({ code: "rejected", windowsReset: 0, httpStatus: 400, succeeded: false })
      if (path === "/_admin/accounts/empty/banked-resets/consume")
        return Response.json({ error: "no_credit" }, { status: 409 })
      if (path === "/_admin/anthropic/accounts/busy/banked-resets/consume")
        return Response.json({ error: "busy" }, { status: 409 })
      if (path === "/_admin/accounts/token/banked-resets/consume")
        return Response.json({ error: "token_unavailable" }, { status: 409 })
      if (path === "/_admin/accounts/upstream/banked-resets/consume")
        return Response.json({ error: "upstream" }, { status: 502 })
      return new Response("missing", { status: 404 })
    },
  })
  const results = await Effect.runPromise(
    withProxy(
      server.url.toString(),
      Effect.all([
        consumeReset({ provider: "codex", accountId: "one" }),
        consumeReset({ provider: "anthropic", accountId: "one" }),
        consumeReset({ provider: "codex", accountId: "empty" }),
        consumeReset({ provider: "anthropic", accountId: "busy" }),
        consumeReset({ provider: "codex", accountId: "token" }),
        consumeReset({ provider: "codex", accountId: "upstream" }),
        consumeReset({ provider: "codex", accountId: "unknown" }),
      ]),
    ).pipe(Effect.ensuring(Effect.sync(() => server.stop(true)))),
  )
  expect(results).toEqual([
    { status: "ok", result: { code: "reset", windowsReset: 2 } },
    { status: "consume_failed" },
    { status: "no_credit" },
    { status: "busy" },
    { status: "consume_failed" },
    { status: "consume_failed" },
    { status: "consume_failed" },
  ])
  expect(requests).toEqual([
    { path: "/_admin/accounts/one/banked-resets/consume", method: "POST" },
    { path: "/_admin/anthropic/accounts/one/banked-resets/consume", method: "POST" },
    { path: "/_admin/accounts/empty/banked-resets/consume", method: "POST" },
    { path: "/_admin/anthropic/accounts/busy/banked-resets/consume", method: "POST" },
    { path: "/_admin/accounts/token/banked-resets/consume", method: "POST" },
    { path: "/_admin/accounts/upstream/banked-resets/consume", method: "POST" },
    { path: "/_admin/accounts/unknown/banked-resets/consume", method: "POST" },
  ])
  expect(await Effect.runPromise(withProxy("", consumeReset({ provider: "codex", accountId: "one" })))).toEqual({
    status: "consume_failed",
  })
})

test("times out an unresponsive proxy after eight seconds", async () => {
  const server = Bun.serve({ port: 0, fetch: () => new Promise<Response>(() => {}) })
  const started = performance.now()
  const result = await Effect.runPromise(
    withProxy(server.url.toString(), read()).pipe(Effect.ensuring(Effect.sync(() => server.stop(true)))),
  )
  expect(result).toEqual({
    status: "unavailable",
    accounts: [],
    automation: null,
    anthropic: { status: "unavailable", accounts: [], automation: null },
  })
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
