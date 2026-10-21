#!/usr/bin/env bun

// bun packages/ios-custom/script/seed-sessions.ts [--reset | --stop] [--url URL] [--home PATH]

import { chmod, mkdir, realpath } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"

const args = parseArgs({
  options: {
    url: { type: "string", default: "http://127.0.0.1:4177" },
    home: { type: "string" },
    reset: { type: "boolean" },
    stop: { type: "boolean" },
  },
})
const url = new URL(args.values.url)
if (!["127.0.0.1", "localhost"].includes(url.hostname) || ["4096", "4178", ""].includes(url.port))
  throw new Error("Seed only an isolated localhost sandbox, never production")
const home = path.resolve(
  args.values.home ?? path.join(await realpath(os.tmpdir()), "opencode", `custom-sandbox-${url.port}`),
)
const owner = await Bun.file(path.join(home, "sandbox.json")).json()
if (owner.home !== home || owner.port !== Number(url.port)) throw new Error("Sandbox home/port do not match")
const password = (await Bun.file(path.join(home, "password")).text()).trim()
const headers = {
  authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
  "content-type": "application/json",
}
const manifest = path.join(home, "seed-sessions.json")
type Fixture = { id: string; title: string; directory: string; state: string }
type Session = {
  id: string
  title: string
  projectID: string
  parentID?: string
  location: { directory: string }
  time: { created: number; updated: number; idle?: number; viewed?: number; archived?: number }
}
type Navigation = { data: { session: Session; unreadAt?: number; permissionCount?: number; questionCount?: number }[] }
type Preferences = {
  data: {
    projects: Record<string, { projects: { worktree: string }[] }>
    pinnedSessions: string[]
    mutedSessions?: string[]
  }
}
type Message = {
  type: string
  text?: string
  files?: unknown[]
  content?: { type: string; name?: string; state?: { status: string; input?: Record<string, unknown> } }[]
}
const previous: { sessions: Fixture[] } = await Bun.file(manifest)
  .json()
  .catch(() => ({ sessions: [] }))
const sessions: Fixture[] = []
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const now = Date.now()
const day = 86_400_000
const repos = path.join(home, "repos")

if (args.values.stop || args.values.reset) {
  const navigation = await rpc<Navigation>("custom.navigation", "list", { limit: 500 })
  const ids = new Set(previous.sessions.map((item) => item.id))
  navigation.data
    .filter((row) => row.session.parentID && ids.has(row.session.parentID))
    .forEach((row) => ids.add(row.session.id))
  await Promise.all([...ids].map((id) => api(`/api/session/${id}/interrupt`, {})))
  if (args.values.stop) {
    console.log(`Interrupted ${ids.size} seeded sessions; history and preferences preserved.`)
    process.exit(0)
  }
  for (const id of [...ids].reverse()) {
    await rpc("custom.preferences", "mutate", { type: "sidebar.pin", session: id, pinned: false })
    await rpc("custom.preferences", "mutate", { type: "sidebar.mute", session: id, muted: false })
    await api(`/api/session/${id}`, undefined, "DELETE", true)
  }
}
if (previous.sessions.length && !args.values.reset)
  throw new Error("Seed already exists. Use --reset to recreate it or --stop to interrupt live work.")
await save()

const avocado = await repository("abacato-v2", [
  "neon-mountain",
  "feat/redesign-identidade",
  "cosmic-moon",
  "calm-mountain",
  "gentle-wolf",
])
const opencode = await repository("opencode2", ["custom", "quiet-nebula"])
const site = await repository("abacato-site", [])
// project.open prepends: reverse insertion yields the mockup's repository order.
for (const directory of [site.main, opencode.main, avocado.main])
  await rpc("custom.preferences", "mutate", { type: "project.open", server: "local", directory })
for (const [toIndex, directory] of [avocado.main, opencode.main, site.main].entries())
  await rpc("custom.preferences", "mutate", { type: "project.move", server: "local", directory, toIndex })

