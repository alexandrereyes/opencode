import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Snippets } from "../src/snippets/rpc"
import { Project } from "@opencode/schema/project"
import { Effect } from "effect"
import { HttpServer } from "effect/http"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { ServerProcess } from "@opencode/server/process"

it.live("serves one persistent snippet catalog across Locations", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-plugin-snippets-")
    const db = path.join(tmp.path, "snippets.db")
    const config = path.join(tmp.path, "config")
    const first = path.join(tmp.path, "first")
    const second = path.join(tmp.path, "second")
    const pluginPackage = path.join(tmp.path, "plugin")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../src/index.ts")).href
    yield* Effect.promise(async () => {
      await Promise.all(
        [config, first, second, pluginPackage].map((directory) => fs.mkdir(directory, { recursive: true })),
      )
      await fs.writeFile(
        path.join(pluginPackage, "package.json"),
        JSON.stringify({ type: "module", exports: "./index.ts" }),
      )
      await fs.writeFile(path.join(pluginPackage, "index.ts"), `export { default } from ${JSON.stringify(plugin)}\n`)
      await Promise.all([first, second].map((directory) => fs.writeFile(path.join(directory, "opencode.json"), "{}")))
    })

    const start = () =>
      ServerProcess.start<never, never>({
        hostname: "127.0.0.1",
        port: 0,
        password: "secret",
        app: { version: "test" },
        database: { path: db },
        config: { directory: config, content: JSON.stringify({ plugins: [pluginPackage] }) },
        models: { fetch: false },
        fs: { filewatcher: false },
      })

    yield* Effect.scoped(
      Effect.gen(function* () {
        const server = yield* start()
        const client = OpenCode.make({
          baseUrl: HttpServer.formatAddress(server.address),
          headers: { authorization: `Basic ${btoa("opencode:secret")}` },
        })
        const snippets = client.rpc(Snippets.Definition)
        expect(yield* Effect.promise(() => snippets.list({}))).toEqual({ items: [] })
        yield* Effect.promise(() => snippets.list({}, { location: { directory: first } }))
        yield* Effect.promise(() => snippets.list({}, { location: { directory: second } }))
        const plugins = yield* Effect.promise(() => client.plugin.list())
        expect(plugins.data.find((item) => item.id === "custom.app-mentions")).toMatchObject({
          state: { status: "active" },
        })

        const feed = client.event.subscribe()[Symbol.asyncIterator]()
        expect((yield* Effect.promise(() => feed.next())).value?.type).toBe("server.connected")
        const project = Project.ID.make("project")
        yield* Effect.promise(() =>
          snippets.save(
            {
              id: "cross-location",
              name: "cross-location",
              description: "Event source",
              aliases: [],
              content: "Refresh every server client",
            },
            { location: { directory: second } },
          ),
        )
        const event = yield* Effect.promise(() => feed.next())
        expect(event.value).toMatchObject({
          type: "rpc.custom.snippets.updated",
          location: { directory: second },
        })
        const closeFeed = feed.return
        if (closeFeed) yield* Effect.promise(() => closeFeed.call(feed))

        const entries = Array.from({ length: 20 }, (_, index) => ({
          id: `snippet-${index}`,
          name: `name-${index}`,
          description: `Description ${index}`,
          aliases: [`alias-${index}`],
          content: `Content ${index}`,
          ...(index % 2 ? { project } : {}),
        }))
        yield* Effect.promise(() =>
          Promise.all(
            entries.map((entry, index) =>
              snippets.save(entry, { location: { directory: index % 2 ? first : second } }),
            ),
          ),
        )
        // Saves alternate between two Location plugin instances; none of the concurrent writes may be lost.
        expect((yield* Effect.promise(() => snippets.list({}, { location: { directory: first } }))).items).toHaveLength(
          21,
        )
        expect(
          (yield* Effect.promise(() => snippets.list({}, { location: { directory: second } }))).items,
        ).toHaveLength(21)
        yield* Effect.promise(() =>
          snippets.save(
            {
              id: "global-same-name",
              name: entries[1].name,
              description: entries[1].description,
              aliases: entries[1].aliases,
              content: entries[1].content,
            },
            { location: { directory: first } },
          ),
        )
        const conflict = yield* Effect.tryPromise({
          try: () =>
            snippets.save(
              { ...entries[1], id: "duplicate", name: entries[1].name.toUpperCase() },
              { location: { directory: second } },
            ),
          catch: (error) => error,
        }).pipe(Effect.flip)
        expect(conflict).toMatchObject({
          type: "conflict",
          data: { name: "NAME-1", field: "name", value: "NAME-1", existing: "name-1" },
        })
        const refused = (snippet: Snippets.Info) =>
          Effect.tryPromise({
            try: () => snippets.save(snippet, { location: { directory: first } }),
            catch: (error) => error,
          }).pipe(Effect.flip)
        // Rev. 2026-10-30: aliases count as handles of their scope, and both must be typeable after `#`.
        expect(yield* refused({ ...entries[2], id: "alias-clash", name: "fresh", aliases: ["ALIAS-2"] })).toMatchObject(
          {
            type: "conflict",
            data: { name: "fresh", field: "alias", value: "ALIAS-2", existing: "name-2" },
          },
        )
        expect(yield* refused({ ...entries[2], id: "bad-name", name: "a@b", aliases: [] })).toMatchObject({
          type: "invalid",
          data: { field: "name", reason: "format", value: "a@b" },
        })
        const removal = client.event.subscribe()[Symbol.asyncIterator]()
        expect((yield* Effect.promise(() => removal.next())).value?.type).toBe("server.connected")
        yield* Effect.promise(() => snippets.remove({ id: "snippet-0" }, { location: { directory: first } }))
        expect((yield* Effect.promise(() => removal.next())).value?.type).toBe("rpc.custom.snippets.updated")
        const closeRemoval = removal.return
        if (closeRemoval) yield* Effect.promise(() => closeRemoval.call(removal))
        yield* Effect.promise(() => snippets.remove({ id: "snippet-0" }, { location: { directory: second } }))

        const old = yield* Effect.promise(() =>
          Promise.all(
            [
              { method: "GET", path: "/api/snippet" },
              { method: "PUT", path: "/api/snippet" },
              { method: "DELETE", path: "/api/snippet/cross-location" },
            ].map((request) =>
              fetch(new URL(request.path, HttpServer.formatAddress(server.address)), {
                method: request.method,
                headers: { authorization: `Basic ${btoa("opencode:secret")}` },
              }),
            ),
          ),
        )
        expect(old.map((response) => response.status)).toEqual([404, 404, 404])
        yield* Effect.promise(() => Promise.all(old.map((response) => response.arrayBuffer())))
      }),
    )

    yield* Effect.scoped(
      Effect.gen(function* () {
        const server = yield* start()
        const client = OpenCode.make({
          baseUrl: HttpServer.formatAddress(server.address),
          headers: { authorization: `Basic ${btoa("opencode:secret")}` },
        })
        const items = (yield* Effect.promise(() => client.rpc(Snippets.Definition).list({}))).items
        expect(
          items.some((item) => item.id === "cross-location" && item.content === "Refresh every server client"),
        ).toBe(true)
        expect(items.some((item) => item.id === "snippet-0")).toBe(false)
        expect(items).toHaveLength(21)
      }),
    )
  }).pipe(Effect.timeout("30 seconds")),
)
