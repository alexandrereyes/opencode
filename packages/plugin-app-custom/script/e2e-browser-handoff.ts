#!/usr/bin/env bun
/**
 * End to end for browse handoffs (`docs/browser-handoff.md`) against an owned sandbox started with
 * `OPENCODE_APNS_ORIGIN` pointing at MyAgents `script/fake-apns.ts`. Real Luna 6 / low runs call a fake browse MCP
 * (`test/fixture/browse-mcp.ts`, configured as `browse` in the test repository) whose `execute` blocks while its code
 * hands off: no relay, no Chrome, nothing reaches Apple or a device.
 *
 *   bun script/e2e-browser-handoff.ts --url http://127.0.0.1:4197 --home <sandbox home> --apns-log <jsonl>
 *
 * Scenarios: a handoff that waits shows in custom.browser-handoffs, Sessões (custom.navigation), the session family,
 * the Live Activity and one alert, and clears when the call continues; one cleared by interrupting the session; and
 * browse code without a handoff that never shows. `--keep-waiting` leaves one waiting session (for app captures) and
 * prints how to release it. Its sessions, repository and device are removed at the end otherwise.
 */
import { mkdir, rm } from "node:fs/promises"
import path from "node:path"
import { parseArgs } from "node:util"

const args = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    url: { type: "string" },
    home: { type: "string" },
    "apns-log": { type: "string" },
    "keep-waiting": { type: "boolean" },
  },
})
const url = args.values.url ?? ""
const home = args.values.home ?? ""
const apnsLog = args.values["apns-log"] ?? ""
if (!url || !home || !apnsLog) throw new Error("Usage: --url URL --home SANDBOX_HOME --apns-log FILE")
if (/:(4096|4178)\b/.test(url)) throw new Error("Never against production")
if (!(await Bun.file(path.join(home, "sandbox.json")).exists())) throw new Error("--home is not an owned sandbox")

