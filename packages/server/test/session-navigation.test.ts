import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Effect } from "effect"
import { it } from "../../core/test/lib/effect"
import { ServerFetch } from "../src/fetch"

it.live("navigation includes closed sessions and live questions, with generated-client pagination", () =>
  Effect.gen(function* () {
    const handler = yield* ServerFetch.make({
      app: { version: "test" },
      database: { path: ":memory:" },
      config: { project: false },
      models: { fetch: false },
      fs: { filewatcher: false },
    })
    const api = OpenCode.make({
      baseUrl: "http://opencode.local",
      fetch: Object.assign((input: string | URL | Request, init?: RequestInit) => handler(new Request(input, init)), {
        preconnect: fetch.preconnect,
      }),
    })
    yield* Effect.promise(async () => {
      const session = await api.session.create({ title: "Closed session" })
      const second = await api.session.create({ title: "Another closed session" })
      const first = await api.session.navigation({ limit: 1 })
      expect(first.data).toHaveLength(1)
      expect(first.next).toBeDefined()
      const last = await api.session.navigation({ after: first.next, limit: 1 })
      expect(last.data).toHaveLength(1)
      expect(last.next).toBeUndefined()
      expect(new Set([...first.data, ...last.data].map((row) => row.session.id))).toEqual(
        new Set([session.id, second.id]),
      )
      const form = await api.form.create({
        sessionID: session.id,
        title: "Question",
        metadata: { kind: "question" },
        fields: [{ key: "answer", type: "string" }],
      })
      const pending = await api.session.navigation({ sessionID: session.id })
      expect(pending.data[0].questionAt).toBe(form.created)
      expect(pending.data[0].questionAt).toBeGreaterThan(0)
      await api.form.reply({ sessionID: session.id, formID: form.id, answer: { answer: "done" } })
      expect((await api.session.navigation({ sessionID: session.id })).data[0].questionAt).toBeUndefined()
      await api.session.archive({ sessionID: session.id })
      expect((await api.session.navigation({ sessionID: session.id })).data).toEqual([])
      expect((await api.session.navigation()).data.map((row) => row.session.id)).toEqual([second.id])
      await api.session.remove({ sessionID: second.id })
      expect((await api.session.navigation({ sessionID: second.id })).data).toEqual([])
      expect((await api.session.navigation()).data).toEqual([])
    })
  }),
)
