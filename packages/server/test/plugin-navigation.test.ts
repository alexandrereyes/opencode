import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Navigation } from "@opencode/plugin-app-custom/navigation/rpc"
import { Archive } from "@opencode/plugin-app-custom/archive/rpc"
import { Session } from "@opencode/schema/session"
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
    expect(JSON.stringify(openapi)).not.toContain("/api/session/{sessionID}/archive")
    const oldURL = new URL("/api/session/navigation", server.base)
    oldURL.searchParams.set("location[directory]", first)
    const old = yield* Effect.promise(() => fetch(oldURL, { headers: server.headers }))
    expect(old.status).toBe(400)
    expect(yield* Effect.promise(() => old.json())).toMatchObject({ _tag: "InvalidRequestError" })
    const oldArchive = yield* Effect.promise(() =>
      fetch(new URL("/api/session/ses_missing/archive", server.base), { method: "POST", headers: server.headers }),
    )
    expect(oldArchive.status).toBe(404)

    const template = yield* Effect.promise(() => client.session.create({ title: "Template", location }))
    const session = yield* Effect.promise(() =>
      client.session.import({
        info: { ...template, id: Session.ID.create(), title: "Navigation" },
        messages: [
          {
            id: "msg_archive_history",
            type: "synthetic",
            text: "Retained archive history",
            time: { created: 1 },
          },
        ],
        location,
      }),
    )
    yield* Effect.promise(() => client.session.remove({ sessionID: template.id }))
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
    const child = yield* Effect.promise(() =>
      client.session.import({
        info: {
          ...session,
          id: Session.ID.create(),
          parentID: session.id,
          title: "Archived child",
          time: { ...session.time, archived: 1 },
        },
        messages: [],
        location,
      }),
    )
    const grandchild = yield* Effect.promise(() =>
      client.session.import({
        info: { ...session, id: Session.ID.create(), parentID: child.id, title: "Grandchild" },
        messages: [],
        location,
      }),
    )
    const feed = client.event.subscribe()[Symbol.asyncIterator]()
    expect((yield* Effect.promise(() => feed.next())).value?.type).toBe("server.connected")
    yield* Effect.promise(() => client.rpc(Archive.Definition).archive({ sessionID: session.id }, { location }))
    const archivedEvents = yield* Effect.forEach([grandchild.id, session.id], () =>
      Effect.promise(() => feed.next()).pipe(
        Effect.map((item) => {
          if (item.value?.type !== "session.archived")
            throw new Error(`Expected archive event, got ${item.value?.type}`)
          return item.value.data.sessionID
        }),
      ),
    )
    expect(archivedEvents).toEqual([grandchild.id, session.id])
    expect(
      (yield* Effect.promise(() => client.rpc(Navigation.Definition).list({ sessionID: session.id }, { location })))
        .data,
    ).toEqual([])
    const archived = yield* Effect.promise(() =>
      Promise.all([
        client.session.get({ sessionID: session.id }),
        client.session.get({ sessionID: child.id }),
        client.session.get({ sessionID: grandchild.id }),
        client.session.get({ sessionID: historicalSession.id }),
      ]),
    )
    expect(archived.slice(0, 3).every((item) => item.time.archived !== undefined)).toBe(true)
    expect(archived[3].time.archived).toBeUndefined()
    expect((yield* Effect.promise(() => client.message.list({ sessionID: session.id }))).data).toEqual([
      expect.objectContaining({ type: "synthetic", text: "Retained archive history" }),
    ])
    const exported = yield* Effect.promise(() => client.session.export({ sessionID: session.id }))
    expect(exported.info.time.archived).toBe(archived[0].time.archived)
    expect(exported.messages).toEqual([
      expect.objectContaining({ type: "synthetic", text: "Retained archive history" }),
    ])
    yield* Effect.promise(() => client.rpc(Archive.Definition).archive({ sessionID: session.id }, { location }))
    const repeated = yield* Effect.promise(() =>
      Promise.all([
        client.session.get({ sessionID: session.id }),
        client.session.get({ sessionID: child.id }),
        client.session.get({ sessionID: grandchild.id }),
      ]),
    )
    expect(repeated.map((item) => item.time.archived)).toEqual(archived.slice(0, 3).map((item) => item.time.archived))
    yield* Effect.promise(async () => {
      await feed.return?.()
    })
    const failure = yield* Effect.tryPromise({
      try: () => client.rpc(Archive.Definition).archive({ sessionID: "ses_missing" }, { location }),
      catch: (error) => error,
    }).pipe(Effect.flip)
    expect(failure).toMatchObject({ type: "operation_failed" })
  }),
)
