import { expect } from "bun:test"
import path from "node:path"
import { Effect, Schema } from "effect"
import { HttpServer } from "effect/unstable/http"
import { Snippet } from "@opencode/schema/snippet"
import { ServerProcess } from "../src/process"
import { tmpdir } from "../../core/test/fixture/tmpdir"
import { it } from "../../core/test/lib/effect"

it.live("shares snippets between clients, authenticates writes, and persists after reopening the server", () =>
  Effect.gen(function* () {
    const tmp = yield* Effect.acquireDisposable(Effect.promise(() => tmpdir("opencode-snippets-")))
    const headers = { authorization: `Basic ${btoa("opencode:secret")}`, "content-type": "application/json" }
    const snippet = {
      id: "saved",
      name: "review",
      description: "Review",
      aliases: ["audit"],
      content: "Persisted content",
    }
    const start = () =>
      ServerProcess.start<never, never>({
        hostname: "127.0.0.1",
        port: 0,
        password: "secret",
        app: { version: "test" },
        database: { path: path.join(tmp.path, "snippets.db") },
        config: { directory: tmp.path, project: false },
        models: { fetch: false },
        fs: { filewatcher: false },
      })
    yield* Effect.scoped(
      Effect.gen(function* () {
        const server = yield* start()
        const url = new URL("/api/snippet", HttpServer.formatAddress(server.address))
        const denied = yield* Effect.promise(() =>
          fetch(url, { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(snippet) }),
        )
        expect(denied.status).toBe(401)
        yield* Effect.promise(() => denied.arrayBuffer())
        const saved = yield* Effect.promise(() => fetch(url, { method: "PUT", headers, body: JSON.stringify(snippet) }))
        expect(saved.status).toBe(200)
        expect(yield* Effect.promise(() => saved.json())).toEqual(snippet)
        const secondClient = yield* Effect.promise(() => fetch(url, { headers }))
        expect(yield* Effect.promise(() => secondClient.json())).toEqual([snippet])
        const invalid = yield* Effect.promise(() =>
          fetch(url, { method: "PUT", headers, body: JSON.stringify({ ...snippet, content: " " }) }),
        )
        expect(invalid.status).toBe(400)
        yield* Effect.promise(() => invalid.arrayBuffer())
        const conflict = yield* Effect.promise(() =>
          fetch(url, { method: "PUT", headers, body: JSON.stringify({ ...snippet, id: "duplicate", name: "REVIEW" }) }),
        )
        expect(conflict.status).toBe(409)
        yield* Effect.promise(() => conflict.arrayBuffer())
      }),
    )
    yield* Effect.scoped(
      Effect.gen(function* () {
        const server = yield* start()
        const url = new URL("/api/snippet", HttpServer.formatAddress(server.address))
        const response = yield* Effect.promise(() => fetch(url, { headers }))
        expect(
          Schema.decodeUnknownSync(Schema.Array(Snippet.Info))(yield* Effect.promise(() => response.json())),
        ).toEqual([snippet])
        const deleted = yield* Effect.promise(() => fetch(`${url}/saved`, { method: "DELETE", headers }))
        expect(deleted.status).toBe(200)
        yield* Effect.promise(() => deleted.arrayBuffer())
        const empty = yield* Effect.promise(() => fetch(url, { headers }))
        expect(yield* Effect.promise(() => empty.json())).toEqual([])
      }),
    )
  }),
)
