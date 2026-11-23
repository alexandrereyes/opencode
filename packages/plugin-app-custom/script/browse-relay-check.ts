#!/usr/bin/env bun
/**
 * End to end for browse resources and handoffs on browse 0.1.5 (`docs/browse-handoff-remoto.md`), isolated from any
 * live browse: its own relay (`browse serve` with `OPENCODE_BROWSER_HOME` in a temporary folder and its own port), a
 * headless Chromium with the unpacked extension paired through the official `relay-pairing.json`, a local login page,
 * the real resources hub with the real Chrome adapter, and the plugin's real browse hooks (`makeBrowseResources`,
 * `makeHandoffs`) for two simulated OpenCode sessions. It never talks to a relay on 19988.
 *
 *   bun script/browse-relay-check.ts --browse <browse 0.1.5 binary> --extension <unpacked browse-extension-0.1.5> \
 *     --chrome <Chromium or Chrome for Testing executable> [--port 19995] [--keep]
 *
 * It checks that each session's resource holds only the tabs its calls named or opened (one by a chosen id, a popup
 * included, never the other session's nor a CLI tab), that while Alexandre controls one the other session's call on
 * its tab is refused, measures `screenshot` latency and the live view's frame rate through the hub, and finishes a real
 * `handoff` by a viewer tap on its Continue card, as the iPhone does. Prints one JSON report; removes everything it
 * started unless `--keep`.
 */
import { createHash, randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"
import { Effect, Exit, Scope } from "effect"
import { browseOwner, resultJson } from "../src/browser-handoff/calls.js"
import { hubResources, makeHandoffs } from "../src/browser-handoff/index.js"
import { makeRegistry } from "../src/browser-handoff/registry.js"
import { callTool, imageOf, textOf } from "../src/resources/adapters/browse-relay.js"
import { makeChromeAdapter } from "../src/resources/adapters/chrome.js"
import { makeBrowseResources } from "../src/resources/browse.js"
import { createHub, protocol } from "../src/resources/hub/hub.js"
import { ResourceProtocol } from "../src/resources/protocol.js"
import { makeHubClient } from "../src/resources/supervisor.js"

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
if (
  await fetch(`http://127.0.0.1:${port}/version`).then(
    () => true,
    () => false,
  )
)
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
}
// The relay client, the adapter and the hub below read these.
Object.assign(process.env, {
  OPENCODE_BROWSER_HOME: env.OPENCODE_BROWSER_HOME,
  OPENCODE_BROWSER_PORT: env.OPENCODE_BROWSER_PORT,
})

