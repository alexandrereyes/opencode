#!/usr/bin/env bun
/**
 * End to end against an owned sandbox started with `OPENCODE_APNS_ORIGIN` pointing at
 * `packages/ios-custom/script/fake-apns.ts`: real Luna 6 / low runs, a fake device token, and the alerts the plugin
 * hands to APNs read back from the fake's log. Nothing reaches Apple or a device.
 *
 *   bun script/e2e-session-notifications.ts --url http://127.0.0.1:4186 --home <sandbox home> --apns-log <jsonl>
 *
 * Scenarios (docs/session-notifications.md): success with and without the bell; a real question; a permission left
 * pending and one answered at once; a failure without retries (unknown model) and with them (a local provider that
 * answers 503 until the retries run out), plus a run that recovers after two 503s; and, for a bell session that fails,
 * one alert only, with the Live Activity update for the same device carrying no `alert`. Its own sessions, repository,
 * preference keys and devices are removed at the end.
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
const luna = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const token = crypto.randomUUID().replaceAll("-", "")
const activityToken = crypto.randomUUID().replaceAll("-", "")
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

type Entry = {
  at: number
  path: string
  type: string
  body: {
    aps: { alert?: { title: string; body: string }; "thread-id"?: string; "interruption-level"?: string }
    opencode?: { kind: string; sessionID: string; attention?: string; requestID?: string; outcome?: string }
  }
}
const log = async () =>
  (await Bun.file(apnsLog).text())
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Entry)
const alerts = async (sessionID: string) =>
  (await log()).filter(
    (entry) =>
      entry.type === "alert" && entry.path === `/3/device/${token}` && entry.body.opencode?.sessionID === sessionID,
  )

async function until<T>(read: () => Promise<T | undefined>, timeout: number, what: string) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await read()
    if (value !== undefined) return value
    await Bun.sleep(500)
  }
  throw new Error(`Timeout waiting for ${what}`)
}
const idle = (sessionID: string, timeout = 240_000) =>
  until(
    async () => (!(await call<{ data: Record<string, unknown> }>("/api/session/active")).data[sessionID] ? true : undefined),
    timeout,
    `${sessionID} to stop`,
  )

// A local OpenAI-compatible provider: `always-503` never recovers; `twice-503` answers after two 503s.
const attempts = new Map<string, number>()
const provider = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    const body = (await request.json()) as { model: string }
    const count = (attempts.get(body.model) ?? 0) + 1
    attempts.set(body.model, count)
    if (body.model === "always-503" || count <= 2)
      return Response.json({ error: { message: "Serviço indisponível (teste)" } }, { status: 503 })
    const chunk = (delta: object, finish: string | null) =>
      `data: ${JSON.stringify({ id: "e2e", object: "chat.completion.chunk", created: 0, model: body.model, choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`
    return new Response(
      chunk({ role: "assistant", content: "ok" }, null) + chunk({}, "stop") + "data: [DONE]\n\n",
      { headers: { "content-type": "text/event-stream" } },
    )
  },
})

const repo = path.join(home, "repos", `notify-e2e-${token.slice(0, 8)}`)
const owned: string[] = []
const results: Record<string, unknown> = {}
try {
  await mkdir(repo, { recursive: true })
  await Bun.$`git init -q ${repo} && git -C ${repo} -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm init`.quiet()
  const model = (id: string) => ({
    name: id,
    capabilities: { tools: true, input: ["text"], output: ["text"] },
    limit: { context: 32_000, output: 4_096 },
  })
  await Bun.write(
    path.join(repo, "opencode.json"),
    JSON.stringify({
      providers: {
        flaky: {
          name: "Flaky (e2e)",
          package: "@opencode/ai/providers/openai-compatible",
          settings: { baseURL: `http://127.0.0.1:${provider.port}/v1`, apiKey: "e2e" },
          models: { "always-503": model("always-503"), "twice-503": model("twice-503") },
        },
      },
    }),
  )
  const create = async (title: string, extra: Record<string, unknown> = {}) => {
    const session = (
      await call<{ data: { id: string } }>("/api/session", {
        title,
        location: { directory: repo },
        agent: "build",
        model: luna,
        ...extra,
      })
    ).data
    owned.push(session.id)
    return session.id
  }
  const bell = (id: string) => rpc("custom.preferences/mutate", { type: "sidebar.notify", session: key(id), notify: true })
  expect(
    (await rpc<{ push: string }>("custom.notifications/register", { deviceID, serverKey: "e2e", environment: "sandbox", token }))
      .push,
    "configured",
  )

  // 1. Success: with the bell one "Terminou", without it nothing.
  const done = await create("Aviso — sucesso com sino")
  const quiet = await create("Aviso — sucesso sem sino")
  await bell(done)
  await call(`/api/session/${done}/prompt`, { text: "Responda apenas: ok" })
  await call(`/api/session/${quiet}/prompt`, { text: "Responda apenas: ok" })
  await idle(done)
  await idle(quiet)
  await Bun.sleep(8_000)
  const finished = await alerts(done)
  expect(finished.length, 1)
  expect(finished[0]?.body.opencode?.kind, "session.finished")
  expect(finished[0]?.body.aps["interruption-level"], "active")
  expect((await alerts(quiet)).length, 0)
  results.success = { bell: finished[0]?.body.aps.alert, withoutBell: "no alert" }

  // 2. A real question: one alert at once, with its request; the interruption that ends it alerts nothing.
  const asks = await create("Aviso — pergunta")
  await call(`/api/session/${asks}/prompt`, {
    text: 'Use a ferramenta question para me perguntar exatamente "Prefere azul ou verde?", com as opções azul e verde. Depois espere a resposta.',
  })
  const form = await until(
    async () => (await call<{ data: { id: string }[] }>(`/api/session/${asks}/form`)).data[0],
    180_000,
    "the question",
  )
  const askedAt = Date.now()
  const asked = await until(async () => (await alerts(asks))[0], 15_000, "the question alert")
  expect(asked.body.opencode?.attention, "question")
  expect(asked.body.opencode?.requestID, form.id)
  await Bun.sleep(5_000)
  await call(`/api/session/${asks}/interrupt?resume=false`, {})
  await idle(asks)
  await Bun.sleep(8_000)
  expect((await alerts(asks)).length, 1)
  results.question = { afterMs: asked.at - askedAt, alert: asked.body.aps.alert, requestID: form.id }

  // 3. Permissions: one left pending alerts after 3 s; one answered at once alerts nothing.
  const ask = { permissions: [{ action: "shell", resource: "*", effect: "ask" }] }
  const slow = await create("Aviso — permissão pendente", ask)
  const quick = await create("Aviso — permissão respondida", ask)
  await call(`/api/session/${quick}/prompt`, { text: "Use a ferramenta shell para rodar exatamente: echo rapido" })
  const fast = await until(
    async () => (await call<{ data: { id: string }[] }>(`/api/session/${quick}/permission`)).data[0],
    180_000,
    "the quick permission",
  )
  await call(`/api/session/${quick}/permission/${fast.id}/reply`, { decision: "once" })
  await call(`/api/session/${slow}/prompt`, { text: "Use a ferramenta shell para rodar exatamente: echo devagar" })
  const pending = await until(
    async () => (await call<{ data: { id: string }[] }>(`/api/session/${slow}/permission`)).data[0],
    180_000,
    "the pending permission",
  )
  const pendingAt = Date.now()
  const permitted = await until(async () => (await alerts(slow))[0], 15_000, "the permission alert")
  expect(permitted.body.opencode?.attention, "permission")
  expect(permitted.body.opencode?.requestID, pending.id)
  if (permitted.at - pendingAt < 2_000) throw new Error("The permission alert did not wait")
  await call(`/api/session/${slow}/permission/${pending.id}/reply`, { decision: "reject" })
  await idle(slow)
  await idle(quick)
  await Bun.sleep(8_000)
  expect((await alerts(quick)).length, 0)
  expect((await alerts(slow)).length, 1)
  results.permission = { afterMs: permitted.at - pendingAt, alert: permitted.body.aps.alert, answeredAtOnce: "no alert" }

  // 4. A bell session that fails without retries (unknown model): one alert, and its device's Live Activity update
  //    for the failure carries no alert.
  await rpc("custom.live-activity/register", {
    deviceID,
    serverKey: "e2e",
    environment: "sandbox",
    theme: {
      background: "#120f0eff",
      surface: "#161313ff",
      border: "#2e2e2dff",
      textStrong: "#e4e0d6ff",
      text: "#c9c5baff",
      textSecondary: "#a29f94ff",
      textWeak: "#6b6861ff",
      primary: "#da7c47ff",
      success: "#83b35fff",
      warning: "#c67f13ff",
      error: "#dc6e5eff",
      accent: "#9988e5ff",
    },
  })
  await rpc("custom.live-activity/activity", { deviceID, activityID: `act-${token.slice(0, 8)}`, pushToken: activityToken })
  const broken = await create("Aviso — falha sem retry")
  await bell(broken)
  const before = (await log()).length
  await call(`/api/session/${broken}/model`, { model: { providerID: "llm-proxy", id: "modelo-inexistente-e2e" } })
  await call(`/api/session/${broken}/prompt`, { text: "Responda apenas: ok" })
  await idle(broken)
  await Bun.sleep(12_000)
  const failed = await alerts(broken)
  expect(failed.length, 1)
  expect(failed[0]?.body.opencode?.attention, "failed")
  const activity = (await log()).slice(before).filter((entry) => entry.path === `/3/device/${activityToken}`)
  if (activity.length === 0) throw new Error("No Live Activity update reached the fake APNs")
  if (activity.some((entry) => entry.body.aps.alert)) throw new Error("A Live Activity update carried an alert")
  await rpc("custom.live-activity/unregister", { deviceID })
  results.failure = { alert: failed[0]?.body.aps.alert, liveActivityUpdates: activity.length, liveActivityAlerts: 0 }

  // 5. Retries: 503 until the retries run out alerts once, only at the end; two 503s then success is a "Terminou".
  const retried = await create("Aviso — falha com retry", { model: { providerID: "flaky", id: "always-503" } })
  const recovers = await create("Aviso — retry que se recupera", { model: { providerID: "flaky", id: "twice-503" } })
  await bell(recovers)
  const started = Date.now()
  await call(`/api/session/${retried}/prompt`, { text: "Responda apenas: ok" })
  await call(`/api/session/${recovers}/prompt`, { text: "Responda apenas: ok" })
  await Bun.sleep(30_000)
  expect((await alerts(retried)).length, 0)
  const midway = attempts.get("always-503") ?? 0
  if (midway < 3) throw new Error(`Expected retries in flight, saw ${midway} attempts`)
  await idle(recovers)
  await idle(retried, 300_000)
  await Bun.sleep(8_000)
  const gaveUp = await alerts(retried)
  expect(gaveUp.length, 1)
  expect(gaveUp[0]?.body.opencode?.attention, "failed")
  const recovered = await alerts(recovers)
  expect(recovered.length, 1)
  expect(recovered[0]?.body.opencode?.kind, "session.finished")
  results.retry = {
    attempts: attempts.get("always-503"),
    alertAfterMs: (gaveUp[0]?.at ?? 0) - started,
    noAlertAt30s: true,
    recovered: { attempts: attempts.get("twice-503"), alert: recovered[0]?.body.aps.alert },
  }
  console.log(JSON.stringify({ ok: true, results }, null, 2))
} finally {
  provider.stop(true)
  await rpc("custom.notifications/unregister", { deviceID }).catch(() => undefined)
  await rpc("custom.live-activity/unregister", { deviceID }).catch(() => undefined)
  for (const id of owned) {
    await rpc("custom.preferences/mutate", { type: "sidebar.notify", session: key(id), notify: false }).catch(() => undefined)
    await call(`/api/session/${id}/interrupt?resume=false`, {}).catch(() => undefined)
    await call(`/api/session/${id}`, undefined, "DELETE").catch(() => undefined)
  }
  await rm(repo, { recursive: true, force: true })
}

function expect<A>(actual: A, expected: A) {
  if (actual !== expected) throw new Error(`Expected ${String(expected)}, got ${String(actual)}`)
}
