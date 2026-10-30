import path from "node:path"
import { mkdir } from "node:fs/promises"
import { Schema } from "effect"
import { Session } from "@opencode/schema/session"
import { SessionMessage } from "@opencode/schema/session-message"
import { Master } from "../src/master/rpc.js"

// Intentionally hard-coded to this feature's owned sandbox. Never discovers a shared server.
const home = "/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/custom-sandbox-4179"
const evidence = path.join(path.dirname(home), "ios-mestra-prints")
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
  if (!response.ok) throw new Error(`${route}: HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`)
  if (response.status === 204) return Schema.decodeUnknownSync(schema)(undefined)
  return Schema.decodeUnknownSync(schema)(await response.json())
}
const info = await api("/api/rpc/custom.master/info", Schema.Struct({ output: Master.Info }), { input: {} })
await mkdir(evidence, { recursive: true, mode: 0o700 })
const directories = await Promise.all(
  ["mestra-alpha", "mestra-beta"].map(async (name) => {
    const directory = path.join(home, "repos", name)
    await mkdir(directory, { recursive: true })
    const git = Bun.spawn(["git", "init", "--quiet", directory], { stdout: "ignore", stderr: "pipe" })
    if (await git.exited) throw new Error("Could not initialize owned fake repository")
    return directory
  }),
)
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const sessionResponse = Schema.Struct({ data: Session.Info })
const root = (
  await api("/api/session", sessionResponse, {
    title: "Mestra · alvo de teste",
    location: { directory: directories[0] },
    agent: "build",
    model,
    permissions: [
      { action: "*", resource: "*", effect: "allow" },
      { action: "master-test", resource: "*", effect: "ask" },
    ],
  })
).data
const runner = (
  await api("/api/session", sessionResponse, {
    title: "Mestra · interromper",
    location: { directory: directories[1] },
    agent: "build",
    model,
  })
).data
const child = (await api("/api/session", sessionResponse, { title: "Mestra · filho excluído", parentID: root.id })).data
const question = await api(
  `/api/session/${root.id}/form`,
  Schema.Struct({ data: Schema.Struct({ id: Schema.String }) }),
  {
    title: "Qual resposta de teste?",
    metadata: { kind: "question" },
    fields: [{ key: "answer", type: "string", required: true, options: [{ value: "ok", label: "OK" }] }],
  },
)
const permission = await api(
  `/api/session/${root.id}/permission`,
  Schema.Struct({ data: Schema.Struct({ id: Schema.String, effect: Schema.String }) }),
  { action: "master-test", resources: [directories[0]] },
)
const allocation = await api(
  "/api/rpc/custom.chats/allocate",
  Schema.Struct({ output: Schema.Struct({ id: Schema.String, directory: Schema.String }) }),
  { input: {} },
)
const master = (
  await api("/api/session", sessionResponse, {
    title: "Sessão mestra · verificação",
    agent: info.output.agent,
    model: info.output.model,
    location: { directory: allocation.output.directory },
  })
).data
await api("/api/rpc/custom.preferences/mutate", Schema.Unknown, {
  input: { type: "master.set", server: "local", sessionID: master.id },
})
await api(`/api/session/${runner.id}/prompt`, Schema.Unknown, {
  text: "Teste controlado: execute shell sleep 90, depois diga OK. Não altere arquivos.",
})
const prompt = `Verificação explicitamente autorizada por Alexandre, somente nestas sessões de teste. Use suas ferramentas, não shell/CLI. Em ordem:
1. sessions.list (limit 20) e também filtro running; sessions.status de ${root.id}; sessions.read de ${root.id}.
2. sessions.requests (sessionID ${root.id}); sessions.answer question ${question.data.id}, answer {"answer":"ok"}; sessions.answer permission ${permission.data.id}, allow true.
3. sessions.send a ${root.id}: "Responda somente ALFA, sem ferramentas", delivery steer. Outro sessions.send a ela: "Responda somente BETA, sem ferramentas", delivery queue.
4. sessions.create directory ${directories[1]}, agent build, model {"providerID":"llm-proxy","id":"gpt-6-luna","variant":"low"}, title "Mestra · criada pela ferramenta", text "Responda somente CRIADA, sem ferramentas".
5. sessions.interrupt ${runner.id}; sessions.wait de ${root.id} com timeoutSeconds 60.
6. sessions.list state idle e resuma os resultados em até 5 linhas. Não controle ${child.id}, que é filho. Não controle esta própria sessão. Execute todas as etapas solicitadas agora.`
await api(`/api/session/${master.id}/prompt`, Schema.Unknown, { text: prompt })
const deadline = Date.now() + 180_000
const activeSchema = Schema.Struct({ data: Schema.Record(Schema.String, Schema.Struct({ type: Schema.String })) })
async function waitMaster() {
  while ((await api("/api/session/active", activeSchema)).data[master.id]) {
    if (Date.now() > deadline) {
      await api(`/api/session/${master.id}/interrupt`, Schema.Unknown, {}, "POST")
      throw new Error("Master live verification exceeded 180 seconds")
    }
    await Bun.sleep(500)
  }
}
await waitMaster()
// Force a separate read-only call: IDs in the first request must not make the model skip discovery.
await api(`/api/session/${master.id}/prompt`, Schema.Unknown, {
  text: `Execute agora tools.sessions.requests({sessionID:"${root.id}"}). Faça a chamada efetiva, não somente search, e informe a quantidade de pendências.`,
})
await waitMaster()
const messages = await api(
  `/api/session/${master.id}/message?limit=50`,
  Schema.Struct({ data: Schema.Array(SessionMessage.Info) }),
)
const decodeCalls = Schema.decodeUnknownSync(
  Schema.Struct({
    toolCalls: Schema.optionalKey(Schema.Array(Schema.Struct({ tool: Schema.String, status: Schema.String }))),
  }),
)
const calls = new Map(
  messages.data.flatMap((message) =>
    message.type === "assistant"
      ? message.content.flatMap((part) =>
          part.type === "tool" && part.state.status === "completed"
            ? [[part.id, decodeCalls(part.state.metadata ?? {}).toolCalls ?? []] as const]
            : [],
        )
      : [],
  ),
)
const used = new Set(
  [...calls.values()]
    .flat()
    .filter((call) => call.status === "completed")
    .map((call) => call.tool),
)
const missing = ["list", "status", "read", "send", "create", "interrupt", "requests", "answer", "wait"].filter(
  (name) => !used.has(`sessions.${name}`),
)
if (missing.length)
  throw new Error(
    `Live verification missed tools: ${missing.join(", ")}; ask this test master explicitly before collecting evidence`,
  )