const children: { kill: (signal?: NodeJS.Signals) => void }[] = []
const stops: (() => unknown)[] = []
const report: Record<string, unknown> = { port, extension: id }
const checks: Record<string, boolean> = {}
try {
  children.push(Bun.spawn([browse, "serve"], { env, stdout: "ignore", stderr: "ignore" }))
  await until(
    () =>
      fetch(`http://127.0.0.1:${port}/version`).then(
        (r) => r.ok,
        () => false,
      ),
    10_000,
    "the relay",
  )
  report.relay = await fetch(`http://127.0.0.1:${port}/version`).then((r) => r.json())
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
    fetch: (request) =>
      new Response(
        `<!doctype html><title>${new URL(request.url).pathname === "/" ? "Entrar" : new URL(request.url).pathname} · Check</title>
<body style="font:16px sans-serif"><h1>Entrar</h1>
<input id=user autocomplete=username> <input id=pass type=password> <button>Entrar</button> <b id=clock></b>
<a id=popup href="/popup" target=_blank>Ajuda</a>
<script>setInterval(() => (clock.textContent = Date.now()), 50)</script>${"<p>linha</p>".repeat(80)}`,
        { headers: { "content-type": "text/html; charset=utf-8" } },
      ),
  })
  stops.push(() => page.stop(true))
  const site = `http://127.0.0.1:${page.port}`

  // The real hub with the real Chrome adapter, reached as the plugin reaches it (`hub.json`, the admin API).
  const adapter = makeChromeAdapter()
  stops.push(() => adapter.close())
  const secret = randomUUID()
  const state = path.join(root, "hub")
  await fs.mkdir(state, { recursive: true })
  const hub = createHub({
    adapters: { "ios-simulator": adapter, "android-emulator": adapter, chrome: adapter },
    secret,
    file: path.join(state, "resources.json"),
  })
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: hub.fetch, websocket: hub.websocket })
  stops.push(() => {
    hub.close()
    server.stop(true)
  })
  await Bun.write(
    path.join(state, "hub.json"),
    JSON.stringify({ protocol, pid: process.pid, port: server.port, secret }),
  )
  const client = makeHubClient({ state })

  // The plugin's browse hooks, as two OpenCode sessions' calls run them.
  const scope = await Effect.runPromise(Scope.make())
  stops.push(() => Effect.runPromise(Scope.close(scope, Exit.void)))
  const endpoint = async () => `http://127.0.0.1:${port}`
  const resources = makeBrowseResources({
    hub: client,
    family: (sessionID) => Effect.succeed({ root: sessionID }),
    scope,
    endpoint,
    graceMs: 3_000,
  })
  const registry = makeRegistry()
  const handoffs = makeHandoffs({
    registry,
    scope,
    now: () => Date.now(),
    resources: hubResources(client, (sessionID) => Effect.succeed(sessionID), endpoint),
    announce: () => Effect.void,
  })
  const one = `ses_check_one_${randomUUID()}`
  const two = `ses_check_two_${randomUUID()}`
  /** One browse call of a session through the plugin's hooks; `refused` is the plugin's refusal, if any. */
  const use = async (sessionID: string, tool: string, input: Record<string, unknown>, timeoutMs = 30_000) => {
    const event = { tool: `browse_${tool}`, sessionID, messageID: "msg_check", id: randomUUID(), input, agent: "build" }
    const before = await Effect.runPromiseExit(Effect.andThen(resources.before(event), handoffs.before(event)))
    if (Exit.isFailure(before)) return { refused: JSON.stringify(before.cause) }
    const output = await callTool(tool, input, { timeoutMs }).then(
      (result) => ({ text: textOf(result) }),
      (error: Error) => ({ error: error.message }),
    )
    const after =
      "text" in output
        ? { ...event, status: "completed" as const, result: { output: output.text } }
        : { ...event, status: "error" as const, error: { message: output.error } }
    await Effect.runPromise(Effect.andThen(resources.after(after), handoffs.after(after)))
    return output
  }
  const tabOf = (output: object) =>
    "text" in output ? (resultJson(output.text) as { tab?: number } | undefined)?.tab : undefined
  const held = (sessionID: string) =>
    hub.entries.get(`chrome:browse:${browseOwner(sessionID)}`)?.tabs?.map((item) => item.tab) ?? []

  // Session one opens a tab by navigating and its page opens a popup; session two opens a named tab and navigates it by
  // that id; a CLI-like call (no session) opens a third.
  const opened = tabOf(await use(one, "navigate", { url: `${site}/` }))
  if (opened === undefined) throw new Error("navigate opened no tab")
  report.popupClick = await use(one, "click", { tab: opened, selector: "#popup" })
  const named = tabOf(await use(two, "tabs", { action: "new", id: "work-mail", url: `${site}/mail` }))
  await use(two, "navigate", { tab: "work-mail", url: `${site}/inbox` })
  const cli = tabOf({ text: textOf(await callTool("navigate", { url: `${site}/cli` }, { timeoutMs: 30_000 })) })
  await Bun.sleep(1_000)
  await hub.probe(["chrome"])
  const listed = resultJson(textOf(await callTool("tabs", {}))) as {
    tabs: { tab: number; id?: string; opener?: number }[]
  }
  const popup = listed.tabs.find((item) => item.opener === opened)?.tab
  report.tabs = { listed: listed.tabs, one: held(one), two: held(two), opened, popup, named, cli }
  checks.ownTabsOnly =
    JSON.stringify(held(one).toSorted()) === JSON.stringify([opened, popup].toSorted()) &&
    JSON.stringify(held(two)) === JSON.stringify([named]) &&
    cli !== undefined &&
    !held(one).includes(cli) &&
    !held(two).includes(cli)
  const resourceOne = `chrome:browse:${browseOwner(one)}`
  report.resourceOne = (await client.get(resourceOne)).meta

  // While Alexandre controls session one's resource, session two may not touch its tab, but may use its own.
  await client.control(resourceOne, "take")
  const refusedOther = await use(two, "click", { tab: opened, x: 5, y: 5 })
  const allowedOwn = await use(two, "snapshot", { tab: "work-mail" })
  const refusedOwn = await use(one, "snapshot", { tab: opened })
  report.lock = { refusedOther, allowedOwn: "refused" in allowedOwn ? allowedOwn : "ok", refusedOwn }
  checks.lock = "refused" in refusedOther && !("refused" in allowedOwn) && "refused" in refusedOwn
  await client.control(resourceOne, "release")

  // Latency of the call the live view polls.
  const latencies: number[] = []
  for (let index = 0; index < 20; index++) {
    const started = performance.now()
    const shot = await callTool("screenshot", { tab: opened, format: "jpeg", quality: 70, scale: "css" })
    latencies.push(performance.now() - started)
    if (index === 0) report.screenshot = { summary: JSON.parse(textOf(shot)), bytes: imageOf(shot)?.byteLength }
  }
  latencies.sort((a, b) => a - b)
  report.screenshotMs = { p50: round(latencies[10]!), p90: round(latencies[18]!), max: round(latencies[19]!) }

  const viewer = watch(
    `ws://127.0.0.1:${server.port}/resources/${encodeURIComponent(resourceOne)}/stream?ticket=${(await client.ticket(resourceOne, "view")).ticket}`,
  )
  stops.push(() => viewer.ws.close())
  await until(async () => viewer.frames.length > 0, 10_000, "the first frame")
  // The page's clock changes every 50 ms, so every capture is a new frame: the counts are the capture rate.
  const rate = async () => {
    const before = viewer.frames.length
    await Bun.sleep(5_000)
    return round((viewer.frames.length - before) / 5)
  }
  report.watching = { fps: await rate(), hello: viewer.hello, meta: viewer.meta.at(-1) }
  checks.viewerTabs =
    JSON.stringify(((viewer.meta.at(-1)?.tabs ?? []) as { id: string }[]).map((item) => Number(item.id)).toSorted()) ===
    JSON.stringify(held(one).toSorted())
  await client.control(resourceOne, "take")
  viewer.ws.send(JSON.stringify({ type: "auth", ticket: (await client.ticket(resourceOne, "control")).ticket }))
  // Control alone does not speed captures up: the first input does (`controlled`).
  viewer.ws.send(JSON.stringify({ type: "input", events: [{ type: "key", key: "Shift" }] }))
  report.controlledFps = await rate()
  await client.control(resourceOne, "release")

  // A real handoff on session one's tab, through the plugin's handoff hooks, then Alexandre's tap on its Continue card.
  const handoff = use(
    one,
    "handoff",
    { tab: opened, message: "Entre e clique em Continue", timeoutSeconds: 60 },
    70_000,
  )
  await until(async () => registry.waiting().some((entry) => entry.resourceID === resourceOne), 15_000, "the handoff")
  const waiting = await client.get(resourceOne)
  report.handoffResource = { handoff: waiting.handoff, capabilities: waiting.capabilities, targetID: waiting.meta }
  await client.control(resourceOne, "take")
  viewer.ws.send(JSON.stringify({ type: "auth", ticket: (await client.ticket(resourceOne, "control")).ticket }))
  const host = JSON.parse(
    textOf(
      await callTool("eval", {
        tab: opened,
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
  const result = await handoff
  report.handoff = { result, tapToContinuedMs: Date.now() - tapped, end: viewer.ends }
  checks.handoff = "text" in result && result.text.includes('"continued"')
  report.viewerErrors = viewer.errors
  console.log(JSON.stringify({ ok: Object.values(checks).every(Boolean), checks, report }, null, 2))
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
  const ends: unknown[] = []
  const state: {
    ws: WebSocket
    frames: number[]
    meta: Record<string, unknown>[]
    errors: string[]
    ends: unknown[]
    hello?: unknown
  } = { ws, frames, meta, errors, ends }
  ws.onmessage = (event) => {
    if (typeof event.data !== "string") return void frames.push(Date.now())
    const message = JSON.parse(event.data) as ResourceProtocol.ServerMessage
    if (message.type === "hello") state.hello = message
    if (message.type === "meta") meta.push(message.value)
    if (message.type === "error") errors.push(message.message)
    if (message.type === "end") ends.push(message)
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
