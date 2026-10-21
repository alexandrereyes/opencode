#!/usr/bin/env bun
// bun packages/ios-custom/script/seed-conversation.ts [--reset | --stop] [--url URL] [--home PATH]
import { chmod, mkdir } from "node:fs/promises"
import path from "node:path"
import { parseArgs } from "node:util"
import { sandbox, type ConversationSeed } from "./conversation-sandbox"

const args = parseArgs({
  options: {
    url: { type: "string" },
    home: { type: "string" },
    reset: { type: "boolean" },
    stop: { type: "boolean" },
  },
})
const server = await sandbox(args.values.url, args.values.home)
const manifest = path.join(server.home, "seed-conversation.json")
const previous: ConversationSeed | undefined = await Bun.file(manifest)
  .json()
  .catch(() => undefined)
if (args.values.reset || args.values.stop) {
  for (const session of [...(previous?.sessions ?? [])].reverse()) {
    await server.api(`/api/session/${session.id}/interrupt`, {})
    if (args.values.reset) await server.api(`/api/session/${session.id}`, undefined, "DELETE")
  }
  if (args.values.stop) {
    console.log("Interrupted only conversation seed sessions; preserved their history and the Sessões seed.")
    process.exit(0)
  }
}
if (previous && !args.values.reset) throw new Error("Conversation seed exists; use --reset or --stop")

const now = Date.now()
const day = 86_400_000
const directory = path.join(server.home, "repos", "ios-conversation")
await mkdir(path.join(directory, "docs"), { recursive: true })
await mkdir(path.join(directory, "infra/stacks"), { recursive: true })
await mkdir(path.join(directory, ".opencode/skills/conversation-check"), { recursive: true })
await Bun.write(
  path.join(directory, "docs/infra.md"),
  Array.from({ length: 212 }, (_, i) => `Linha ${i + 1}: infraestrutura fictícia.`).join("\n") + "\n",
)
await Bun.write(
  path.join(directory, "docs/alternativas.md"),
  "# Alternativas ao Linear\n\nPlane, Huly e Focalboard. Dados fictícios para testar a interface.\n",
)
await Bun.write(
  path.join(directory, "infra/stacks/plane.yml"),
  "services:\n  plane:\n    image: makeplane/plane:stable\n    deploy:\n      replicas: 1\n",
)
await Bun.write(
  path.join(directory, "AGENTS.md"),
  "Repositório fictício para testar a interface. Nunca pesquise nem faça trabalho real. Cumpra somente a instrução explícita; comandos longos usam timeout=0. Não acesse outros repositórios.\n",
)
await Bun.write(
  path.join(directory, "wait-tests.ts"),
  'console.log("bun test · validação fictícia em andamento")\nawait Bun.sleep(86400000)\nexport {}\n',
)
await Bun.write(
  path.join(directory, "opencode.json"),
  JSON.stringify(
    {
      commands: {
        "conversation-review": {
          description: "Revisa o exemplo fictício da conversa",
          template: "Responda apenas: exemplo revisado. $ARGUMENTS",
        },
      },
    },
    null,
    2,
  ),
)
await Bun.write(
  path.join(directory, ".opencode/skills/conversation-check/SKILL.md"),
  "---\nname: conversation-check\ndescription: Confere o exemplo fictício da conversa\nslash: true\n---\nResponda apenas que o exemplo foi conferido. Não use ferramentas.\n",
)
if (!(await Bun.file(path.join(directory, ".git/config")).exists())) {
  await git("init", "-b", "neon-mountain")
  await git("config", "user.name", "Conversation Fixture")
  await git("config", "user.email", "fixture@example.invalid")
  await git("add", ".")
  await git("-c", "commit.gpgsign=false", "commit", "-m", "Conversation fixture")
}
const seed: ConversationSeed = { createdAt: now, directory, sessions: [] }
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const tokens = { input: 436700, output: 240, reasoning: 60, cache: { read: 4000, write: 0 } }
const permissionTokens = { ...tokens, input: 604700 }
const comparison =
  "Compara alternativas open source ao Linear que dê para hospedar no Swarm. Quero custo, licença e integração com o GitHub."
