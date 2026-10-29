#!/usr/bin/env bun
/**
 * End to end of the watch complication's WidgetKit pushes against an owned sandbox started with
 * `OPENCODE_APNS_ORIGIN` pointing at `packages/ios-custom/script/fake-apns.ts`. It pairs a test watch, registers a
 * fake widget token, plays a fixed sequence of real Luna 6 / low runs, questions, permissions and a failure, then
 * `--churn-minutes` of routine work (a short answer every 15 s while a long run goes on), and counts the `widgets`
 * pushes the plugin hands to APNs. Like a real complication, it reads `/watch/v1/state` (as the
 * widget) after each push it receives. Nothing reaches Apple or a device.
 *
 *   bun script/e2e-watch-widget-push.ts --url http://127.0.0.1:4186 --home <sandbox home> \
 *     --apns-log <jsonl> --watch-port <sandbox watch gateway port> [--settle-minutes 32] [--out result.json]
 *
 * After the sequence it waits up to `--settle-minutes` for the last change to reach the watch (a push or a fetch),
 * then removes its device, sessions and repository.
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
    "watch-port": { type: "string" },
    "settle-minutes": { type: "string", default: "32" },
    "churn-minutes": { type: "string", default: "10" },
    out: { type: "string" },
  },
})
const url = args.values.url ?? ""
const home = args.values.home ?? ""
const apnsLog = args.values["apns-log"] ?? ""
const watchPort = Number(args.values["watch-port"])
const settleMs = Number(args.values["settle-minutes"]) * 60_000
const churnMs = Number(args.values["churn-minutes"]) * 60_000
if (!url || !home || !apnsLog || !watchPort)
  throw new Error("Usage: --url URL --home SANDBOX_HOME --apns-log FILE --watch-port N [--settle-minutes N]")
if (/:(4096|4178)\b/.test(url) || watchPort === 4192) throw new Error("Never against production")
if (!(await Bun.file(path.join(home, "sandbox.json")).exists())) throw new Error("--home is not an owned sandbox")

const password = (await Bun.file(path.join(home, "password")).text()).trim()
const auth = `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`
const model = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const token = crypto.randomUUID().replaceAll("-", "") + crypto.randomUUID().replaceAll("-", "")
const gateway = `http://127.0.0.1:${watchPort}/watch/v1`
const started = Date.now()
const marks: { at: number; event: string }[] = []
const mark = (event: string) => {
  marks.push({ at: Date.now() - started, event })
  console.log(`${((Date.now() - started) / 1000).toFixed(1).padStart(6)}s ${event}`)
}

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

type State = { activeTotal: number; attentionTotal: number; counts: Record<string, number> } | null
const watch = { token: "" }
async function watchCall<T>(route: string, body?: unknown, client = "app"): Promise<T> {
  const response = await fetch(gateway + route, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      authorization: `Bearer ${watch.token}`,
      "content-type": "application/json",
      "user-agent": "OpenCodeWatch/e2e",
      "x-watch-client": client,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!response.ok) throw new Error(`watch ${route}: HTTP ${response.status} ${await response.text()}`)
  return (await response.json()) as T
}
const summary = (state: State) =>
  state ? { active: state.activeTotal, attention: state.attentionTotal, failed: state.counts.failed ?? 0 } : null

type Push = { at: number; path: string; type: string; priority: string }
const pushes = async () =>
  (
    await Bun.file(apnsLog)
      .text()
      .catch(() => "")
  )
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Push)
    .filter((entry) => entry.type === "widgets" && entry.path === `/3/device/${token}`)

/** The complication: every push reloads it, and a reload reads the state as the widget. */
const complication = { seen: 0, fetched: [] as { at: number; state: ReturnType<typeof summary> }[], stop: false }
async function reloadOnPush() {
  while (!complication.stop) {
    const all = await pushes()
    for (const push of all.slice(complication.seen)) {
      const state = (await watchCall<{ state: State }>("/state", undefined, "widget")).state
      complication.fetched.push({ at: push.at - started, state: summary(state) })
      mark(`widget push → complication reads ${JSON.stringify(summary(state))}`)
    }
    complication.seen = all.length
    await Bun.sleep(500)
  }
}

async function idle(sessionID: string, timeout = 300_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const running = (await call<{ data: Record<string, unknown> }>("/api/session/active")).data
    if (!running[sessionID]) return
    await Bun.sleep(500)
  }
  throw new Error(`Timeout waiting for ${sessionID}`)
}

