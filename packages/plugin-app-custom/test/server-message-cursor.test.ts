import { expect } from "bun:test"
import { OpenCode, type SessionMessageInfo } from "@opencode/client"
import { MessagePage } from "@opencode/plugin/message"
import { ServerFetch } from "@opencode/server/fetch"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Effect } from "effect"
import { it } from "../../core/test/lib/effect"

const messages: SessionMessageInfo[] = [
  { id: "msg_z", type: "user", text: "First request", time: { created: 300 } },
  {
    id: "msg_assistant",
    type: "assistant",
    agent: "build",
    model: { providerID: "test", id: "test" },
    content: [{ type: "text", text: "First answer" }],
    finish: "stop",
    time: { created: 400, completed: 500 },
  },
  { id: "msg_b", type: "user", text: "Second request", time: { created: 100 } },
]

// The plugin host's message.list and the server's message route must read each other's cursors.
it.live("the server accepts plugin message cursors and rejects invalid cursor combinations", () =>
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
    const session = yield* Effect.promise(async () => {
      const template = await api.session.create({ title: "Message cursor" })
      return api.experimental.session.import({ info: { ...template, id: Session.ID.create() }, messages })
    })
    const request = (query: string) =>
      Effect.promise(() => handler(new Request(`http://opencode.local/api/session/${session.id}/message?${query}`)))

    const cursor = MessagePage.Cursor.make({ id: SessionMessage.ID.make("msg_b"), order: "desc", direction: "next" })
    const valid = yield* request(`cursor=${cursor}`)
    expect(valid.status).toBe(200)
    const body = yield* Effect.promise(() => valid.json())
    expect(body.data.map((message: SessionMessageInfo) => message.id)).toEqual(["msg_assistant", "msg_z"])

    for (const query of [`cursor=invalid`, `cursor=${cursor}&order=desc`]) {
      const response = yield* request(query)
      expect(response.status).toBe(400)
      expect(yield* Effect.promise(() => response.json())).toMatchObject({ _tag: "InvalidCursorError" })
    }

    const missing = MessagePage.Cursor.make({
      id: SessionMessage.ID.make("msg_missing"),
      order: "desc",
      direction: "next",
    })
    const response = yield* request(`cursor=${missing}`)
    expect(response.status).toBe(200)
    expect(yield* Effect.promise(() => response.json())).toEqual({ data: [], cursor: { previous: null, next: null } })
  }),
)