const markdown =
  "Encontrei três opções viáveis:\n\n- **Plane** · AGPL-3.0\n- **Huly** · EPL-2.0\n- **Focalboard** · MIT\n\nTodas sobem com `docker compose` e convertem para stack.\n\n```yaml\nservices:\n  plane:\n    image: makeplane/plane:stable\n    deploy:\n      replicas: 1\n```\n\nRecomendo o **Plane**: tem integração nativa com o GitHub."
const stacks = "São 6 stacks: `core-infra`, `abacato`, `opencode`, `observability`, `whatsapp` e `llm-proxy`."
// Valid 96×64 RGB PNG: orange circle and green rectangle on a light background.
const image = "iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAyUlEQVR42u3asRGDMBBFQTVGB06pxSldugViB8QuACPEWNJw8s68CjaT/qXtvSpTQgAIECBAgAABAiRAgADFBXo9p5L+EaiQJihT6kxzlemxzI1qDvSjTqFRVKAqOiVGIYEq6pwaxQOqrpM3CgbUSCdjFAmoqc6REaBRgDrofDUCNARQN529ESBAgAABAgQIECBAgAABAuQ1D8iPIiCrhl1s2F3Msmqbd93RDch90C0uzEYAcqPoylWAAAECBAgQIEACBAgQoDv1AQkKOb0EQHvHAAAAAElFTkSuQmCC"
await Bun.write(path.join(directory, "exemplo.png"), Buffer.from(image, "base64"))
const id = (prefix: string) => `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`
const user = (text: string, date: number, extra = {}) => ({
  id: id("msg"),
  type: "user",
  text,
  time: { created: date },
  ...extra,
})
const assistant = (
  text: string,
  date: number,
  content: ({ time?: { completed?: number } } & Record<string, unknown>)[] = [],
  extra = {},
) => ({
  id: id("msg"),
  type: "assistant",
  agent: "build",
  model,
  tokens,
  cost: 0.004,
  time: {
    created: date,
    streamed: date + 2000,
    completed: Math.max(date + 3000, ...content.map((part) => part.time?.completed ?? 0)),
  },
  finish: "stop",
  content: [...content, ...(text ? [{ type: "text", text }] : [])],
  ...extra,
})
const tool = (name: string, input: object, text: string, date: number, metadata = {}, duration = 2000) => ({
  type: "tool",
  id: id("call"),
  name,
  time: { created: date, ran: date, completed: date + duration },
  state: { status: "completed", input, content: [{ type: "text", text }], metadata },
})
const reasoning = (text: string, date: number, duration: number) => ({
  type: "reasoning",
  text,
  time: { created: date, completed: date + duration },
})
const aID = id("ses")
const childIDs = [id("ses"), id("ses"), id("ses")]
const descriptions = ["Comparar alternativas Linear", "Revisar licença dos projetos", "Avaliar integrações disponíveis"]
await imported(aID, "Conversa A — trabalhando", "running + queue + 2 active children", "working", [
  user("Quais stacks estão no Swarm?", now - day),
  assistant(stacks, now - day + 1000),
  user(comparison, now - 240_000),
  assistant("Vou dividir em três frentes e delegar para subagentes.", now - 239_000, [
    reasoning("Vou consultar a infraestrutura e separar licença de integrações.", now - 239_000, 6000),
    tool(
      "read",
      { path: "docs/infra.md" },
      `Read file docs/infra.md, lines 1-212\n${Array.from({ length: 212 }, (_, i) => `${i + 1}: Infraestrutura fictícia.`).join("\n")}`,
      now - 232_000,
      { truncated: false },
    ),
    reasoning("As três frentes são independentes.", now - 230_000, 2000),
    ...childIDs.map((sessionID, index) =>
      tool(
        "subagent",
        {
          agent: index === 1 ? "general" : "explore",
          description: descriptions[index],
          prompt: "Exemplo fictício.",
          model: "llm-proxy/gpt-6-luna#low",
          background: index !== 1,
        },
        index === 1 ? "Licenças revisadas." : "Subagente iniciado em background.",
        now - 225_000 + index * 2000,
        { sessionID, status: index === 1 ? "completed" : "running" },
        index === 1 ? 108_000 : 1000,
      ),
    ),
    tool(
      "edit",
      { path: "docs/alternativas.md", oldString: "", newString: "Resumo fictício" },
      "Arquivo atualizado.",
      now - 110_000,
      {
        files: [
          {
            file: "docs/alternativas.md",
            patch: `--- /dev/null\n+++ docs/alternativas.md\n@@ -0,0 +1,48 @@\n${Array.from({ length: 48 }, (_, i) => `+Resumo fictício ${i + 1}`).join("\n")}\n`,
            status: "added",
            additions: 48,
            deletions: 0,
          },
        ],
      },
    ),
  ]),
])
for (const [index, childID] of childIDs.entries()) {
  await imported(
    childID,
    descriptions[index],
    index === 1 ? "completed child" : "running child",
    `child-${index}`,
    [
      user(
        index === 1
          ? "Revise somente as licenças do exemplo fictício."
          : 'Validação autorizada: execute somente shell command="sleep 86400", timeout=0, background=false.',
        now - 210_000,
      ),
      ...(index === 1 ? [assistant("Licenças revisadas: AGPL-3.0, EPL-2.0 e MIT.", now - 110_000)] : []),
    ],
    aID,
    index === 1 ? "general" : "explore",
  )
}
const bID = id("ses")
await imported(
  bID,
  "Conversa B — precisa de você",
  "pending git push permission",
  "permission",
  [
    user(comparison, now - 200_000),
    assistant(markdown, now - 190_000, [], { tokens: permissionTokens }),
    user("Depois disso, abre um PR com o resumo.", now - 180_000),
    assistant(
      "",
      now - 170_000,
      [
        tool(
          "edit",
          { path: "docs/alternativas.md", oldString: "Plane", newString: "**Plane**" },
          "Resumo pronto.",
          now - 170_000,
        ),
        tool("shell", { command: "git diff --stat" }, "docs/alternativas.md | 48 +\n", now - 167_000),
      ],
      { tokens: permissionTokens },
    ),
  ],
  undefined,
  "build",
  true,
)
const historyID = id("ses")
const final = assistant(markdown, now - 10_000, [], { tokens: { ...tokens, input: 636200 } })
const quote = {
  id: "quote-conversation",
  messageID: final.id,
  partID: `${final.id}:text:0`,
  text: "tem integração nativa com o GitHub",
  comment: "Confere essa integração antes do PR",
  anchor: {
    start: markdown.indexOf("tem integração"),
    end: markdown.indexOf("tem integração") + "tem integração nativa com o GitHub".length,
    exact: "tem integração nativa com o GitHub",
  },
}
await imported(
  historyID,
  "Conversa C — histórico e compositor",
  "89 messages + image + quote + errors + compaction + unread tail",
  "history",
  [
    ...Array.from({ length: 40 }, (_, i) => [
      user(`Revisão ${i + 1}: o que mudou?`, now - 2 * day + i * 10000),
      assistant(`Revisão ${i + 1} concluída. O exemplo permanece isolado.`, now - 2 * day + i * 10000 + 1000),
    ]).flat(),
    user("Analisa esta imagem fictícia.", now - day, {
      files: [{ data: image, mime: "image/png", name: "exemplo.png", source: { type: "inline" } }],
    }),
    assistant("A imagem de teste tem um círculo laranja e um retângulo verde.", now - day + 1000),
    assistant("Pesquisa e validação concluídas.", now - 100_000, [
      tool("glob", { pattern: "**/*.md" }, "docs/infra.md\ndocs/alternativas.md", now - 100_000),
      tool("grep", { pattern: "Plane", path: "docs" }, "docs/alternativas.md:3:Plane", now - 99000),
      tool(
        "websearch",
        { query: "alternativas Linear open source" },
        "Exemplo fictício: Plane, Huly, Focalboard.",
        now - 98000,
      ),
      tool(
        "webfetch",
        { url: "https://example.invalid/plane", format: "markdown" },
        "# Plane\nDocumentação fictícia.",
        now - 97500,
      ),
      tool("execute", { code: 'return { status: "ok" }' }, '{"status":"ok"}', now - 97300, { toolCalls: [] }),
      {
        ...tool("read", { path: "exemplo.png" }, "Image read successfully", now - 97200),
        state: {
          status: "completed",
          input: { path: "exemplo.png" },
          content: [
            { type: "text", text: "Image read successfully" },
            { type: "file", mime: "image/png", uri: `data:image/png;base64,${image}` },
          ],
          metadata: { truncated: false },
        },
      },
      tool(
        "patch",
        { patchText: "*** Begin Patch\n*** Update File: docs/alternativas.md\n@@\n-Plane\n+**Plane**\n*** End Patch" },
        "Patch aplicado.",
        now - 97000,
        {
          files: [
            {
              file: "docs/alternativas.md",
              status: "modified",
              additions: 1,
              deletions: 1,
              patch: "--- docs/alternativas.md\n+++ docs/alternativas.md\n@@ -1 +1 @@\n-Plane\n+**Plane**\n",
            },
          ],
        },
      ),
      tool(
        "shell",
        { command: "printf 'Falha demonstrativa\\n'; exit 2" },
        "Falha demonstrativa\nExited with code 2",
        now - 96000,
        { exit: 2 },
      ),
      {
        ...tool("read", { path: "ausente.md" }, "", now - 95000),
        state: {
          status: "error",
          input: { path: "ausente.md" },
          error: { type: "ToolError", message: "File not found: ausente.md" },
        },
      },
      tool(
        "question",
        {
          questions: [
            {
              header: "Licença",
              question: "Qual licença revisar?",
              options: [{ label: "MIT", description: "Permissiva" }],
            },
          ],
        },
        "MIT",
        now - 94000,
      ),
    ]),
    {
      id: id("msg"),
      type: "compaction",
      status: "completed",
      reason: "manual",
      summary: "Resumo fictício das revisões anteriores.",
      recent: "Comparação de ferramentas.",
      model,
      time: { created: now - 80000 },
    },
    assistant("Tentativa recuperada.", now - 70000, [], {
      retry: {
        attempt: 1,
        at: now - 71000,
        error: { type: "RateLimitError", message: "Limite temporário demonstrativo", status: 429 },
      },
    }),
    user(comparison, now - 20000),
    final,
    user(
      `Comments on earlier assistant messages:\n\n1. Quoted from message ${final.id} (part ${quote.partID}):\n> ${quote.text}\nUser comment: ${quote.comment}`,
      now - 5000,
      { metadata: { displayText: "Antes de subir, confere isso", comments: [], quotes: [quote] } },
    ),
    assistant(
      "Vou conferir a integração antes do PR.\n\nPR fictício: #482 · `neon-mountain` → `main`.",
      now - 4000,
      [],
      { tokens: { ...tokens, input: 636200 } },
    ),
  ],
)
const formsID = id("ses")
await imported(formsID, "Conversa D — pergunta", "pending question", "question", [
  user("Qual licença revisar?", now - 1000),
])

