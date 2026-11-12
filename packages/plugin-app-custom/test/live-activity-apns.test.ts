import { expect } from "bun:test"
import { ConfigProvider, Effect, Logger } from "effect"
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

it.effect("a WidgetKit push uses the widgets push type and the watch app's widget topic", () =>
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
    const body = { aps: { "content-changed": true } }
    expect(
      yield* client.send({
        token: "c0ffee",
        environment: "production",
        priority: 5,
        expiration: 1,
        body,
        type: "widgets",
        bundleID: `${defaults.bundleID}.watchkitapp`,
      }),
    ).toEqual({ status: "sent" })
    expect(fake.received[0]?.headers).toMatchObject({
      ":path": "/3/device/c0ffee",
      "apns-push-type": "widgets",
      "apns-topic": "br.com.alexandrem.opencode.watchkitapp.push-type.widgets",
      "apns-priority": "5",
    })
    expect(JSON.parse(fake.received[0]?.body ?? "")).toEqual(body)
  }),
)

it.live("credentials come from the environment; a missing key or key ID means unconfigured", () =>
  Effect.gen(function* () {
    const directory = yield* Effect.promise(() => mkdtemp(path.join(os.tmpdir(), "apns-")))
    const file = path.join(directory, "AuthKey.p8")
    yield* Effect.promise(() => Bun.write(file, keys().privateKey.export({ type: "pkcs8", format: "pem" }).toString()))
    const pem = keys().privateKey.export({ type: "pkcs8", format: "pem" }).toString()
    const missing = path.join(directory, "missing.p8")
    const notAKey = "-----BEGIN PRIVATE KEY-----\nnot-a-key-c0ffee\n-----END PRIVATE KEY-----\n"
    // Each case runs with its own log, which must never carry key material.
    const withEnv = (env: Record<string, string>, report = true) =>
      Effect.gen(function* () {
        const lines: string[] = []
        const logger = Logger.make((entry) => lines.push(JSON.stringify(entry.message)))
        const client = yield* load(report).pipe(
          Effect.provide(ConfigProvider.layer(ConfigProvider.fromEnv({ env }))),
          Effect.provideService(Logger.CurrentLoggers, new Set([logger])),
        )
        yield* client?.close ?? Effect.void
        expect(lines.join("\n")).not.toContain("PRIVATE KEY")
        expect(lines.join("\n")).not.toContain("c0ffee")
        return { configured: client !== undefined, log: lines.join("\n") }
      })
    const id = { OPENCODE_APNS_KEY_ID: "KEY1234567" }
    const cases: [Record<string, string>, boolean, string | undefined][] = [
      [{}, false, undefined],
      // The key without its ID (host-6, rev. 2026-11-12) says so at startup instead of staying silent.
      [{ OPENCODE_APNS_KEY_PATH: file }, false, "OPENCODE_APNS_KEY_ID is missing"],
      [{ OPENCODE_APNS_KEY_P8: pem }, false, "OPENCODE_APNS_KEY_ID is missing"],
      [{ ...id, OPENCODE_APNS_KEY_P8: pem, OPENCODE_APNS_KEY_PATH: missing }, true, "OPENCODE_APNS_KEY_P8"],
      [{ ...id, OPENCODE_APNS_KEY_PATH: file }, true, file],
      [{ ...id }, false, "OPENCODE_APNS_KEY_P8 (manual.json mycred, MyCredentials) and OPENCODE_APNS_KEY_PATH are missing"],
      [{ ...id, OPENCODE_APNS_KEY_PATH: missing }, false, missing],
      [{ ...id, OPENCODE_APNS_KEY_P8: notAKey, OPENCODE_APNS_KEY_PATH: file }, false, "unreadable"],
    ]
    for (const [env, configured, logged] of cases) {
      const result = yield* withEnv(env)
      expect({ env: Object.keys(env), configured: result.configured }).toEqual({ env: Object.keys(env), configured })
      if (logged) expect(result.log).toContain(logged)
    }
    // Nothing configured stays quiet: a server without pushes on purpose logs nothing.
    expect((yield* withEnv({})).log).toBe("")
    expect((yield* withEnv({ ...id, OPENCODE_APNS_KEY_PATH: file })).log).toContain("Live Activity APNs enabled")
    // The watch gateway's own load stays quiet, so the startup says each of these once.
    expect((yield* withEnv({ OPENCODE_APNS_KEY_PATH: file }, false)).log).toBe("")
    const quiet = yield* withEnv({ ...id, OPENCODE_APNS_KEY_PATH: file }, false)
    expect(quiet).toEqual({ configured: true, log: "" })
    yield* Effect.promise(() => rm(directory, { recursive: true }))
  }),
)

it.live("a session alert uses the alert push type with the bare bundle topic; OPENCODE_APNS_ORIGIN redirects tests", () =>
  Effect.gen(function* () {
    const fake = yield* fakeApns
    const directory = yield* Effect.promise(() => mkdtemp(path.join(os.tmpdir(), "apns-")))
    const file = path.join(directory, "AuthKey.p8")
    yield* Effect.promise(() => Bun.write(file, keys().privateKey.export({ type: "pkcs8", format: "pem" }).toString()))
    const client = yield* load().pipe(
      Effect.provide(
        ConfigProvider.layer(
          ConfigProvider.fromEnv({
            env: { OPENCODE_APNS_KEY_PATH: file, OPENCODE_APNS_KEY_ID: "KEY1234567", OPENCODE_APNS_ORIGIN: fake.origin },
          }),
        ),
      ),
    )
    if (!client) throw new Error("client expected")
    yield* Effect.addFinalizer(() => client.close)
    const body = { aps: { alert: { title: "Sessão", body: "Terminou · repo" }, "thread-id": "ses_1" } }
    expect(
      yield* client.send({
        token: "c0ffee",
        environment: "production",
        priority: 10,
        expiration: 1,
        body,
        type: "alert",
        collapseID: "attention:ses_1",
      }),
    ).toEqual({ status: "sent" })
    expect(fake.received[0]?.headers).toMatchObject({
      "apns-push-type": "alert",
      "apns-topic": defaults.bundleID,
      "apns-priority": "10",
      "apns-collapse-id": "attention:ses_1",
    })
    expect(JSON.parse(fake.received[0]?.body ?? "")).toEqual(body)
    yield* Effect.promise(() => rm(directory, { recursive: true }))
  }),
)
