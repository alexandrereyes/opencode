import { randomBytes } from "node:crypto"
import fs from "node:fs/promises"
import path from "node:path"
import { writeConfig } from "../adapters/chrome.js"
import { adapters } from "../adapters/index.js"
import { text } from "../adapters/process.js"
import { parseSimulators } from "../discovery.js"
import { createHub, protocol } from "./hub.js"

/** Argument that makes the bundled plugin (`plugin/index.js`) run the hub instead of exporting the plugin. */
export const flag = "--opencode-resources-hub"

/**
 * Hub process entry. Environment: `OPENCODE_RESOURCES_HUB_STATE` (required directory),
 * `OPENCODE_RESOURCES_HUB_PORT` (0 or unset = any free port), `OPENCODE_RESOURCES_HUB_PARENT` (server PID; the hub
 * exits when it dies; unset for a standalone hub, such as the Mac's LaunchAgent serving a remote server). Writes
 * `hub.json` ({ protocol, pid, port, secret }, mode 0600) once it listens, and `playwright-cli.json`, the config Mac
 * shells point `PLAYWRIGHT_MCP_CONFIG` to when the plugin cannot set it for them.
 */
export async function main() {
  const state = process.env.OPENCODE_RESOURCES_HUB_STATE
  if (!state) throw new Error("OPENCODE_RESOURCES_HUB_STATE is required")
  // Set only so the compiled server binary behaves as Bun; adapters' child processes must not inherit it.
  delete process.env.BUN_BE_BUN
  await fs.mkdir(state, { recursive: true, mode: 0o700 })
  const lock = path.join(state, "hub.lock")
  if (!(await acquire(lock))) return
  await Promise.all(Object.values(adapters).map((adapter) => adapter.recover?.()))
  const secret = randomBytes(32).toString("base64url")
  await writeConfig(path.join(state, "playwright-cli.json"))
  const hub = createHub({
    adapters,
    secret,
    file: path.join(state, "resources.json"),
    simulators: async () => parseSimulators(JSON.parse(await text(["xcrun", "simctl", "list", "devices", "-j"]))),
  })
  await hub.start()
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: Number(process.env.OPENCODE_RESOURCES_HUB_PORT ?? 0),
    idleTimeout: 120,
    fetch: hub.fetch,
    websocket: hub.websocket,
  })
  const info = path.join(state, "hub.json")
  await Bun.write(`${info}.tmp`, JSON.stringify({ protocol, pid: process.pid, port: server.port, secret }), {
    mode: 0o600,
  })
  await fs.chmod(`${info}.tmp`, 0o600)
  await fs.rename(`${info}.tmp`, info)
  const parent = Number(process.env.OPENCODE_RESOURCES_HUB_PARENT ?? 0)
  const stop = async () => {
    hub.close()
    void server.stop(true)
    const current: unknown = await Bun.file(info)
      .json()
      .catch(() => undefined)
    if (typeof current === "object" && current !== null && "pid" in current && current.pid === process.pid)
      await fs.rm(info, { force: true })
    await fs.rm(lock, { force: true })
    process.exit(0)
  }
  process.on("SIGTERM", () => void stop())
  process.on("SIGINT", () => void stop())
  if (parent > 0) setInterval(() => !alive(parent) && void stop(), 2_000)
}

/** One hub per state directory: the lock file holds the owner's PID; a dead owner's lock is taken over. */
async function acquire(lock: string): Promise<boolean> {
  // The lock appears with its owner's PID already in it (written aside, then hard-linked into place). Created empty and
  // filled afterwards, a hub started at the same moment read it as ownerless, took it over, and both hubs served.
  const claim = `${lock}.${process.pid}`
  await fs.writeFile(claim, String(process.pid), { mode: 0o600 })
  const take = () =>
    fs.link(claim, lock).then(
      () => true,
      () => false,
    )
  const acquired = (await take()) || ((await abandoned(lock)) && (await take()))
  await fs.rm(claim, { force: true })
  return acquired
}

async function abandoned(lock: string) {
  const owner = Number(await fs.readFile(lock, "utf8").catch(() => "0"))
  if (owner > 0 && owner !== process.pid && alive(owner)) return false
  await fs.rm(lock, { force: true })
  return true
}

function alive(pid: number) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}
