import { expect } from "bun:test"
import { ConfigProvider, Effect } from "effect"
import { TestClock } from "effect/testing"
import { generateKeyPairSync, verify } from "node:crypto"
import { mkdtemp, rm } from "node:fs/promises"
import http2 from "node:http2"
import os from "node:os"
import path from "node:path"
import { it } from "../../core/test/lib/effect"
import { defaults, load, makeClient, origins } from "../src/live-activity/apns"
import { T } from "./fixture/live-activity"

type Received = { headers: http2.IncomingHttpHeaders; body: string }

/** A local cleartext HTTP/2 stand-in for APNs; the token in the path picks the answer. */
const fakeApns = Effect.acquireRelease(
  Effect.promise(
    () =>
      new Promise<{ origin: string; received: Received[]; server: http2.Http2Server }>((resolve) => {
        const received: Received[] = []
        const server = http2.createServer()
        server.on("stream", (stream, headers) => {
          const chunks: Buffer[] = []
          stream.on("data", (chunk: Buffer) => chunks.push(chunk))
          stream.on("end", () => {
            received.push({ headers, body: Buffer.concat(chunks).toString("utf8") })
            const token = String(headers[":path"]).split("/").at(-1)
            const answer: Record<string, [number, string]> = {
              gone: [410, JSON.stringify({ reason: "Unregistered", timestamp: T })],
              bad: [400, JSON.stringify({ reason: "BadDeviceToken" })],
              topic: [400, JSON.stringify({ reason: "DeviceTokenNotForTopic" })],
              busy: [503, JSON.stringify({ reason: "ServiceUnavailable" })],
              html: [500, "<html>oops</html>"],
            }
            const [status, body] = answer[token ?? ""] ?? [200, ""]
            stream.respond({ ":status": status, "apns-id": "id-1" })
            stream.end(body)
          })
        })
        server.listen(0, "127.0.0.1", () => {
          const address = server.address()
          const port = typeof address === "object" && address ? address.port : 0
          resolve({ origin: `http://127.0.0.1:${port}`, received, server })
        })
      }),
  ),
  (fake) => Effect.promise(() => new Promise<void>((resolve) => fake.server.close(() => resolve()))),
)

function keys() {
  return generateKeyPairSync("ec", { namedCurve: "P-256" })
}

function claims(authorization: string | string[] | undefined) {
  const [header, payload, signature] = String(authorization)
    .replace(/^bearer /, "")
    .split(".")
  return {
    header: JSON.parse(Buffer.from(header ?? "", "base64url").toString("utf8")),
    payload: JSON.parse(Buffer.from(payload ?? "", "base64url").toString("utf8")),
    signed: `${header}.${payload}`,
    signature: Buffer.from(signature ?? "", "base64url"),
  }
}

it.effect("sends contract headers, path and body over HTTP/2 with a reused ES256 provider token", () =>
  Effect.gen(function* () {
    yield* TestClock.setTime(T)
    const fake = yield* fakeApns
    const pair = keys()
    const environments: string[] = []
    const client = makeClient({
      key: pair.privateKey,
      keyID: "KEY1234567",
      teamID: defaults.teamID,
      bundleID: defaults.bundleID,
      origin: (environment) => {
        environments.push(environment)
        return fake.origin
      },
    })
    yield* Effect.addFinalizer(() => client.close)
    const body = {
      aps: { timestamp: T / 1000, event: "update", "content-state": { v: 1 }, "stale-date": T / 1000 + 900 },
    }
    const push = {
      token: "a1b2",
      environment: "production" as const,
      priority: 5 as const,
      expiration: T / 1000 + 900,
      body,
    }
    expect(yield* client.send(push)).toEqual({ status: "sent" })
    expect(yield* client.send({ ...push, priority: 10, environment: "sandbox" })).toEqual({ status: "sent" })
    expect(environments).toEqual(["production", "sandbox"])
    const [first, second] = fake.received
    expect(first?.headers).toMatchObject({
      ":method": "POST",
      ":path": "/3/device/a1b2",
      "apns-push-type": "liveactivity",
      "apns-topic": "br.com.alexandrem.opencode.push-type.liveactivity",
      "apns-priority": "5",
      "apns-expiration": String(T / 1000 + 900),
    })
    expect(second?.headers["apns-priority"]).toBe("10")
    expect(JSON.parse(first?.body ?? "")).toEqual(body)
    const token = claims(first?.headers.authorization)
    expect(token.header).toEqual({ alg: "ES256", kid: "KEY1234567" })
    expect(token.payload).toEqual({ iss: "ERRYZ68LX5", iat: T / 1000 })
    expect(
      verify("sha256", Buffer.from(token.signed), { key: pair.publicKey, dsaEncoding: "ieee-p1363" }, token.signature),
    ).toBe(true)
    // The provider token is reused for about 50 minutes, then reissued.
    expect(second?.headers.authorization).toBe(first?.headers.authorization)
    yield* TestClock.adjust(defaults.tokenMs)
    yield* client.send(push)
    expect(claims(fake.received[2]?.headers.authorization).payload.iat).toBe((T + defaults.tokenMs) / 1000)
  }),
)