const password = (await Bun.file(path.join(home, "password")).text()).trim()
const auth = `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
const luna = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const token = crypto.randomUUID().replaceAll("-", "")
const deviceID = `e2e-${token.slice(0, 8)}`

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
const rpc = <T>(route: string, input: unknown) =>
  call<{ output: T }>(`/api/rpc/${route}`, { input }).then((r) => r.output)

async function until<T>(read: () => Promise<T | undefined>, timeout: number, what: string) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await read()
    if (value !== undefined) return value
    await Bun.sleep(250)
  }
  throw new Error(`Timeout waiting for ${what}`)
}
const idle = (sessionID: string, timeout = 240_000) =>
  until(
    async () =>
      !(await call<{ data: Record<string, unknown> }>("/api/session/active")).data[sessionID] ? true : undefined,
    timeout,
    `${sessionID} to stop`,
  )

type Handoff = { id: string; sessionID: string; callID: string; message: string; since: number }
const waiting = (sessionID: string) =>
  rpc<{ data: Handoff[] }>("custom.browser-handoffs/list", { sessionID }).then((r) => r.data)
const row = (sessionID: string) =>
  rpc<{ data: { session: { id: string }; browserAt?: number; browserCount?: number; browserText?: string }[] }>(
    "custom.navigation/list",
    { sessionID },
  ).then((page) => page.data.find((item) => item.session.id === sessionID))
type Entry = {
  at: number
  path: string
  type: string
  body: { aps: { alert?: { title: string; body: string } }; opencode?: Record<string, unknown> }
}
const alerts = async (sessionID: string) =>
  (await Bun.file(apnsLog).text())
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Entry)
    .filter(
      (entry) =>
        entry.type === "alert" && entry.path === `/3/device/${token}` && entry.body.opencode?.sessionID === sessionID,
    )

const repo = path.join(home, "repos", `handoff-e2e-${token.slice(0, 8)}`)
const releases = path.join(repo, ".releases")
const owned: string[] = []
const results: Record<string, unknown> = {}
let keep = false
try {
  await mkdir(releases, { recursive: true })
  await Bun.$`git init -q ${repo} && git -C ${repo} -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm init`.quiet()
  // The repository's `browse` replaces the real one for its sessions: the fake never reaches a relay or a browser.
  await Bun.write(
    path.join(repo, "opencode.json"),
    JSON.stringify({
      mcp: {
        servers: {
          browse: {
            type: "local",
            // The sandbox may disable its copy of the real browse; this one runs whatever the global says.
            disabled: false,
            command: [process.execPath, path.resolve(import.meta.dir, "../test/fixture/browse-mcp.ts")],
            environment: { BROWSE_FAKE_RELEASE_DIR: releases, BROWSE_FAKE_TIMEOUT_MS: "240000" },
          },
        },
      },
    }),
  )
  await Bun.write(path.join(repo, ".gitignore"), ".releases/\n")
  const create = async (title: string) => {
    const session = (
      await call<{ data: { id: string } }>("/api/session", {
        title,
        location: { directory: repo },
        agent: "build",
        model: luna,
      })
    ).data
    owned.push(session.id)
    return session.id
  }
  const browse = (id: string, code: string) =>
    call(`/api/session/${id}/prompt`, {
      text: [
        "Chame exatamente uma vez, pelo execute do Code Mode, a ferramenta tools.browse.execute com este code,",
        "sem mudar nada, e espere o resultado; depois responda apenas: pronto.",
        "```js",
        code,
        "```",
      ].join("\n"),
    })
  expectEqual(
    (
      await rpc<{ push: string }>("custom.notifications/register", {
        deviceID,
        serverKey: "e2e",
        environment: "sandbox",
        token,
      })
    ).push,
    "configured",
  )

  // 1. A handoff that waits: every surface shows it, one alert; it clears when the user continues.
  const login = await create("Navegador — login de teste")
  await browse(login, 'await handoff("Faça login no GitHub de teste e clique em Continue") // release:login')
  const asked = Date.now()
  const shown = await until(async () => (await waiting(login))[0], 180_000, "the handoff to wait")
  expectEqual(shown.message, "Faça login no GitHub de teste e clique em Continue")
  const graceMs = Date.now() - shown.since
  if (graceMs < 2_500) throw new Error(`Shown ${graceMs} ms after the call started, before the grace period`)
  const listed = await row(login)
  expectEqual(listed?.browserText, shown.message)
  expectEqual(listed?.browserCount, 1)
  const family = await rpc<{ browser?: Handoff[] }>("custom.session-family/snapshot", { sessionID: login })
  expectEqual(family.browser?.[0]?.callID, shown.callID)
  const snapshot = await rpc<{
    state: {
      counts: Record<string, number>
      attention: { sessionID: string; kind: string; text?: string }[]
      sessions: { sessionID: string; status: string }[]
    } | null
  }>("custom.live-activity/snapshot", {})
  const attention = snapshot.state?.attention.find((item) => item.sessionID === login)
  expectEqual(attention?.kind, "browser")
  expectEqual(snapshot.state?.sessions.find((item) => item.sessionID === login)?.status, "browser")
  const alert = await until(async () => (await alerts(login))[0], 15_000, "the handoff alert")
  expectEqual(alert.body.aps.alert?.body, `Navegador: ${shown.message}`)
  expectEqual(alert.body.opencode?.attention, "browser")
  expectEqual("requestID" in (alert.body.opencode ?? {}), false)
  results.waiting = {
    shownAfterMs: Date.now() - asked,
    graceMs,
    handoff: shown,
    navigation: listed,
    liveActivity: { attention, counts: snapshot.state?.counts },
    alert: alert.body.aps.alert,
    collapse: alert.path,
  }
  if (args.values["keep-waiting"]) {
    keep = true
    console.log(
      JSON.stringify(
        { ok: true, keep: { sessionID: login, release: path.join(releases, "login"), repo, deviceID }, results },
        null,
        2,
      ),
    )
    process.exit(0)
  }
  await Bun.write(path.join(releases, "login"), "")
  await until(async () => ((await waiting(login)).length === 0 ? true : undefined), 15_000, "the handoff to clear")
  expectEqual((await row(login))?.browserText, undefined)
  await idle(login)
  expectEqual((await alerts(login)).length, 1)
  results.continued = { cleared: true, alerts: 1 }

  // 2. Interrupting the session clears a waiting handoff (the hook after the call never runs).
  const stuck = await create("Navegador — interrompido")
  await browse(stuck, 'await handoff("Resolva o captcha de teste") // release:never')
  await until(async () => (await waiting(stuck))[0], 180_000, "the second handoff to wait")
  await call(`/api/session/${stuck}/interrupt?resume=false`, {})
  await until(async () => ((await waiting(stuck)).length === 0 ? true : undefined), 15_000, "the interrupted handoff")
  await idle(stuck)
  results.interrupted = { cleared: true }

  // 3. browse code without a handoff never shows.
  const plain = await create("Navegador — sem handoff")
  await browse(plain, "return await page.title() // release:none")
  const started = Date.now()
  let seen = false
  while (Date.now() - started < 60_000) {
    if ((await waiting(plain)).length > 0) seen = true
    if (!(await call<{ data: Record<string, unknown> }>("/api/session/active")).data[plain]) break
    await Bun.sleep(250)
  }
  expectEqual(seen, false)
  expectEqual((await alerts(plain)).length, 0)
  results.plain = { shown: false }
  console.log(JSON.stringify({ ok: true, results }, null, 2))
} finally {
  if (!keep) {
    await rpc("custom.notifications/unregister", { deviceID }).catch(() => undefined)
    for (const id of owned) {
      await call(`/api/session/${id}/interrupt?resume=false`, {}).catch(() => undefined)
      await call(`/api/session/${id}`, undefined, "DELETE").catch(() => undefined)
    }
    await rm(repo, { recursive: true, force: true })
  }
}

function expectEqual<A>(actual: A, expected: A) {
  if (actual !== expected) throw new Error(`Expected ${String(expected)}, got ${String(actual)}`)
}
