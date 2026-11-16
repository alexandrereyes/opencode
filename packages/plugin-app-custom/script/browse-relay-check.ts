#!/usr/bin/env bun
/**
 * End to end for browse resources and handoffs on browse 0.1.0 (`docs/browse-handoff-remoto.md`), isolated from any
 * live browse: its own relay (`browse serve` with `OPENCODE_BROWSER_HOME` in a temporary folder and its own port), a
 * headless Chromium with the unpacked extension paired through the official `relay-pairing.json`, a local login page,
 * and the real resources hub with the real Chrome adapter. It never talks to a relay on 19988.
 *
 *   bun script/browse-relay-check.ts --browse <browse 0.1.0 binary> --extension <unpacked browse-extension-0.1.0> \
 *     --chrome <Chromium or Chrome for Testing executable> [--port 19995] [--keep]
 *
 * It checks that the probe shows only the owner's tab, measures `screenshot` latency and the live view's frame rate
 * through the hub, and finishes a real `handoff` by a viewer tap on its Continue card, as the iPhone does. Prints one
 * JSON report; removes everything it started unless `--keep`.
 */
import { createHash, randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"
import { browseOwner } from "../src/browser-handoff/calls.js"
import { callTool, imageOf, jsonOf, textOf } from "../src/resources/adapters/browse-relay.js"
import { makeChromeAdapter } from "../src/resources/adapters/chrome.js"
import { createHub } from "../src/resources/hub/hub.js"
import { ResourceProtocol } from "../src/resources/protocol.js"
import { Resources } from "../src/resources/rpc.js"
import { Schema } from "effect"

const args = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    browse: { type: "string" },
    extension: { type: "string" },
    chrome: { type: "string" },
    port: { type: "string", default: "19995" },
    keep: { type: "boolean" },
  },
})
const browse = args.values.browse ?? ""
const extension = args.values.extension ?? ""
const chrome = args.values.chrome ?? ""
const port = Number(args.values.port)
if (!browse || !extension || !chrome) throw new Error("Usage: --browse BINARY --extension DIR --chrome EXECUTABLE")
if (port === 19988) throw new Error("Never on browse's default port: a live relay may be there")
if (await fetch(`http://127.0.0.1:${port}/version`).then(() => true, () => false))
  throw new Error(`Something already answers on ${port}`)

const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), "browse-relay-check-")))
const unpacked = path.join(root, "extension")
await fs.cp(extension, unpacked, { recursive: true })
// Chrome's ID of an unpacked extension: the SHA-256 of its path, its first 32 hex digits spelled a–p.
const id = [...createHash("sha256").update(unpacked).digest("hex").slice(0, 32)]
  .map((digit) => String.fromCharCode(97 + Number.parseInt(digit, 16)))
  .join("")
const env = {
  ...process.env,
  OPENCODE_BROWSER_HOME: path.join(root, "browse"),
  OPENCODE_BROWSER_PORT: String(port),
  OPENCODE_BROWSER_EXTENSION_ORIGINS: `chrome-extension://${id}`,
  OPENCODE_BROWSER_AUTO_UPDATE: "off",
  OPENCODE_BROWSER_IDLE_SHUTDOWN_MS: "0",
}
// The relay client, the adapter and the hub below read these.
Object.assign(process.env, { OPENCODE_BROWSER_HOME: env.OPENCODE_BROWSER_HOME, OPENCODE_BROWSER_PORT: env.OPENCODE_BROWSER_PORT })

