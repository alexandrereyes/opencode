#!/usr/bin/env bun

import { Database } from "bun:sqlite"
import { chmod, mkdir, readdir, realpath, rm, stat } from "node:fs/promises"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"
import { settings } from "./custom-release"

const source = path.resolve(import.meta.dirname, "../../..")
const args = parseArgs({
  args: Bun.argv.slice(2),
  allowPositionals: true,
  options: {
    port: { type: "string", default: "4177" },
    home: { type: "string" },
    // The watch gateway of a sandbox never takes production's 4192; 0 lets the OS pick a free port.
    "watch-port": { type: "string", default: "0" },
  },
})
const action = args.positionals[0] ?? "status"
const port = Number(args.values.port)
// 4179 is production's resources hub; OrbStack forwards the Linux machine's loopback ports to the Mac's.
if (!Number.isInteger(port) || port < 1024 || port > 65535 || [4096, 4178, 4179].includes(port))
  throw new Error("Choose a non-production port between 1024 and 65535 (never 4096, 4178 or 4179)")
const watchPort = Number(args.values["watch-port"])
if (
  !Number.isInteger(watchPort) ||
  watchPort < 0 ||
  watchPort > 65535 ||
  [4096, 4178, 4179, 4192, port].includes(watchPort)
)
  throw new Error(
    "Choose a sandbox watch gateway port other than 4096, 4178, 4179, 4192 and the server port (0 = any free port)",
  )
if (!["up", "down", "status", "hub"].includes(action))
  throw new Error("Usage: custom-sandbox.ts up|down|status|hub [--port N] [--home PATH]")
const home = path.resolve(
  args.values.home ?? path.join(await realpath(os.tmpdir()), "opencode", `custom-sandbox-${port}`),
)
const session = `custom-sandbox-${port}`
// OrbStack's name for the Mac, whose loopback serves the sandbox hub.
const hubHost = "host.orb.internal"
const url = `http://127.0.0.1:${port}`
const marker = Bun.file(path.join(home, "sandbox.json"))
type Owner = { format: 1; home: string; port: number; token: string; source: string }
const owner: Owner | undefined = (await marker.exists()) ? await marker.json() : undefined
if (owner && (owner.format !== 1 || owner.home !== home || owner.port !== port))
  throw new Error("Sandbox ownership does not match --home/--port")

if (action === "status") {
  const info = await health()
  const hub = owner && macHub(owner)
  console.log(
    JSON.stringify(
      {
        health: info ? "ready" : "stopped",
        version: info?.version,
        url,
        home,
        session,
        ...(hub ? { hub: { mac: hub.state, ready: await hubReady(owner) } } : {}),
      },
      null,
      2,
    ),
  )
}
if (action === "down") {
  if (!owner) throw new Error("No sandbox ownership record; refusing to stop anything")
  await stop(owner)
  const hub = macHub(owner)
  if (hub) await removeHubState(hub)
  console.log(`Stopped ${session}; preserved ${home}`)
}
if (action === "up") await up()
if (action === "hub") {
  // Test scripts reach the sandbox hub's admin API through this file, never through production's hub.
  if (!owner || !(await health())) throw new Error("The sandbox is not running")
  const file = path.join(home, "resources-hub.json")
  const access = await hubAccess(owner)
  if (!access) throw new Error("The sandbox resources hub is not running")
  await privateFile(file, JSON.stringify(access))
  console.log(file)
}

