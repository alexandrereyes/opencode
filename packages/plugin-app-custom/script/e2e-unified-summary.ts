#!/usr/bin/env bun
/**
 * End to end for the single "Todos" Live Activity (docs/unified-summary.md): two owned sandboxes, one sending its
 * summary to the other over the normal API, each with its own MyAgents `script/fake-apns.ts`, so every push is read
 * back per server. Nothing reaches Apple, a device or production. It starts and stops everything it uses.
 *
 *   bun script/e2e-unified-summary.ts [--hub-port 4187] [--peer-port 4188] [--fake-apns <MyAgents>/script/fake-apns.ts]
 *
 * The hub sandbox (`OPENCODE_HUB=1`) plays the Linux BRS, the peer (`--summary-hub`) the Mac; the peer takes the hub's
 * password, as production's two servers share one. One session fails on each (an unknown model, no LLM run) and one works
 * on the peer (a real Luna 6 / low run that sleeps in a shell). Checked: the activity registered on the hub with
 * `scope: "all"` gets an update with both servers' sessions; the peer frozen (SIGSTOP, a Mac asleep) while working
 * goes offline about 60 s after its last renewal, its work leaving and its failure staying, and returns when resumed;
 * the peer stopped says goodbye and is offline at once, and started again is back; the peer never pushes to that
 * activity's token and alerts its own failure as a plain notification, which the hub does not repeat.
 */
import { mkdir, mkdtemp, realpath, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"

const args = parseArgs({
  args: Bun.argv.slice(2),
  options: {
    "hub-port": { type: "string", default: "4187" },
    "peer-port": { type: "string", default: "4188" },
    "fake-apns": { type: "string", default: path.join(os.homedir(), "Dev/MyAgents/script/fake-apns.ts") },
  },
})
const source = path.resolve(import.meta.dirname, "../../..")
const sandboxScript = path.join(source, "packages/cli/script/custom-sandbox.ts")
const root = await mkdtemp(path.join(await realpath(os.tmpdir()), "opencode", "unified-e2e-"))
const luna = { providerID: "llm-proxy", id: "gpt-6-luna", variant: "low" }
const theme = Object.fromEntries(
  [
    "background",
    "surface",
    "border",
    "textStrong",
    "text",
    "textSecondary",
    "textWeak",
    "primary",
    "success",
    "warning",
    "error",
    "accent",
  ].map((role) => [role, "#120f0eff"]),
)

type Row = { sessionID: string; server?: string; status: string }
type State = {
  host: string
  counts: { failed: number; working: number }
  sessions: Row[]
  servers?: { instanceID: string; name: string; short: string; offline?: boolean }[]
}
type Entry = {
  at: number
  path: string
  type: string
  priority: string
  body: { aps: { alert?: { title: string }; "content-state"?: State }; opencode?: { sessionID: string } }
}

async function freePort() {
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response() })
  const port = server.port
  await server.stop(true)
  return port
}

async function until<T>(read: () => Promise<T | undefined>, timeout: number, what: string) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = await read().catch(() => undefined)
    if (value !== undefined) return value
    await Bun.sleep(500)
  }
  throw new Error(`Timeout waiting for ${what}`)
}

