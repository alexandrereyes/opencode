/**
 * End to end check of `docs/browse-handoff-remoto.md` against a sandbox server (never production), with a real agent
 * whose browse `execute` hands off in Alexandre's Chrome, on the login fixture (`chrome-login-fixture.ts`, fake data):
 *
 * - `completed`: the resource appears with the handoff, frames arrive, taps and typing reach the page (secure field
 *   included), `navigate` is refused, `focus` brings the tab forward, a tap on browse's Continue finishes the call;
 * - `timeout`: the handoff gives up after `timeoutMs`; a link to another origin stays blocked by the allowlist;
 * - `cancelled`: the agent's session is interrupted while the handoff waits;
 * - `keys`: browser shortcuts sent as `key` inputs (Cmd+L and a typed URL, Cmd+T, Cmd+[, Cmd+], Alt+←, Cmd+R,
 *   Backspace outside a field, Cmd+W) reach the page only: the tab keeps its URL, the session its tabs and the page its
 *   focus, with history both ways so going back or forward would show; then Continue finishes it.
 *
 * Each checks the end in the contract's order (stream `end`, `browser-handoffs.changed` with `ended`,
 * `resources.changed`) and that the resource is gone. Positions on the page are read through the relay (its token is
 * read here and never printed). The browse session must exist with `--allow-origin <fixture>`.
 *
 *   bun packages/plugin-app-custom/script/browse-handoff-check.ts --server-url http://127.0.0.1:4196 --home <sandbox> \
 *     --session <browse session> --scenario completed|timeout|cancelled|keys [--fixture http://127.0.0.1:5191]
 */
import { readFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"
import { machineID, parsePlatformUUID } from "../src/resources/machine"

const args = parseArgs({
  options: {
    "server-url": { type: "string" },
    home: { type: "string" },
    session: { type: "string" },
    scenario: { type: "string", default: "completed" },
    fixture: { type: "string", default: "http://127.0.0.1:5191" },
    model: { type: "string", default: "anthropic/claude-haiku-5-5" },
    email: { type: "string", default: "teste@exemplo.com" },
    password: { type: "string", default: "senha-falsa-123" },
  },
}).values
const server = args["server-url"]!
if (/:(4096|4178|4179)\b/.test(server)) throw new Error("Never against production")
const scenario = args.scenario as "completed" | "timeout" | "cancelled" | "keys"
const expected = scenario === "keys" ? "completed" : scenario
const browse = args.session!
const resourceID = `chrome:browse:${browse}`
const started = Date.now()
const log = (...values: unknown[]) => console.log(`+${((Date.now() - started) / 1000).toFixed(1)}s`, ...values)
const results: Record<string, unknown> = { scenario }
const check = (name: string, ok: boolean, detail?: unknown) => {
  results[name] = ok ? "ok" : { failed: detail ?? true }
  log(ok ? "OK  " : "FAIL", name, detail === undefined ? "" : JSON.stringify(detail))
}

const password = (await Bun.file(path.join(args.home!, "password")).text()).trim()
const auth = `Basic ${btoa(`opencode:${password}`)}`
const api = async <T>(route: string, body?: unknown, method = body === undefined ? "GET" : "POST"): Promise<T> => {
  const response = await fetch(server + route, {
    method,
    headers: { authorization: auth, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) throw Object.assign(new Error(`${route}: ${response.status} ${text}`), { body: text })
  return (text ? JSON.parse(text) : undefined) as T
}
const rpc = <T>(method: string, input: unknown) =>
  api<{ output: T }>(`/api/rpc/${method}`, { input }).then((result) => result.output)
const until = async <T>(read: () => Promise<T | undefined>, what: string, timeout = 180_000) => {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await read().catch(() => undefined)
    if (value !== undefined) return value
    await Bun.sleep(200)
  }
  throw new Error(`timed out waiting for ${what}`)
}

// Everything that matters, in arrival order: server events and this viewer's stream messages.
const timeline: { at: number; what: string; data?: unknown }[] = []
const note = (what: string, data?: unknown) => timeline.push({ at: Date.now() - started, what, data })
const events = await fetch(`${server}/api/event`, { headers: { authorization: auth, accept: "text/event-stream" } })
void (async () => {
  const reader = events.body!.pipeThrough(new TextDecoderStream()).getReader()
  let buffer = ""
  for (;;) {
    const { value, done } = await reader.read().catch(() => ({ value: undefined, done: true }))
    if (done) return
    buffer += value
    for (let split = buffer.indexOf("\n\n"); split >= 0; split = buffer.indexOf("\n\n")) {
      const frame = buffer.slice(0, split)
      buffer = buffer.slice(split + 2)
      const data = frame
        .split("\n")
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).trim())
        .join("")
      if (!data) continue
      const event = JSON.parse(data) as { type: string; data: unknown }
      if (event.type === "rpc.custom.browser-handoffs.changed" || event.type === "rpc.custom.resources.changed")
        note(event.type, event.data)
    }
  }
})()

