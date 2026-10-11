import { afterEach, describe, expect, test } from "bun:test"
import { createServer, type IncomingMessage, type Server } from "node:http"
import { base64Encode } from "@opencode/util/encode"
import { decodePairingCode, decodePairingScan, decodePairingUrl, pairingLink, redeemPairingLink } from "./pairing"

const info = {
  urls: ["http://192.168.1.2:49374", "http://127.0.0.1:49374"],
  username: "opencode",
  password: "a+b & café",
}

describe("pairing scan", () => {
  test("accepts raw JSON and legacy query and fragment codes", () => {
    const expected = { urls: info.urls, password: info.password }
    expect(decodePairingScan(JSON.stringify(info))).toEqual(expected)
    expect(
      decodePairingScan(`http://192.168.1.2:49374/connect?data=${encodeURIComponent(JSON.stringify(info))}`),
    ).toEqual(expected)
    expect(decodePairingUrl(`#${encodeURIComponent(JSON.stringify(info))}`)).toEqual(expected)
  })

  test("uses a direct link origin when the payload omits server URLs", () => {
    const origin = "https://opencode.example.com:49709"
    const payload = JSON.stringify({ username: info.username, password: info.password })
    expect(decodePairingScan(` ${origin}/connect#${base64Encode(payload)} `)).toEqual({
      urls: [origin],
      password: info.password,
    })
    expect(decodePairingCode(payload)).toBeUndefined()
  })

  test("rejects malformed codes, non-HTTP schemes, and invalid payload credentials", () => {
    for (const value of [
      "http://192.168.1.2:49374/connect",
      "https://example.com/?data=invalid",
      "opencode-ios://connect?password=secret",
      "https://example.com/connect#A",
      "not a code",
      JSON.stringify({ ...info, username: "other" }),
      JSON.stringify({ ...info, urls: ["file:///tmp"] }),
    ])
      expect(decodePairingScan(value)).toBeUndefined()
  })
})

describe("pairing link", () => {
  test("reads the server address and code from opencode pair links", () => {
    expect(pairingLink(" http://192.168.1.2:49374/auth/connect/abc_DEF-123 ")).toEqual({
      urls: ["http://192.168.1.2:49374"],
      code: "abc_DEF-123",
    })
  })

  test("reads remote pairing links on a tunnel subdomain", () => {
    const link = "https://k3j9x2m4q8w7.f00dcafe.opentunnel.dev/auth/connect/Q2hpY2tlbi1zb3VwXzEyMw"
    expect(pairingLink(link)).toEqual({
      urls: ["https://k3j9x2m4q8w7.f00dcafe.opentunnel.dev"],
      code: "Q2hpY2tlbi1zb3VwXzEyMw",
    })
    // A pairing link is not one of the custom scan formats, so the scanner falls through to redeeming it.
    expect(decodePairingScan(link)).toBeUndefined()
  })

  test("reads every server address from opencode pair QR codes", () => {
    const qr = JSON.stringify({ code: "abc_DEF-123", urls: ["http://192.168.1.2:49374", "http://100.64.0.3:49374"] })
    expect(pairingLink(qr)).toEqual({
      urls: ["http://192.168.1.2:49374", "http://100.64.0.3:49374"],
      code: "abc_DEF-123",
    })
    expect(
      pairingLink(JSON.stringify({ code: "abc", urls: ["https://k3j9x2m4q8w7.f00dcafe.opentunnel.dev"] })),
    ).toEqual({ urls: ["https://k3j9x2m4q8w7.f00dcafe.opentunnel.dev"], code: "abc" })
    // The QR payload has no password, so the custom credential decoders leave it to the pairing link path.
    expect(decodePairingScan(qr)).toBeUndefined()
  })

  test("rejects other URLs", () => {
    expect(pairingLink("http://192.168.1.2:49374/auth/connect/")).toBeUndefined()
    expect(pairingLink("http://192.168.1.2:49374/auth/connect/abc/extra")).toBeUndefined()
    expect(pairingLink("http://192.168.1.2:49374/connect#abc")).toBeUndefined()
    expect(pairingLink("opencode-ios://auth/connect/abc")).toBeUndefined()
    expect(pairingLink("192.168.1.2:49374")).toBeUndefined()
  })

  test("rejects malformed QR payloads", () => {
    expect(pairingLink(JSON.stringify({ code: "abc", urls: [] }))).toBeUndefined()
    expect(pairingLink(JSON.stringify({ code: "a/b", urls: ["http://192.168.1.2:49374"] }))).toBeUndefined()
    expect(pairingLink(JSON.stringify({ code: "abc", urls: ["opencode-ios://host"] }))).toBeUndefined()
    expect(pairingLink(JSON.stringify({ urls: ["http://192.168.1.2:49374"] }))).toBeUndefined()
    expect(pairingLink(JSON.stringify(info))).toBeUndefined()
    expect(pairingLink("{not json")).toBeUndefined()
  })
})