const snippets = await server.rpc<{ items: { name: string }[] }>("custom.snippets", "list", {})
for (const [name, description, content] of [
  ["revisar", "Revisa o diff e aponta riscos", "Revise o diff fictício e aponte riscos."],
  ["resumo", "Resume o que foi feito na sessão", "Resuma o exemplo fictício desta sessão."],
])
  if (!snippets.items.some((item) => item.name === name))
    await server.rpc("custom.snippets", "save", { id: `conversation-${name}`, name, description, content, aliases: [] })

// A synthetic instruction preserves the exact approved user bubbles. Imported history is never claimed to be live work.
await Promise.all([
  synthetic(
    aID,
    'Use somente shell, command="bun run wait-tests.ts", timeout=0, background=false. O script demonstra bun test com sleep barato. Não use outras ferramentas nem finalize antes do comando.',
  ),
  ...[0, 2].map((index) =>
    synthetic(
      childIDs[index],
      'Use somente shell, command="sleep 86400", timeout=0, background=false. Não use outras ferramentas.',
    ),
  ),
  synthetic(
    bID,
    'Use somente shell para executar exatamente "git push origin neon-mountain", em primeiro plano. Aguarde a permissão; não altere remotos nem contorne a permissão.',
  ),
  synthetic(
    formsID,
    'Use somente question: cabeçalho "Licença", pergunta "Qual licença você quer revisar?", opções "AGPL-3.0" (Plane), "EPL-2.0" (Huly), "MIT" (Focalboard). Aguarde a resposta.',
  ),
])
await server.api(`/api/session/${aID}/prompt`, {
  id: id("msg"),
  text: "Depois disso, abre um PR com o resumo",
  delivery: "queue",
  resume: false,
})
const deadline = Date.now() + 300_000
while (Date.now() < deadline) {
  const [active, permissions, forms, transcript] = await Promise.all([
    server.api<{ data: Record<string, unknown> }>("/api/session/active"),
    server.api<{ data: unknown[] }>(`/api/session/${bID}/permission`),
    server.api<{ data: unknown[] }>(`/api/session/${formsID}/form`),
    server.rpc<{ data: { content?: { name?: string; state?: { status: string } }[] }[] }>("custom.transcript", "list", {
      sessionID: aID,
      limit: 5,
      order: "desc",
    }),
  ])
  if (
    [aID, childIDs[0], childIDs[2]].every((id) => active.data[id]) &&
    permissions.data.length &&
    forms.data.length &&
    transcript.data.some((m) => m.content?.some((p) => p.name === "shell" && p.state?.status === "running"))
  ) {
    await save()
    console.log(JSON.stringify(seed, null, 2))
    process.exit(0)
  }
  await Bun.sleep(2000)
}
throw new Error("Live seed did not settle within five minutes. Manifest retained; inspect, then --stop or --reset.")

