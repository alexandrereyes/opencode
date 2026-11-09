/**
 * End to end check of a browse session's resource (`docs/browse-handoff-remoto.md`, rev. 2026-11-09) against a sandbox
 * server (never production), with a real agent whose browse calls run in Alexandre's Chrome on the login fixture
 * (`chrome-login-fixture.ts`, fake data):
 *
 * 1. the agent uses the browser without a handoff: the resource appears (`agent`, the session's capabilities, its
 *    owner) and a viewer gets frames and the session's tab;
 * 2. Alexandre takes control: he navigates (allowed outside a handoff) and the agent's next browse call on the session
 *    is refused with the lock's message;
 * 3. he gives it back: the agent hears it and its next call runs;
 * 4. a handoff on the same resource: locked in place, finished by a tap on Continue; the resource stays (`end` with
 *    `kept`), without the handoff, as the session's again;
 * 5. `session_delete` removes the resource.
 *
 * The browse session must exist with `--allow-origin <fixture>`. Positions on the page are read through the relay (its
 * token is read here and never printed).
 *
 *   bun packages/plugin-app-custom/script/browse-resource-check.ts --server-url http://127.0.0.1:4196 \
 *     --home <sandbox> --session <browse session> [--fixture http://127.0.0.1:5191]
 */
import { readFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"

const args = parseArgs({
  options: {
    "server-url": { type: "string" },
    home: { type: "string" },
    session: { type: "string" },
    fixture: { type: "string", default: "http://127.0.0.1:5191" },
    model: { type: "string", default: "anthropic/claude-haiku-5-5" },
    email: { type: "string", default: "teste@exemplo.com" },
    password: { type: "string", default: "senha-falsa-123" },
  },
}).values
const server = args["server-url"]!
if (/:(4096|4178|4179)\b/.test(server)) throw new Error("Never against production")
const browse = args.session!
const resourceID = `chrome:browse:${browse}`
const started = Date.now()
const log = (...values: unknown[]) => console.log(`+${((Date.now() - started) / 1000).toFixed(1)}s`, ...values)
const results: Record<string, unknown> = {}
const check = (name: string, ok: boolean, detail?: unknown) => {
  results[name] = ok ? "ok" : { failed: detail ?? true }
  log(ok ? "OK  " : "FAIL", name, detail === undefined ? "" : JSON.stringify(detail).slice(0, 400))
}

const password = (await Bun.file(path.join(args.home!, "password")).text()).trim()
const auth = `Basic ${btoa(`opencode:${password}`)}`
const api = async <T>(route: string, body?: unknown): Promise<T> => {
  const response = await fetch(server + route, {
    method: body === undefined ? "GET" : "POST",
    headers: { authorization: auth, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  if (!response.ok) throw Object.assign(new Error(`${route}: ${response.status} ${text}`), { body: text })
  return (text ? JSON.parse(text) : undefined) as T
}
const rpc = <T>(method: string, input: unknown) =>
  api<{ output: T }>(`/api/rpc/${method}`, { input }).then((result) => result.output)
const until = async <T>(read: () => Promise<T | undefined>, what: string, timeout = 120_000) => {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await read().catch(() => undefined)
    if (value !== undefined) return value
    await Bun.sleep(200)
  }
  throw new Error(`timed out waiting for ${what}`)
}

type Resource = {
  id: string
  state: string
  label: string
  capabilities?: { navigation?: boolean; tabs?: boolean; focus?: boolean }
  handoff?: { id: string }
  owner?: { sessionID: string; rootSessionID: string }
  machine?: string
  meta: Record<string, unknown>
  activity?: { command: string; running?: boolean }[]
}
const resource = () =>
  rpc<{ resources: Resource[] }>("custom.resources/list", {}).then((list) =>
    list.resources.find((item) => item.id === resourceID),
  )

await fetch(`${args.fixture}/reset`)
const repo = path.join(args.home!, "repos", `browse-resource-${process.pid}`)
await Bun.$`mkdir -p ${repo} && git init -q ${repo} && git -C ${repo} -c user.name=Check -c user.email=check@example.invalid commit --allow-empty -qm init`.quiet()
const [providerID, ...model] = args.model!.split("/")
const sessionID = (
  await api<{ data: { id: string } }>("/api/session", {
    title: "Checagem — recurso do browse",
    location: { directory: repo },
    agent: "build",
    model: { providerID, id: model.join("/") },
  })
).data.id
log("agent session", sessionID, "browse session", browse)

type Part = {
  type: string
  name?: string
  id?: string
  text?: string
  state?: { status: string; content?: { text?: string }[]; error?: { message?: string } }
}
const parts = async () => {
  const messages = await api<{ data: { type: string; content?: Part[]; text?: string }[] }>(
    `/api/session/${sessionID}/message?limit=100`,
  )
  return messages.data.slice().reverse()
}
const executes = async () =>
  (await parts())
    .flatMap((message) => message.content ?? [])
    .filter((part) => part.type === "tool" && part.name === "execute")

/** One prompt asking for exactly one Code Mode call, then waits for the agent to finish; the call's part. */
async function ask(call: string) {
  const before = (await executes()).length
  await api(`/api/session/${sessionID}/prompt`, {
    text: [
      "Chame exatamente uma vez, pelo execute do Code Mode, esta chamada, sem mudar nada, e espere o resultado;",
      "depois responda apenas com o resultado ou o erro, numa linha. Não tente de novo se der erro.",
      "```js",
      call,
      "```",
    ].join("\n"),
  })
  await Bun.sleep(1_500)
  await until(
    async () =>
      (await api<{ data: Record<string, unknown> }>("/api/session/active")).data[sessionID] ? undefined : true,
    "the agent to finish",
    300_000,
  )
  const part = (await executes())[before]
  const text = [...(part?.state?.content ?? []).map((item) => item.text ?? ""), part?.state?.error?.message ?? ""].join(
    "\n",
  )
  return { status: part?.state?.status, text }
}
const run = (code: string) => `await tools.browse.execute(${JSON.stringify({ session: browse, code })})`

// 0. A new Location starts its own browse MCP: wait until the agent's catalog has it.
for (let attempt = 0; attempt < 6; attempt++) {
  const status = await ask("await tools.browse.status()")
  if (!status.text.includes("Unknown tool")) break
  log("browse is not in the catalog yet; waiting")
  await Bun.sleep(5_000)
}

// 1. The agent uses the browser, long enough to count as in use while it runs.
const first = ask(
  run(`await page.goto(${JSON.stringify(`${args.fixture}/`)}); await page.waitForTimeout(6000); return page.url()`),
)
const inUse = await until(
  async () => {
    const found = await resource()
    return found?.state === "agent" ? found : undefined
  },
  "the resource while the agent uses it",
  60_000,
)
check("the resource appears while the agent uses the browser", true, { label: inUse.label, state: inUse.state })
check(
  "capabilities, owner and machine, no handoff",
  JSON.stringify(inUse.capabilities) === JSON.stringify({ navigation: true, tabs: true, focus: true }) &&
    inUse.owner?.sessionID === sessionID &&
    inUse.handoff === undefined &&
    typeof inUse.machine === "string",
  inUse,
)
check("its activity never shows the code", !JSON.stringify(inUse).includes("waitForTimeout"), inUse.activity)
await first
const used = await until(async () => {
  const found = await resource()
  return found?.meta.targetID ? found : undefined
}, "the session's tab")
check("after the call: the session's tab", String(used.meta.url).startsWith(args.fixture!), used.meta)

type Ticket = { ticket: string; path: string; loopbackPort: number }
let meta: { url?: string; tabs?: unknown[]; viewport?: { width: number; height: number } } = {}
let frames = 0
const ended: { reason?: string; kept?: boolean }[] = []
const errors: string[] = []
function viewer(ticket: Ticket) {
  const ws = new WebSocket(`ws://127.0.0.1:${ticket.loopbackPort}${ticket.path}/stream?ticket=${ticket.ticket}`)
  ws.binaryType = "arraybuffer"
  const closed = new Promise<void>((resolve) => ws.addEventListener("close", () => resolve()))
  ws.onmessage = (event) => {
    if (typeof event.data !== "string") {
      frames++
      if (frames % 15 === 0) ws.send(JSON.stringify({ type: "ack", n: frames }))
      return
    }
    const value = JSON.parse(event.data)
    if (value.type === "meta") meta = value.value ?? {}
    if (value.type === "end") ended.push(value)
    if (value.type === "error") errors.push(value.message)
  }
  const send = (events: unknown[]) => ws.send(JSON.stringify({ type: "input", events }))
  return { ws, closed, send, opened: new Promise((resolve, reject) => ((ws.onopen = resolve), (ws.onerror = reject))) }
}
const watching = viewer(await rpc<Ticket>("custom.resources/ticket", { id: resourceID }))
await watching.opened
await until(async () => (frames > 0 && meta.url ? true : undefined), "frames", 20_000)
check("a viewer gets frames and the session's tabs", frames > 0 && (meta.tabs?.length ?? 0) >= 1, {
  frames,
  url: meta.url,
  tabs: meta.tabs?.length,
})
watching.ws.close()

// 2. Alexandre takes control and navigates; the agent is refused.
const control = await rpc<{ ticket?: Ticket; resource: Resource }>("custom.resources/control", {
  id: resourceID,
  action: "take",
})
check("control: state user", control.resource.state === "user", control.resource.state)
const controlling = viewer(control.ticket!)
await controlling.opened
await until(async () => (meta.url ? true : undefined), "the viewer's meta", 20_000)
controlling.send([{ type: "navigate", action: "url", url: `${args.fixture}/ajuda` }])
await until(async () => (String(meta.url).endsWith("/ajuda") ? true : undefined), "his navigation", 15_000).catch(
  () => undefined,
)
check("he navigates outside a handoff", String(meta.url).endsWith("/ajuda") && errors.length === 0, {
  url: meta.url,
  errors,
})
const refused = await ask(run("return page.url()"))
check(
  "the agent's call on the session is refused with the lock's message",
  refused.text.includes("Alexandre está controlando") && refused.text.includes(browse),
  refused,
)

// 3. He gives it back: the agent hears it, and its next call runs.
await rpc("custom.resources/control", { id: resourceID, action: "release" })
controlling.ws.close()
const back = await ask(run("return page.url()"))
check("its next call runs", back.status === "completed" && back.text.includes("/ajuda"), back)
// The notice waits for the agent's next turn (`resume: false`): that one has it.
check(
  "the agent hears the hand-back with its next turn",
  (await parts()).some((message) => JSON.stringify(message).includes("devolveu o controle")),
)

// 4. A handoff on the same resource, finished by a tap on Continue; the resource stays.
const handoffCall = ask(
  run(
    [
      `await page.goto(${JSON.stringify(`${args.fixture}/`)}, { waitUntil: "load" })`,
      `await handoff("Toque em Continue")`,
      "return page.url()",
    ].join("\n"),
  ),
)
const locked = await until(
  async () => {
    const found = await resource()
    return found?.handoff ? found : undefined
  },
  "the handoff on the resource",
  60_000,
)
check(
  "the handoff locks the same resource",
  locked.id === resourceID &&
    JSON.stringify(locked.capabilities) === JSON.stringify({ navigation: false, tabs: false, focus: true }),
  locked,
)
const handoffs = await rpc<{ data: { resourceID?: string }[] }>("custom.browser-handoffs/list", { sessionID })
check("the handoff names the resource", handoffs.data[0]?.resourceID === resourceID, handoffs.data)
const takeover = await rpc<{ ticket?: Ticket }>("custom.resources/control", { id: resourceID, action: "take" })
const tapping = viewer(takeover.ticket!)
await tapping.opened
meta = {}
await until(async () => (meta.viewport ? true : undefined), "the handoff's viewport", 20_000)
// The viewer's own coordinates: the page's CSS pixels over the viewport its stream reports; tapped again if it missed.
for (let attempt = 0; attempt < 3; attempt++) {
  const css = (await positions(["continue"])).continue!
  const point = { x: css.x / meta.viewport!.width, y: css.y / meta.viewport!.height }
  log("tapping Continue", JSON.stringify(point))
  tapping.send([{ type: "touch", phase: "began", ...point }])
  await Bun.sleep(60)
  tapping.send([{ type: "touch", phase: "ended", ...point }])
  const left = await until(
    async () =>
      (await rpc<{ data: unknown[] }>("custom.browser-handoffs/list", { sessionID })).data.length === 0
        ? true
        : undefined,
    "the handoff to end",
    8_000,
  ).catch(() => false)
  if (left) break
}
const handoffDone = await handoffCall
check("Continue finishes the call", handoffDone.status === "completed", handoffDone)
await until(async () => (ended.length > 0 ? true : undefined), "the stream's end", 20_000).catch(() => undefined)
check(
  "the viewer gets end with kept",
  ended.at(-1)?.reason === "handoff_completed" && ended.at(-1)?.kept === true,
  ended,
)
const after = await until(
  async () => {
    const found = await resource()
    return found && !found.handoff ? found : undefined
  },
  "the resource after the handoff",
  20_000,
)
check(
  "the resource stays, the session's again, without control",
  JSON.stringify(after.capabilities) === JSON.stringify({ navigation: true, tabs: true, focus: true }) &&
    after.state !== "user",
  after,
)

// 5. session_delete removes it.
const deleted = await ask(`await tools.browse.session_delete(${JSON.stringify({ id: browse })})`)
check("session_delete runs", deleted.status === "completed", deleted)
const gone = await until(async () => ((await resource()) ? undefined : true), "the resource to go", 30_000).catch(
  () => false,
)
check("session_delete removes the resource", gone === true)

const secrets = [args.password!, relayToken()]
const leaks = await Promise.all(
  [
    path.join(args.home!, "server.log"),
    path.join(args.home!, "xdg/state/opencode/resources-hub/hub.log"),
    path.join(os.homedir(), ".local/state/browse/logs/relay.log"),
  ].map(async (file) => {
    const text = await Bun.file(file)
      .text()
      .catch(() => "")
    return { file: path.basename(file), leaks: secrets.filter((secret) => text.includes(secret)).length }
  }),
)
check(
  "no password or token in the logs",
  leaks.every((item) => item.leaks === 0),
  leaks,
)
await fetch(`${server}/api/session/${sessionID}`, { method: "DELETE", headers: { authorization: auth } })
await Bun.$`rm -rf ${repo}`.quiet()
console.log(JSON.stringify(results, null, 2))
process.exit(Object.values(results).every((value) => value === "ok") ? 0 : 1)

function relayToken() {
  return readFileSync(path.join(os.homedir(), ".local/share/browse/relay-token"), "utf8").trim()
}

/** Centers of elements (by id, through closed shadow roots) in the session's tab, in CSS pixels. */
async function positions(ids: string[]) {
  const target = String((await resource())?.meta.targetID)
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
    const { sessionId } = await cdp("Target.attachToTarget", { targetId: target, flatten: true })
    const doc = await cdp("DOM.getDocument", { depth: -1, pierce: true }, sessionId)
    const find = (node: any, id: string): any => {
      const attributes: string[] = node.attributes ?? []
      const index = attributes.indexOf("id")
      if (index >= 0 && index % 2 === 0 && attributes[index + 1] === id) return node
      for (const child of [...(node.children ?? []), ...(node.shadowRoots ?? [])]) {
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
        x: (quad[0]! + quad[2]! + quad[4]! + quad[6]!) / 4,
        y: (quad[1]! + quad[3]! + quad[5]! + quad[7]!) / 4,
      }
    }
    await cdp("Target.detachFromTarget", { sessionId })
    return result
  } finally {
    ws.close()
  }
}