await fetch(`${args.fixture}/reset`)
const repo = path.join(args.home!, "repos", `browse-handoff-${process.pid}`)
await Bun.$`mkdir -p ${repo} && git init -q ${repo} && git -C ${repo} -c user.name=Check -c user.email=check@example.invalid commit --allow-empty -qm init`.quiet()
const [providerID, ...model] = args.model!.split("/")
const sessionID = (
  await api<{ data: { id: string } }>("/api/session", {
    title: `Checagem — handoff remoto (${scenario})`,
    location: { directory: repo },
    agent: "build",
    model: { providerID, id: model.join("/") },
  })
).data.id
log("agent session", sessionID)
const message = "Entre com o login de teste e clique em Continue"
const visit = (route: string) => `await page.goto(${JSON.stringify(`${args.fixture}${route}`)}, { waitUntil: "load" })`
const code = [
  // `keys`: history both ways (/ajuda before and after the login page), so a back or forward would change the URL.
  ...(scenario === "keys"
    ? [visit("/ajuda"), visit("/"), visit("/ajuda"), `await page.goBack({ waitUntil: "load" })`]
    : []),
  ...(scenario === "keys" ? [] : [visit("/")]),
  `await handoff(${JSON.stringify(message)}${scenario === "timeout" ? ", { timeoutMs: 20000 }" : ""})`,
  `const email = await page.inputValue("#email")`,
  `await page.click("#submit")`,
  `await page.waitForSelector("#welcome")`,
  `return { email, title: await page.title() }`,
].join("\n")
await api(`/api/session/${sessionID}/prompt`, {
  text: [
    "Chame exatamente uma vez, pelo execute do Code Mode, tools.browse.execute com estes argumentos, sem mudar nada,",
    "e espere o resultado; depois responda apenas com o resultado ou o erro, numa linha.",
    "```json",
    JSON.stringify({ session: browse, code }),
    "```",
  ].join("\n"),
})

type Handoff = { id: string; sessionID: string; message: string; resourceID?: string }
const handoff = await until(async () => {
  const { data } = await rpc<{ data: Handoff[] }>("custom.browser-handoffs/list", { sessionID })
  return data.find((item) => item.resourceID)
}, "the waiting handoff with its resource")
log("handoff", handoff.id, "resource", handoff.resourceID)
check("resourceID on the handoff", handoff.resourceID === resourceID, handoff.resourceID)
const navigation = await rpc<{ data: { session: { id: string }; browserResourceID?: string }[] }>(
  "custom.navigation/list",
  {},
).catch(() => undefined)
const row = navigation?.data.find((item) => item.session.id === sessionID)
check("browserResourceID in Sessões", row?.browserResourceID === resourceID, row?.browserResourceID)

type Resource = {
  id: string
  label: string
  capabilities?: object
  handoff?: { id: string; machine?: string }
  meta: Record<string, unknown>
  owner?: { sessionID: string; rootSessionID: string }
}
const resource = await rpc<Resource>("custom.resources/get", { id: resourceID })
const ownMachine = machineID(
  parsePlatformUUID(await Bun.$`/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice`.quiet().text()) ?? "",
)
check(
  "resource: capabilities, handoff, owner, machine",
  JSON.stringify(resource.capabilities) === JSON.stringify({ navigation: false, tabs: false, focus: true }) &&
    resource.handoff?.id === handoff.id &&
    resource.owner?.sessionID === sessionID &&
    resource.handoff?.machine === ownMachine,
  { label: resource.label, capabilities: resource.capabilities, handoff: resource.handoff, owner: resource.owner },
)
check("no token in the resource", !JSON.stringify(resource).includes(relayToken()))