async function imported(
  sessionID: string,
  title: string,
  state: string,
  role: string,
  messages: unknown[],
  parentID?: string,
  agent = "build",
  ask = false,
) {
  await server.api("/api/experimental/session/import", {
    info: {
      id: sessionID,
      title,
      ...(parentID ? { parentID } : {}),
      projectID: "global",
      location: { directory },
      model,
      agent,
      cost: 0.02,
      tokens,
      outcome: "succeeded",
      time: {
        created: now - 3 * day,
        updated: now,
        idle: now - 1000,
        viewed: role === "history" ? now - day : now - 1000,
      },
      permissions: [
        { action: "*", resource: "*", effect: "allow" },
        ...(ask ? [{ action: "shell", resource: "git push*", effect: "ask" }] : []),
      ],
    },
    messages,
    location: { directory },
  })
  seed.sessions.push({ id: sessionID, title, state, role })
  await save()
}
async function save() {
  await Bun.write(manifest, JSON.stringify(seed, null, 2) + "\n", { mode: 0o600 })
  await chmod(manifest, 0o600)
}
async function synthetic(sessionID: string, text: string) {
  await server.api(`/api/session/${sessionID}/synthetic`, {
    text,
    description: "Demonstração de interface isolada",
    delivery: "steer",
  })
}
async function git(...command: string[]) {
  const child = Bun.spawn(["git", "-c", "core.hooksPath=/dev/null", ...command], {
    cwd: directory,
    stdout: "ignore",
    stderr: "pipe",
  })
  if (await child.exited) throw new Error(`Fixture git ${command[0]} failed`)
}
