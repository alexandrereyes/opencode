import { existsSync } from "node:fs"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Option, Schema } from "effect"
import { protocol, type HubEvent, type Lock, type Upsert } from "./hub/hub.js"
import { flag } from "./hub/main.js"
import { Resources } from "./rpc.js"

const Info = Schema.Struct({ protocol: Schema.Number, pid: Schema.Number, port: Schema.Number, secret: Schema.String })
type Info = typeof Info.Type
const decodeInfo = Schema.decodeUnknownOption(Info)

export class HubError extends Error {
  constructor(
    readonly reason: "hub" | "not_found" | "failed",
    message: string,
  ) {
    super(message)
  }
}

/** Where the hub keeps `hub.json`, its registry and its log: one hub per server state directory. */
export function stateDirectory(env: Record<string, string | undefined> = process.env) {
  if (env.OPENCODE_RESOURCES_HUB_STATE) return env.OPENCODE_RESOURCES_HUB_STATE
  return path.join(env.XDG_STATE_HOME || path.join(os.homedir(), ".local/state"), "opencode", "resources-hub")
}

/** Command that starts the hub: its `bin` beside this module in source/dist, or the release bundle itself. */
export function hubCommand(module = fileURLToPath(import.meta.url), exec = process.execPath) {
  const bin = path.join(path.dirname(module), "hub", module.endsWith(".ts") ? "bin.ts" : "bin.js")
  return existsSync(bin) ? [exec, bin] : [exec, module, flag]
}

/**
 * The plugin's view of the hub process. Every Location's plugin instance has one; they share the hub through
 * `hub.json`. `spawn: true` starts the hub when it is not running (the server PID is its parent: it exits with it).
 */
