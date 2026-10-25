/**
 * Drives the Chrome adapter against a real `playwright-cli` session showing the login fixture
 * (`chrome-login-fixture.ts`): probe, snapshot, live frames, tap, typing, password focus, scroll and navigation.
 * Prints latencies and saves the first and last frames.
 *
 *   PLAYWRIGHT_MCP_CONFIG=<config> playwright-cli -s=<session> open --browser=chrome http://127.0.0.1:5173/login
 *   bun packages/plugin-app-custom/script/chrome-resource-check.ts --session <session> --out <dir>
 */
import path from "node:path"
import { parseArgs } from "node:util"
import { makeChromeAdapter, type ChromeState } from "../src/resources/adapters/chrome"
import type { Entry, StreamSink } from "../src/resources/adapters/types"
import type { Input } from "../src/resources/protocol"

const args = parseArgs({
  options: {
    session: { type: "string" },
    out: { type: "string" },
    user: { type: "string", default: "alexandre@abacato.app" },
  },
}).values
if (!args.session || !args.out) throw new Error("--session and --out are required")

const adapter = makeChromeAdapter()
const now = Date.now()
const entry: Entry = {
  id: `chrome:${args.session}`,
  kind: "chrome",
  meta: { kind: "chrome", session: args.session },
  status: "running",
  discoveredAt: now,
  lastUsedAt: now,
  updatedAt: now,
}

const timed = async <A>(name: string, work: () => Promise<A>) => {
  const started = performance.now()
  const value = await work()
  console.log(`${name}: ${(performance.now() - started).toFixed(1)} ms`)
  return value
}

const probe = await timed("probe", () => adapter.probe([entry]))
console.log("probe result", JSON.stringify(probe.get(entry.id)))
const snapshot = await timed("snapshot (first, includes connect)", () => adapter.snapshot(entry))
await Bun.write(path.join(args.out, "snapshot.jpg"), snapshot.data)
await timed("snapshot (warm)", () => adapter.snapshot(entry))

const frames: { at: number; data: Uint8Array }[] = []
let state: ChromeState | undefined
const waiters: (() => void)[] = []
const sink: StreamSink = {
  hello: (hello) => console.log("hello", JSON.stringify(hello)),
  frame: (data) => {
    frames.push({ at: performance.now(), data })
    waiters.splice(0).forEach((resolve) => resolve())
  },
  meta: (value) => {
    // The adapter publishes exactly `ChromeState`.
    state = value as unknown as ChromeState
    waiters.splice(0).forEach((resolve) => resolve())
  },
}
const until = async (condition: () => boolean, timeout = 5_000) => {
  const deadline = performance.now() + timeout
  while (!condition()) {
    if (performance.now() > deadline) throw new Error(`timed out; state ${JSON.stringify(state)}`)
    await new Promise<void>((resolve) => {
      waiters.push(resolve)
      setTimeout(resolve, 50)
    })
  }
}

const controller = new AbortController()
const streamStarted = performance.now()
const streaming = adapter.stream!(entry, sink, controller.signal)
await until(() => frames.length > 0 && state?.viewport !== undefined)
console.log(`first frame: ${(frames[0]!.at - streamStarted).toFixed(1)} ms`)
await Bun.write(path.join(args.out, "frame-first.jpg"), frames[0]!.data)

/** Time from sending an input to the next frame that arrives after it. */
const inputToFrame = async (name: string, events: Input[]) => {
  const before = frames.length
  const started = performance.now()
  for (const event of events) await adapter.input!(entry, event)
  const sent = performance.now()
  await until(() => frames.length > before)
  console.log(
    `${name}: input ${(sent - started).toFixed(1)} ms, next frame ${(frames[before]!.at - started).toFixed(1)} ms`,
  )
}

const tap = (x: number, y: number): Input[] => [
  { type: "touch", phase: "began", x, y },
  { type: "touch", phase: "ended", x, y },
]
const at = async (selector: string) => {
  const { CDP } = await import("../src/resources/adapters/cdp")
  const version: { webSocketDebuggerUrl: string } = await (
    await fetch(`${(probe.get(entry.id)?.meta as { cdp: string }).cdp}/json/version`)
  ).json()
  const cdp = await CDP.connect(version.webSocketDebuggerUrl)
  const target = (await cdp.send("Target.getTargets", {})).targetInfos.find(
    (info) => info.targetId === state?.targetID,
  )!
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId: target.targetId, flatten: true })
  const rect = await cdp.send(
    "Runtime.evaluate",
    {
      expression: `(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 } })()`,
      returnByValue: true,
    },
    sessionId,
  )
  await cdp.close()
  const point = rect.result.value as { x: number; y: number }
  const viewport = state!.viewport!
  return { x: point.x / viewport.width, y: point.y / viewport.height }
}

const email = await at("#email")
await inputToFrame("tap e-mail", tap(email.x, email.y))
await until(() => state?.focus.editable === true)
console.log("focus after e-mail tap", JSON.stringify(state?.focus))
await inputToFrame("type e-mail (insertText)", [{ type: "text", text: args.user }])
const password = await at("#password")
await inputToFrame("tap password", tap(password.x, password.y))
await until(() => state?.focus.field === "password")
console.log("focus after password tap", JSON.stringify(state?.focus))
await inputToFrame("type password (insertText)", [{ type: "text", text: "s3cr3t!x" }])
await Bun.write(path.join(args.out, "frame-typed.jpg"), frames.at(-1)!.data)
await inputToFrame("scroll down", [{ type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 0.5 }])
await inputToFrame("scroll up", [{ type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: -0.5 }])
await inputToFrame("key Enter (submit)", [{ type: "key", key: "Enter" }])
await until(() => state?.url.includes("/login") === true && state.title.startsWith("Bem-vindo"))
console.log("after submit", state?.title, state?.url, "canGoBack", state?.canGoBack)
await Bun.write(path.join(args.out, "frame-welcome.jpg"), frames.at(-1)!.data)
await inputToFrame("navigate url", [{ type: "navigate", action: "url", url: "127.0.0.1:5173/ajuda" }])
await until(() => state?.title.startsWith("Ajuda") === true)
await inputToFrame("back", [{ type: "navigate", action: "back" }])
await until(() => state?.title.startsWith("Ajuda") === false)
console.log("after back", state?.title, "canGoForward", state?.canGoForward)
await inputToFrame("forward", [{ type: "navigate", action: "forward" }])
await until(() => state?.title.startsWith("Ajuda") === true)
await inputToFrame("reload", [{ type: "navigate", action: "reload" }])
console.log("tabs", JSON.stringify(state?.tabs))
console.log(
  `frames: ${frames.length}, avg size ${Math.round(frames.reduce((sum, frame) => sum + frame.data.byteLength, 0) / frames.length / 1024)} KiB`,
)
controller.abort()
await streaming
await adapter.close()