describe("redeem pairing link", () => {
  // Real local HTTP servers (node:http, since the DOM preload replaces the Response class Bun.serve expects): one
  // accepts its code once, as `GET /auth/connect/:code` does, and closed ones refuse connections.
  const servers: Server[] = []
  afterEach(() => {
    for (const server of servers.splice(0)) server.close()
  })

  const listen = async (handler: (request: IncomingMessage) => { status: number; body: unknown }) => {
    const server = createServer((request, response) => {
      const reply = handler(request)
      response.writeHead(reply.status, {
        "content-type": "application/json",
        "access-control-allow-origin": "*",
        "access-control-allow-headers": "*",
      })
      response.end(JSON.stringify(reply.body))
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    servers.push(server)
    const address = server.address()
    if (!address || typeof address === "string") throw new Error("Test server has no port")
    return { server, url: `http://127.0.0.1:${address.port}` }
  }

  const unauthorized = (message: string) => ({ status: 401, body: { _tag: "UnauthorizedError", message } })

  const pairingServer = async (code: string, token: string) => {
    const state = { redeemed: false }
    const listening = await listen((request) => {
      const url = new URL(request.url ?? "/", "http://127.0.0.1")
      if (request.method === "OPTIONS") return { status: 204, body: "" }
      if (url.pathname === "/api/info") {
        if (request.headers.authorization !== `Basic ${btoa(`opencode:${token}`)}`)
          return unauthorized("Authentication required")
        return { status: 200, body: { version: "2.0.26", pid: 1, urls: [], paths: {}, capabilities: {} } }
      }
      if (url.pathname !== `/auth/connect/${code}` || state.redeemed)
        return unauthorized("Pairing link expired or already used")
      state.redeemed = true
      return { status: 200, body: { token } }
    })
    return listening.url
  }

  const closedAddress = async () => {
    const listening = await listen(() => ({ status: 200, body: {} }))
    await new Promise((resolve) => listening.server.close(resolve))
    return listening.url
  }

  test("exchanges the code for a token at the address that answers", async () => {
    const url = await pairingServer("abc_DEF-123", "session-token")
    expect(await redeemPairingLink({ urls: [url], code: "abc_DEF-123" })).toEqual({
      type: "paired",
      pairing: { urls: [url], password: "session-token" },
    })
  })

  test("reports a spent code as expired", async () => {
    const url = await pairingServer("abc", "session-token")
    await redeemPairingLink({ urls: [url], code: "abc" })
    expect(await redeemPairingLink({ urls: [url], code: "abc" })).toEqual({ type: "expired" })
  })

  test("reports a server that cannot be reached as unreachable, not expired", async () => {
    expect(await redeemPairingLink({ urls: [await closedAddress()], code: "abc" })).toEqual({ type: "unreachable" })
  })

  test("pairs through any reachable address of a QR code", async () => {
    const url = await pairingServer("abc", "session-token")
    expect(await redeemPairingLink({ urls: [await closedAddress(), url], code: "abc" })).toEqual({
      type: "paired",
      pairing: { urls: [url], password: "session-token" },
    })
  })

  test("keeps the first address when another one spent the code first and the token works there", async () => {
    // Two addresses of one server: the second redeems the code, the first answers 401 but accepts the token.
    const first = await pairingServer("spent-by-the-other-address", "session-token")
    const second = await pairingServer("abc", "session-token")
    expect(await redeemPairingLink({ urls: [first, second], code: "abc" })).toEqual({
      type: "paired",
      pairing: { urls: [first], password: "session-token" },
    })
  })
})
