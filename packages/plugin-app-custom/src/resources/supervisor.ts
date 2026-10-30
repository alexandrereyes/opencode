import { existsSync } from "node:fs"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Option, Schema } from "effect"
import type { Simulator } from "./discovery.js"
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
 * Translates directories between this server and a hub on another machine: `local=hub` prefix pairs separated by
 * `:`, for example `/home/alexandremartins=/Users/alexandremartins/OrbStack/dev/home/alexandremartins`. Paths outside
 * every prefix stay as they are.
 */
export function pathMap(spec: string | undefined) {
  const trim = (value: string) => (value.length > 1 ? value.replace(/\/+$/, "") : value)
  const pairs = (spec ?? "").split(":").flatMap((entry) => {
    const split = entry.indexOf("=")
    if (split <= 0 || split === entry.length - 1) return []
    return [[trim(entry.slice(0, split)), trim(entry.slice(split + 1))] as const]
  })
  const swap = (value: string, from: string, to: string) =>
    value === from ? to : value.startsWith(`${from}/`) ? `${to}${value.slice(from.length)}` : undefined
  const apply = (value: string, toHub: boolean) => {
    for (const [local, hub] of pairs) {
      const result = toHub ? swap(value, local, hub) : swap(value, hub, local)
      if (result !== undefined) return result
    }
    return value
  }
  return { toHub: (value: string) => apply(value, true), fromHub: (value: string) => apply(value, false) }
}
export type PathMap = ReturnType<typeof pathMap>

export interface HubSettings {
  readonly state: string
  readonly command?: readonly string[]
  /**
   * A hub another machine runs (the Mac's LaunchAgent for a server on Linux): its `hub.json` as this machine reads it
   * and the host that reaches its loopback port. The plugin never starts, stops or inspects that hub's process.
   */
  readonly remote?: { readonly info: string; readonly host: string }
  readonly paths?: PathMap
}

/**
 * Hub settings from the server environment. `OPENCODE_RESOURCES_HUB_REMOTE_INFO` (path of the remote hub's
 * `hub.json`) turns on remote mode, with `OPENCODE_RESOURCES_HUB_REMOTE_HOST` (default `127.0.0.1`) and
 * `OPENCODE_RESOURCES_HUB_PATH_MAP` (`pathMap`) for the working directories the hub sees.
 */
export function hubSettings(env: Record<string, string | undefined> = process.env): HubSettings {
  const info = env.OPENCODE_RESOURCES_HUB_REMOTE_INFO
  return {
    state: stateDirectory(env),
    ...(info ? { remote: { info, host: env.OPENCODE_RESOURCES_HUB_REMOTE_HOST || "127.0.0.1" } } : {}),
    ...(env.OPENCODE_RESOURCES_HUB_PATH_MAP ? { paths: pathMap(env.OPENCODE_RESOURCES_HUB_PATH_MAP) } : {}),
  }
}

/**
 * The plugin's view of the hub process. Every Location's plugin instance has one; they share the hub through
 * `hub.json`. `spawn: true` starts the hub when it is not running (the server PID is its parent: it exits with it).
 * A remote hub is only read: it is never started or shut down here, and its `hub.json` is read again whenever a
 * request cannot connect or is refused (a restarted hub has a new secret).
 */