it.effect("classifies APNs answers: 410 and 400 bad token are invalid, other errors fail", () =>
  Effect.gen(function* () {
    const fake = yield* fakeApns
    const client = makeClient({
      key: keys().privateKey,
      keyID: "KEY1234567",
      teamID: defaults.teamID,
      bundleID: defaults.bundleID,
      origin: () => fake.origin,
    })
    yield* Effect.addFinalizer(() => client.close)
    const send = (token: string) =>
      client.send({ token, environment: "sandbox", priority: 10, expiration: 1, body: {} })
    expect(yield* send("gone")).toEqual({ status: "invalid", reason: "Unregistered" })
    expect(yield* send("bad")).toEqual({ status: "invalid", reason: "BadDeviceToken" })
    expect(yield* send("topic")).toEqual({ status: "failed", reason: "DeviceTokenNotForTopic" })
    expect(yield* send("busy")).toEqual({ status: "failed", reason: "ServiceUnavailable" })
    expect(yield* send("html")).toEqual({ status: "failed", reason: "HTTP 500" })
    const unreachable = makeClient({
      key: keys().privateKey,
      keyID: "KEY1234567",
      teamID: defaults.teamID,
      bundleID: defaults.bundleID,
      origin: () => "http://127.0.0.1:1",
    })
    expect(
      (yield* unreachable.send({ token: "x", environment: "sandbox", priority: 5, expiration: 1, body: {} })).status,
    ).toBe("failed")
    expect(origins).toEqual({ sandbox: "https://api.sandbox.push.apple.com", production: "https://api.push.apple.com" })
  }),
)

it.live("credentials come from the environment; a missing key or key ID means unconfigured", () =>
  Effect.gen(function* () {
    const directory = yield* Effect.promise(() => mkdtemp(path.join(os.tmpdir(), "apns-")))
    const file = path.join(directory, "AuthKey.p8")
    yield* Effect.promise(() => Bun.write(file, keys().privateKey.export({ type: "pkcs8", format: "pem" }).toString()))
    const withEnv = (env: Record<string, string>) =>
      load().pipe(Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnv({ env }))))
    expect(yield* withEnv({})).toBeUndefined()
    expect(yield* withEnv({ OPENCODE_APNS_KEY_PATH: file })).toBeUndefined()
    expect(yield* withEnv({ OPENCODE_APNS_KEY_ID: "KEY1234567" })).toBeUndefined()
    expect(
      yield* withEnv({ OPENCODE_APNS_KEY_PATH: path.join(directory, "missing.p8"), OPENCODE_APNS_KEY_ID: "K" }),
    ).toBeUndefined()
    const client = yield* withEnv({ OPENCODE_APNS_KEY_PATH: file, OPENCODE_APNS_KEY_ID: "KEY1234567" })
    expect(client).toBeDefined()
    yield* client?.close ?? Effect.void
    yield* Effect.promise(() => rm(directory, { recursive: true }))
  }),
)
