import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Quotes } from "@opencode/plugin-app-custom/quotes/rpc"
import { Effect } from "effect"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "./fixture/server"

it.live("stores pending chat quotes per session over plugin RPC with live updates", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-quotes-")
    const project = path.join(tmp.path, "project")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
    yield* Effect.promise(async () => {
      await fs.mkdir(path.join(project, ".opencode", "plugins"), { recursive: true })
      await fs.writeFile(
        path.join(project, ".opencode", "plugins", "app-custom.ts"),
        `export { default } from ${JSON.stringify(plugin)}\n`,
      )
    })
    const server = yield* startServer(path.join(tmp.path, "config"))
    const client = OpenCode.make({ baseUrl: server.base, headers: server.headers })
    const location = { directory: project }
    const options = { location }
    const quotes = client.rpc(Quotes.Definition)
    const session = yield* Effect.promise(() => client.session.create({ title: "Quotes", location }))
    const call = (method: string, input: unknown) =>
      Effect.promise(async () => {
        const url = new URL(`/api/rpc/custom.quotes/${method}`, server.base)
        url.searchParams.set("location[directory]", project)
        const response = await fetch(url, {
          method: "POST",
          headers: { ...server.headers, "content-type": "application/json" },
          body: JSON.stringify({ input }),
        })
        return { status: response.status, body: await response.json() }
      })

    expect(yield* Effect.promise(() => quotes.info({}, options))).toMatchObject({
      version: 1,
      limits: { quotesPerSession: 100 },
    })
    expect(yield* call("list", { sessionID: session.id })).toEqual({
      status: 200,
      body: { output: { sessionID: session.id, revision: 0, quotes: [], dismissed: [] } },
    })

    const feed = client.event.subscribe()[Symbol.asyncIterator]()
    expect((yield* Effect.promise(() => feed.next())).value?.type).toBe("server.connected")
    const bytes = Buffer.from("fake png bytes")
    const uploaded = yield* Effect.promise(() =>
      quotes.upload(
        { sessionID: session.id, mime: "image/png", filename: "shot.png", data: bytes.toString("base64") },
        options,
      ),
    )
    expect(uploaded).toMatchObject({ mime: "image/png", filename: "shot.png", size: bytes.length })
    const input = {
      id: "6F1C2A4E-0000-4000-8000-000000000001",
      messageID: "msg_answer",
      partID: "prt_text",
      text: "Rodando: nada.",
      comment: "Comentário",
      commentPrompt: [{ type: "text", start: 0, end: 10, content: "Comentário" }],
      anchor: { start: 4, end: 20, exact: "**Rodando:** nada", coordinate: "source" as const, prefix: "", suffix: "" },
      attachments: [uploaded.id],
    }
    const saved = yield* call("save", { sessionID: session.id, quote: input })
    expect(saved.status).toBe(200)
    expect(saved.body.output.quote).toMatchObject({ id: input.id, attachments: [uploaded], revision: 1 })
    const event = yield* Effect.promise(async () => {
      for (let next = await feed.next(); !next.done; next = await feed.next())
        if (next.value.type.startsWith("rpc.custom.quotes.")) return next.value
    })
    expect(event).toMatchObject({
      type: "rpc.custom.quotes.updated",
      data: { sessionID: session.id, revision: 1 },
    })
    const closeFeed = feed.return
    if (closeFeed) yield* Effect.promise(() => closeFeed.call(feed))

    const listed = yield* Effect.promise(() => quotes.list({ sessionID: session.id }, options))
    expect(listed.quotes).toHaveLength(1)
    expect(JSON.stringify(listed)).not.toContain(bytes.toString("base64"))
    expect(yield* Effect.promise(() => quotes.attachment({ sessionID: session.id, id: uploaded.id }, options))).toEqual(
      {
        ...uploaded,
        data: bytes.toString("base64"),
      },
    )

    const imported = yield* Effect.promise(() =>
      quotes.import(
        {
          sessionID: session.id,
          quotes: [input, { ...input, id: "other-client-copy" }, { ...input, id: "q2", text: "Na fila" }],
        },
        options,
      ),
    )
    expect([imported.imported, imported.skipped]).toEqual([["q2"], [input.id, "other-client-copy"]])
    expect(
      (yield* Effect.promise(() =>
        quotes.import({ sessionID: session.id, quotes: [{ ...input, id: "q2", text: "Na fila" }] }, options),
      )).imported,
    ).toEqual([])

    yield* Effect.promise(() => quotes.clear({ sessionID: session.id, ids: [input.id], reason: "sent" }, options))
    const stale = yield* call("save", { sessionID: session.id, quote: { ...input, comment: "late edit" } })
    expect(stale).toMatchObject({
      status: 400,
      body: { _tag: "RpcError", type: "already_sent", data: { ids: [input.id] } },
    })
    expect(yield* call("save", { sessionID: "ses_missing", quote: { ...input, id: "x" } })).toMatchObject({
      status: 400,
      body: { type: "session_not_found" },
    })
    expect(
      yield* call("save", {
        sessionID: session.id,
        quote: { ...input, id: "x", anchor: { start: 3, end: 1, exact: "" } },
      }),
    ).toMatchObject({ status: 400, body: { type: "rpc.invalid_input" } })
    expect(yield* call("upload", { sessionID: session.id, mime: "image/png", data: "%%%" })).toMatchObject({
      status: 400,
      body: { type: "invalid_data" },
    })

    const unavailable = yield* Effect.promise(async () => {
      const url = new URL("/api/rpc/custom.quotes-next/list", server.base)
      url.searchParams.set("location[directory]", project)
      const response = await fetch(url, {
        method: "POST",
        headers: { ...server.headers, "content-type": "application/json" },
        body: JSON.stringify({ input: { sessionID: session.id } }),
      })
      return { status: response.status, body: await response.json() }
    })
    expect(unavailable).toMatchObject({ status: 400, body: { _tag: "RpcError", type: "rpc.unavailable" } })

    yield* Effect.promise(() => client.session.remove({ sessionID: session.id }))
    const deadline = Date.now() + 10_000
    const cleared = yield* Effect.promise(async () => {
      while (Date.now() < deadline) {
        const state = await quotes.list({ sessionID: session.id }, options)
        if (state.revision === 0) return state
        await Bun.sleep(25)
      }
    })
    expect(cleared).toMatchObject({ revision: 0, quotes: [], dismissed: [] })
    expect(yield* call("attachment", { sessionID: session.id, id: uploaded.id })).toMatchObject({
      status: 400,
      body: { type: "not_found" },
    })
  }).pipe(Effect.timeout("30 seconds")),
)