export function makeHubClient(options: HubSettings) {
  const remote = options.remote
  const file = remote?.info ?? path.join(options.state, "hub.json")
  const origin = (info: Info) => `http://${remote?.host ?? "127.0.0.1"}:${info.port}`
  const toHub = options.paths?.toHub ?? ((value: string) => value)
  const fromHub = options.paths?.fromHub ?? ((value: string) => value)
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
    fetch(`${origin(info)}/admin/health`, {
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
    if (remote) return undefined
    if (current && health === "stale")
      await fetch(`${origin(current)}/admin/shutdown`, {
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
    if (!spawn && !remote) {
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
      const response = await fetch(`${origin(info)}${route}`, {
        ...init,
        headers: { ...init.headers, authorization: `Bearer ${info.secret}`, "content-type": "application/json" },
      }).catch(() => undefined)
      if (response && response.status !== 401) return response
      cached = undefined
      return retry ? attempt(false) : undefined
    }
    return attempt(true)
  }

  const unavailable = () =>
    new HubError(
      "hub",
      remote
        ? `The resources hub at ${remote.host} (${remote.info}) is not reachable`
        : "The resources hub is not running",
    )

  // The hub keeps working directories as its own machine sees them; this side works with local ones.
  const localMeta = <M extends Resources.Meta>(meta: M): M =>
    meta.kind === "chrome" && meta.workspace ? { ...meta, workspace: fromHub(meta.workspace) } : meta
  const hubMeta = <M extends Resources.Meta>(meta: M): M =>
    meta.kind === "chrome" && meta.workspace ? { ...meta, workspace: toHub(meta.workspace) } : meta
  const local = <R extends { readonly meta: Resources.Meta }>(resource: R): R => ({
    ...resource,
    meta: localMeta(resource.meta),
  })

  const json = async <T>(route: string, init: RequestInit & { readonly spawn?: boolean } = {}): Promise<T> => {
    const response = await request(route, init)
    if (!response) throw unavailable()
    if (response.status === 404) throw new HubError("not_found", "Resource not found")
    if (!response.ok) throw new HubError("failed", (await response.text()) || `Hub answered ${response.status}`)
    return (await response.json()) as T
  }

  const resource = (id: string) => `/admin/resources/${encodeURIComponent(id)}`

  return {
    /** Whether the hub runs on another machine (`HubSettings.remote`). */
    remote: remote !== undefined,
    /** The hub's loopback port as it announces it; clients on its machine connect there. */
    port: async () => (await ensure(true))?.port,
    /** `spawn: false` reads only a hub already running (no hub, no resources). */
    list: (spawn = true) =>
      json<{ resources: Resources.Resource[] }>("/admin/resources", { spawn }).then((result) => ({
        resources: result.resources.map(local),
      })),
    get: (id: string) => json<Resources.Resource>(resource(id)).then(local),
    upsert: (input: Upsert) =>
      json<Resources.Resource>("/admin/resources", {
        method: "PUT",
        body: JSON.stringify({ ...input, meta: hubMeta(input.meta) }),
      }).then(local),
    remove: (id: string) => json<{}>(resource(id), { method: "DELETE" }),
    control: (id: string, action: "take" | "renew" | "release") =>
      json<{ resource: Resources.Resource; token?: string }>(`${resource(id)}/control`, {
        method: "POST",
        body: JSON.stringify({ action }),
      }).then((result) => ({ ...result, resource: local(result.resource) })),
    /** The iOS simulators of the hub's machine (`simctl` runs there). Never starts the hub. */
    simulators: () =>
      json<{ simulators: Simulator[] }>("/admin/simulators", { spawn: false }).then((result) => result.simulators),
    ticket: (id: string, capability: Resources.Capability) =>
      json<{ ticket: string; expiresAt: number }>("/admin/tickets", {
        method: "POST",
        body: JSON.stringify({ id, capability }),
      }),
    snapshot: async (id: string, maxWidth?: number) => {
      const response = await request(`${resource(id)}/snapshot${maxWidth ? `?maxWidth=${maxWidth}` : ""}`)
      if (!response) throw unavailable()
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
    /** Ends a shell command on the resources it named. Never starts the hub: only a running one marked it. */
    end: (call: string) =>
      json<{}>(`/admin/calls/${encodeURIComponent(call)}/end`, { method: "POST", spawn: false }).then(
        () => undefined,
        () => undefined,
      ),
    /**
     * Never starts the hub: no hub means no locks. A remote hub should always answer; `undefined` says it did not, so
     * nobody knows which resources Alexandre holds.
     */
    locks: () =>
      json<{ locks: Lock[] }>("/admin/locks", { spawn: false }).then(
        (result): Lock[] | undefined => result.locks.map(local),
        () => (remote ? undefined : []),
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