async function up() {
  if (await health()) {
    if (!owner || !(await owned(owner))) throw new Error("Port is healthy but is not owned by this sandbox")
    await requirePlugin(owner)
    await requireHub(owner)
    return report(owner)
  }
  if (await listening()) throw new Error(`Port ${port} is occupied; refusing to touch its process`)
  if (await hasSession())
    throw new Error(`tmux session ${session} already exists; inspect it or run this sandbox's down command`)
  if (!owner && (await readdir(home).catch(() => [])).length)
    throw new Error("Nonempty --home has no sandbox ownership record")
  await mkdir(home, { recursive: true, mode: 0o700 })
  await chmod(home, 0o700)
  const identity: Owner = owner ?? { format: 1, home, port, token: crypto.randomUUID(), source }
  await privateFile(path.join(home, "sandbox.json"), JSON.stringify(identity, null, 2))
  await mkdir(path.join(home, ".up-lock"), { mode: 0o700 }).catch(() => {
    throw new Error("Another sandbox up is in progress")
  })
  try {
    const installed = path.join(os.homedir(), ".local/share/opencode-custom-v2")
    const manual = await settings(installed)
    const environmentFile = path.join(installed, "environment.sh")
    const exported = (await Bun.file(environmentFile).exists())
      ? Object.fromEntries(
          (await run(["/bin/zsh", "-c", 'set -a; source "$1"; env -0', "sandbox-env", environmentFile]))
            .split("\0")
            .filter(Boolean)
            .map((entry) => [entry.slice(0, entry.indexOf("=")), entry.slice(entry.indexOf("=") + 1)]),
        )
      : {}
    const environment = { ...process.env, ...manual.environment, ...exported }
    const config = environment.OPENCODE_CONFIG_DIR ?? manual.config
    if (home === (await realpath(config)) || home === (await realpath(path.dirname(manual.database))))
      throw new Error("Sandbox must not use production configuration or persistence")
    const configTarget = path.join(home, "config/opencode")
    await copyConfig(config, configTarget)
    await Promise.all(
      ["data/opencode", "xdg/data", "xdg/state", "xdg/cache"].map((name) =>
        mkdir(path.join(home, name), { recursive: true, mode: 0o700 }),
      ),
    )
    if (!(await Bun.file(path.join(home, "password")).exists()))
      await privateFile(path.join(home, "password"), crypto.randomUUID() + crypto.randomUUID())
    const commit = (await run(["git", "rev-parse", "HEAD"], source)).trim()
    await privateFile(
      path.join(home, "build.json"),
      JSON.stringify(
        {
          commit,
          builtAt: new Date().toISOString(),
          source,
          dirty: Boolean((await run(["git", "status", "--porcelain"], source)).trim()),
        },
        null,
        2,
      ),
    )
    const hub = macHub(identity)
    const runtime = {
      ...environment,
      // No production hub setting is inherited: neither its fixed port (4179) nor the remote hub on the Mac that
      // `manual.json` points a Linux server to. The sandbox uses its own hub (`macHub`), or the plugin starts a
      // local one in the sandbox's state directory on any free port.
      ...Object.fromEntries(
        Object.keys(environment)
          .filter((name) => name.startsWith("OPENCODE_RESOURCES_HUB_"))
          .map((name) => [name, undefined]),
      ),
      ...(hub
        ? {
            OPENCODE_RESOURCES_HUB_REMOTE_INFO: `${hub.state}/hub.json`,
            // Read on the Mac: opening /Users from Linux goes through virtio-fs and can hang the machine.
            OPENCODE_RESOURCES_HUB_REMOTE_INFO_COMMAND: JSON.stringify([
              hub.bridge,
              "/mnt/mac/bin/cat",
              `/mnt/mac${hub.state}/hub.json`,
            ]),
            OPENCODE_RESOURCES_HUB_REMOTE_HOST: hubHost,
            OPENCODE_RESOURCES_HUB_PATH_MAP: `${os.homedir()}/=${hub.mount}${os.homedir()}/`,
          }
        : {}),
      OPENCODE_CUSTOM_HOME: home,
      OPENCODE_CUSTOM_COMMIT: commit,
      OPENCODE_CUSTOM_PORT: String(port),
      OPENCODE_WATCH_GATEWAY_PORT: String(watchPort),
      OPENCODE_CUSTOM_DB: path.join(home, "data/opencode/custom.db"),
      OPENCODE_DB: path.join(home, "data/opencode/custom.db"),
      OPENCODE_CONFIG_DIR: configTarget,
      XDG_CONFIG_HOME: path.join(home, "config"),
      XDG_DATA_HOME: path.join(home, "xdg/data"),
      XDG_STATE_HOME: path.join(home, "xdg/state"),
      XDG_CACHE_HOME: path.join(home, "xdg/cache"),
      OPENCODE_CUSTOM_LAUNCHD: "1",
    }
    await privateFile(path.join(home, "environment.json"), JSON.stringify(runtime))
    console.log("Building the custom plugin and the upstream web app (service worker disabled)…")
    await run([process.execPath, "run", "build"], path.join(source, "packages/plugin-app-custom"))
    await run([process.execPath, "run", "build"], path.join(source, "packages/app"))
    if (!(await Bun.file(path.join(source, "packages/app/dist/index.html")).exists()))
      throw new Error("Web build did not produce dist/index.html")
    // The upstream app always registers /sw.js in production builds; without the file the sandbox origin keeps none.
    await rm(path.join(source, "packages/app/dist/sw.js"), { force: true })
    // The hub runs in the foreground of `mac`: signals reach it through the bridge, and it ends with the bridge.
    const hubCommand = hub && [
      hub.bridge,
      "env",
      `OPENCODE_RESOURCES_HUB_STATE=${hub.state}`,
      "OPENCODE_RESOURCES_HUB_PORT=0",
      "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      `/mnt/mac${hub.bun}`,
      path.join(source, "packages/plugin-app-custom/dist/resources/hub/bin.js"),
    ]
    await privateFile(
      path.join(home, "launch.ts"),
      [
        'const env = await Bun.file(new URL("./environment.json", import.meta.url)).json()',
        `const log = Bun.file(${JSON.stringify(path.join(home, "server.log"))})`,
        `const hubLog = Bun.file(${JSON.stringify(path.join(home, "hub.log"))})`,
        `const hubCommand = ${JSON.stringify(hubCommand ?? null)}`,
        'const hub = hubCommand ? Bun.spawn(hubCommand, { stdin: "ignore", stdout: hubLog, stderr: hubLog }) : undefined',
        `const child = Bun.spawn(${JSON.stringify([process.execPath, path.join(source, "packages/cli/script/custom-server.ts")])}, { cwd: ${JSON.stringify(source)}, env, stdin: "ignore", stdout: log, stderr: log })`,
        "const forward = (signal) => { child.kill(signal); hub?.kill(signal) }",
        'process.on("SIGINT", () => forward("SIGINT"))',
        'process.on("SIGTERM", () => forward("SIGTERM"))',
        "const code = await child.exited",
        'hub?.kill("SIGTERM")',
        "await hub?.exited",
        "process.exit(code)",
      ].join("\n"),
    )
    // Let the real server create/migrate its schema before copying only credentials.
    await start(identity)
    if (!(await Bun.file(path.join(home, "credentials-copied.json")).exists())) {
      await stop(identity)
      copyCredentials(manual.database, runtime.OPENCODE_CUSTOM_DB)
      await chmod(runtime.OPENCODE_CUSTOM_DB, 0o600)
      await privateFile(
        path.join(home, "credentials-copied.json"),
        JSON.stringify({ copiedAt: new Date().toISOString() }),
      )
      await start(identity)
    }
    await requirePlugin(identity)
    await requireHub(identity)
    report(identity)
  } finally {
    await rm(path.join(home, ".up-lock"), { recursive: true, force: true })
  }
}

