// Loopback proxy for the custom server, installed by custom:activate/update as <runtime>/bin/proxy.mjs and run by
// launchd (com.alexandrem.opencode2-ui) with Homebrew Node. nginx (Cloudflare One route), the Mac app and local
// browsers reach 127.0.0.1:4096. Other users and processes of the Mac reach it too, so the proxy demands the
// server's own credentials (packages/server/src/middleware/authorization.ts) before forwarding, and forwards them
// unchanged: it never adds a credential. /resources/* goes to the session resources hub instead, which authorizes
// every request with its own short tickets (no server credentials are forwarded).
import http from "node:http"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import { createHmac, timingSafeEqual } from "node:crypto"
// The launchd job sets no environment; the overrides exist for tests.
const home = process.env.OPENCODE_CUSTOM_HOME ?? path.join(os.homedir(), ".local/share/opencode-custom-v2")
const port = Number(process.env.OPENCODE_PROXY_PORT ?? 4096)
const hubPort = Number(process.env.OPENCODE_RESOURCES_HUB_PORT ?? 4179)
const username = "opencode"
// Routes the server opens without credentials because it validates their single-use code or ticket itself.
const pairing = /^\/auth\/connect\/[^/]+$/
const ticketed = [
  /^\/api\/pty\/[^/]+\/connect$/,
  /^\/api\/experimental\/persistent-pty\/[^/]+\/connect$/,
  /^\/api\/experimental\/client-mcp$/,
]
function config() {
  const value = JSON.parse(fs.readFileSync(path.join(home, "config/opencode/service-custom.json"), "utf8"))
  // Without a password the server would not ask for one either: refuse instead of forwarding.
  if (typeof value.password !== "string" || value.password === "") throw new Error("no server password")
  return value
}
// The path as the upstream will route it (dot segments resolved), so the checks below and the upstream agree.
function target(req) {
  const url = new URL(req.url ?? "/", "http://localhost")
  return { url, path: url.pathname + url.search }
}
function resources(url) {
  return url.pathname.startsWith("/resources/")
}
function same(a, b) {
  const left = Buffer.from(a)
  const right = Buffer.from(b)
  return left.length === right.length && timingSafeEqual(left, right)
}
// Session tokens from pairing links and the web sign-in: `<expires>.<hmac>`, keyed by the password.
function session(token, password) {
  const parts = token.split(".")
  if (parts.length !== 2) return false
  const expires = Number(parts[0])
  if (!Number.isSafeInteger(expires) || expires * 1000 <= Date.now()) return false
  const key = createHmac("sha256", password).update("opencode-session-v1").digest()
  return same(parts[1], createHmac("sha256", key).update(parts[0]).digest("base64url"))
}
function credential(encoded, password) {
  const decoded = Buffer.from(encoded, "base64").toString("utf8")
  const separator = decoded.indexOf(":")
  if (separator === -1 || decoded.slice(0, separator) !== username) return false
  const secret = decoded.slice(separator + 1)
  return same(secret, password) || session(secret, password)
}
function sessionCookie(req, password) {
  const host = req.headers.host ?? ""
  const hostPort = URL.parse(`http://${host}`)?.port
  const name = hostPort ? `opencode_session_${hostPort}` : "opencode_session"
  const entry = (req.headers.cookie ?? "")
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(name + "="))
  const token = entry?.slice(name.length + 1)
  if (!token) return false
  // Same-site pages on other ports still send the cookie, so only same-origin requests may use it.
  if (req.headers.origin !== undefined && URL.parse(req.headers.origin)?.host !== host) return false
  return session(token, password)
}
function authorized(req, url, password) {
  if (pairing.test(url.pathname)) return true
  if (url.searchParams.get("ticket") && ticketed.some((route) => route.test(url.pathname))) return true
  const token = url.searchParams.get("auth_token")
  const header = /^Basic\s+(.+)$/i.exec(req.headers.authorization ?? "")?.[1]
  const encoded = token || header
  return (encoded !== undefined && credential(encoded, password)) || sessionCookie(req, password)
}
function challenge(req) {
  const mode = req.headers["sec-fetch-mode"]
  return mode === undefined || mode === "navigate"
}
// What to do with a request: forward it (`options`) or answer it with a status.
function route(req) {
  if (!allowed(req)) return { status: 403 }
  const { url, path: forwarded } = target(req)
  if (resources(url)) {
    // The hub needs only its ticket: server credentials never reach it.
    const { authorization: _authorization, cookie: _cookie, ...rest } = req.headers
    return { options: { hostname: "127.0.0.1", port: hubPort, path: forwarded, method: req.method, headers: rest } }
  }
  let server
  try {
    server = config()
  } catch {
    return { status: 503 }
  }
  if (!authorized(req, url, server.password)) return { status: 401, challenge: challenge(req) }
  return {
    options: {
      hostname: server.hostname,
      port: server.port,
      path: forwarded,
      method: req.method,
      headers: req.headers,
    },
  }
}
const unauthorized = JSON.stringify({ _tag: "UnauthorizedError", message: "Authentication required" })
function refusal(decision) {
  if (decision.status !== 401) return {}
  return {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(unauthorized),
    ...(decision.challenge ? { "www-authenticate": 'Basic realm="Secure Area"' } : {}),
  }
}
function allowed(req) {
  return (
    [`localhost:${port}`, `127.0.0.1:${port}`, `[::1]:${port}`].includes((req.headers.host ?? "").toLowerCase()) &&
    (!req.headers.origin ||
      [`http://localhost:${port}`, `http://127.0.0.1:${port}`, `http://[::1]:${port}`].includes(req.headers.origin))
  )
}
const server = http.createServer((req, res) => {
  const decision = route(req)
  if (!decision.options) {
    res.writeHead(decision.status, refusal(decision)).end(decision.status === 401 ? unauthorized : undefined)
    return
  }
  let upstream
  try {
    upstream = http.request(decision.options, (response) => {
      res.writeHead(response.statusCode, response.headers)
      response.pipe(res)
    })
  } catch {
    res.writeHead(503).end()
    return
  }
  upstream.on("error", () => {
    if (!res.headersSent) res.writeHead(502)
    res.end()
  })
  res.on("close", () => upstream.destroy())
  req.pipe(upstream)
})
server.on("upgrade", (req, socket, head) => {
  const decision = route(req)
  if (!decision.options) {
    if (decision.status === 401)
      socket.end(
        "HTTP/1.1 401 Unauthorized\r\n" +
          Object.entries({ ...refusal(decision), connection: "close" })
            .map(([key, value]) => `${key}: ${value}`)
            .join("\r\n") +
          "\r\n\r\n" +
          unauthorized,
      )
    else socket.destroy()
    return
  }
  let upstream
  try {
    upstream = http.request(decision.options)
  } catch {
    socket.destroy()
    return
  }
  upstream.on("upgrade", (res, peer, upstreamHead) => {
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        Object.entries(res.headers)
          .map(([key, value]) => `${key}: ${value}`)
          .join("\r\n") +
        "\r\n\r\n",
    )
    if (upstreamHead.length) socket.write(upstreamHead)
    if (head.length) peer.write(head)
    // Live streams send many small frames; do not delay them.
    socket.setNoDelay(true)
    peer.setNoDelay(true)
    peer.on("error", () => socket.destroy())
    socket.on("error", () => peer.destroy())
    peer.pipe(socket)
    socket.pipe(peer)
  })
  upstream.on("response", () => socket.destroy())
  upstream.on("error", () => socket.destroy())
  upstream.end()
})
server.listen(port, "127.0.0.1")