export function makeHubClient(options: { readonly state: string; readonly command?: readonly string[] }) {
  const file = path.join(options.state, "hub.json")
  let cached: Info | undefined
  let starting: Promise<Info | undefined> | undefined

  const read = async () =>
    Option.getOrUndefined(
      decodeInfo(
        await Bun.file(file)
          .json()
          .catch(() => undefined),
      ),
    )

  const healthy = (info: Info) =>
    fetch(`http://127.0.0.1:${info.port}/admin/health`, {
      headers: { authorization: `Bearer ${info.secret}` },
      signal: AbortSignal.timeout(1_500),
    })
      .then(async (response) => {
        if (!response.ok) return "down" as const
        const body: unknown = await response.json()
        return typeof body === "object" && body !== null && "protocol" in body && body.protocol === protocol
          ? ("ok" as const)
          : ("stale" as const)
      })
      .catch(() => "down" as const)

  const start = async (): Promise<Info | undefined> => {
    const current = await read()
    const health = current ? await healthy(current) : "down"
    if (current && health === "ok") return current
    if (current && health === "stale")
      await fetch(`http://127.0.0.1:${current.port}/admin/shutdown`, {
        method: "POST",
        headers: { authorization: `Bearer ${current.secret}` },
      }).catch(() => undefined)
    const command = options.command ?? hubCommand()
    await fs.mkdir(options.state, { recursive: true, mode: 0o700 })
    const child = Bun.spawn([...command], {
      env: {
        ...process.env,
        BUN_BE_BUN: "1",
        OPENCODE_RESOURCES_HUB_STATE: options.state,
        OPENCODE_RESOURCES_HUB_PARENT: String(process.pid),
      },
      stdin: "ignore",
      stdout: Bun.file(path.join(options.state, "hub.log")),
      stderr: Bun.file(path.join(options.state, "hub.log")),
    })
    child.unref()
    for (const _ of Array.from({ length: 50 })) {
      await Bun.sleep(100)
      const next = await read()
      if (next && next.pid !== current?.pid && (await healthy(next)) === "ok") return next
    }
    // Another plugin instance may have won the start race; use whatever hub is healthy now.
    const winner = await read()
    return winner && (await healthy(winner)) === "ok" ? winner : undefined
  }

  const ensure = async (spawn: boolean) => {
    if (cached) return cached
    if (!spawn) {
      const current = await read()
      if (current && (await healthy(current)) === "ok") cached = current
      return cached
    }
    starting ??= start().finally(() => (starting = undefined))
    cached = await starting
    return cached
  }

  const request = async (route: string, init: RequestInit & { readonly spawn?: boolean } = {}) => {
    const attempt = async (retry: boolean): Promise<Response | undefined> => {
      const info = await ensure(init.spawn ?? true)
      if (!info) return undefined
      const response = await fetch(`http://127.0.0.1:${info.port}${route}`, {
        ...init,
        headers: { ...init.headers, authorization: `Bearer ${info.secret}`, "content-type": "application/json" },
      }).catch(() => undefined)
      if (response && response.status !== 401) return response
      cached = undefined
      return retry ? attempt(false) : undefined
    }
    return attempt(true)
  }

  const json = async <T>(route: string, init: RequestInit & { readonly spawn?: boolean } = {}): Promise<T> => {
    const response = await request(route, init)
    if (!response) throw new HubError("hub", "The resources hub is not running")
    if (response.status === 404) throw new HubError("not_found", "Resource not found")
    if (!response.ok) throw new HubError("failed", (await response.text()) || `Hub answered ${response.status}`)
    return (await response.json()) as T
  }

  const resource = (id: string) => `/admin/resources/${encodeURIComponent(id)}`

  return {
    port: async () => (await ensure(true))?.port,
    list: () => json<{ resources: Resources.Resource[] }>("/admin/resources"),
    get: (id: string) => json<Resources.Resource>(resource(id)),
    upsert: (input: Upsert) =>
      json<Resources.Resource>("/admin/resources", { method: "PUT", body: JSON.stringify(input) }),
    remove: (id: string) => json<{}>(resource(id), { method: "DELETE" }),
    control: (id: string, action: "take" | "renew" | "release") =>
      json<{ resource: Resources.Resource; token?: string }>(`${resource(id)}/control`, {
        method: "POST",
        body: JSON.stringify({ action }),
      }),
    ticket: (id: string, capability: Resources.Capability) =>
      json<{ ticket: string; expiresAt: number }>("/admin/tickets", {
        method: "POST",
        body: JSON.stringify({ id, capability }),
      }),
    snapshot: async (id: string, maxWidth?: number) => {
      const response = await request(`${resource(id)}/snapshot${maxWidth ? `?maxWidth=${maxWidth}` : ""}`)
      if (!response) throw new HubError("hub", "The resources hub is not running")
      if (response.status === 404) throw new HubError("not_found", "Resource not found")
      if (!response.ok) throw new HubError("failed", (await response.text()) || "Snapshot failed")
      const width = Number(response.headers.get("x-width") ?? 0)
      const height = Number(response.headers.get("x-height") ?? 0)
      return {
        mime: response.headers.get("content-type") === "image/png" ? ("image/png" as const) : ("image/jpeg" as const),
        data: Buffer.from(await response.arrayBuffer()).toString("base64"),
        takenAt: Number(response.headers.get("x-taken-at") ?? Date.now()),
        ...(width > 0 ? { width, height } : {}),
      }
    },
    /** Never starts the hub: no hub means no locks. */
    locks: () =>
      json<{ locks: Lock[] }>("/admin/locks", { spawn: false }).then(
        (result) => result.locks,
        () => [] as Lock[],
      ),
    /** Long-polls the hub's event queue; each event goes to exactly one plugin instance. Never starts the hub. */
    events: (wait: number) =>
      json<{ events: HubEvent[] }>(`/admin/events?wait=${wait}`, {
        method: "POST",
        spawn: false,
        signal: AbortSignal.timeout(wait + 5_000),
      }).then(
        (result) => result.events,
        () => [] as HubEvent[],
      ),
  }
}

export type HubClient = ReturnType<typeof makeHubClient>