/**
 * Copies only `credential` from production. Production opens read-only (`SQLITE_OPEN_READONLY`, no create): a URI
 * filename such as `file:…?mode=ro` is not honored by Bun's SQLite on Linux, which then fails with SQLITE_CANTOPEN.
 * The rows are read in one statement (a consistent snapshot under WAL) and written to the sandbox in one transaction,
 * through the columns both schemas share, since the sandbox may run newer migrations than production.
 */
function copyCredentials(production: string, sandbox: string) {
  const source = new Database(production, { readonly: true })
  const target = new Database(sandbox)
  try {
    const columns = (db: Database) =>
      db
        .query<{ name: string }, []>("PRAGMA table_info(credential)")
        .all()
        .map((column) => column.name)
    const available = new Set(columns(source))
    const shared = columns(target).filter((column) => available.has(column))
    if (!shared.length) throw new Error("No credential columns shared between production and the sandbox")
    const list = shared.map((column) => `"${column}"`).join(", ")
    const rows = source.query(`SELECT ${list} FROM credential`).values()
    const insert = target.prepare(
      `INSERT OR REPLACE INTO credential (${list}) VALUES (${shared.map(() => "?").join(", ")})`,
    )
    target.transaction(() => rows.forEach((row) => insert.run(...row)))()
  } finally {
    source.close()
    target.close()
  }
}

async function copyConfig(from: string, to: string) {
  await mkdir(to, { recursive: true, mode: 0o700 })
  const entries = await readdir(from, { withFileTypes: true })
  await Promise.all(
    entries
      .filter(
        (entry) =>
          !/^(?:\.git|\.DS_Store|backups?|service(?:-.*)?\.json)$|(?:\.bak|\.backup|\.before-|\.pre-)|(?:package-lock\.json|bun\.lock)$/.test(
            entry.name,
          ),
      )
      .map(async (entry) => {
        const input = path.join(from, entry.name)
        const output = path.join(to, entry.name)
        const info = await stat(input)
        if (info.isDirectory()) return copyConfig(input, output)
        await Bun.write(output, Bun.file(input))
        await chmod(output, 0o600)
      }),
  )
}