// Import resets time.updated, so oldest-first also preserves the intended relative list order.
await historical("Documentação atualizada", site.main, now - 15 * day, "Guia de publicação atualizado.")
await historical("Landing nova", site.main, now - 10 * day, "Prévia da nova landing", { image: true })
await historical(
  "Revisar próximos passos",
  opencode.branches["quiet-nebula"],
  now - 5 * day,
  "Podemos revisar o plano amanhã?",
  { userLast: true },
)
const muted = await historical(
  "UI opencode com imagem",
  opencode.branches.custom,
  now - 3 * day,
  "Temas OpenChamber revisados nos dois modos.",
)
await rpc("custom.preferences", "mutate", { type: "sidebar.mute", session: muted.id, muted: true })
muted.state = "muted + read"
await historical(
  "Ajustes na navegação",
  opencode.branches["quiet-nebula"],
  now - 2 * day,
  "Navegação revisada e pronta para testar.",
)
const migration = await historical(
  "Pendências na migração do v1 para o v2",
  avocado.branches["gentle-wolf"],
  now - day,
  "Migração concluída: 12 de 14 tabelas",
  { unread: true },
)
for (const index of Array.from({ length: 12 }, (_, index) => index)) {
  const item = await historical(
    `Arquivada ${String(index + 1).padStart(2, "0")}`,
    index % 2 ? opencode.branches["quiet-nebula"] : site.main,
    now - (20 + index) * day,
    "Trabalho concluído e arquivado.",
  )
  await rpc("custom.archive", "archive", { sessionID: item.id })
  item.state = "archived"
}

const question = await live("Google Play", avocado.branches["cosmic-moon"], "question")
const permission = await live("App Store Connect", avocado.branches["calm-mountain"], "permission", true)
const alternatives = await live(
  "Alternativas Linear open source",
  avocado.branches["neon-mountain"],
  "running + pinned + 3 subagents",
)
const redesign = await live("Redesign", avocado.branches["feat/redesign-identidade"], "running")
await rpc("custom.preferences", "mutate", { type: "sidebar.pin", session: alternatives.id, pinned: true })
await save()
await Promise.all([
  prompt(
    question.id,
    'Use agora somente a ferramenta question com uma pergunta: "Qual opção você prefere?", cabeçalho "Google Play", opções "Teste interno" (publicar para testadores), "Teste fechado" (grupo restrito), "Produção" (publicação pública). Não faça outras ações nem responda sem chamar question. Aguarde a resposta.',
  ),
  prompt(
    permission.id,
    'Use agora somente a ferramenta shell para executar exatamente "git push", em primeiro plano. É um repositório fictício sem remoto; não configure remoto nem contorne a permissão. Não use outras ferramentas. Aguarde a aprovação.',
  ),
  prompt(
    redesign.id,
    'Use agora somente a ferramenta shell, em primeiro plano, command="bun run work-on-header.ts", timeout=0. O script de demonstração trabalha em header.tsx e espera sem consumir recursos. Não rode em background e não faça outras ações.',
  ),
  prompt(
    alternatives.id,
    'Demonstração de UI em repositório fictício. Primeiro chame subagent EXATAMENTE três vezes, uma para cada tarefa independente: "Comparar alternativas Linear", "Revisar licença dos projetos", "Avaliar integrações disponíveis". Use agent="general", background=true e model="llm-proxy/gpt-6-luna#low" em todas. Prompt de cada filho: "Use imediatamente somente shell em primeiro plano com command=\"sleep 86400\", timeout=0, para manter uma demonstração de execução sem gastar modelo. Não use outras ferramentas nem rode em background." Depois das três delegações, use shell em primeiro plano com command="bun test --timeout 86401000", timeout=0. Não faça pesquisa real, não leia arquivos, não repita chamadas e não finalize antes dos comandos.',
  ),
])
await until(async () => {
  const navigation = await rpc<Navigation>("custom.navigation", "list", { limit: 500 })
  const children = navigation.data.filter((row) => row.session.parentID === alternatives.id)
  children.forEach((row) => {
    if (!sessions.some((item) => item.id === row.session.id))
      sessions.push({
        id: row.session.id,
        title: row.session.title,
        directory: row.session.location.directory,
        state: "running subagent",
      })
  })
  await save()
  const active = await api<{ data: Record<string, { type: string }> }>("/api/session/active")
  const q = navigation.data.find((row) => row.session.id === question.id)
  const p = navigation.data.find((row) => row.session.id === permission.id)
  const tools = await Promise.all(
    [alternatives, redesign, ...sessions.filter((item) => item.state === "running subagent")].map(async (item) => {
      const transcript = await rpc<{ data: Message[] }>("custom.transcript", "list", {
        sessionID: item.id,
        limit: 3,
        order: "desc",
      })
      return transcript.data.some((message) =>
        message.content?.some(
          (part) => part.type === "tool" && part.name === "shell" && part.state?.status === "running",
        ),
      )
    }),
  )
  return Boolean(
    q?.questionCount &&
      p?.permissionCount &&
      children.length === 3 &&
      children.every((row) => active.data[row.session.id]) &&
      tools.every(Boolean),
  )
}, "Live states did not all settle within five minutes. Inspect the seed sessions; --stop is safe.")

