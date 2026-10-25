// Loopback proxy for the custom server, installed by custom:activate/update as <runtime>/bin/proxy.mjs and run by
// launchd (com.alexandrem.opencode2-ui) with Homebrew Node. nginx (Cloudflare One route) and local browsers reach
// 127.0.0.1:4096; the proxy injects the server credentials. /resources/* goes to the session resources hub
// instead, which authorizes every request with its own short tickets (no server credentials are forwarded).
import http from "node:http"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
// The launchd job sets no environment; the overrides exist for tests.
const home = process.env.OPENCODE_CUSTOM_HOME ?? path.join(os.homedir(), ".local/share/opencode-custom-v2")
const port = Number(process.env.OPENCODE_PROXY_PORT ?? 4096)
const hubPort = Number(process.env.OPENCODE_RESOURCES_HUB_PORT ?? 4179)
function options(req) {
  if (resources(req)) {
    const { authorization, ...headers } = req.headers
    return { hostname: "127.0.0.1", port: hubPort, path: req.url, method: req.method, headers }
  }
  const config = JSON.parse(fs.readFileSync(path.join(home, "config/opencode/service-custom.json"), "utf8"))
  return {
    hostname: config.hostname,
    port: config.port,
    path: req.url,
    method: req.method,
    headers: {
      ...req.headers,
      authorization: "Basic " + Buffer.from("opencode:" + config.password).toString("base64"),
    },
  }
}
function resources(req) {
  return (req.url ?? "").startsWith("/resources/")
}
function allowed(req) {
  return (
    [`localhost:${port}`, `127.0.0.1:${port}`, `[::1]:${port}`].includes((req.headers.host ?? "").toLowerCase()) &&
    (!req.headers.origin ||
      [`http://localhost:${port}`, `http://127.0.0.1:${port}`, `http://[::1]:${port}`].includes(req.headers.origin))
  )
}
const server = http.createServer((req, res) => {
  if (!allowed(req)) {
    res.writeHead(403).end()
    return
  }
  let upstream
  try {
    upstream = http.request(options(req), (response) => {
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
  if (!allowed(req)) {
    socket.destroy()
    return
  }
  let upstream
  try {
    upstream = http.request(options(req))
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