async function privateFile(file: string, value: string) {
  await Bun.write(file, value, { mode: 0o600 })
  await chmod(file, 0o600)
}

async function run(command: string[], cwd = home, env: NodeJS.ProcessEnv = process.env) {
  const child = Bun.spawn(command, { cwd, env, stdin: "ignore", stdout: "pipe", stderr: "pipe" })
  const [output] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()])
  if (await child.exited)
    throw new Error(`${path.basename(command[0])} failed; output withheld because configuration may contain secrets`)
  return output
}

async function hasSession() {
  const child = Bun.spawn(["tmux", "list-sessions", "-F", "#{session_name}"], { stdout: "pipe", stderr: "ignore" })
  const names = await new Response(child.stdout).text()
  return (await child.exited) === 0 && names.split("\n").includes(session)
}

async function owned(identity: Owner) {
  return (
    (await hasSession()) &&
    (await run(["tmux", "show-options", "-t", session, "-v", "@opencode-sandbox"])).trim() === identity.token
  )
}

async function start(identity: Owner) {
  await privateFile(path.join(home, "server.log"), "")
  await run([
    "tmux",
    "new-session",
    "-d",
    "-s",
    session,
    `${quote(process.execPath)} ${quote(path.join(home, "launch.ts"))}`,
  ])
  await run(["tmux", "set-option", "-t", session, "@opencode-sandbox", identity.token])
  await until(async () => Boolean(await health()), "Sandbox did not become healthy; inspect its private server.log")
}

async function stop(identity: Owner) {
  if (!(await hasSession())) return
  if (!(await owned(identity))) throw new Error("tmux ownership does not match; refusing to stop it")
  await run(["tmux", "send-keys", "-t", session, "C-c"])
  await until(
    async () => !(await hasSession()) && !(await listening()),
    "Sandbox did not stop gracefully; inspect its tmux session",
  )
}