const wire = Schema.encodeSync(Schema.Array(SessionMessage.Info))(messages.data)
await Bun.write(
  path.join(evidence, "live-transcript.json"),
  JSON.stringify(
    { master: master.id, root: root.id, runner: runner.id, child: child.id, directories, messages: wire },
    null,
    2,
  ),
)
const text = messages.data
  .toReversed()
  .flatMap((message) =>
    message.type === "assistant"
      ? message.content.flatMap((part) =>
          part.type === "text"
            ? ["Mestra: " + part.text]
            : part.type === "tool"
              ? (calls.get(part.id) ?? []).map((call) => `[${call.tool}: ${call.status}]`)
              : [],
        )
      : message.type === "user"
        ? [
            "Alexandre: " +
              message.text.slice(0, 300) +
              (message.text.length > 300 ? "… (pedido completo no JSON)" : ""),
          ]
        : [],
  )
await Bun.write(path.join(evidence, "live-transcript.txt"), text.join("\n\n"))
console.log(JSON.stringify({ master: master.id, root: root.id, runner: runner.id, child: child.id, evidence }, null, 2))
// Leave only idle, owned test histories for the iOS tests; nothing remains executing.
for (const session of [root, runner, master])
  await api(`/api/session/${session.id}/interrupt`, Schema.Unknown, {}, "POST")
