#!/usr/bin/env bun
/**
 * End to end for the single "Todos" Live Activity (docs/unified-summary.md): two owned sandboxes linked by a Unix
 * socket, each with its own MyAgents `script/fake-apns.ts`, so every push is read back per server. Nothing reaches
 * Apple, a device or production. It starts and stops everything it uses.
 *
 *   bun script/e2e-unified-summary.ts [--hub-port 4187] [--peer-port 4188] [--fake-apns <MyAgents>/script/fake-apns.ts]
 *
 * The hub sandbox (`--summary-peers`) plays the Linux BRS, the peer (`--summary-socket`) the Mac. One session fails
 * on each (an unknown model, no LLM run). Checked: the activity registered on the hub with `scope: "all"` gets an
 * update with both servers' sessions; with the peer stopped its part leaves and it is listed offline; started again,
 * it returns; the peer never pushes to that activity's token and alerts its own failure as a plain notification,
 * which the hub does not repeat.
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
const socket = path.join(root, "summary.sock")
if (Buffer.byteLength(socket) > 100) throw new Error("The socket path is too long for a Unix socket")
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

type Row = { sessionID: string; server?: string }
type State = {
  host: string
  counts: { failed: number }
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
async function node(name: string, port: number, hostName: string, link: string[]) {
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
  return { name, home, url, sandbox, call, rpc, log, fail, stop: () => apns.kill() }
}

function expect<A>(actual: A, expected: A, what: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected))
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

const hub = await node("hub", Number(args.values["hub-port"]), "Linux e2e", ["--summary-peers", socket])
const peer = await node("peer", Number(args.values["peer-port"]), "Mac e2e", ["--summary-socket", socket])
const token = crypto.randomUUID().replaceAll("-", "")
const alertToken = crypto.randomUUID().replaceAll("-", "")
const deviceID = `e2e-${token.slice(0, 8)}`
const results: Record<string, unknown> = {}
try {
  console.log("Starting the two sandboxes (each builds the plugin and the web app)…")
  await peer.sandbox("up")
  await hub.sandbox("up")

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
    "a server without peers does not confirm the scope",
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

  // 3. The peer stops: its part leaves about 60 s later and it is listed offline.
  const stoppedAt = Date.now()
  await peer.sandbox("down")
  const alone = await latest((state) => state.servers?.[1]?.offline === true, stoppedAt, "the peer shown as offline")
  expect(alone.state.counts.failed, 1, "only the hub's failure remains")
  expect(
    alone.state.sessions.map((row) => row.sessionID),
    [onHub],
    "only the hub's row remains",
  )
  results.offline = { host: alone.state.host, afterMs: alone.at - stoppedAt, failed: alone.state.counts.failed }

  // 4. The peer returns (its hub starts with the first RPC) and its failure is back in the card.
  const startedAt = Date.now()
  await peer.sandbox("up")
  await peer.rpc("custom.live-activity/snapshot", {})
  const back = await latest(
    (state) => state.servers?.[1]?.offline !== true && state.sessions.some((row) => row.sessionID === onPeer),
    startedAt,
    "the peer's session back in the card",
  )
  expect(back.state.counts.failed, 2, "failed sessions of both servers again")
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
  ] as const)
    await server.call(`/api/session/${id}`, undefined, "DELETE").catch(() => undefined)
  console.log(JSON.stringify({ ok: true, results }, null, 2))
} finally {
  await hub.rpc("custom.live-activity/unregister", { deviceID }).catch(() => undefined)
  await peer.rpc("custom.notifications/unregister", { deviceID }).catch(() => undefined)
  await hub.sandbox("down").catch(() => undefined)
  await peer.sandbox("down").catch(() => undefined)
  hub.stop()
  peer.stop()
  await rm(root, { recursive: true, force: true })
}
