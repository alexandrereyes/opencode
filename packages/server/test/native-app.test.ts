import { expect } from "bun:test"
import { Effect, Schema } from "effect"
import { NativeApp } from "@opencode/core/native-app"
import { ServerFetch } from "../src/fetch"
import { it } from "../../core/test/lib/effect"

it.live("authenticates native app routes, validates app IDs, and reports an unsupported host", () =>
  Effect.gen(function* () {
    const handler = yield* ServerFetch.make(
      {
        password: "secret",
        database: { path: ":memory:" },
        config: { project: false, content: "{}" },
        models: { fetch: false },
        fs: { filewatcher: false, fff: false },
      },
      { overrides: [NativeApp.node.replace(NativeApp.configured({ platform: "linux" }))] },
    )
    const url = "http://opencode.local/api/server/native-apps"
    const headers = { authorization: `Basic ${btoa("opencode:secret")}`, "content-type": "application/json" }

    expect((yield* Effect.promise(() => handler(new Request(url)))).status).toBe(401)
    expect(
      (yield* Effect.promise(() =>
        handler(
          new Request(`${url}/open`, {
            method: "POST",
            body: JSON.stringify({ app: "rider", path: "/project" }),
          }),
        ),
      )).status,
    ).toBe(401)

    const list = yield* Effect.promise(() => handler(new Request(url, { headers })))
    expect(list.status).toBe(200)
    expect(yield* Effect.promise(() => list.json())).toEqual({ os: null, apps: [] })

    const invalid = yield* Effect.promise(() =>
      handler(
        new Request(`${url}/open`, {
          method: "POST",
          headers,
          body: JSON.stringify({ app: "sh", path: "/project" }),
        }),
      ),
    )
    expect(invalid.status).toBe(400)

    const unsupported = yield* Effect.promise(() =>
      handler(
        new Request(`${url}/open`, {
          method: "POST",
          headers,
          body: JSON.stringify({ app: "rider", path: "/project" }),
        }),
      ),
    )
    expect(unsupported.status).toBe(503)
    const error = Schema.decodeUnknownSync(Schema.Struct({ _tag: Schema.String, service: Schema.String }))(
      yield* Effect.promise(() => unsupported.json()),
    )
    expect(error).toEqual({ _tag: "ServiceUnavailableError", service: "native-apps" })
  }),
)