const repo = path.join(home, "repos", `watch-e2e-${token.slice(0, 8)}`)
const owned: string[] = []
const device = { id: "" }
const loop = { promise: Promise.resolve() }
try {
  await mkdir(repo, { recursive: true })
  await Bun.$`git init -q ${repo} && git -C ${repo} -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm init`.quiet()
  // The sandbox inherits a permissive config; this action always asks, so the permission stays pending.
  const create = async (title: string) => {
    const session = (
      await call<{ data: { id: string } }>("/api/session", {
        title,
        location: { directory: repo },
        agent: "build",
        model,
        permissions: [{ action: "watch-e2e", resource: "*", effect: "ask" }],
      })
    ).data
    owned.push(session.id)
    return session.id
  }
  const paired = await rpc<{ deviceID: string; deviceToken: string }>("custom.watch/pair", { deviceName: "E2E Watch" })
  device.id = paired.deviceID
  watch.token = paired.deviceToken
  await watchCall("/widget-token", { token, environment: "sandbox" })
  loop.promise = reloadOnPush()
  mark(`paired ${device.id}, widget token registered`)
  await Bun.sleep(3_000)

  const long = await create("Relógio — tarefa longa")
  const short = await create("Relógio — respostas curtas")
  const asks = await create("Relógio — pergunta")
  const allows = await create("Relógio — permissão")
  const broken = await create("Relógio — falha")
  const answer = async () => {
    await call(`/api/session/${short}/prompt`, { text: "Responda apenas: ok" })
    await idle(short)
  }

  await call(`/api/session/${long}/prompt`, {
    text: `Use a ferramenta shell com timeout 0 (sem limite) para rodar exatamente "sleep ${Math.round(churnMs / 1000) + 150}" e espere ele terminar. Depois responda apenas: ok.`,
  })
  mark("long run started (active 0 → 1)")
  for (const round of [1, 2, 3]) {
    await answer()
    mark(`short answer ${round} (active 1 → 2 → 1)`)
  }
  const question = (
    await call<{ data: { id: string } }>(`/api/session/${asks}/form`, {
      title: "Qual opção usar?",
      metadata: { kind: "question" },
      fields: [{ key: "answer", type: "string", required: true, options: [{ value: "ok", label: "OK" }] }],
    })
  ).data.id
  mark("question asked (attention 0 → 1)")
  await Bun.sleep(5_000)
  const permission = (
    await call<{ data: { id: string; effect: string } }>(`/api/session/${allows}/permission`, {
      action: "watch-e2e",
      resources: [repo],
    })
  ).data
  mark(`permission asked (attention 1 → 2, effect ${permission.effect})`)
  await Bun.sleep(5_000)
  await answer()
  mark("short answer 4")
  await watchCall(`/requests/${question}/reply`, {
    kind: "question",
    answers: [{ questionID: "answer", optionIDs: ["ok"] }],
  })
  mark("question answered from the watch (attention 2 → 1)")
  await Bun.sleep(5_000)
  await call(`/api/session/${broken}/model`, { model: { providerID: "llm-proxy", id: "modelo-inexistente-e2e" } })
  await call(`/api/session/${broken}/prompt`, { text: "Responda apenas: ok" })
  await idle(broken)
  mark("failed run (failed 0 → 1)")
  await watchCall(`/requests/${permission.id}/reply`, { kind: "permission", decision: "once" })
  mark("permission answered from the watch (attention 1 → 0)")
  const churnStart = Date.now()
  const churn = { rounds: 0 }
  while (Date.now() - churnStart < churnMs) {
    await answer()
    churn.rounds += 1
    await Bun.sleep(15_000)
  }
  mark(`routine work: ${churn.rounds} short answers in ${Math.round((Date.now() - churnStart) / 60_000)} min`)
  await idle(long, churnMs + 600_000)
  mark("long run finished (active 1 → 0)")
  await Bun.sleep(5_000)
  await call(`/api/session/${broken}`, undefined, "DELETE")
  owned.splice(owned.indexOf(broken), 1)
  mark("failed session deleted (failed 1 → 0)")
  const sequenceEnd = Date.now()

  // Settle: the final state must reach the complication, by a push it reloads on or by a fetch.
  // Read through the server, not the gateway: a gateway read would itself count as the watch having it.
  await Bun.sleep(2_000)
  const final = summary((await rpc<{ state: State }>("custom.live-activity/snapshot", {})).state)
  const deadline = Date.now() + settleMs
  const delivered = () => JSON.stringify(complication.fetched.at(-1)?.state) === JSON.stringify(final)
  while (Date.now() < deadline && !delivered()) await Bun.sleep(5_000)
  await Bun.sleep(3_000)
  complication.stop = true
  await loop.promise
  const sent = await pushes()
  const stats = await rpc("custom.watch/stats", {}).catch(() => "unavailable (server without custom.watch/stats)")
  const result = {
    pushes: sent.length,
    duringSequence: sent.filter((push) => push.at <= sequenceEnd).length,
    afterSequence: sent
      .filter((push) => push.at > sequenceEnd)
      .map((push) => Math.round((push.at - sequenceEnd) / 1000)),
    pushTimesSeconds: sent.map((push) => Math.round((push.at - started) / 1000)),
    sequenceSeconds: Math.round((sequenceEnd - started) / 1000),
    finalState: final,
    finalDelivered: delivered(),
    complicationReads: complication.fetched,
    marks,
    stats,
  }
  console.log(JSON.stringify(result, null, 2))
  if (args.values.out) await Bun.write(args.values.out, JSON.stringify(result, null, 2))
} finally {
  complication.stop = true
  await loop.promise.catch(() => undefined)
  if (device.id) await rpc("custom.watch/revoke", { deviceID: device.id }).catch(() => undefined)
  for (const id of owned) await call(`/api/session/${id}`, undefined, "DELETE").catch(() => undefined)
  await rm(repo, { recursive: true, force: true })
}