type Ticket = { ticket: string; path: string; loopbackPort: number }
const control = await rpc<{ ticket?: Ticket }>("custom.resources/control", { id: resourceID, action: "take" })
const ticket = control.ticket!
const ws = new WebSocket(`ws://127.0.0.1:${ticket.loopbackPort}${ticket.path}/stream?ticket=${ticket.ticket}`)
ws.binaryType = "arraybuffer"
let frames = 0
let meta: { url?: string; tabs?: unknown[]; focus?: { editable: boolean; field?: string }; viewport?: object } = {}
const errors: string[] = []
let ended: string | undefined
const closed = new Promise<void>((resolve) => ws.addEventListener("close", () => resolve()))
ws.onmessage = (event) => {
  if (typeof event.data !== "string") {
    frames++
    if (frames % 15 === 0) ws.send(JSON.stringify({ type: "ack", n: frames }))
    return
  }
  const value = JSON.parse(event.data) as { type: string; value?: typeof meta; message?: string; reason?: string }
  if (value.type === "meta") meta = value.value ?? {}
  if (value.type === "error") errors.push(value.message ?? "")
  if (value.type === "end") {
    ended = value.reason
    note("stream end", value.reason)
  }
}
await new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = reject)))
await until(async () => (frames > 0 && meta.url ? true : undefined), "frames and the tab's meta", 20_000)
check("frames and only the handoff's tab", frames > 0 && meta.tabs?.length === 1, {
  frames,
  url: meta.url,
  viewport: meta.viewport,
})
const send = (events: unknown[]) => ws.send(JSON.stringify({ type: "input", events }))
const tap = async (point: { x: number; y: number }) => {
  send([{ type: "touch", phase: "began", ...point }])
  await Bun.sleep(60)
  send([{ type: "touch", phase: "ended", ...point }])
  await Bun.sleep(400)
}

send([{ type: "navigate", action: "url", url: "https://example.com" }])
send([{ type: "navigate", action: "back" }])
await until(async () => (errors.length >= 2 ? true : undefined), "navigation refusals", 5_000).catch(() => undefined)
check(
  "navigate refused with not_allowed",
  errors.slice(0, 2).every((error) => error === "not_allowed") && errors.length >= 2,
  errors,
)

if (scenario === "completed") {
  const points = await positions(["email", "password", "continue"])
  await tap(points.email!)
  await until(
    async () => (meta.focus?.field === "username" || meta.focus?.field === "email" ? true : undefined),
    "e-mail focus",
    5_000,
  ).catch(() => undefined)
  check("tap focuses the e-mail field", meta.focus?.editable === true, meta.focus)
  send([{ type: "text", text: args.email }])
  await tap(points.password!)
  await until(async () => (meta.focus?.field === "password" ? true : undefined), "password focus", 5_000).catch(
    () => undefined,
  )
  check("tap focuses the password field (secure entry)", meta.focus?.field === "password", meta.focus)
  send([{ type: "text", text: args.password }])
  await Bun.sleep(500)
  const focus = await rpc<object>("custom.resources/focus", { id: resourceID }).then(
    (value) => ({ value }),
    (error: Error) => ({ error: error.message }),
  )
  // The contract's `failed` when the browser refuses to activate the tab (browse 0.0.14 always does, see `activate`).
  check(
    "focus answers {} or failed",
    "value" in focus || ("error" in focus && focus.error.includes('"reason":"failed"')),
    focus,
  )
  log("tapping Continue")
  await tap((await positions(["continue"])).continue!)
} else if (scenario === "keys") {
  const before = { url: meta.url, tabs: await sessionTabs() }
  const key = (key: string, modifiers: string[] = []) => ({
    type: "key",
    key,
    ...(modifiers.length ? { modifiers } : {}),
  })
  const shortcuts: [string, unknown[]][] = [
    ["Cmd+L, a URL, Enter", [key("l", ["meta"]), { type: "text", text: "example.com" }, key("Enter")]],
    ["Cmd+T", [key("t", ["meta"])]],
    ["Cmd+[", [key("[", ["meta"])]],
    ["Cmd+]", [key("]", ["meta"])]],
    ["Alt+←", [key("ArrowLeft", ["alt"])]],
    ["Cmd+R", [key("r", ["meta"])]],
    ["Backspace outside a field", [key("Backspace")]],
    ["Cmd+W", [key("w", ["meta"])]],
  ]
  const seen = async () => (await (await fetch(`${args.fixture}/last`)).json()) as { keys: string[]; focus: string[] }
  log("before", JSON.stringify(before))
  for (const [name, events] of shortcuts) {
    await fetch(`${args.fixture}/seen?focus=-`)
    const mark = await seen()
    send(events)
    await Bun.sleep(1_500)
    const after = { url: meta.url, tabs: await sessionTabs() }
    const page = await seen()
    const focus = page.focus.slice(mark.focus.length)
    const keys = page.keys.slice(mark.keys.length)
    check(
      `key ${name}: the page got it, no navigation, tab or focus change`,
      after.url === before.url &&
        JSON.stringify(after.tabs) === JSON.stringify(before.tabs) &&
        ended === undefined &&
        keys.length >= events.filter((event) => (event as { type: string }).type === "key").length &&
        !focus.some((item) => item === "blur" || item === "hidden"),
      { url: after.url, tabs: after.tabs.length, pageKeys: keys, focus, errors: errors.slice(2) },
    )
  }
  log("tapping Continue")
  await tap((await positions(["continue"])).continue!)
} else if (scenario === "timeout") {
  const before = meta.url
  await tap((await positions(["outside"])).outside!)
  await Bun.sleep(2_500)
  const relayLog = await Bun.file(path.join(os.homedir(), ".local/state/browse/logs/relay.log"))
    .text()
    .catch(() => "")
  const stopped = relayLog
    .split("\n")
    .filter((line) => Date.parse(line.slice(0, 24)) >= started && /allowlist\.(stopped|violation)/.test(line))
    .filter((line) => line.includes(`session=${browse}`))
  check(
    "a link to another origin is stopped by the session's allowlist",
    !String(meta.url).startsWith("http://localhost") && stopped.length > 0,
    { before, after: meta.url, relay: stopped.map((line) => line.slice(25, 200)) },
  )
  log("waiting for the handoff's 20 s timeout")
} else {
  await Bun.sleep(1_000)
  log("interrupting the agent's session")
  await api(`/api/session/${sessionID}/interrupt`, {})
}