const children: { kill: (signal?: NodeJS.Signals) => void }[] = []
const stops: (() => unknown)[] = []
const report: Record<string, unknown> = { port, extension: id }
try {
  children.push(Bun.spawn([browse, "serve"], { env, stdout: "ignore", stderr: "ignore" }))
  await until(() => fetch(`http://127.0.0.1:${port}/version`).then((r) => r.ok, () => false), 10_000, "the relay")
  const pair = Bun.spawn([browse, "pair", "--wait-seconds", "120"], { env, stdout: "pipe", stderr: "ignore" })
  children.push(pair)
  const code = await pairingCode(pair.stdout)
  await Bun.write(path.join(unpacked, "relay-pairing.json"), JSON.stringify({ code, port }))
  children.push(
    Bun.spawn(
      [
        chrome,
        "--headless=new",
        `--user-data-dir=${path.join(root, "profile")}`,
        `--disable-extensions-except=${unpacked}`,
        `--load-extension=${unpacked}`,
        // Without these a headless Chrome on macOS waits on a Keychain prompt nobody sees, and the extension never
        // connects.
        "--use-mock-keychain",
        "--password-store=basic",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-renderer-backgrounding",
        "--disable-background-timer-throttling",
        "--no-first-run",
        "--no-default-browser-check",
        "--window-size=1280,800",
        "about:blank",
      ],
      { stdout: "ignore", stderr: "ignore" },
    ),
  )
  const token = (await Bun.file(path.join(root, "browse/relay-token")).text()).trim()
  await until(
    () =>
      fetch(`http://127.0.0.1:${port}/extension/status`, { headers: { authorization: `Bearer ${token}` } })
        .then((r) => r.json())
        .then((status: { connected?: boolean }) => status.connected === true),
    30_000,
    "the extension to pair",
  )

  const page = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: () =>
      new Response(
        `<!doctype html><title>Entrar · Check</title><body style="font:16px sans-serif"><h1>Entrar</h1>
<input id=user autocomplete=username> <input id=pass type=password> <button>Entrar</button> <b id=clock></b>
<script>setInterval(() => (clock.textContent = Date.now()), 50)</script>${"<p>linha</p>".repeat(80)}`,
        { headers: { "content-type": "text/html; charset=utf-8" } },
      ),
  })
  stops.push(() => page.stop(true))
  const owner = browseOwner(`ses_check_${randomUUID()}`)
  const opened = jsonOf(
    await callTool(owner, "navigate", { url: `http://127.0.0.1:${page.port}/` }, { timeoutMs: 30_000 }),
    Schema.Struct({ tab: Schema.Int }),
  )
  if (!opened) throw new Error("navigate opened no tab")
  const tab = opened.tab

  // Latency of the call the live view polls.
  const latencies: number[] = []
  for (let index = 0; index < 20; index++) {
    const started = performance.now()
    const shot = await callTool(owner, "screenshot", { tab, format: "jpeg", quality: 70, scale: "css" })
    latencies.push(performance.now() - started)
    if (index === 0) report.screenshot = { summary: JSON.parse(textOf(shot)), bytes: imageOf(shot)?.byteLength }
  }
  latencies.sort((a, b) => a - b)
  report.screenshotMs = { p50: round(latencies[10]!), p90: round(latencies[18]!), max: round(latencies[19]!) }

  // The real hub with the real Chrome adapter, as the plugin registers a session's browse resource.
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const secret = randomUUID()
  const hub = createHub({ adapters: { "ios-simulator": adapter, "android-emulator": adapter, chrome: adapter }, secret })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  stops.push(() => {
    hub.close()
    server.stop(true)
  })
  const cdp = `http://127.0.0.1:${port}`
  const owned = { sessionID: "ses_check", rootSessionID: "ses_check" }
  const resource = await hub.register({
    kind: "chrome",
    meta: { kind: "chrome", cdp, browse: owner, targetID: String(tab) },
    owner: owned,
    used: true,
  })
  await hub.probe(["chrome"])
  report.probe = hub.view(hub.entries.get(resource.id)!).meta
  // Another owner sees none of it.
  report.otherOwnerTabs = JSON.parse(textOf(await callTool(browseOwner("ses_other"), "tabs", {})))

  const viewer = watch(`ws://127.0.0.1:${server.port}/resources/${encodeURIComponent(resource.id)}/stream?ticket=${hub.ticket(resource.id, "view")!.ticket}`)
  stops.push(() => viewer.ws.close())
  await until(async () => viewer.frames.length > 0, 10_000, "the first frame")
  // The page's clock changes every 50 ms, so every capture is a new frame: the counts are the capture rate.
  const rate = async () => {
    const before = viewer.frames.length
    await Bun.sleep(5_000)
    return round((viewer.frames.length - before) / 5)
  }
  report.watching = { fps: await rate(), hello: viewer.hello, meta: viewer.meta.at(-1) }
  await hub.control(resource.id, "take")
  viewer.ws.send(JSON.stringify({ type: "auth", ticket: hub.ticket(resource.id, "control")!.ticket }))
  // Control alone does not speed captures up: the first input does (`controlled`).
  viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "key", key: "Shift" }] }))
  report.controlledFps = await rate()

  // A handoff on the agent's tab, then Alexandre's tap on its Continue card from the viewer.
  const handoff = callTool(owner, "handoff", { tab, message: "Entre e clique em Continue", timeoutSeconds: 60 }, { timeoutMs: 70_000 }).then(
    (output) => textOf(output),
    (error: Error) => `error: ${error.message}`,
  )
  await Bun.sleep(1_000)
  await hub.register({
    kind: "chrome",
    meta: { kind: "chrome", cdp, browse: owner, targetID: String(tab) },
    owner: owned,
    used: true,
    capabilities: Resources.handoffCapabilities,
    handoff: { id: "brw_check", sessionID: "ses_check", message: "Entre e clique em Continue", since: Date.now() },
  })
  const host = JSON.parse(
    textOf(
      await callTool(owner, "eval", {
        tab,
        world: "isolated",
        expression: `(() => { const host = [...document.documentElement.children].find((e) => { try { return e.matches(":popover-open") } catch { return false } }); const r = host.getBoundingClientRect(); return [r.right, r.bottom, innerWidth, innerHeight] })()`,
      }),
    ),
  ) as [number, number, number, number]
  // Continue sits at the card's bottom right, above the pill (the extension's page-status.ts layout).
  const x = (host[0] - 64) / host[2]
  const y = (host[1] - 74) / host[3]
  const tapped = Date.now()
  viewer.ws.send(
    JSON.stringify({
      type: "input",
      events: [
        { type: "touch", phase: "began", x, y },
        { type: "touch", phase: "ended", x, y },
      ],
    }),
  )
  report.handoff = { result: await handoff, tapToContinuedMs: Date.now() - tapped }
  report.viewerErrors = viewer.errors
  console.log(JSON.stringify({ ok: report.handoff && String((report.handoff as { result: string }).result).includes('"continued"'), report }, null, 2))
} finally {
  if (!args.values.keep) {
    for (const stop of stops.toReversed()) await Promise.resolve(stop()).catch(() => undefined)
    for (const child of children.toReversed()) child.kill()
    await Bun.sleep(500)
    // A Chrome still starting (or stuck on a prompt) ignores SIGTERM.
    for (const child of children) child.kill("SIGKILL")
    await fs.rm(root, { recursive: true, force: true })
  }
}

