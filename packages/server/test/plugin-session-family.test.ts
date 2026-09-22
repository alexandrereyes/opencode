import fs from "node:fs/promises"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { expect } from "bun:test"
import { OpenCode } from "@opencode/client"
import { Family } from "@opencode/plugin-app-custom/session-family/rpc"
import { SessionMessage } from "@opencode/schema/session-message"
import { Session } from "@opencode/schema/session"
import { Effect } from "effect"
import { tmpdirScoped } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"
import { startServer } from "./fixture/server"

it.live("serves bounded family pages and pending descendants through the actual plugin RPC", () =>
  Effect.gen(function* () {
    const tmp = yield* tmpdirScoped("opencode-session-family-")
    const directory = path.join(tmp.path, "project")
    const plugin = pathToFileURL(path.resolve(import.meta.dir, "../../plugin-app-custom/src/index.ts")).href
    yield* Effect.promise(async () => {
      await fs.mkdir(path.join(directory, ".opencode", "plugins"), { recursive: true })
      await fs.writeFile(
        path.join(directory, ".opencode", "plugins", "app-custom.ts"),
        `export { default } from ${JSON.stringify(plugin)}\n`,
      )
    })
    const server = yield* startServer(path.join(tmp.path, "config"))
    const requests: string[] = []
    const client = OpenCode.make({
      baseUrl: server.base,
      headers: server.headers,
      fetch: Object.assign(
        (...args: Parameters<typeof fetch>) => {
          requests.push(String(args[0]))
          return fetch(...args)
        },
        { preconnect: fetch.preconnect },
      ),
    })
    const location = { directory }
    const root = yield* Effect.promise(() => client.session.create({ title: "Family with 154 descendants", location }))
    const ids = Array.from({ length: 154 }, () => Session.ID.create())
    yield* Effect.forEach(
      ids,
      (id, i) =>
        Effect.promise(() =>
          client.session.import({
            info: {
              ...root,
              id,
              parentID: i === 153 ? ids[0] : root.id,
              title: `Child ${i}`,
              time: { ...root.time, ...(i === 150 ? { archived: 1 } : {}) },
            },
            messages:
              i === 0 || i === 153
                ? [
                    { id: `msg_family_${i}_before`, type: "user", text: "Before", time: { created: 99 } },
                    { id: `msg_family_${i}_exact`, type: "user", text: "At cutoff", time: { created: 100 } },
                  ]
                : [],
            location,
          }),
        ),
      { concurrency: 4 },
    )
    const before = requests.length
    expect(
      yield* Effect.promise(() =>
        client.rpc(Family.Definition).revert({ sessionID: root.id, cutoff: 101 }, { location }),
      ),
    ).toEqual([])
    expect(requests.length - before).toBe(1)
    const boundaries = yield* Effect.promise(() =>
      client.rpc(Family.Definition).revert({ sessionID: root.id, cutoff: 100 }, { location }),
    )
    expect(boundaries).toEqual([
      { sessionID: ids[0], messageID: SessionMessage.ID.make("msg_family_0_exact") },
      { sessionID: ids[153], messageID: SessionMessage.ID.make("msg_family_153_exact") },
    ])
    yield* Effect.forEach(boundaries, (boundary) =>
      Effect.promise(() => client.session.revert.stage({ ...boundary, files: false })),
    )
    expect(
      yield* Effect.promise(() => client.rpc(Family.Definition).clear({ sessionID: root.id }, { location })),
    ).toEqual(boundaries)
    expect((yield* Effect.promise(() => client.session.get({ sessionID: ids[0] }))).revert?.files).toEqual([])
    const missingPlan = yield* Effect.promise(() =>
      client
        .rpc(Family.Definition)
        .revert({ sessionID: "ses_missing", cutoff: 100 }, { location })
        .catch((error: unknown) => error),
    )
    expect(missingPlan).toMatchObject({ type: "read_failed" })
    const form = yield* Effect.promise(() =>
      client.session.form.create({
        sessionID: ids[153],
        title: "Question from an unloaded grandchild",
        metadata: { kind: "question" },
        fields: [{ key: "answer", type: "string" }],
      }),
    )
    const snapshot = yield* Effect.promise(() =>
      client.rpc(Family.Definition).snapshot({ sessionID: root.id }, { location }),
    )
    expect(snapshot.count).toBe(154)
    expect(snapshot.forms.map((item) => item.id)).toEqual([form.id])
    expect(snapshot).not.toHaveProperty("data")
    const page = yield* Effect.promise(() =>
      client.rpc(Family.Definition).page({ sessionID: root.id, limit: 10 }, { location }),
    )
    expect(page.data).toHaveLength(10)
    const second = yield* Effect.promise(() =>
      client.rpc(Family.Definition).page({ sessionID: root.id, limit: 10, after: page.next }, { location }),
    )
    expect(new Set([...page.data, ...second.data].map((item) => item.id)).size).toBe(20)
    yield* Effect.promise(() =>
      client.session.form.reply({ sessionID: ids[153], formID: form.id, answer: { answer: "done" } }),
    )
    const cleared = yield* Effect.promise(() =>
      client.rpc(Family.Definition).snapshot({ sessionID: root.id }, { location }),
    )
    expect(cleared.forms).toEqual([])
    const missing = yield* Effect.promise(() =>
      client
        .rpc(Family.Definition)
        .snapshot({ sessionID: "ses_missing" }, { location })
        .catch((error: unknown) => error),
    )
    expect(missing).toMatchObject({ type: "read_failed" })
  }),
)