await until(async () => (ended ? true : undefined), "the stream's end", 60_000).catch(() => undefined)
await Promise.race([closed, Bun.sleep(3_000)])
const reason = { completed: "handoff_completed", timeout: "handoff_timeout", cancelled: "handoff_cancelled" }[expected]
check("stream ends with the reason and closes", ended === reason && ws.readyState === WebSocket.CLOSED, ended)
await until(
  async () =>
    timeline.some(
      (item) =>
        item.what === "rpc.custom.resources.changed" &&
        JSON.stringify(item.data).includes(resourceID) &&
        item.at > (timeline.find((e) => e.what === "stream end")?.at ?? Infinity),
    )
      ? true
      : undefined,
  "resources.changed after the end",
  10_000,
).catch(() => undefined)
const endAt = timeline.findIndex((item) => item.what === "stream end")
const changedAt = timeline.findIndex(
  (item, index) =>
    index > endAt &&
    item.what === "rpc.custom.browser-handoffs.changed" &&
    (item.data as { ended?: { id: string } }).ended?.id === handoff.id,
)
const resourcesAt = timeline.findIndex(
  (item, index) =>
    index > changedAt && item.what === "rpc.custom.resources.changed" && JSON.stringify(item.data).includes(resourceID),
)
const outcome = (timeline[changedAt]?.data as { ended?: { outcome: string; resourceID?: string } } | undefined)?.ended
check(
  "end order: stream end, handoff ended, resources changed",
  endAt >= 0 && changedAt > endAt && resourcesAt > changedAt,
  timeline.slice(-6),
)
check("ended outcome", outcome?.outcome === expected && outcome.resourceID === resourceID, outcome)
const gone = await rpc("custom.resources/get", { id: resourceID }).then(
  () => "still there",
  (error: Error & { body?: string }) => error.body ?? error.message,
)
check("resource gone (not_found)", gone.includes("not_found"), gone)
const listed = await rpc<{ data: Handoff[] }>("custom.browser-handoffs/list", { sessionID })
check("handoff no longer listed", listed.data.length === 0, listed.data)

await until(
  async () =>
    (await api<{ data: Record<string, unknown> }>("/api/session/active")).data[sessionID] ? undefined : true,
  "the agent to finish",
  120_000,
).catch(() => undefined)
const fixture = (await (await fetch(`${args.fixture}/last`)).json()) as { email: string; passwordLength: number }
if (scenario === "completed")
  check(
    "the page got the typed login",
    fixture.email === args.email && fixture.passwordLength === args.password!.length,
    fixture,
  )
const messages = await api<{
  data: { content?: { type: string; name?: string; state?: { status: string; content?: { text?: string }[] } }[] }[]
}>(`/api/session/${sessionID}/message?limit=20`)
const call = messages.data
  .flatMap((item) => item.content ?? [])
  .find((part) => part.type === "tool" && part.name === "execute")
