import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { AppMentions } from "@opencode/plugin-app-custom/rpc"
import { NativeApps } from "@opencode/plugin-app-custom/native-apps/rpc"
import { Subscriptions } from "@opencode/plugin-app-custom/subscriptions/rpc"
import { Effect, Schedule } from "effect"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "./fixture/server"

it.live(
  "serves custom app RPCs from the same Location plugin over HTTP",
  () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped("opencode-app-mentions-")
      const first = path.join(tmp.path, "first")
      const second = path.join(tmp.path, "second")
      const config = path.join(tmp.path, "config")
      const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
      const fixture = path.resolve(import.meta.dir, "../../plugin-app-custom/test/fixture/mcp-server.ts")
      const proxy = Bun.serve({
        port: 0,
        fetch: () =>
          Response.json({
            accounts: [
              {
                account: {
                  id: "quota",
                  name: null,
                  email: "quota@example.test",
                  enabled: true,
                  planType: "pro",
                  authenticationState: "Authenticated",
                  oauth: { accessToken: "private" },
                },
                usage: {
                  weeklyPercent: 25,
                  weeklyResetAt: null,
                  observedAt: "2026-09-12T12:00:00Z",
                  hasCapacity: true,
                  planType: "pro",
                },
                usageAgeSeconds: 0,
                cooldownSeconds: 0,
                bankedResets: null,
              },
            ],
          }),
      })
      const previousProxy = process.env.OPENCODE_LLM_PROXY_URL
      process.env.OPENCODE_LLM_PROXY_URL = proxy.url.toString()
      yield* Effect.addFinalizer(() =>
        Effect.promise(() => proxy.stop(true)).pipe(
          Effect.andThen(
            Effect.sync(() => {
              if (previousProxy === undefined) delete process.env.OPENCODE_LLM_PROXY_URL
              if (previousProxy !== undefined) process.env.OPENCODE_LLM_PROXY_URL = previousProxy
            }),
          ),
        ),
      )
      yield* Effect.promise(async () => {
        await Promise.all([fs.mkdir(path.join(first, ".opencode", "plugins"), { recursive: true }), fs.mkdir(second)])
        await fs.writeFile(
          path.join(first, ".opencode", "plugins", "app-custom.ts"),
          `export { default } from ${JSON.stringify(plugin)}\n`,
        )
        await fs.writeFile(
          path.join(first, "opencode.json"),
          JSON.stringify({
            mcp: {
              servers: {
                "codex-computer-use": {
                  type: "local",
                  command: [process.execPath, fixture],
                  environment: {
                    APP_MENTION_FIXTURE_NAME: "Legacy App",
                    APP_MENTION_FIXTURE_BUNDLE: "com.example.legacy",
                  },
                },
                "open-computer-use": {
                  type: "local",
                  command: [process.execPath, fixture],
                  environment: {
                    APP_MENTION_FIXTURE_NAME: "Preferred App",
                    APP_MENTION_FIXTURE_BUNDLE: "com.example.preferred",
                  },
                },
              },
            },
          }),
        )
      })

      const server = yield* startServer(config)
      const client = OpenCode.make({ baseUrl: server.base, headers: server.headers })
      const firstLocation = { directory: first }
      const secondLocation = { directory: second }

      yield* Effect.promise(() => client.plugin.awaitActivation({ location: firstLocation }))
      const inventory = yield* Effect.promise(() => client.plugin.list({ location: firstLocation }))
      expect(inventory.data.find((item) => item.id === "custom.app-mentions")).toMatchObject({
        source: { type: "local" },
        state: { status: "active" },
      })

      yield* Effect.tryPromise(() => client.mcp.list({ location: firstLocation })).pipe(
        Effect.filterOrFail(
          (result) => result.data.filter((entry) => entry.status.status === "connected").length === 2,
        ),
        Effect.retry(Schedule.max([Schedule.spaced("10 millis"), Schedule.recurs(200)])),
      )
      expect(
        yield* Effect.promise(() => client.rpc(AppMentions.Definition).list({}, { location: firstLocation })),
      ).toEqual({
        apps: [
          {
            server: "open-computer-use",
            name: "Preferred App",
            bundleID: "com.example.preferred",
            running: true,
          },
        ],
      })
      const nativeApps = yield* Effect.promise(() =>
        client.rpc(NativeApps.Definition).list({}, { location: firstLocation }),
      )
      expect(nativeApps.os).toBe(process.platform === "darwin" ? "macos" : null)
      expect(Array.isArray(nativeApps.apps)).toBe(true)
      const subscriptions = yield* Effect.promise(() =>
        client.rpc(Subscriptions.Definition).list({}, { location: firstLocation }),
      )
      expect(subscriptions).toEqual({
        status: "ok",
        accounts: [
          {
            id: "quota",
            name: "quota@example.test",
            enabled: true,
            plan: "pro",
            authenticated: true,
            cooldownSeconds: 0,
            bankedResets: null,
            remaining: 75,
            resetAt: null,
            observedAt: "2026-09-12T12:00:00Z",
            stale: false,
            hasCapacity: true,
          },
        ],
      })
      expect(JSON.stringify(subscriptions)).not.toContain("private")

      yield* Effect.promise(() => client.plugin.awaitActivation({ location: secondLocation }))
      const isolated = yield* Effect.promise(() => client.plugin.list({ location: secondLocation }))
      expect(isolated.data.some((item) => item.id === "custom.app-mentions")).toBe(false)
      const unavailable = yield* Effect.tryPromise({
        try: () => client.rpc(AppMentions.Definition).list({}, { location: secondLocation }),
        catch: (error) => error,
      }).pipe(Effect.flip)
      expect(unavailable).toMatchObject({ type: "rpc.unavailable" })
      const subscriptionsUnavailable = yield* Effect.tryPromise({
        try: () => client.rpc(Subscriptions.Definition).list({}, { location: secondLocation }),
        catch: (error) => error,
      }).pipe(Effect.flip)
      expect(subscriptionsUnavailable).toMatchObject({ type: "rpc.unavailable" })

      const nativeAppsUnavailable = yield* Effect.tryPromise({
        try: () => client.rpc(NativeApps.Definition).list({}, { location: secondLocation }),
        catch: (error) => error,
      }).pipe(Effect.flip)
      expect(nativeAppsUnavailable).toMatchObject({ type: "rpc.unavailable" })

      const oldSubscriptions = yield* Effect.promise(() =>
        fetch(new URL("/api/server/subscriptions", server.base), { headers: server.headers }),
      )
      expect(oldSubscriptions.status).toBe(404)

      const oldNativeApps = yield* Effect.promise(() =>
        Promise.all([
          fetch(new URL("/api/server/native-apps", server.base), { headers: server.headers }),
          fetch(new URL("/api/server/native-apps/open", server.base), {
            method: "POST",
            headers: { ...server.headers, "content-type": "application/json" },
            body: JSON.stringify({ app: "rider", path: first }),
          }),
        ]),
      )
      expect(oldNativeApps.map((response) => response.status)).toEqual([404, 404])

      const removed = yield* Effect.promise(() =>
        fetch(new URL(`/api/mcp/computer-use/app?location[directory]=${encodeURIComponent(first)}`, server.base), {
          headers: server.headers,
        }),
      )
      expect(removed.status).toBe(404)
    }).pipe(Effect.timeout("20 seconds")),
  25_000,
)

