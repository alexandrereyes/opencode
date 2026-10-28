#!/usr/bin/env bun
/**
 * End to end against an owned sandbox started with `OPENCODE_APNS_ORIGIN` pointing at
 * `packages/ios-custom/script/fake-apns.ts`: real Luna 6 / low runs, a fake device token, and the alerts the plugin
 * hands to APNs read back from the fake's log. Nothing reaches Apple or a device.
 *
 *   bun script/e2e-session-notifications.ts --url http://127.0.0.1:4186 --home <sandbox home> --apns-log <jsonl>
 *
 * Scenarios: a bell session that answers alerts once ("Terminou"); one whose background shell outlives its answer
 * alerts only after the shell ends; one whose run fails says "Terminou com erro"; one interrupted by the user alerts
 * nothing; a session without the bell alerts nothing. Its own sessions, repository, preference keys and device are removed at the end.
 */
import { mkdir, rm } from "node:fs/promises"
import path from "node:path"
import { parseArgs } from "node:util"

const args = parseArgs({
  args: Bun.argv.slice(2),
  options: { url: { type: "string" }, home: { type: "string" }, "apns-log": { type: "string" } },
})
const url = args.values.url ?? ""
const home = args.values.home ?? ""
const apnsLog = args.values["apns-log"] ?? ""
if (!url || !home || !apnsLog) throw new Error("Usage: --url URL --home SANDBOX_HOME --apns-log FILE")
if (/:(4096|4178)\b/.test(url)) throw new Error("Never against production")
if (!(await Bun.file(path.join(home, "sandbox.json")).exists())) throw new Error("--home is not an owned sandbox")