log("agent's execute:", call?.state?.status, (call?.state?.content?.[0]?.text ?? "").replace(/\s+/g, " ").slice(0, 240))

const secrets = [args.password!, relayToken()]
const files = [
  path.join(args.home!, "server.log"),
  path.join(args.home!, "xdg/state/opencode/resources-hub/hub.log"),
  path.join(os.homedir(), ".local/state/browse/logs/relay.log"),
]
const leaks = await Promise.all(
  files.map(async (file) => {
    const text = await Bun.file(file)
      .text()
      .catch(() => "")
    return {
      file: path.basename(file),
      bytes: text.length,
      leaks: secrets.filter((secret) => text.includes(secret)).length,
    }
  }),
)
check(
  "no password or token in the logs",
  leaks.every((item) => item.leaks === 0),
  leaks,
)

ws.close()
await fetch(`${server}/api/session/${sessionID}`, { method: "DELETE", headers: { authorization: auth } })
await Bun.$`rm -rf ${repo}`.quiet()
console.log(JSON.stringify(results, null, 2))
process.exit(Object.values(results).every((value) => value === "ok" || value === scenario) ? 0 : 1)

/** The browse session's tabs as the relay lists them (URL each). */
async function sessionTabs() {
  const headers = { authorization: `Bearer ${relayToken()}`, "opencode-browser-session-id": browse }
  const listed = (await (await fetch("http://127.0.0.1:19988/json/list", { headers })).json()) as {
    id: string
    type: string
    url: string
    opencodeBrowserSessionId?: string
  }[]
  return listed
    .filter((item) => item.opencodeBrowserSessionId === browse && item.type === "page")
    .map((item) => `${item.id} ${item.url}`)
}

function relayToken() {
  return readFileSync(path.join(os.homedir(), ".local/share/browse/relay-token"), "utf8").trim()
}

/** Centers of elements (by id, through closed shadow roots) in the session's tab, normalized to its viewport. */
async function positions(ids: string[]) {
  const headers = { authorization: `Bearer ${relayToken()}`, "opencode-browser-session-id": browse }
  const version = await (await fetch("http://127.0.0.1:19988/json/version", { headers })).json()
  const ws = new WebSocket(version.webSocketDebuggerUrl)
  await new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = () => reject(new Error("relay")))))
  let next = 1
  const pending = new Map<number, (message: any) => void>()
  ws.onmessage = (event) => {
    const message = JSON.parse(String(event.data))
    pending.get(message.id)?.(message)
    pending.delete(message.id)
  }
  const cdp = (method: string, params: object = {}, sessionId?: string) =>
    new Promise<any>((resolve, reject) => {
      const id = next++
      pending.set(id, (message) => (message.error ? reject(new Error(message.error.message)) : resolve(message.result)))
      ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }))
    })
  try {
    const { targetInfos } = await cdp("Target.getTargets")
    const target = targetInfos.find((item: { targetId: string }) => item.targetId === resource.meta.targetID)
    const { sessionId } = await cdp("Target.attachToTarget", { targetId: target.targetId, flatten: true })
    const size = (
      await cdp(
        "Runtime.evaluate",
        { expression: "({ w: innerWidth, h: innerHeight })", returnByValue: true },
        sessionId,
      )
    ).result.value
    const doc = await cdp("DOM.getDocument", { depth: -1, pierce: true }, sessionId)
    const find = (node: any, id: string): any => {
      const attributes: string[] = node.attributes ?? []
      const index = attributes.indexOf("id")
      if (index >= 0 && index % 2 === 0 && attributes[index + 1] === id) return node
      for (const child of [
        ...(node.children ?? []),
        ...(node.shadowRoots ?? []),
        ...(node.contentDocument ? [node.contentDocument] : []),
      ]) {
        const found = find(child, id)
        if (found) return found
      }
    }
    const result: Record<string, { x: number; y: number }> = {}
    for (const id of ids) {
      const node = find(doc.root, id)
      if (!node) throw new Error(`#${id} not found`)
      const { model } = await cdp("DOM.getBoxModel", { backendNodeId: node.backendNodeId }, sessionId)
      const quad = model.border as number[]
      result[id] = {
        x: (quad[0]! + quad[2]! + quad[4]! + quad[6]!) / 4 / size.w,
        y: (quad[1]! + quad[3]! + quad[5]! + quad[7]!) / 4 / size.h,
      }
    }
    await cdp("Target.detachFromTarget", { sessionId })
    return result
  } finally {
    ws.close()
  }
}
