#!/usr/bin/env bun

import { Database } from "bun:sqlite"
import { chmod, mkdir, readdir, realpath, rm, stat } from "node:fs/promises"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { parseArgs } from "node:util"
import { settings } from "./custom-release"
import { buildMacData, signingIdentity } from "./custom-signing"

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
if (!Number.isInteger(port) || port < 1024 || port > 65535 || [4096, 4178].includes(port))
  throw new Error("Choose a non-production port between 1024 and 65535 (never 4096 or 4178)")
const watchPort = Number(args.values["watch-port"])
if (!Number.isInteger(watchPort) || watchPort < 0 || watchPort > 65535 || [4096, 4178, 4192, port].includes(watchPort))
  throw new Error(
    "Choose a sandbox watch gateway port other than 4096, 4178, 4192 and the server port (0 = any free port)",
  )
if (!["up", "down", "status"].includes(action))
  throw new Error("Usage: custom-sandbox.ts up|down|status [--port N] [--home PATH]")
const home = path.resolve(
  args.values.home ?? path.join(await realpath(os.tmpdir()), "opencode", `custom-sandbox-${port}`),
)
const session = `custom-sandbox-${port}`
const url = `http://127.0.0.1:${port}`
const marker = Bun.file(path.join(home, "sandbox.json"))
type Owner = { format: 1; home: string; port: number; token: string; source: string }
const owner: Owner | undefined = (await marker.exists()) ? await marker.json() : undefined
if (owner && (owner.format !== 1 || owner.home !== home || owner.port !== port))
  throw new Error("Sandbox ownership does not match --home/--port")

if (action === "status") {
  const info = await health()
  console.log(
    JSON.stringify({ health: info ? "ready" : "stopped", version: info?.version, url, home, session }, null, 2),
  )
}
if (action === "down") {
  if (!owner) throw new Error("No sandbox ownership record; refusing to stop anything")
  await stop(owner)
  console.log(`Stopped ${session}; preserved ${home}`)
}
if (action === "up") await up()

async function up() {
  if (await health()) {
    if (!owner || !(await owned(owner))) throw new Error("Port is healthy but is not owned by this sandbox")
    return report()
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
    // Production's certificate gives the sandbox helper the same TCC identity, so grants carry over.
    const macData =
      process.platform === "darwin"
        ? await buildMacData(
            await signingIdentity(
              (await Bun.file(path.join(installed, "signing/signing.keychain-db")).exists()) ? installed : home,
            ),
            source,
            path.join(home, "mac-data"),
          )
        : undefined
    const runtime = {
      ...environment,
      ...(macData ? { OPENCODE_MAC_DATA_HELPER: path.join(macData, "Contents/MacOS/opencode-mac-data") } : {}),
      OPENCODE_CUSTOM_HOME: home,
      OPENCODE_CUSTOM_COMMIT: commit,
      OPENCODE_CUSTOM_PORT: String(port),
      // Production's fixed resources hub port (4179) must not be inherited: let the sandbox hub pick a free one.
      OPENCODE_RESOURCES_HUB_PORT: undefined,
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
    console.log("Building the custom plugin and web assets (service worker disabled)…")
    await run([process.execPath, "run", "build"], path.join(source, "packages/plugin-app-custom"))
    await run([process.execPath, "run", "build"], path.join(source, "packages/app-custom"), {
      ...process.env,
      VITE_OPENCODE_DISABLE_SERVICE_WORKER: "1",
    })
    if (!(await Bun.file(path.join(source, "packages/app-custom/dist/index.html")).exists()))
      throw new Error("Web build did not produce dist/index.html")
    await privateFile(
      path.join(home, "launch.ts"),
      [
        'const env = await Bun.file(new URL("./environment.json", import.meta.url)).json()',
        `const log = Bun.file(${JSON.stringify(path.join(home, "server.log"))})`,
        `const child = Bun.spawn(${JSON.stringify([process.execPath, path.join(source, "packages/cli/script/custom-server.ts")])}, { cwd: ${JSON.stringify(source)}, env, stdin: "ignore", stdout: log, stderr: log })`,
        'process.on("SIGINT", () => child.kill("SIGINT"))',
        'process.on("SIGTERM", () => child.kill("SIGTERM"))',
        "process.exit(await child.exited)",
      ].join("\n"),
    )
    // Let the real server create/migrate its schema before copying only credentials.
    await start(identity)
    if (!(await Bun.file(path.join(home, "credentials-copied.json")).exists())) {
      await stop(identity)
      const db = new Database(runtime.OPENCODE_CUSTOM_DB)
      try {
        db.exec("ATTACH DATABASE ? AS production", [`file:${manual.database}?mode=ro`])
        db.transaction(() => {
          db.exec("INSERT OR REPLACE INTO main.credential SELECT * FROM production.credential")
        })()
        db.exec("DETACH DATABASE production")
      } finally {
        db.close()
      }
      await chmod(runtime.OPENCODE_CUSTOM_DB, 0o600)
      await privateFile(
        path.join(home, "credentials-copied.json"),
        JSON.stringify({ copiedAt: new Date().toISOString() }),
      )
      await start(identity)
    }
    report()
  } finally {
    await rm(path.join(home, ".up-lock"), { recursive: true, force: true })
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

function report() {
  console.log(`Ready: ${url}\nHome: ${home}\ntmux: ${session}\nPassword file: ${path.join(home, "password")}`)
}