async function health(): Promise<{ version: string } | undefined> {
  if (!(await Bun.file(path.join(home, "password")).exists())) return
  const password = (await Bun.file(path.join(home, "password")).text()).trim()
  return fetch(`${url}/api/info`, {
    headers: { authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}` },
    signal: AbortSignal.timeout(2000),
    redirect: "error",
  })
    .then(async (response) => (response.ok ? await response.json() : undefined))
    .catch(() => undefined)
}

/**
 * A plugin that fails to load leaves the server healthy without any custom RPC, tool or route, and a sandbox in that
 * state would let every custom test pass without testing anything. Wait for a custom RPC to answer; stop the sandbox
 * and fail when the plugin reports a load failure or never answers.
 */
async function requirePlugin(identity: Owner) {
  if (await pluginLoaded()) return
  await stop(identity)
  throw new Error(
    "The custom plugin did not load, so the sandbox was stopped. Its private server.log names the cause " +
      '(search "failed to load plugin"); a non-TypeScript file missing from packages/plugin-app-custom/dist is a usual one.',
  )
}

async function pluginLoaded() {
  const deadline = Date.now() + 60_000
  const plugin = path.join(source, "packages/plugin-app-custom/dist")
  while (Date.now() < deadline) {
    const answer = await request<{ output?: unknown }>("/api/rpc/custom.preferences/get", { input: {} })
    if (answer?.output !== undefined) return true
    // A plugin still activating answers rpc.unavailable for a moment; one that failed to load is listed at once.
    const plugins = await request<{ data?: { source?: { path?: string }; state?: { status?: string } }[] }>(
      "/api/plugin",
    )
    if (plugins?.data?.some((item) => item.source?.path === plugin && item.state?.status === "failed")) return false
    await Bun.sleep(500)
  }
  return false
}

async function request<T>(route: string, body?: unknown): Promise<T | undefined> {
  const password = (await Bun.file(path.join(home, "password")).text()).trim()
  return fetch(`${url}${route}`, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(5000),
    redirect: "error",
  })
    .then((response) => response.json() as Promise<T>)
    .catch(() => undefined)
}

async function listening() {
  return new Promise<boolean>((resolve) => {
    const socket = net.connect(port, "127.0.0.1")
    socket.once("connect", () => {
      socket.destroy()
      resolve(true)
    })
    socket.once("error", () => resolve(false))
  })
}

async function until(condition: () => Promise<boolean>, message: string) {
  const deadline = Date.now() + 90_000
  while (Date.now() < deadline) {
    if (await condition()) return
    await Bun.sleep(200)
  }
  throw new Error(message)
}

function quote(value: string) {
  return `'${value.replaceAll("'", "'\\''")}'`
}

function report(identity: Owner) {
  const hub = macHub(identity)
  console.log(
    `Ready: ${url}\nHome: ${home}\ntmux: ${session}\nPassword file: ${path.join(home, "password")}` +
      (hub ? `\nResources hub (Mac): ${hub.state}` : ""),
  )
}

/**
 * On the OrbStack Linux machine simulators, emulators and Chrome live on the Mac, so the sandbox runs its own hub
 * there: the worktree's built hub (`dist/resources/hub/bin.js`, read by the Mac through OrbStack's mount) with the
 * Mac runtime's Bun, its state under `~/.local/state/opencode-sandbox-hubs/<sandbox token>` and any free port. It
 * never shares production's hub (4179, `~/.local/share/opencode-resources-hub`). Elsewhere (macOS, plain Linux) the
 * plugin starts a local hub in the sandbox's own state directory instead.
 */
function macHub(identity: Owner) {
  const bridge = process.platform === "linux" ? Bun.which("mac") : null
  if (!bridge) return
  const user = os.userInfo().username
  return {
    bridge,
    state: `/Users/${user}/.local/state/opencode-sandbox-hubs/${identity.token}`,
    bun: `/Users/${user}/.local/share/opencode-custom-v2/bin/bun`,
    // Where the Mac sees this machine's files, for the hub's working-directory map.
    mount: `/Users/${user}/OrbStack/dev`,
  }
}
type MacHub = NonNullable<ReturnType<typeof macHub>>

async function onMac(hub: MacHub, args: string[]) {
  const child = Bun.spawn([hub.bridge, ...args], {
    cwd: os.homedir(),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
    timeout: 15_000,
  })
  const [output, code] = await Promise.all([new Response(child.stdout).text(), child.exited])
  return code === 0 ? output : undefined
}

/**
 * Host, port and secret of the sandbox's hub, wherever it runs: the Mac hub (`macHub`), or the hub the plugin
 * started in the sandbox's state directory. Undefined until it writes its `hub.json`.
 */
async function hubAccess(identity: Owner) {
  const hub = macHub(identity)
  const text = hub
    ? await onMac(hub, ["/mnt/mac/bin/cat", `/mnt/mac${hub.state}/hub.json`])
    : await Bun.file(path.join(home, "xdg/state/opencode/resources-hub/hub.json"))
        .text()
        .catch(() => undefined)
  const info: { port?: unknown; secret?: unknown } | undefined = await Promise.resolve()
    .then(() => (text ? JSON.parse(text) : undefined))
    .catch(() => undefined)
  if (typeof info?.port !== "number" || typeof info.secret !== "string") return
  return { host: hub ? hubHost : "127.0.0.1", port: info.port, secret: info.secret }
}

async function hubReady(identity: Owner) {
  const access = await hubAccess(identity)
  if (!access) return false
  return fetch(`http://${access.host}:${access.port}/admin/health`, {
    headers: { authorization: `Bearer ${access.secret}` },
    signal: AbortSignal.timeout(2_000),
  })
    .then((response) => response.ok)
    .catch(() => false)
}

/** Like the plugin check: a sandbox whose hub never came up would make resource tests pass against nothing. */
async function requireHub(identity: Owner) {
  const hub = macHub(identity)
  if (!hub) return
  const deadline = Date.now() + 60_000
  while (Date.now() < deadline) {
    if (await hubReady(identity)) return
    await Bun.sleep(500)
  }
  await stop(identity)
  throw new Error(
    `The sandbox resources hub did not start on the Mac, so the sandbox was stopped. See ${path.join(home, "hub.log")}.`,
  )
}

/**
 * After a clean hub exit (its `hub.json` is gone and its serve-sim helpers were stopped), the Mac state is removed.
 * After an abrupt one it is kept, so the next `up` of this sandbox recovers the helpers it recorded.
 */
async function removeHubState(hub: MacHub) {
  const removed = await onMac(hub, [
    "/mnt/mac/bin/sh",
    "-c",
    'test ! -e "$1/hub.json" && rm -rf "$1"',
    "sandbox-hub",
    `/mnt/mac${hub.state}`,
  ])
  if (removed === undefined) console.log(`Kept the resources hub state on the Mac: ${hub.state}`)
}