const navigation = await rpc<Navigation>("custom.navigation", "list", { limit: 500 })
const preferences = await rpc<Preferences>("custom.preferences", "get", {})
const archived = await Promise.all(
  sessions.filter((item) => item.state === "archived").map((item) => api<{ data: Session }>(`/api/session/${item.id}`)),
)
if (archived.filter((item) => item.data.time.archived).length !== 12) throw new Error("Archive verification failed")
if (!navigation.data.find((row) => row.session.id === migration.id)?.unreadAt)
  throw new Error("Unread verification failed")
if (!preferences.data.pinnedSessions.includes(alternatives.id) || !preferences.data.mutedSessions?.includes(muted.id))
  throw new Error("Preference verification failed")
for (const item of sessions.filter((item) => ["read", "muted + read"].includes(item.state)))
  if (navigation.data.find((row) => row.session.id === item.id)?.unreadAt)
    throw new Error(`Unexpected unread: ${item.title}`)
const forms = await api<{ data: unknown[] }>(`/api/session/${question.id}/form`)
const permissions = await api<{ data: unknown[] }>(`/api/session/${permission.id}/permission`)
if (!forms.data.length || !permissions.data.length) throw new Error("Pending requests verification failed")
await save()
console.log(
  JSON.stringify(
    {
      url: url.origin,
      home,
      pendingQuestions: forms.data.length,
      pendingPermissions: permissions.data.length,
      archives: 12,
      repositories: preferences.data.projects.local.projects.map((item) => item.worktree),
      sessions,
    },
    null,
    2,
  ),
)
console.log(
  "Historical message/idle dates are preserved; the import API intentionally sets time.updated to import time.",
)

async function api<T = unknown>(
  pathname: string,
  body?: unknown,
  method = body === undefined ? "GET" : "POST",
  allowMissing = false,
): Promise<T> {
  const response = await fetch(new URL(pathname, url), {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30_000),
  })
  if (allowMissing && response.status === 404) return undefined as T
  if (!response.ok)
    throw new Error(`${method} ${pathname}: ${response.status} ${(await response.text()).slice(0, 700)}`)
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

async function rpc<T = unknown>(id: string, method: string, input: unknown) {
  return (await api<{ output: T }>(`/api/rpc/${id}/${method}`, { input })).output
}

async function save() {
  await Bun.write(manifest, JSON.stringify({ createdAt: now, sessions }, null, 2), { mode: 0o600 })
  await chmod(manifest, 0o600)
}

async function git(directory: string, ...command: string[]) {
  const child = Bun.spawn(["git", "-c", "core.hooksPath=/dev/null", ...command], {
    cwd: directory,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()])
  if (await child.exited) throw new Error(`Fixture git ${command[0]}: ${stderr}`)
  return stdout.trim()
}

