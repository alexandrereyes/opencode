#!/usr/bin/env bun
/**
 * End to end for the browse credential guard (`docs/browse-guard.md`) against an owned sandbox. A real Luna 6 / low
 * run calls, through Code Mode, a fake browse MCP (`test/fixture/browse-mcp.ts`, configured as `browse` in a test
 * repository) that logs every call reaching it: no relay, no browser, no credentials.
 *
 *   bun script/e2e-browse-guard.ts --url http://127.0.0.1:4197 --home <sandbox home>
 *
 * Proves that capture and a redacted HAR reach browse, that `network` with `secrets` never does, and that the agent
 * reads the guard's reason. Its session and repository are removed at the end.
 */
import { mkdir, rm } from "node:fs/promises"
import path from "node:path"
import { parseArgs } from "node:util"
import { refusal } from "../src/browse-guard/index.js"

const args = parseArgs({ args: Bun.argv.slice(2), options: { url: { type: "string" }, home: { type: "string" } } })
const url = args.values.url ?? ""
const home = args.values.home ?? ""
if (!url || !home) throw new Error("Usage: --url URL --home SANDBOX_HOME")
if (/:(4096|4178)\b/.test(url)) throw new Error("Never against production")
if (!(await Bun.file(path.join(home, "sandbox.json")).exists())) throw new Error("--home is not an owned sandbox")

const password = (await Bun.file(path.join(home, "password")).text()).trim()
const auth = `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
const luna = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }

async function call<T>(route: string, body?: unknown, method = body === undefined ? "GET" : "POST"): Promise<T> {
  const response = await fetch(url + route, {
    method,
    headers: { authorization: auth, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`${method} ${route}: HTTP ${response.status} ${await response.text()}`)
  const text = await response.text()
  return (text ? JSON.parse(text) : undefined) as T
}

type Part = { type: string; name?: string; state?: { input?: unknown; content?: unknown; error?: unknown } }
type Export = { data: { messages: { content?: Part[] }[] } }

const repo = path.join(home, "repos", `browse-guard-e2e-${crypto.randomUUID().slice(0, 8)}`)
const log = path.join(repo, ".calls.jsonl")
let sessionID: string | undefined
try {
  await mkdir(repo, { recursive: true })
  await Bun.$`git init -q ${repo} && git -C ${repo} -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm init`.quiet()
  await Bun.write(
    path.join(repo, "opencode.json"),
    JSON.stringify({
      mcp: {
        servers: {
          browse: {
            type: "local",
            disabled: false,
            command: [process.execPath, path.resolve(import.meta.dir, "../test/fixture/browse-mcp.ts")],
            environment: { BROWSE_FAKE_CALLS_LOG: log },
          },
        },
      },
    }),
  )
  await Bun.write(path.join(repo, ".gitignore"), ".calls.jsonl\n")
  sessionID = (
    await call<{ data: { id: string } }>("/api/session", {
      title: "browse guard e2e",
      location: { directory: repo },
      agent: "build",
      model: luna,
    })
  ).data.id
  await call(`/api/session/${sessionID}/prompt`, {
    text: [
      "Teste com um browse falso (sem navegador e sem credenciais). Pelo execute do Code Mode, faça estas três chamadas,",
      "cada uma num execute separado, nesta ordem, sem mudar nada e continuando mesmo se uma falhar:",
      '1. `await tools.browse.network({ action: "start" })`',
      '2. `await tools.browse.network({ action: "stop", outputPath: "capture.har" })`',
      '3. `await tools.browse.network({ action: "stop", secrets: "perfil-e2e" })`',
      "Não tente contornar erros. Depois responda apenas: pronto.",
    ].join("\n"),
  })
  await call(`/api/experimental/session/${sessionID}/wait`, {})

  const reached = (await Bun.file(log).text())
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { name: string; arguments?: Record<string, unknown> })
  const exported = await call<Export>(`/api/experimental/session/${sessionID}/export`)
  const outputs = exported.data.messages
    .flatMap((message) => message.content ?? [])
    .filter((part) => part.type === "tool")
    .map((part) => JSON.stringify([part.state?.content, part.state?.error]))
  const result = {
    start: reached.some((item) => item.name === "network" && item.arguments?.action === "start"),
    redactedHar: reached.some((item) => item.name === "network" && item.arguments?.outputPath === "capture.har"),
    secretsReachedBrowse: reached.some((item) => item.arguments?.secrets !== undefined),
    agentReadTheReason: outputs.some((text) => text.includes(JSON.stringify(refusal).slice(1, 60))),
  }
  console.log(JSON.stringify({ sessionID, reached, result }, null, 2))
  if (!result.start || !result.redactedHar || result.secretsReachedBrowse || !result.agentReadTheReason)
    throw new Error("The browse credential guard did not behave as expected")
  console.log("ok")
} finally {
  if (sessionID) {
    await call(`/api/session/${sessionID}/interrupt?resume=false`, {}).catch(() => undefined)
    await call(`/api/session/${sessionID}`, undefined, "DELETE").catch(() => undefined)
  }
  await rm(repo, { recursive: true, force: true })
}
