import path from "node:path"
import { mkdir } from "node:fs/promises"
import { Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { controlNames } from "../src/master/index.js"

// Never discover the installed server. All writes/model calls belong to the owned 4179 sandbox.
const home = "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/custom-sandbox-4179"
const evidence = path.join(path.dirname(home), "master-tool-visibility")
const directory = path.join(home, "repos", "master-visibility")
const password = (await Bun.file(path.join(home, "password")).text()).trim()
const headers = {
  Authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
  "Content-Type": "application/json",
}
async function api<A>(
  route: string,
  schema: Schema.Codec<A, unknown>,
  input?: unknown,
  method = input === undefined ? "GET" : "POST",
): Promise<A> {
  const response = await fetch(`http://127.0.0.1:4179${route}`, {
    method,
    headers,
    ...(input === undefined ? {} : { body: JSON.stringify(input) }),
  })
  if (!response.ok) throw new Error(`${route}: HTTP ${response.status}`)
  if (response.status === 204) return Schema.decodeUnknownSync(schema)(undefined)
  return Schema.decodeUnknownSync(schema)(await response.json())
}
await mkdir(directory, { recursive: true, mode: 0o700 })
await mkdir(evidence, { recursive: true, mode: 0o700 })
const git = Bun.spawn(["git", "init", "--quiet", directory], { stdout: "ignore", stderr: "pipe" })
if (await git.exited) throw new Error("Could not initialize owned fake repository")
await Bun.write(
  path.join(directory, "opencode.json"),
  JSON.stringify({
    agents: { "visibility-late": { mode: "primary", permissions: [{ action: "*", resource: "*", effect: "allow" }] } },
  }),
)
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const created: string[] = []
const report = []
const SearchOutput = Schema.Struct({
  items: Schema.Array(Schema.Struct({ path: Schema.String })),
  remaining: Schema.Number,
})
const active = Schema.Struct({ data: Schema.Record(Schema.String, Schema.Struct({ type: Schema.String })) })
try {
  for (const agent of ["build", "mestra", "general", "visibility-late"]) {
    const session = (
      await api("/api/session", Schema.Struct({ data: Session.Info }), {
        title: "Visibility verification · " + agent,
        agent,
        model,
        ...(agent === "general" ? { parentID: created[0] } : { location: { directory } }),
        permissions: [{ action: "*", resource: "*", effect: "allow" }],
      })
    ).data
    created.push(session.id)
    await api(`/api/session/${session.id}/prompt`, Schema.Unknown, {
      text: 'Verificação autorizada e somente leitura do catálogo: execute exatamente return search({namespace:"opencode",limit:100}) na ferramenta execute. Não invoque ferramentas opencode, não leia arquivos, não use shell e não envie mensagens. Depois responda somente CATÁLOGO VERIFICADO.',
    })
    const deadline = Date.now() + 120_000
    while ((await api("/api/session/active", active)).data[session.id]) {
      if (Date.now() > deadline) throw new Error(`Timed out checking ${agent}`)
      await Bun.sleep(250)
    }
    const messages = (
      await api(
        `/api/session/${session.id}/message?limit=50`,
        Schema.Struct({ data: Schema.Array(SessionMessage.Info) }),
      )
    ).data
    const search = messages
      .flatMap((message) => (message.type === "assistant" ? message.content : []))
      .find((part) => part.type === "tool" && part.name === "execute" && part.state.status === "completed")
    if (search?.type !== "tool" || search.state.status !== "completed")
      throw new Error(`No completed Code Mode search for ${agent}`)
    const text = search.state.content?.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n") ?? ""
    const result = Schema.decodeUnknownSync(Schema.fromJsonString(SearchOutput))(text)
    if (result.remaining) throw new Error(`Incomplete catalog search for ${agent}`)
    const controls = result.items
      .map((item) => item.path)
      .filter((name) => controlNames.some((tool) => name === `tools.opencode.${tool}`))
      .toSorted()
    const expected = agent === "mestra" ? controlNames.map((name) => `tools.opencode.${name}`).toSorted() : []
    if (JSON.stringify(controls) !== JSON.stringify(expected))
      throw new Error(`Incorrect master-tool visibility for ${agent}`)
    const catalog = messages
      .filter((message) => message.type === "system" && message.text.includes("# Code Mode"))
      .map((message) => message.text)
    if (agent !== "mestra" && catalog.some((text) => controlNames.some((name) => text.includes(`opencode.${name}(`))))
      throw new Error(`Master tool leaked into ${agent}'s inline catalog`)
    const entry = {
      agent,
      sessionID: session.id,
      parentID: session.parentID,
      controls,
      tools: result.items.map((item) => item.path),
      catalog,
    }
    report.push(entry)
    await Bun.write(path.join(evidence, agent + ".json"), JSON.stringify(entry, null, 2))
    console.log(`${agent}: ${controls.length} master controls; ${result.items.length} opencode tools`)
  }
  await Bun.write(
    path.join(evidence, "summary.json"),
    JSON.stringify({ server: "http://127.0.0.1:4179", report }, null, 2),
  )
} finally {
  for (const id of created.toReversed()) {
    await api(`/api/session/${id}/interrupt`, Schema.Unknown, { resume: false })
    await api(`/api/experimental/session/${id}/wait`, Schema.Unknown, {})
    await api(`/api/session/${id}`, Schema.Unknown, undefined, "DELETE")
  }
}