async function repository(name: string, branches: string[]) {
  const main = path.join(repos, name)
  await mkdir(main, { recursive: true, mode: 0o700 })
  if (!(await Bun.file(path.join(main, ".git/config")).exists())) {
    await git(main, "init", "-b", "main")
    await Bun.write(
      path.join(main, ".git/config"),
      `${await Bun.file(path.join(main, ".git/config")).text()}\n[user]\n\tname = OpenCode Fixture\n\temail = fixture@example.invalid\n[commit]\n\tgpgsign = false\n[core]\n\tfsmonitor = false\n`,
    )
    await Bun.write(path.join(main, "package.json"), JSON.stringify({ name, private: true }))
    await Bun.write(
      path.join(main, "fixture.test.ts"),
      'import { test } from "bun:test"\ntest("interface fixture: running bun test", async () => { await Bun.sleep(86400000) }, 86401000)\n',
    )
    await Bun.write(
      path.join(main, "work-on-header.ts"),
      'console.log("Trabalhando em header.tsx")\nawait Bun.sleep(86400000)\nexport {}\n',
    )
    await Bun.write(path.join(main, "header.tsx"), 'export const Header = () => "Redesign"\n')
    await Bun.write(
      path.join(main, "AGENTS.md"),
      "Repositório fictício de demonstração. Não faça trabalho real. Execute apenas a ação explícita do usuário. Para shell longo use timeout=0, background=false. O usuário autoriza explicitamente as três delegações da demonstração. Nunca use um repositório ou serviço real.\n",
    )
    await git(main, "add", ".")
    await git(main, "commit", "-m", `Fixture ${name}`)
    await git(main, "commit", "--allow-empty", "-m", "Second fixture commit")
    await git(main, "commit", "--allow-empty", "-m", "Third fixture commit")
  }
  const directories: Record<string, string> = {}
  for (const branch of branches) {
    const directory = path.join(repos, `${name}-worktrees`, branch)
    if (!(await Bun.file(path.join(directory, ".git")).exists())) {
      await mkdir(path.dirname(directory), { recursive: true, mode: 0o700 })
      const exists = (await git(main, "branch", "--list", branch)).length > 0
      await git(main, "worktree", "add", ...(exists ? [] : ["-b", branch]), directory, ...(exists ? [branch] : []))
    }
    directories[branch] = directory
  }
  return { main, branches: directories }
}

async function historical(
  title: string,
  directory: string,
  date: number,
  text: string,
  options: { unread?: boolean; userLast?: boolean; image?: boolean } = {},
) {
  const id = `ses_ios_${crypto.randomUUID().replaceAll("-", "")}`
  const assistant = {
    id: `msg_${crypto.randomUUID()}`,
    type: "assistant",
    agent: "build",
    model,
    time: { created: date - 1000, completed: date },
    finish: "stop",
    content: [{ type: "text", text }],
  }
  const user = {
    id: `msg_${crypto.randomUUID()}`,
    type: "user",
    time: { created: date },
    text: options.image ? "" : text,
    ...(options.image
      ? {
          files: [
            {
              data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6NQAAAABJRU5ErkJggg==",
              mime: "image/png",
              source: { type: "inline" },
              name: "landing.png",
            },
          ],
        }
      : {}),
  }
  const result = await api<{ data: Session }>("/api/experimental/session/import", {
    info: {
      id,
      projectID: "global",
      title,
      location: { directory },
      model,
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      outcome: "succeeded",
      time: { created: date - 60_000, updated: date, idle: date, viewed: options.unread ? date - day : date },
    },
    messages:
      options.userLast || options.image ? [assistant, user] : [{ ...user, time: { created: date - 2000 } }, assistant],
    location: { directory },
  })
  const item = { id: result.data.id, title, directory, state: options.unread ? "unread" : "read" }
  sessions.push(item)
  await save()
  return item
}

async function live(title: string, directory: string, state: string, askPush = false) {
  const result = await api<{ data: Session }>("/api/session", {
    title,
    location: { directory },
    model,
    agent: "build",
    permissions: [
      { action: "*", resource: "*", effect: "allow" },
      ...(askPush ? [{ action: "shell", resource: "git push*", effect: "ask" }] : []),
    ],
  })
  const item = { id: result.data.id, title, directory, state }
  sessions.push(item)
  await save()
  return item
}

async function prompt(id: string, text: string) {
  await api(`/api/session/${id}/prompt`, { text })
}

async function until(check: () => Promise<boolean>, message: string) {
  const deadline = Date.now() + 300_000
  while (Date.now() < deadline) {
    if (await check()) return
    await Bun.sleep(1000)
  }
  throw new Error(message)
}
