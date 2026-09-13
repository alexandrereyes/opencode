import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Navigation } from "@opencode/plugin-app-custom/navigation/rpc"
import { Effect } from "effect"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "./fixture/server"

it.live("serves navigation through plugin RPC without reviving historical locations", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-navigation-")
    const first = path.join(tmp.path, "first")
    const historical = path.join(tmp.path, "historical")
    const config = path.join(tmp.path, "config")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
    yield* Effect.promise(async () => {
      await Promise.all([fs.mkdir(path.join(first, ".opencode", "plugins"), { recursive: true }), fs.mkdir(historical)])
      await fs.writeFile(
        path.join(first, ".opencode", "plugins", "app-custom.ts"),
        `export { default } from ${JSON.stringify(plugin)}\n`,
      )
    })

    const server = yield* startServer(config)
    const client = OpenCode.make({ baseUrl: server.base, headers: server.headers })
    const location = { directory: first }
    const openapi = yield* Effect.promise(() =>
      fetch(new URL("/openapi.json", server.base)).then((response) => response.json()),
    )
    expect(JSON.stringify(openapi)).not.toContain("/api/session/navigation")
    const oldURL = new URL("/api/session/navigation", server.base)
    oldURL.searchParams.set("location[directory]", first)
    const old = yield* Effect.promise(() => fetch(oldURL, { headers: server.headers }))
    expect(old.status).toBe(400)
    expect(yield* Effect.promise(() => old.json())).toMatchObject({ _tag: "InvalidRequestError" })

    const session = yield* Effect.promise(() => client.session.create({ title: "Navigation", location }))
    const form = yield* Effect.promise(() =>
      client.form.create({
        sessionID: session.id,
        title: "Question",
        metadata: { kind: "question" },
        fields: [{ key: "answer", type: "string" }],
      }),
    )
    const historicalSession = yield* Effect.promise(() =>
      client.session.create({ title: "Historical", location: { directory: historical } }),
    )
    yield* Effect.promise(() => client.debug.location.evict({ location: { directory: historical } }))

    const firstPage = yield* Effect.promise(() => client.rpc(Navigation.Definition).list({ limit: 1 }, { location }))
    const secondPage = yield* Effect.promise(() =>
      client.rpc(Navigation.Definition).list({ after: firstPage.next, limit: 1 }, { location }),
    )
    const rows = [...firstPage.data, ...secondPage.data]
    expect(new Set(rows.map((row) => row.session.id))).toEqual(new Set([session.id, historicalSession.id]))
    expect(rows.find((row) => row.session.id === session.id)?.questionAt).toBe(form.created)
    expect(typeof rows[0].session.time.created).toBe("number")
    expect(
      (yield* Effect.promise(() => client.debug.location.list())).some((ref) => ref.directory === historical),
    ).toBe(false)

    yield* Effect.promise(() =>
      client.form.reply({ sessionID: session.id, formID: form.id, answer: { answer: "done" } }),
    )
    const cleared = yield* Effect.promise(() =>
      client.rpc(Navigation.Definition).list({ sessionID: session.id }, { location }),
    )
    expect(cleared.data[0].questionAt).toBeUndefined()
    yield* Effect.promise(() => client.session.archive({ sessionID: session.id }))
    expect(
      (yield* Effect.promise(() => client.rpc(Navigation.Definition).list({ sessionID: session.id }, { location })))
        .data,
    ).toEqual([])
  }),
)
