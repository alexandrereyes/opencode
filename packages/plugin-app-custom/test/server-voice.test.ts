import { Database } from "bun:sqlite"
import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { ServerProcess } from "@opencode/server/process"
import { Effect } from "effect"
import { HttpServer } from "effect/http"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { Master } from "../src/master/rpc"
import { Voice } from "../src/voice/rpc"

const hour = 3_600_000

it.live("the iPhone's queue drains through the real handlers and KV table, keeping what was said after its reset", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-plugin-voice-")
    const db = path.join(tmp.path, "voice.db")
    const config = path.join(tmp.path, "config")
    const directory = path.join(tmp.path, "location")
    const pluginPackage = path.join(tmp.path, "plugin")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../src/index.ts")).href
    yield* Effect.promise(async () => {
      await Promise.all([config, directory, pluginPackage].map((item) => fs.mkdir(item, { recursive: true })))
      await fs.writeFile(
        path.join(pluginPackage, "package.json"),
        JSON.stringify({ type: "module", exports: "./index.ts" }),
      )
      await fs.writeFile(path.join(pluginPackage, "index.ts"), `export { default } from ${JSON.stringify(plugin)}\n`)
      await fs.writeFile(path.join(directory, "opencode.json"), "{}")
    })
    // The Mestra lives in a managed chat under XDG_DATA_HOME; keep it out of the real home.
    const previousData = process.env.XDG_DATA_HOME
    process.env.XDG_DATA_HOME = path.join(tmp.path, "data")
    yield* Effect.addFinalizer(() =>
      Effect.sync(() => {
        if (previousData === undefined) delete process.env.XDG_DATA_HOME
        if (previousData !== undefined) process.env.XDG_DATA_HOME = previousData
      }),
    )
    const server = yield* ServerProcess.start<never, never>({
      hostname: "127.0.0.1",
      port: 0,
      password: "secret",
      app: { version: "test" },
      database: { path: db },
      config: { directory: config, content: JSON.stringify({ plugins: [pluginPackage] }) },
      models: { fetch: false },
      fs: { filewatcher: false },
    })
    const client = OpenCode.make({
      baseUrl: HttpServer.formatAddress(server.address),
      headers: { authorization: `Basic ${btoa("opencode:secret")}` },
    })
    const options = { location: { directory } }
    const voice = client.rpc(Voice.Definition)
    const target = { version: Voice.version, scope: "global" } as const
    const window = () => {
      const sqlite = new Database(db, { readonly: true })
      const row = sqlite.query("select value from kv where key like '%:voice/window'").get()
      sqlite.close()
      return row
    }
    const turn = (id: string, at: number, role: Voice.Turn["role"] = "user") => ({ id, role, text: `Fala ${id}.`, at })
    const now = Date.now()

    // Before the end got stuck (31/10): a call's turns, then the Mestra it delegated to opens its window.
    expect(
      yield* Effect.promise(() =>
        voice.append(
          { ...target, turns: [turn("old-1", now - 72 * hour), turn("old-2", now - 72 * hour, "assistant")] },
          options,
        ),
      ),
    ).toMatchObject({ appended: 2 })
    yield* Effect.promise(() => client.rpc(Master.Definition).ensure({ voice: true }, options))
    expect(window()).toBeTruthy()

    // The end that failed 300 times: it takes the window, and a later end (another call) finds none.
    expect(yield* Effect.promise(() => voice.end(target, options))).toEqual({ ...target, compactionScheduled: false })
    expect(window()).toBeNull()
    expect(yield* Effect.promise(() => voice.end(target, options))).toEqual({ ...target, compactionScheduled: false })

    // The local reset of 04:38, queued before resets had a time: the app sends the earliest turn after it in its
    // queue (said after the clear), and those turns stay although the reset reaches the server hours later.
    const said = [turn("new-1", now - 5 * hour), turn("new-2", now - 5 * hour + 4_000, "assistant")]
    const queued = yield* Effect.promise(() => voice.reset({ ...target, at: said[0].at }, options))
    expect(queued).toEqual({ ...target, resetAt: said[0].at })
    expect(yield* Effect.promise(() => voice.append({ ...target, turns: said }, options))).toMatchObject({
      appended: 2,
    })
    // What was said before the clear stays out: a straggler of the old conversation, and a retry of it.
    expect(
      yield* Effect.promise(() =>
        voice.append({ ...target, turns: [turn("old-3", now - 6 * hour), turn("old-1", now - 72 * hour)] }, options),
      ),
    ).toMatchObject({ appended: 0 })
    expect(yield* Effect.promise(() => voice.end(target, options))).toEqual({ ...target, compactionScheduled: false })
    expect((yield* Effect.promise(() => voice.context(target, options))).turns).toEqual(said)

    // A reset queued by the new app carries when it cleared: before it out, after it in.
    const cleared = yield* Effect.promise(() => voice.reset({ ...target, at: now - hour }, options))
    expect(cleared.resetAt).toBe(now - hour)
    expect(
      yield* Effect.promise(() =>
        voice.append({ ...target, turns: [turn("before", now - 2 * hour), turn("kept", now - hour / 2)] }, options),
      ),
    ).toMatchObject({ appended: 1 })
    expect((yield* Effect.promise(() => voice.context(target, options))).turns).toEqual([turn("kept", now - hour / 2)])

    // An app without `at` (the watch, older builds): the server's time, as before.
    const immediate = yield* Effect.promise(() => voice.reset(target, options))
    expect(immediate.resetAt).toBeGreaterThanOrEqual(now)
    expect(
      yield* Effect.promise(() =>
        voice.append(
          { ...target, turns: [turn("late", immediate.resetAt - 1), turn("after", immediate.resetAt + 1)] },
          options,
        ),
      ),
    ).toMatchObject({ appended: 1 })
    expect((yield* Effect.promise(() => voice.context(target, options))).turns).toEqual([
      turn("after", immediate.resetAt + 1),
    ])
  }).pipe(Effect.timeout("30 seconds")),
)