/** One sandbox with its own fake APNs. */
async function node(name: string, port: number, hostName: string, link: string[], hubFlag: boolean) {
  const home = path.join(root, name)
  const apnsLog = path.join(root, `${name}-apns.jsonl`)
  await Bun.write(apnsLog, "")
  const apnsPort = await freePort()
  const apns = Bun.spawn([process.execPath, args.values["fake-apns"], "--port", String(apnsPort), "--log", apnsLog], {
    stdin: "ignore",
    stdout: "ignore",
    stderr: "inherit",
  })
  const sandbox = async (action: "up" | "down") => {
    const child = Bun.spawn(
      [
        process.execPath,
        sandboxScript,
        action,
        "--port",
        String(port),
        "--home",
        home,
        ...(action === "up" ? link : []),
      ],
      {
        cwd: source,
        env: {
          ...process.env,
          OPENCODE_APNS_ORIGIN: `http://127.0.0.1:${apnsPort}`,
          OPENCODE_HOST_NAME: hostName,
          OPENCODE_HUB: hubFlag ? "1" : "",
        },
        stdin: "ignore",
        stdout: "ignore",
        stderr: "inherit",
      },
    )
    if ((await child.exited) !== 0) throw new Error(`custom-sandbox ${action} failed for ${name}`)
  }
  const url = `http://127.0.0.1:${port}`
  const call = async <T>(route: string, body?: unknown, method = body === undefined ? "GET" : "POST"): Promise<T> => {
    const password = (await Bun.file(path.join(home, "password")).text()).trim()
    const response = await fetch(url + route, {
      method,
      headers: {
        authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
        "content-type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    if (!response.ok) throw new Error(`${method} ${route}: HTTP ${response.status} ${await response.text()}`)
    const text = await response.text()
    return (text ? JSON.parse(text) : undefined) as T
  }
  const rpc = <T>(route: string, input: unknown) =>
    call<{ output: T }>(`/api/rpc/${route}`, { input }).then((result) => result.output)
  const log = async () =>
    (await Bun.file(apnsLog).text())
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line) as Entry)
  /** A top-level session whose only run fails at once: an unknown model, so no LLM is called. */
  const fail = async (title: string) => {
    const repo = path.join(home, "repos", "unified-e2e")
    await mkdir(repo, { recursive: true })
    await Bun.$`git init -q ${repo} && git -C ${repo} -c user.name=E2E -c user.email=e2e@example.invalid commit --allow-empty -qm init`.quiet()
    const id = (
      await call<{ data: { id: string } }>("/api/session", {
        title,
        location: { directory: repo },
        agent: "build",
        model: luna,
      })
    ).data.id
    await call(`/api/session/${id}/model`, { model: { providerID: "llm-proxy", id: "modelo-inexistente-e2e" } })
    await call(`/api/session/${id}/prompt`, { text: "Responda apenas: ok" })
    await until(
      async () => ((await call<{ data: Record<string, unknown> }>("/api/session/active")).data[id] ? undefined : true),
      120_000,
      `${title} to stop`,
    )
    return id
  }
  /** A session kept working by a shell that sleeps (one real Luna 6 / low run). */
  const work = async (title: string) => {
    const repo = path.join(home, "repos", "unified-e2e")
    const id = (
      await call<{ data: { id: string } }>("/api/session", {
        title,
        location: { directory: repo },
        agent: "build",
        model: luna,
      })
    ).data.id
    await call(`/api/session/${id}/prompt`, {
      text: "Use a ferramenta shell para rodar exatamente: sleep 240. Não faça mais nada antes disso.",
    })
    return id
  }
  /** Freezes or resumes the server process, as a Mac that sleeps and wakes: no goodbye, no renewal. */
  const signal = async (name: "STOP" | "CONT") => {
    const { pid } = (await Bun.file(path.join(home, "server.json")).json()) as { pid: number }
    process.kill(pid, `SIG${name}`)
  }
  return { name, home, url, sandbox, call, rpc, log, fail, work, signal, stop: () => apns.kill() }
}

function expect<A>(actual: A, expected: A, what: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

const hub = await node("hub", Number(args.values["hub-port"]), "Linux e2e", [], true)
const peer = await node(
  "peer",
  Number(args.values["peer-port"]),
  "Mac e2e",
  // The same password on both, as in production: the sender presents its own to the hub.
  ["--summary-hub", `http://127.0.0.1:${args.values["hub-port"]}`, "--password-from", path.join(root, "hub")],
  false,
)
const token = crypto.randomUUID().replaceAll("-", "")
const alertToken = crypto.randomUUID().replaceAll("-", "")
const deviceID = `e2e-${token.slice(0, 8)}`
const results: Record<string, unknown> = {}
try {
  console.log("Starting the two sandboxes (each builds the plugin and the web app)…")
  await hub.sandbox("up")
  await peer.sandbox("up")

  // The app in the "Todos" scope: the activity on the hub only; on the peer, just the ordinary notifications.
  expect(
    await hub.rpc("custom.live-activity/register", {
      deviceID,
      serverKey: "todos",
      environment: "sandbox",
      theme,
      scope: "all",
    }),
    { push: "configured", scope: "all" },
    "the hub confirms the Todos scope",
  )
  await hub.rpc("custom.live-activity/activity", { deviceID, activityID: "act-todos", pushToken: token })
  expect(
    await peer.rpc("custom.live-activity/register", {
      deviceID: `${deviceID}-probe`,
      serverKey: "probe",
      environment: "sandbox",
      theme,
      scope: "all",
    }),
    { push: "configured" },
    "a server that is not the hub does not confirm the scope",
  )
  await peer.rpc("custom.live-activity/unregister", { deviceID: `${deviceID}-probe` })
  await peer.rpc("custom.notifications/register", {
    deviceID,
    serverKey: "mac",
    environment: "sandbox",
    token: alertToken,
  })
  const identity = {
    hub: await hub.rpc<{ instanceID: string }>("custom.instance/get", {}),
    peer: await peer.rpc<{ instanceID: string }>("custom.instance/get", {}),
  }

  const onPeer = await peer.fail("Unificado — falha no Mac")
  const onHub = await hub.fail("Unificado — falha no Linux")

  const states = async () =>
    (await hub.log()).flatMap((entry) =>
      entry.path === `/3/device/${token}` && entry.body.aps["content-state"]
        ? [{ at: entry.at, state: entry.body.aps["content-state"] }]
        : [],
    )
  const latest = (wanted: (state: State) => boolean, since: number, what: string) =>
    until(async () => (await states()).findLast((item) => item.at >= since && wanted(item.state)), 120_000, what)

  // 1. Both servers in one push to the Todos activity.
  const both = await latest(
    (state) =>
      state.sessions.some((row) => row.sessionID === onPeer && row.server === identity.peer.instanceID) &&
      state.sessions.some((row) => row.sessionID === onHub && row.server === identity.hub.instanceID),
    0,
    "an update with both servers' sessions",
  )
  expect(both.state.counts.failed, 2, "failed sessions of both servers")
  expect(
    both.state.servers?.map((item) => [item.name, item.offline ?? false]),
    [
      ["Linux e2e", false],
      ["Mac e2e", false],
    ],
    "servers",
  )
  results.joined = { host: both.state.host, failed: both.state.counts.failed, servers: both.state.servers }

  // 2. The peer's own failure is one plain notification from the peer; the hub alerts only its own, through the card.
  await until(
    async () => (await peer.log()).find((entry) => entry.type === "alert" && entry.body.opencode?.sessionID === onPeer),
    30_000,
    "the peer's notification of its failure",
  )
  await Bun.sleep(8_000)
  const peerLog = await peer.log()
  const hubLog = await hub.log()
  expect(
    peerLog.filter((entry) => entry.type === "alert" && entry.body.opencode?.sessionID === onPeer).length,
    1,
    "the peer's notification",
  )
  expect(
    hubLog.filter((entry) => entry.body.aps.alert).map((entry) => [entry.path, entry.body.aps.alert?.title]),
    [[`/3/device/${token}`, "Unificado — falha no Linux"]],
    "the hub's only alert is its own session's, through the Todos card",
  )
  expect(hubLog.filter((entry) => entry.type === "alert").length, 0, "no notification from the hub")
  results.alerts = { peerNotification: 1, hubCardAlert: 1, hubNotification: 0 }

  // 3. A session works on the peer; frozen like a Mac asleep, the peer stops renewing: about 60 s later it is
  //    offline, its work gone and its failure still there. Resumed, its work is back.
  const working = await peer.work("Unificado — trabalhando no Mac")
  const busy = (state: State) => state.sessions.some((row) => row.sessionID === working && row.status === "working")
  await latest((state) => busy(state) && state.servers?.[1]?.offline !== true, 0, "the peer's working session")
  const frozenAt = Date.now()
  await peer.signal("STOP")
  const asleep = await latest((state) => state.servers?.[1]?.offline === true, frozenAt, "the frozen peer as offline")
  expect(asleep.state.counts.working, 0, "no work of the frozen peer")
  expect(asleep.state.counts.failed, 2, "the frozen peer's failure stays")
  expect(busy(asleep.state), false, "the frozen peer's working row left")
  results.asleep = { host: asleep.state.host, afterMs: asleep.at - frozenAt, failed: asleep.state.counts.failed }
  const resumedAt = Date.now()
  await peer.signal("CONT")
  const awake = await latest(
    (state) => state.servers?.[1]?.offline !== true && busy(state),
    resumedAt,
    "the resumed peer's work back",
  )
  results.awake = { host: awake.state.host, afterMs: awake.at - resumedAt }
  await peer.call(`/api/session/${working}/interrupt?resume=false`, {})

  // 4. The peer stops for good: it says goodbye and is offline at once, its failure still listed. Started again
  //    (its hub starts with the first RPC), it is back.
  const stoppedAt = Date.now()
  await peer.sandbox("down")
  const gone = await latest((state) => state.servers?.[1]?.offline === true, stoppedAt, "the stopped peer as offline")
  expect(gone.state.counts.failed, 2, "the stopped peer's failure stays")
  results.stopped = { host: gone.state.host, afterMs: gone.at - stoppedAt }
  const startedAt = Date.now()
  await peer.sandbox("up")
  await peer.rpc("custom.live-activity/snapshot", {})
  const back = await latest(
    (state) => state.servers?.[1]?.offline !== true && state.sessions.some((row) => row.sessionID === onPeer),
    startedAt,
    "the peer back",
  )
  results.back = { host: back.state.host, afterMs: back.at - startedAt }

  // 5. The peer never wrote to the Todos activity's token.
  expect(
    (await peer.log()).filter((entry) => entry.path === `/3/device/${token}`).length,
    0,
    "pushes from the peer to the Todos activity",
  )
  results.peerPushesToTodosToken = 0
  for (const [server, id] of [
    [hub, onHub],
    [peer, onPeer],
    [peer, working],
  ] as const)
    await server.call(`/api/session/${id}`, undefined, "DELETE").catch(() => undefined)
  console.log(JSON.stringify({ ok: true, results }, null, 2))
} finally {
  await peer.signal("CONT").catch(() => undefined)
  await hub.rpc("custom.live-activity/unregister", { deviceID }).catch(() => undefined)
  await peer.rpc("custom.notifications/unregister", { deviceID }).catch(() => undefined)
  await hub.sandbox("down").catch(() => undefined)
  await peer.sandbox("down").catch(() => undefined)
  hub.stop()
  peer.stop()
  await rm(root, { recursive: true, force: true })
}
