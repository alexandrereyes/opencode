import fs from "node:fs/promises"
import path from "node:path"
import { describe, expect } from "bun:test"
import { Effect, Schema } from "effect"
import { Plugin } from "@opencode/core/plugin"
import { PluginHost } from "@opencode/core/plugin/host"
import { PluginModule } from "@opencode/core/plugin/module"
import { Rpc } from "@opencode/core/rpc"
import { Watcher } from "@opencode/core/filesystem/watcher"
import { Session } from "@opencode/schema/session"
import { Master } from "../../plugin-app-custom/src/master/rpc"
import { testEffect } from "./lib/effect"
import { tmpdirScoped } from "./fixture/tmpdir"
import { OfflinePluginTestLayer } from "./plugin/fixture"

const it = testEffect(OfflinePluginTestLayer)
// The pointer production kept after the web deleted its Mestra session.
const deleted = Session.ID.make("ses_0318DBC98EA04683BEB8ACECD7EF3F7F")

describe.each(["source", "bundle"])("Mestra ensure through the custom plugin (%s)", (distribution) => {
  it.live("replaces a deleted master with real managed chats and preferences", () =>
    Effect.gen(function* () {
      const build = yield* tmpdirScoped()
      const data = yield* tmpdirScoped()
      // Managed chats live under XDG_DATA_HOME; keep them inside this test.
      yield* Effect.acquireRelease(
        Effect.sync(() => {
          const previous = process.env.XDG_DATA_HOME
          process.env.XDG_DATA_HOME = data.path
          return previous
        }),
        (previous) =>
          Effect.sync(() => {
            if (previous === undefined) delete process.env.XDG_DATA_HOME
            else process.env.XDG_DATA_HOME = previous
          }),
      )
      const target =
        distribution === "source"
          ? path.join(import.meta.dir, "../../plugin-app-custom/src/index.ts")
          : path.join(build.path, "custom-plugin.js")
      if (distribution === "bundle") {
        // The release bundles its own Effect runtime, separate from the host's.
        const result = yield* Effect.promise(() =>
          Bun.build({
            entrypoints: [path.join(import.meta.dir, "../../cli/script/custom-plugin.ts")],
            outdir: build.path,
            target: "bun",
            minify: true,
          }),
        )
        expect(result.success).toBe(true)
      }
      const plugins = yield* Plugin.Service
      const modules = yield* PluginModule.make().pipe(Effect.provide(Watcher.testLayer))
      const custom = yield* modules.load({ type: "add", target, options: {} })
      if ("pending" in custom || "blocked" in custom) throw new Error("Custom plugin was not loaded")
      yield* plugins.activate([custom])
      const rpc = yield* Rpc.Service
      const host = yield* PluginHost.make(plugins)

      yield* rpc.call("custom.preferences", "mutate", { type: "master.set", server: "local", sessionID: deleted })
      const [ensured, second] = (yield* Effect.all(
        [rpc.call("custom.master", "ensure", {}), rpc.call("custom.master", "ensure", {})],
        { concurrency: "unbounded" },
      )).map((value) => Schema.decodeUnknownSync(Master.Ensured)(value))
      expect(ensured.created).toBe(true)
      expect(ensured.sessionID).not.toBe(deleted)
      expect(ensured.preferences.data.masterSessions).toEqual({ local: ensured.sessionID })
      expect(second).toMatchObject({ sessionID: ensured.sessionID, created: false })
      expect(
        ensured.directory.startsWith(
          path.join(yield* Effect.promise(() => fs.realpath(data.path)), "opencode", "chats"),
        ),
      ).toBe(true)
      expect(yield* host.session.get({ sessionID: ensured.sessionID })).toMatchObject({
        agent: "mestra",
        title: "Sessão mestra",
        location: { directory: ensured.directory },
      })
      expect(yield* rpc.call("custom.preferences", "get", {})).toMatchObject({
        data: { masterSessions: { local: ensured.sessionID } },
      })
    }),
  )
})
