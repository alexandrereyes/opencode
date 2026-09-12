import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { AppMentions } from "@opencode/plugin-app-custom/rpc"
import { Effect, Schedule } from "effect"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "./fixture/server"

it.live(
  "discovers the app plugin per Location and serves its RPC through the public client",
  () =>
    Effect.gen(function* () {
      const tmp = yield* tmpdirScoped("opencode-app-mentions-")
      const first = path.join(tmp.path, "first")
      const second = path.join(tmp.path, "second")
      const config = path.join(tmp.path, "config")
      const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
      const fixture = path.resolve(import.meta.dir, "../../plugin-app-custom/test/fixture/mcp-server.ts")
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

      yield* Effect.promise(() => client.plugin.awaitActivation({ location: secondLocation }))
      const isolated = yield* Effect.promise(() => client.plugin.list({ location: secondLocation }))
      expect(isolated.data.some((item) => item.id === "custom.app-mentions")).toBe(false)
      const unavailable = yield* Effect.tryPromise({
        try: () => client.rpc(AppMentions.Definition).list({}, { location: secondLocation }),
        catch: (error) => error,
      }).pipe(Effect.flip)
      expect(unavailable).toMatchObject({ type: "rpc.unavailable" })

      const removed = yield* Effect.promise(() =>
        fetch(new URL(`/api/mcp/computer-use/app?location[directory]=${encodeURIComponent(first)}`, server.base), {
          headers: server.headers,
        }),
      )
      expect(removed.status).toBe(404)
    }).pipe(Effect.timeout("20 seconds")),
  25_000,
)