function watch(url: string) {
  const ws = new WebSocket(url)
  ws.binaryType = "arraybuffer"
  const frames: number[] = []
  const meta: Record<string, unknown>[] = []
  const errors: string[] = []
  const state: { ws: WebSocket; frames: number[]; meta: Record<string, unknown>[]; errors: string[]; hello?: unknown } =
    { ws, frames, meta, errors }
  ws.onmessage = (event) => {
    if (typeof event.data !== "string") return void frames.push(Date.now())
    const message = JSON.parse(event.data) as ResourceProtocol.ServerMessage
    if (message.type === "hello") state.hello = message
    if (message.type === "meta") meta.push(message.value)
    if (message.type === "error") errors.push(message.message)
  }
  return state
}

async function pairingCode(stream: ReadableStream<Uint8Array>) {
  const reader = stream.getReader()
  let text = ""
  while (true) {
    const found = /Pairing code: ([0-9A-Z-]+)/.exec(text)?.[1]
    if (found) return found
    const { value, done } = await reader.read()
    if (done) throw new Error("browse pair printed no code")
    text += new TextDecoder().decode(value)
  }
}

async function until(condition: () => Promise<boolean>, timeout: number, what: string) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (await condition().catch(() => false)) return
    await Bun.sleep(200)
  }
  throw new Error(`Timed out waiting for ${what}`)
}

function round(value: number) {
  return Math.round(value * 10) / 10
}
