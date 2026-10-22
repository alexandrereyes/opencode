#!/usr/bin/env bun
// bun packages/ios-custom/script/capture-conversation.ts [--url URL] [--home PATH]
import { chmod } from "node:fs/promises"
import path from "node:path"
import { parseArgs } from "node:util"
import { sandbox, type ConversationSeed } from "./conversation-sandbox"

const args = parseArgs({
  options: { url: { type: "string" }, home: { type: "string" }, "snapshot-only": { type: "boolean" } },
})
const server = await sandbox(args.values.url, args.values.home)
const manifest = path.join(server.home, "seed-conversation.json")
const seed: ConversationSeed = await Bun.file(manifest).json()
if (!seed.directory.startsWith(path.join(server.home, "repos") + path.sep))
  throw new Error("Seed escaped sandbox repositories")
const root = path.join(import.meta.dir, "../OpenCodeKit/Tests/OpenCodeKitTests/Fixtures/Conversation")
const location = `location%5Bdirectory%5D=${encodeURIComponent(seed.directory)}`
const password = (await Bun.file(path.join(server.home, "password")).text()).trim()
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const find = (role: string) => {
  const item = seed.sessions.find((session) => session.role === role)
  if (!item) throw new Error(`Missing seed role ${role}`)
  return item.id
}
const files: string[] = []
function scrub(value: unknown, redact = false): unknown {
  if (typeof value === "string" && redact) return "[REDACTED]"
  if (typeof value === "string")
    return value
      .replaceAll(password, "[REDACTED]")
      .replaceAll(server.home, "/sandbox")
      .replace(/\/Users\/[^\s"'<>),;]+/g, "/sandbox/local")
      .replace(/\/private\/var\/[^\s"'<>),;]+/g, "/sandbox/temp")
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "account@example.invalid")
  if (Array.isArray(value)) return value.map((item) => scrub(item, redact))
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [
        key,
        scrub(
          item,
          redact ||
            /^(authorization|password|api[-_]?key|access[-_]?token|refresh[-_]?token|client[-_]?secret|headers|encrypted_content|signature)$/i.test(
              key,
            ) ||
            (typeof item === "string" && /secret|credential|token|password|api.?key/i.test(key)),
        ),
      ]),
    )
  return value
}
async function save(name: string, value: unknown) {
  await Bun.write(path.join(root, `${name}.json`), JSON.stringify(scrub(value), null, 2) + "\n")
  files.push(`${name}.json`)
}
for (const [name, route] of [
  ["models", `/api/model?${location}`],
  ["agents", `/api/agent?${location}`],
  ["commands", `/api/command?${location}`],
  ["skills", `/api/skill?${location}`],
  ["references", `/api/reference?${location}`],
  ["file-search", `/api/fs/find?${location}&query=infra&limit=20`],
  ["shells", `/api/shell?${location}`],
  ["active", "/api/session/active"],
]) {
  const value = await server.api<{ data: { id?: string; content?: string; prompt?: string }[] }>(route)
  // The inherited catalog can include private personal skills. Keep the complete wire shape of
  // the fixture-owned entry only; prompts from other local agents are not contract fixtures.
  if (name === "skills") value.data = value.data.filter((item) => item.id === "conversation-check")
  // The full catalog is ~400 models; the sandbox's own provider and Anthropic cover the selector and footer shapes.
  if (name === "models")
    value.data = value.data.filter((item) =>
      ["llm-proxy", "anthropic"].includes((item as { providerID?: string }).providerID ?? ""),
    )
  if (name === "agents")
    value.data = value.data.map((item) => ({
      ...item,
      ...(item.prompt ? { prompt: "[REDACTED: local agent instructions]" } : {}),
      ...("system" in item ? { system: "[REDACTED: local agent instructions]" } : {}),
    }))
  await save(name, value)
}
for (const [name, rpcID] of [
  ["snippets", "custom.snippets"],
  ["preferences", "custom.preferences"],
])
  await save(name, { output: await server.rpc(rpcID, name === "snippets" ? "list" : "get", {}) })
for (const role of ["working", "permission", "history", "question", "child-0"]) {
  const sessionID = find(role)
  await save(`session-${role}`, await server.api(`/api/session/${sessionID}`))
  await save(`transcript-${role}`, {
    output: await server.rpc("custom.transcript", "list", { sessionID, limit: 40, order: "desc" }),
  })
  await save(`inbox-${role}`, await server.api(`/api/session/${sessionID}/inbox`))
}
const latest = await server.rpc<{ data: unknown[]; cursor: { next?: string } }>("custom.transcript", "list", {
  sessionID: find("history"),
  limit: 40,
  order: "desc",
})
if (!latest.cursor.next) throw new Error("History seed must have an older page")
await save("transcript-history-older", {
  output: await server.rpc("custom.transcript", "list", {
    sessionID: find("history"),
    limit: 40,
    cursor: latest.cursor.next,
  }),
})
const older = await server.rpc<{ cursor: { next?: string } }>("custom.transcript", "list", {
  sessionID: find("history"),
  limit: 40,
  cursor: latest.cursor.next,
})
if (older.cursor.next)
  await save("transcript-history-oldest", {
    output: await server.rpc("custom.transcript", "list", {
      sessionID: find("history"),
      limit: 40,
      cursor: older.cursor.next,
    }),
  })
await save("context-history", await server.api(`/api/session/${find("history")}/context`))
await save("permissions", await server.api(`/api/session/${find("permission")}/permission`))
await save("forms", await server.api(`/api/session/${find("question")}/form`))
await save("family-working", {
  output: await server.rpc("custom.session-family", "snapshot", { sessionID: find("working") }),
})
await save("family-page", {
  output: await server.rpc("custom.session-family", "page", { sessionID: find("working"), limit: 10 }),
})
const missing = await fetch(new URL("/api/rpc/custom.session-family/snapshot", server.url), {
  method: "POST",
  headers: server.headers,
  body: JSON.stringify({ input: { sessionID: "ses_conversation_missing" } }),
})
await save("family-missing", { status: missing.status, body: await missing.json() })
const detail = await server.api<{ data: { id: string; type: string; content?: { name?: string }[] }[] }>(
  `/api/session/${find("history")}/message?limit=40&order=desc`,
)
const imageMessage = detail.data.find((message) => message.content?.some((part) => part.name === "read"))
if (imageMessage)
  await save("message-full-tool-image", await server.api(`/api/session/${find("history")}/message/${imageMessage.id}`))

if (args.values["snapshot-only"]) {
  await save("events-live-step", await Bun.file(path.join(root, "events-live-step.json")).json())
  await save("transcript-live-step", await Bun.file(path.join(root, "transcript-live-step.json")).json())
  if (await Bun.file(path.join(root, "btw-response.json")).exists())
    await save("btw-response", await Bun.file(path.join(root, "btw-response.json")).json())
  await finish()
  process.exit(0)
}

// Only this capture's scratch session receives a prompt. Other seeded requests are read-only.
const scratchID = `ses_${crypto.randomUUID().replaceAll("-", "")}`
const controller = new AbortController()
const response = await fetch(new URL("/api/event", server.url), { headers: server.headers, signal: controller.signal })
if (!response.ok || !response.body) throw new Error("SSE connection failed")
type Event = { type: string; data: { sessionID?: string }; [key: string]: unknown }
const events: Event[] = []
const recording = (async () => {
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ""
  while (true) {
    const chunk = await reader.read()
    if (chunk.done) break
    buffer += decoder.decode(chunk.value, { stream: true })
    const frames = buffer.split(/\r?\n\r?\n/)
    buffer = frames.pop() ?? ""
    for (const frame of frames) {
      const text = frame
        .split(/\r?\n/)
        .filter((line) => line.startsWith("data:"))
        .map((line) => line.slice(5).trimStart())
        .join("\n")
      if (!text) continue
      const event: Event = JSON.parse(text)
      if (event.type === "server.connected" || event.data.sessionID === scratchID) events.push(event)
      if (
        event.data.sessionID === scratchID &&
        ["session.execution.succeeded", "session.execution.failed"].includes(event.type)
      ) {
        await reader.cancel()
        return
      }
    }
  }
})()
await server.api("/api/session", {
  id: scratchID,
  title: "Conversa — captura SSE",
  model,
  location: { directory: seed.directory },
  permissions: [{ action: "*", resource: "*", effect: "allow" }],
})
seed.sessions.push({
  id: scratchID,
  title: "Conversa — captura SSE",
  state: "completed SSE recording",
  role: "event-scratch",
})
await Bun.write(manifest, JSON.stringify(seed, null, 2) + "\n")
await chmod(manifest, 0o600)
await server.api(`/api/session/${scratchID}/prompt`, {
  text: 'Use só shell command="printf OK". Depois responda só "OK".',
})
const timeout = setTimeout(() => controller.abort(), 120_000)
await recording.finally(() => {
  clearTimeout(timeout)
  controller.abort()
})
if (!events.some((event) => event.type === "session.execution.succeeded"))
  throw new Error("Scratch execution did not succeed; do not accept an incomplete event fixture")
await save("events-live-step", events)
const completed = await server.rpc("custom.transcript", "list", { sessionID: scratchID, limit: 40, order: "asc" })
await save("transcript-live-step", { output: completed })
await save(
  "btw-response",
  await server.api(`/api/session/${scratchID}/generate`, {
    prompt: "Pergunta paralela de teste. Responda apenas OK, sem ferramentas.",
  }),
)
if (
  JSON.stringify(completed) !==
  JSON.stringify(await server.rpc("custom.transcript", "list", { sessionID: scratchID, limit: 40, order: "asc" }))
)
  throw new Error("Side question modified the transcript")
await finish()

async function finish() {
  const scratch = seed.sessions.findLast((session) => session.role === "event-scratch")
  if (!scratch) throw new Error("No owned scratch session")
  const text = "Confira @docs/infra.md com @explore e $conversation-check."
  const mention = (token: string) => ({
    start: text.indexOf(token),
    end: text.indexOf(token) + token.length,
    text: token,
  })
  const request = {
    id: `msg_${crypto.randomUUID().replaceAll("-", "")}`,
    text,
    files: [{ uri: `file://${seed.directory}/docs/infra.md`, name: "infra.md", mention: mention("@docs/infra.md") }],
    agents: [{ name: "explore", mention: mention("@explore") }],
    skills: [{ id: "conversation-check", mention: mention("$conversation-check") }],
    metadata: {
      displayText: text,
      comments: [],
      agent: "build",
      model: { providerID: model.providerID, modelID: model.id, variant: model.variant },
    },
    delivery: "queue",
    resume: false,
  }
  await save("prompt-request", request)
  const admission = await server.api(`/api/session/${scratch.id}/prompt`, request)
  await save("prompt-admission", admission)
  const retry = await server.api(`/api/session/${scratch.id}/prompt`, { ...request, text: "Ignored idempotent retry" })
  if (JSON.stringify(admission) !== JSON.stringify(retry)) throw new Error("Admission was not idempotent")
  await server.api(`/api/session/${scratch.id}/inbox/${request.id}`, undefined, "DELETE")
  const session = await server.api<{ data: { time: { idle?: number } } }>(`/api/session/${scratch.id}`)
  if (session.data.time.idle) await server.api(`/api/session/${scratch.id}/view`, { idle: session.data.time.idle })
  await save("viewed-session", await server.api(`/api/session/${scratch.id}`))
  await save("index", {
    version: 1,
    capturedAt: Date.now(),
    source: server.url.origin,
    seed,
    files: [...files, "index.json"],
    note: "Native HTTP/RPC envelopes, scrubbed paths and credentials; imported history is deliberate fixture data, events-live-step is observed execution.",
  })
  console.log(`Captured ${files.length} sanitized conversation fixtures; SSE session ${scratch.id}.`)
}