const password = (await Bun.file(path.join(home, "password")).text()).trim()
const auth = `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const token = crypto.randomUUID().replaceAll("-", "")
const deviceID = `e2e-${token.slice(0, 8)}`
const key = (sessionID: string) => JSON.stringify(["http://localhost:4096", sessionID])

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
const rpc = <T>(route: string, input: unknown) => call<{ output: T }>(`/api/rpc/${route}`, { input }).then((r) => r.output)

type Alert = { at: number; path: string; type: string; topic: string; body: { aps: { alert: { title: string; body: string }; "thread-id": string }; opencode: { sessionID: string; outcome: string } } }
const alerts = async () =>
  (await Bun.file(apnsLog).text())
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Alert)
    .filter((entry) => entry.type === "alert" && entry.path === `/3/device/${token}`)

async function idle(sessionID: string, timeout = 240_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const running = (await call<{ data: Record<string, unknown> }>("/api/session/active")).data
    if (!running[sessionID]) return
    await Bun.sleep(500)
  }
  throw new Error(`Timeout waiting for ${sessionID}`)
}

const repo = path.join(home, "repos", `notify-e2e-${token.slice(0, 8)}`)
const owned: string[] = []
const results: Record<string, unknown> = {}
try {
  await mkdir(repo, { recursive: true })
  await Bun.$`git init -q ${repo} && git -C ${repo} -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm init`.quiet()
  const create = async (title: string) => {
    const session = (
      await call<{ data: { id: string } }>("/api/session", { title, location: { directory: repo }, agent: "build", model })
    ).data
    owned.push(session.id)
    return session.id
  }
  expect((await rpc<{ push: string }>("custom.notifications/register", { deviceID, serverKey: "e2e", environment: "sandbox", token })).push, "configured")
  const bell = await create("Aviso — responde")
  const shell = await create("Aviso — tarefa em segundo plano")
  const stop = await create("Aviso — interrompida")
  const broken = await create("Aviso — falha")
  const plain = await create("Sem aviso")
  for (const id of [bell, shell, stop, broken]) await rpc("custom.preferences/mutate", { type: "sidebar.notify", session: key(id), notify: true })

  // 1. Answers and finishes: one alert after the grace period.
  await call(`/api/session/${bell}/prompt`, { text: "Responda apenas: ok" })
  await call(`/api/session/${plain}/prompt`, { text: "Responda apenas: ok" })
  await idle(bell)
  await idle(plain)
  const bellIdleAt = Date.now()
  await Bun.sleep(8_000)
  const first = await alerts()
  expect(first.length, 1)
  expect(first[0]?.body.opencode.sessionID, bell)
  expect(first[0]?.body.aps["thread-id"], bell)
  expect(first[0]?.body.aps.alert.title, "Aviso — responde")
  expect(first[0]?.body.aps.alert.body, `Terminou · ${path.basename(repo)}`)
  expect(first[0]?.topic, "br.com.alexandrem.opencode")
  results.bell = { alertAfterIdleMs: (first[0]?.at ?? 0) - bellIdleAt, body: first[0]?.body }
  results.plain = "no alert"

  // 2. A background shell outlives the answer: the alert waits for it (and for the wake it causes).
  await call(`/api/session/${shell}/prompt`, {
    text: 'Use a ferramenta shell com background: true para rodar exatamente o comando "sleep 20 && echo pronto". Não espere por ele: assim que ele for para o segundo plano, responda apenas: iniciado.',
  })
  const started = Date.now()
  await idle(shell)
  const answeredAt = Date.now()
  await Bun.sleep(3_000)
  const early = (await alerts()).filter((entry) => entry.body.opencode.sessionID === shell)
  const deadline = Date.now() + 120_000
  while ((await alerts()).filter((entry) => entry.body.opencode.sessionID === shell).length === 0 && Date.now() < deadline)
    await Bun.sleep(1_000)
  await idle(shell)
  const late = (await alerts()).filter((entry) => entry.body.opencode.sessionID === shell)
  expect(early.length, 0)
  expect(late.length, 1)
  if ((late[0]?.at ?? 0) - started < 20_000) throw new Error("The background alert came before the shell could end")
  results.background = { answeredAfterMs: answeredAt - started, alertAfterMs: (late[0]?.at ?? 0) - started }

  // 3. A failed run: "Terminou com erro".
  await call(`/api/session/${broken}/model`, { model: { providerID: "llm-proxy", id: "modelo-inexistente-e2e" } })
  await call(`/api/session/${broken}/prompt`, { text: "Responda apenas: ok" })
  await idle(broken)
  await Bun.sleep(8_000)
  const failed = (await alerts()).filter((entry) => entry.body.opencode.sessionID === broken)
  expect(failed.length, 1)
  expect(failed[0]?.body.opencode.outcome, "failed")
  expect(failed[0]?.body.aps.alert.body, `Terminou com erro · ${path.basename(repo)}`)
  results.failed = failed[0]?.body.aps.alert

  // 4. Interrupted by the user: no alert.
  await call(`/api/session/${stop}/prompt`, { text: 'Use a ferramenta shell para rodar "sleep 60" e espere ele terminar.' })
  await Bun.sleep(6_000)
  await call(`/api/session/${stop}/interrupt?resume=false`, {})
  await idle(stop)
  await Bun.sleep(8_000)
  expect((await alerts()).filter((entry) => entry.body.opencode.sessionID === stop).length, 0)
  results.interrupted = "no alert"
  expect((await alerts()).filter((entry) => entry.body.opencode.sessionID === plain).length, 0)
  console.log(JSON.stringify({ ok: true, results }, null, 2))
} finally {
  await rpc("custom.notifications/unregister", { deviceID }).catch(() => undefined)
  for (const id of owned) {
    await rpc("custom.preferences/mutate", { type: "sidebar.notify", session: key(id), notify: false }).catch(() => undefined)
    await call(`/api/session/${id}`, undefined, "DELETE").catch(() => undefined)
  }
  await rm(repo, { recursive: true, force: true })
}

function expect<A>(actual: A, expected: A) {
  if (actual !== expected) throw new Error(`Expected ${String(expected)}, got ${String(actual)}`)
}