it.live(
  "returns declared native app errors through HTTP RPC without launching host applications",
  () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped("opencode-native-apps-")
      const project = path.join(tmp.path, "project")
      const config = path.join(tmp.path, "config")
      const plugin = pathToFileURL(
        path.resolve(import.meta.dir, "../../plugin-app-custom/test/fixture/native-apps-plugin.ts"),
      ).href
      yield* Effect.promise(async () => {
        await fs.mkdir(path.join(project, ".opencode", "plugins"), { recursive: true })
        await fs.writeFile(
          path.join(project, ".opencode", "plugins", "native-apps.ts"),
          `export { default } from ${JSON.stringify(plugin)}\n`,
        )
      })

      const server = yield* startServer(config)
      const client = OpenCode.make({ baseUrl: server.base, headers: server.headers })
      const location = { directory: project }
      yield* Effect.promise(() => client.plugin.awaitActivation({ location }))
      expect(yield* Effect.promise(() => client.rpc(NativeApps.Definition).list({}, { location }))).toEqual({
        os: null,
        apps: [],
      })

      const error = yield* Effect.tryPromise({
        try: () => client.rpc(NativeApps.Definition).open({ app: "rider", path: project }, { location }),
        catch: (error) => error,
      }).pipe(Effect.flip)
      expect(error).toMatchObject({ type: "open_failed", data: { reason: "unsupported" } })
    }).pipe(Effect.timeout("20 seconds")),
  25_000,
)
