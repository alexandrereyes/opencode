import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Effect } from "effect"
import { QuestionDrafts } from "../src/question-drafts/rpc"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "../../server/test/fixture/server"

it.live("keeps question drafts per session and request, announces them and forgets them with the form", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-question-drafts-")
    const project = path.join(tmp.path, "project")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../src/index.ts")).href
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
    const drafts = client.rpc(QuestionDrafts.Definition)
    const request = (method: string, url: string, body?: unknown) =>
      Effect.promise(async () => {
        const target = new URL(url, server.base)
        target.searchParams.set("location[directory]", project)
        const response = await fetch(target, {
          method,
          headers: { ...server.headers, "content-type": "application/json" },
          ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        })
        return { status: response.status, body: await response.json().catch(() => undefined) }
      })
    const form = (sessionID: string) =>
      request("POST", `/api/session/${sessionID}/form`, {
        title: "Questions",
        metadata: { kind: "question" },
        fields: [
          { key: "voz", type: "string", options: [{ value: "marin", label: "marin" }], custom: true },
          { key: "nota", type: "string" },
        ],
      }).pipe(Effect.map((created) => created.body.data.id as string))
    const fields = { voz: { selected: ["marin"], text: "", added: [] } }
    const draftOf = (sessionID: string, requestID: string) =>
      Effect.promise(() => drafts.get({ sessionID, requestID }, options)).pipe(Effect.map((output) => output.draft))
    // Cleanup runs off the event stream: wait for it.
    const gone = (sessionID: string, requestID: string) =>
      Effect.gen(function* () {
        for (let attempt = 0; attempt < 50; attempt++) {
          if ((yield* draftOf(sessionID, requestID)) === null) return true
          yield* Effect.sleep("50 millis")
        }
        return false
      })

    const session = yield* Effect.promise(() => client.session.create({ title: "Drafts", location }))
    const answered = yield* form(session.id)
    expect(yield* draftOf(session.id, answered)).toBeNull()

    const feed = client.event.subscribe()[Symbol.asyncIterator]()
    expect((yield* Effect.promise(() => feed.next())).value?.type).toBe("server.connected")
    const saved = yield* Effect.promise(() =>
      drafts.save({ sessionID: session.id, requestID: answered, fields, client: "phone" }, options),
    )
    expect(saved).toMatchObject({ requestID: answered, fields, revision: 1 })
    const event = yield* Effect.promise(async () => {
      for (let next = await feed.next(); !next.done; next = await feed.next())
        if (next.value.type.startsWith("rpc.custom.question-drafts.")) return next.value
    })
    expect(event).toMatchObject({
      type: "rpc.custom.question-drafts.updated",
      data: { sessionID: session.id, requestID: answered, revision: 1, cleared: false, client: "phone" },
    })
    const closeFeed = feed.return
    if (closeFeed) yield* Effect.promise(() => closeFeed.call(feed))
    // The other device merges another question into the same draft.
    yield* Effect.promise(() =>
      drafts.save(
        { sessionID: session.id, requestID: answered, fields: { nota: { selected: [], text: "ok", added: [] } } },
        options,
      ),
    )
    expect((yield* draftOf(session.id, answered))?.fields).toEqual({
      ...fields,
      nota: { selected: [], text: "ok", added: [] },
    })

    // Answered.
    const reply = yield* request("POST", `/api/session/${session.id}/form/${answered}/reply`, {
      answer: { voz: "marin", nota: "ok" },
    })
    expect(reply.status).toBeLessThan(300)
    expect(yield* gone(session.id, answered)).toBe(true)

    // Dismissed.
    const dismissed = yield* form(session.id)
    yield* Effect.promise(() => drafts.save({ sessionID: session.id, requestID: dismissed, fields }, options))
    expect((yield* request("DELETE", `/api/session/${session.id}/form/${dismissed}`)).status).toBeLessThan(300)
    expect(yield* gone(session.id, dismissed)).toBe(true)

    // Cleared by a client.
    const cleared = yield* form(session.id)
    yield* Effect.promise(() => drafts.save({ sessionID: session.id, requestID: cleared, fields }, options))
    yield* Effect.promise(() => drafts.clear({ sessionID: session.id, requestID: cleared }, options))
    expect(yield* draftOf(session.id, cleared)).toBeNull()

    // Archived: every draft of the session goes.
    const archived = yield* form(session.id)
    yield* Effect.promise(() => drafts.save({ sessionID: session.id, requestID: archived, fields }, options))
    expect((yield* request("PATCH", `/api/session/${session.id}`, { archived: true })).status).toBeLessThan(300)
    expect(yield* gone(session.id, archived)).toBe(true)

    // Deleted.
    const other = yield* Effect.promise(() => client.session.create({ title: "Drafts 2", location }))
    const deleted = yield* form(other.id)
    yield* Effect.promise(() => drafts.save({ sessionID: other.id, requestID: deleted, fields }, options))
    expect((yield* request("DELETE", `/api/session/${other.id}`)).status).toBeLessThan(300)
    expect(yield* gone(other.id, deleted)).toBe(true)

    // An unknown session cannot store anything.
    const missing = yield* request("POST", "/api/rpc/custom.question-drafts/save", {
      input: { sessionID: "ses_missing", requestID: "frm_x", fields },
    })
    expect(missing.status).toBeGreaterThanOrEqual(400)
  }),
)
