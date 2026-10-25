import { randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import path from "node:path"
import type { Server, ServerWebSocket } from "bun"
import { optional } from "@opencode/schema/schema"
import { Option, Schema } from "effect"
import { jpeg, size } from "../adapters/process.js"
import type { Adapter, Entry, Image, StreamSink } from "../adapters/types.js"
import { ResourceProtocol } from "../protocol.js"
import { Resources } from "../rpc.js"
import { sign, verify } from "./ticket.js"

/** Bumped on incompatible admin API changes; the plugin replaces a hub that reports another value. */
export const protocol = 1

export interface HubOptions {
  readonly adapters: Readonly<Record<Resources.Kind, Adapter>>
  readonly secret: string
  /** Registry file; omitted keeps the registry in memory only. */
  readonly file?: string
  readonly now?: () => number
  readonly probeMs?: number
  /** Width of fallback (snapshot polling) stream frames. */
  readonly fallbackWidth?: number
}

export const Upsert = Schema.Struct({
  kind: Resources.Kind,
  meta: Resources.Meta,
  name: optional(Schema.String),
  purpose: optional(Schema.String),
  owner: optional(Resources.Owner),
  /** Marks an agent use now (state `agent`). */
  used: optional(Schema.Boolean),
})
export type Upsert = typeof Upsert.Type

export const ControlInput = Schema.Struct({ action: Schema.Literals(["take", "renew", "release"]) })
export const TicketInput = Schema.Struct({ id: Schema.String, capability: Resources.Capability })

export type HubEvent =
  | { readonly type: "changed"; readonly ids: readonly string[] }
  | {
      readonly type: "released"
      readonly id: string
      readonly kind: Resources.Kind
      readonly label: string
      readonly owner?: Resources.Owner
      readonly reason: "returned" | "expired"
    }

export interface Lock {
  readonly id: string
  readonly kind: Resources.Kind
  readonly label: string
  readonly meta: Resources.Meta
  readonly owner?: Resources.Owner
  readonly expiresAt: number
}

const StoredEntry = Schema.Struct({
  id: Schema.String,
  kind: Resources.Kind,
  name: optional(Schema.String),
  purpose: optional(Schema.String),
  owner: optional(Resources.Owner),
  meta: Resources.Meta,
  status: Schema.Literals(["running", "stopped", "gone"]),
  discoveredAt: Schema.Number,
  lastUsedAt: Schema.Number,
  updatedAt: Schema.Number,
})
const decodeStored = Schema.decodeUnknownOption(Schema.Array(StoredEntry))
const decodeUpsert = Schema.decodeUnknownOption(Upsert)
const decodeControl = Schema.decodeUnknownOption(ControlInput)
const decodeTicket = Schema.decodeUnknownOption(TicketInput)
const decodeClient = Schema.decodeUnknownOption(Schema.fromJsonString(ResourceProtocol.ClientMessage))
const decodeInputs = Schema.decodeUnknownOption(
  Schema.Struct({ events: Schema.Array(ResourceProtocol.Input).check(Schema.isMaxLength(64)) }),
)

type SocketData = { readonly id: string; readonly capability: Resources.Capability; readonly lock?: string }

interface Viewer {
  readonly lock?: string
  readonly capability: Resources.Capability
  waitingKeyframe: boolean
  text(message: ResourceProtocol.ServerMessage): void
  frame(encoded: Uint8Array, payload: Uint8Array, keyframe: boolean): void
  buffered(): number
  close(): void
}

interface Live {
  readonly controller: AbortController
  readonly viewers: Set<Viewer>
  hello?: ResourceProtocol.Hello
  /** Latest `meta`, replayed to viewers that join later (an iOS Simulator's rotation). */
  meta?: Record<string, unknown>
  keyframe?: { readonly encoded: Uint8Array; readonly payload: Uint8Array }
}

const maxBuffered = 2 * 1024 * 1024
const goneRetentionMs = 24 * 3_600_000
const stoppedRetentionMs = 7 * 24 * 3_600_000

/**
 * The resources hub: registry, Alexandre's control locks, tickets and the shared live streams. It runs in its own
 * process (see `main.ts`) so a crashing adapter cannot take the server down. `fetch` and `websocket` plug into
 * `Bun.serve`; `/admin/*` needs the secret as a bearer token, `/resources/*` needs a ticket.
 */
export function createHub(options: HubOptions) {
  const now = options.now ?? Date.now
  const entries = new Map<string, Entry>()
  const locks = new Map<string, { token: string; since: number; expiresAt: number }>()
  const lives = new Map<string, Live>()
  const snapshots = new Map<string, { at: number; image: Promise<Image> }>()
  const inputs = new Map<string, Promise<void>>()
  const pending: HubEvent[] = []
  const waiters = new Set<() => void>()
  let writing: ReturnType<typeof setTimeout> | undefined
  let probes = Promise.resolve()
  let probing = 0

  const load = async () => {
    if (!options.file) return
    const stored = await Bun.file(options.file)
      .json()
      .catch(() => [])
    Option.getOrElse(decodeStored(stored), () => []).forEach((entry) => entries.set(entry.id, entry))
  }

  const persist = () => {
    const file = options.file
    if (!file || writing) return
    writing = setTimeout(() => {
      writing = undefined
      const temporary = `${file}.${process.pid}.tmp`
      void Bun.write(temporary, JSON.stringify([...entries.values()]), { mode: 0o600 })
        .then(() => fs.rename(temporary, file))
        .catch((error) => console.error("resources hub: could not persist the registry", error))
    }, 300)
  }

  const emit = (event: HubEvent) => {
    const merged = event.type === "changed" ? pending.find((item) => item.type === "changed") : undefined
    if (merged && event.type === "changed" && merged.type === "changed")
      pending.splice(pending.indexOf(merged), 1, { type: "changed", ids: [...new Set([...merged.ids, ...event.ids])] })
    else pending.push(event)
    waiters.forEach((wake) => wake())
  }

  const changed = (...ids: string[]) => {
    persist()
    emit({ type: "changed", ids })
  }

  const view = (entry: Entry): Resources.Resource => {
    const lock = locks.get(entry.id)
    const at = now()
    const adapter = options.adapters[entry.kind]
    const state: Resources.State = lock
      ? "user"
      : entry.status !== "running"
        ? entry.status
        : at - entry.lastUsedAt < Resources.limits.agentRecentMs
          ? "agent"
          : at - entry.lastUsedAt < Resources.limits.liveRecentMs
            ? "live"
            : "idle"
    return {
      id: entry.id,
      kind: entry.kind,
      label: label(entry),
      ...(entry.purpose ? { purpose: entry.purpose } : {}),
      ...(entry.owner ? { owner: entry.owner } : {}),
      state,
      ...(lock ? { control: { holder: "user" as const, since: lock.since, expiresAt: lock.expiresAt } } : {}),
      meta: entry.meta,
      discoveredAt: entry.discoveredAt,
      lastUsedAt: entry.lastUsedAt,
      updatedAt: entry.updatedAt,
      live: { stream: adapter.stream !== undefined, input: adapter.input !== undefined },
    }
  }

  const upsert = (input: Upsert) => {
    const at = now()
    const existing = [...entries.values()].find(
      (entry) => entry.kind === input.kind && sameResource(entry.meta, input.meta),
    )
    const id = existing?.id ?? idFor(input.meta)
    const entry: Entry = {
      id,
      kind: input.kind,
      ...((input.name ?? existing?.name) ? { name: input.name ?? existing?.name } : {}),
      ...((input.purpose ?? existing?.purpose) ? { purpose: input.purpose ?? existing?.purpose } : {}),
      ...((input.owner ?? existing?.owner) ? { owner: input.owner ?? existing?.owner } : {}),
      meta: existing ? mergeMeta(existing.meta, input.meta) : input.meta,
      status: "running",
      discoveredAt: existing?.discoveredAt ?? at,
      lastUsedAt: input.used || !existing ? at : existing.lastUsedAt,
      updatedAt: at,
    }
    entries.set(id, entry)
    changed(id)
    void probe([entry.kind])
    return view(entry)
  }

  const remove = (id: string) => {
    const live = lives.get(id)
    live?.controller.abort()
    if (locks.has(id)) release(id, "returned")
    entries.delete(id)
    snapshots.delete(id)
    changed(id)
  }

  const broadcastControl = (id: string) => {
    const lock = locks.get(id)
    lives.get(id)?.viewers.forEach((viewer) =>
      viewer.text({
        type: "control",
        holder: lock ? "user" : null,
        ...(lock ? { expiresAt: lock.expiresAt } : {}),
        mine: lock !== undefined && viewer.lock === lock.token,
      }),
    )
  }

  const release = (id: string, reason: "returned" | "expired") => {
    if (!locks.delete(id)) return
    const entry = entries.get(id)
    broadcastControl(id)
    if (entry)
      emit({
        type: "released",
        id,
        kind: entry.kind,
        label: label(entry),
        ...(entry.owner ? { owner: entry.owner } : {}),
        reason,
      })
    changed(id)
  }

  const control = (id: string, action: "take" | "renew" | "release") => {
    const entry = entries.get(id)
    if (!entry) return undefined
    const at = now()
    if (action === "release") {
      release(id, "returned")
      return { resource: view(entry) }
    }
    const current = locks.get(id)
    if (action === "renew" && !current) return { resource: view(entry) }
    const lock = {
      token: current?.token ?? randomUUID(),
      since: current?.since ?? at,
      expiresAt: at + Resources.limits.controlIdleMs,
    }
    locks.set(id, lock)
    if (!current) {
      broadcastControl(id)
      changed(id)
    }
    return { resource: view(entry), token: lock.token }
  }

  const ticket = (id: string, capability: Resources.Capability) => {
    const lock = locks.get(id)
    if (!entries.has(id) || (capability === "control" && !lock)) return undefined
    const expiresAt = now() + Resources.limits.ticketMs
    return {
      ticket: sign(options.secret, {
        r: id,
        c: capability,
        e: expiresAt,
        ...(capability === "control" ? { l: lock?.token } : {}),
      }),
      expiresAt,
    }
  }

  const expire = () => {
    const at = now()
    ;[...locks.entries()].filter(([, lock]) => lock.expiresAt <= at).forEach(([id]) => release(id, "expired"))
  }

  // Serialized: an explicit probe after an upsert must observe the adapter, not skip a periodic one in flight.
  const probe = (kinds?: readonly Resources.Kind[]) => {
    probing++
    probes = probes.then(() => probeNow(kinds)).finally(() => probing--)
    return probes
  }

  const probeNow = async (kinds?: readonly Resources.Kind[]) => {
    const at = now()
    const byKind = Object.groupBy(
      [...entries.values()].filter((entry) => entry.status !== "gone" && (!kinds || kinds.includes(entry.kind))),
      (entry) => entry.kind,
    )
    const results = await Promise.all(
      Object.entries(byKind).map(([kind, list]) =>
        options.adapters[kind as Resources.Kind].probe(list ?? []).catch((error) => {
          console.error(`resources hub: ${kind} probe failed`, error)
          return new Map()
        }),
      ),
    )
    const updated = results.flatMap((result) =>
      [...result.entries()].flatMap(([id, found]) => {
        const entry = entries.get(id)
        if (!entry) return []
        const meta = found.meta ? mergeMeta(entry.meta, found.meta) : entry.meta
        if (found.status === entry.status && JSON.stringify(meta) === JSON.stringify(entry.meta)) return []
        entries.set(id, { ...entry, status: found.status, meta, updatedAt: at })
        if (found.status !== "running") lives.get(id)?.controller.abort()
        return [id]
      }),
    )
    const pruned = [...entries.values()]
      .filter(
        (entry) =>
          (entry.status === "gone" && at - entry.updatedAt > goneRetentionMs) ||
          (entry.status === "stopped" && at - entry.updatedAt > stoppedRetentionMs),
      )
      .map((entry) => {
        entries.delete(entry.id)
        return entry.id
      })
    if (updated.length + pruned.length > 0) changed(...updated, ...pruned)
  }

  const snapshot = (id: string, maxWidth?: number) => {
    const entry = entries.get(id)
    if (!entry) return undefined
    const cached = snapshots.get(id)
    const image =
      cached && now() - cached.at < 1_500
        ? cached.image
        : options.adapters[entry.kind].snapshot(entry).catch((error: unknown) => {
            snapshots.delete(id)
            throw error
          })
    if (image !== cached?.image) snapshots.set(id, { at: now(), image })
    return image.then(async (full): Promise<Image> => {
      if (!maxWidth || (full.width !== undefined && full.width <= maxWidth && full.mime === "image/jpeg")) return full
      const data = await jpeg(full.data, full.width === undefined || full.width > maxWidth ? maxWidth : undefined)
      return { mime: "image/jpeg", data, ...size(data) }
    })
  }

  const claim = (wait: number) =>
    new Promise<HubEvent[]>((resolve) => {
      const take = () => {
        waiters.delete(take)
        clearTimeout(timer)
        resolve(pending.splice(0))
      }
      const timer = setTimeout(take, pending.length > 0 ? 0 : wait)
      if (pending.length > 0) return take()
      waiters.add(take)
    })

  const subscribe = (id: string, viewer: Viewer) => {
    const entry = entries.get(id)
    if (!entry) return viewer.close()
    const existing = lives.get(id)
    const live: Live = existing ?? { controller: new AbortController(), viewers: new Set() }
    live.viewers.add(viewer)
    const lock = locks.get(id)
    viewer.text({
      type: "control",
      holder: lock ? "user" : null,
      ...(lock ? { expiresAt: lock.expiresAt } : {}),
      mine: lock !== undefined && viewer.lock === lock.token,
    })
    if (live.hello) viewer.text(live.hello)
    if (live.meta) viewer.text({ type: "meta", value: live.meta })
    if (live.keyframe) {
      viewer.frame(live.keyframe.encoded, live.keyframe.payload, true)
      viewer.waitingKeyframe = false
    }
    if (existing) return
    lives.set(id, live)
    const sink: StreamSink = {
      hello: (hello) => {
        live.hello = { type: "hello", ...hello }
        live.keyframe = undefined
        live.viewers.forEach((item) => item.text({ type: "hello", ...hello }))
      },
      frame: (payload, frame = {}) => {
        const keyframe = live.hello?.format !== "h264" || frame.keyframe === true
        const encoded = ResourceProtocol.encodeFrame(payload, frame.capturedAt ?? now(), keyframe)
        if (keyframe) live.keyframe = { encoded, payload }
        live.viewers.forEach((item) => {
          if (item.waitingKeyframe && !keyframe) return
          if (item.buffered() > maxBuffered) {
            item.waitingKeyframe = true
            return
          }
          item.waitingKeyframe = false
          item.frame(encoded, payload, keyframe)
        })
      },
      meta: (value) => {
        live.meta = value
        live.viewers.forEach((item) => item.text({ type: "meta", value }))
      },
    }
    const adapter = options.adapters[entry.kind]
    const run = adapter.stream
      ? adapter.stream(entry, sink, live.controller.signal)
      : fallback(entry, sink, live.controller.signal)
    void run
      .then(
        () => ({ type: "end" as const, reason: "ended" }),
        (error: unknown) => ({
          type: "error" as const,
          message: String(error instanceof Error ? error.message : error),
        }),
      )
      .then((message) => {
        if (lives.get(id) !== live) return
        lives.delete(id)
        if (live.controller.signal.aborted && live.viewers.size === 0) return
        live.viewers.forEach((item) => {
          item.text(message)
          item.close()
        })
      })
  }

  const unsubscribe = (id: string, viewer: Viewer) => {
    const live = lives.get(id)
    if (!live) return
    live.viewers.delete(viewer)
    if (live.viewers.size > 0) return
    lives.delete(id)
    live.controller.abort()
  }

  /** Without an adapter stream, viewers still see the screen: snapshots as JPEG frames, a few per second. */
  const fallback = async (entry: Entry, sink: StreamSink, signal: AbortSignal) => {
    const width = options.fallbackWidth ?? 828
    const frames = async (announced: boolean): Promise<void> => {
      if (signal.aborted) return
      const started = now()
      const image = await options.adapters[entry.kind].snapshot(entry)
      const data =
        image.mime === "image/jpeg" && (image.width ?? 0) <= width ? image.data : await jpeg(image.data, width)
      if (signal.aborted) return
      const dimensions = size(data)
      if (!announced && dimensions) sink.hello({ format: "jpeg", ...dimensions })
      sink.frame(data, { capturedAt: started })
      await Bun.sleep(Math.max(0, 300 - (now() - started)))
      return frames(announced || dimensions !== undefined)
    }
    return frames(false)
  }

  const applyInput = (id: string, token: string | undefined, events: readonly ResourceProtocol.Input[]) => {
    const entry = entries.get(id)
    const lock = locks.get(id)
    if (!entry) return "not_found" as const
    if (!lock || lock.token !== token) return "not_in_control" as const
    const adapter = options.adapters[entry.kind]
    if (!adapter.input) return "unsupported" as const
    locks.set(id, { ...lock, expiresAt: now() + Resources.limits.controlIdleMs })
    const apply = adapter.input.bind(adapter)
    const previous = inputs.get(id) ?? Promise.resolve()
    const next = events
      .reduce((chain, event) => chain.then(() => apply(entry, event)), previous)
      .catch((error: unknown) => {
        // Text may be a password: report the failure without the event.
        console.error(`resources hub: ${entry.kind} input failed`, error instanceof Error ? error.message : "unknown")
      })
    inputs.set(id, next)
    return "ok" as const
  }

  const admin = async (request: Request, url: URL, parts: string[]) => {
    if (request.headers.get("authorization") !== `Bearer ${options.secret}`) return status(401)
    const [, resource, id, action] = parts
    if (resource === "health") return Response.json({ protocol, pid: process.pid })
    if (resource === "shutdown" && request.method === "POST") {
      queueMicrotask(() => process.emit("SIGTERM"))
      return Response.json({})
    }
    if (resource === "events" && request.method === "POST")
      return Response.json({ events: await claim(Math.min(Number(url.searchParams.get("wait") ?? 0), 30_000)) })
    if (resource === "locks")
      return Response.json({
        locks: [...locks.entries()].flatMap(([lockID, lock]): Lock[] => {
          const entry = entries.get(lockID)
          if (!entry) return []
          return [
            {
              id: lockID,
              kind: entry.kind,
              label: label(entry),
              meta: entry.meta,
              ...(entry.owner ? { owner: entry.owner } : {}),
              expiresAt: lock.expiresAt,
            },
          ]
        }),
      })
    if (resource === "tickets" && request.method === "POST") {
      const input = decodeTicket(await request.json().catch(() => undefined))
      if (Option.isNone(input)) return status(400)
      const result = ticket(input.value.id, input.value.capability)
      return result ? Response.json(result) : status(409)
    }
    if (resource !== "resources") return status(404)
    if (!id && request.method === "GET")
      return Response.json({
        resources: [...entries.values()].map(view).toSorted((a, b) => b.lastUsedAt - a.lastUsedAt),
      })
    if (!id && request.method === "PUT") {
      const input = decodeUpsert(await request.json().catch(() => undefined))
      return Option.isSome(input) ? Response.json(upsert(input.value)) : status(400)
    }
    const decoded = decodeURIComponent(id ?? "")
    const entry = entries.get(decoded)
    if (!entry) return status(404)
    if (!action && request.method === "GET") return Response.json(view(entry))
    if (!action && request.method === "DELETE") {
      remove(decoded)
      return Response.json({})
    }
    if (action === "control" && request.method === "POST") {
      const input = decodeControl(await request.json().catch(() => undefined))
      if (Option.isNone(input)) return status(400)
      return Response.json(control(decoded, input.value.action))
    }
    if (action === "snapshot") return image(decoded, url)
    return status(404)
  }

  const image = async (id: string, url: URL) => {
    const width = Number(url.searchParams.get("maxWidth") ?? 0)
    const maxWidth =
      Number.isInteger(width) && width >= 64 ? Math.min(width, Resources.limits.snapshotMaxWidth) : undefined
    const taking = snapshot(id, maxWidth)
    if (!taking) return status(404)
    const result = await taking.then(
      (value) => ({ value }),
      (error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }),
    )
    if ("error" in result) return new Response(result.error, { status: 502 })
    const value = result.value
    return new Response(value.data, {
      headers: {
        "content-type": value.mime,
        "cache-control": "no-store",
        "x-taken-at": String(snapshots.get(id)?.at ?? now()),
        ...(value.width ? { "x-width": String(value.width), "x-height": String(value.height ?? 0) } : {}),
      },
    })
  }

  const fetch = async (request: Request, server: Server<SocketData>) => {
    const url = new URL(request.url)
    const parts = url.pathname.split("/").filter(Boolean)
    if (parts[0] === "admin") return admin(request, url, parts)
    if (parts[0] !== "resources" || parts.length !== 3) return status(404)
    const id = decodeURIComponent(parts[1] ?? "")
    const action = parts[2]
    const claims = verify(options.secret, url.searchParams.get("ticket") ?? "", id, now())
    if (!claims) return status(401)
    if (!entries.has(id)) return status(404)
    if (action === "snapshot" && request.method === "GET") return image(id, url)
    if (action === "stream" && request.method === "GET") {
      const data: SocketData = { id, capability: claims.c, ...(claims.l ? { lock: claims.l } : {}) }
      if (server.upgrade(request, { data })) return undefined
      return mjpeg(id, data)
    }
    if (action === "input" && request.method === "POST") {
      if (claims.c !== "control") return status(403)
      const input = decodeInputs(await request.json().catch(() => undefined))
      if (Option.isNone(input)) return status(400)
      const result = applyInput(id, claims.l, input.value.events)
      return result === "ok" ? Response.json({}) : Response.json({ error: result }, { status: 409 })
    }
    return status(404)
  }

  const mjpeg = (id: string, data: SocketData) => {
    const boundary = "opencode-frame"
    const encoder = new TextEncoder()
    let viewer: Viewer | undefined
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        viewer = {
          capability: data.capability,
          waitingKeyframe: false,
          text: () => {},
          frame: (_encoded, payload) => {
            if (lives.get(id)?.hello?.format !== "jpeg") return
            controller.enqueue(
              encoder.encode(
                `--${boundary}\r\nContent-Type: image/jpeg\r\nContent-Length: ${payload.byteLength}\r\n\r\n`,
              ),
            )
            controller.enqueue(payload)
            controller.enqueue(encoder.encode("\r\n"))
          },
          buffered: () => Math.max(0, -(controller.desiredSize ?? 0)),
          close: () => controller.close(),
        }
        subscribe(id, viewer)
      },
      cancel() {
        if (viewer) unsubscribe(id, viewer)
      },
    })
    return new Response(body, {
      headers: { "content-type": `multipart/x-mixed-replace; boundary=${boundary}`, "cache-control": "no-store" },
    })
  }

  const sockets = new WeakMap<ServerWebSocket<SocketData>, Viewer>()
  const websocket = {
    open(socket: ServerWebSocket<SocketData>) {
      const viewer: Viewer = {
        capability: socket.data.capability,
        ...(socket.data.lock ? { lock: socket.data.lock } : {}),
        waitingKeyframe: true,
        text: (message) => void socket.send(JSON.stringify(message)),
        frame: (encoded) => void socket.send(encoded),
        buffered: () => socket.getBufferedAmount(),
        close: () => socket.close(1000),
      }
      sockets.set(socket, viewer)
      subscribe(socket.data.id, viewer)
    },
    message(socket: ServerWebSocket<SocketData>, message: string | Buffer) {
      if (typeof message !== "string") return
      const parsed = decodeClient(message)
      if (Option.isNone(parsed)) return void socket.send(JSON.stringify({ type: "error", message: "invalid message" }))
      if (parsed.value.type === "ping")
        return void socket.send(JSON.stringify({ type: "pong", t: parsed.value.t, hub: now() }))
      if (socket.data.capability !== "control")
        return void socket.send(JSON.stringify({ type: "error", message: "not_in_control" }))
      const result = applyInput(socket.data.id, socket.data.lock, parsed.value.events)
      if (result !== "ok") socket.send(JSON.stringify({ type: "error", message: result }))
    },
    close(socket: ServerWebSocket<SocketData>) {
      const viewer = sockets.get(socket)
      if (viewer) unsubscribe(socket.data.id, viewer)
    },
  }

  const timers: ReturnType<typeof setInterval>[] = []
  const start = async () => {
    await load()
    timers.push(setInterval(expire, 1_000))
    timers.push(setInterval(() => probing === 0 && void probe(), options.probeMs ?? 5_000))
    void probe()
  }

  const close = () => {
    timers.forEach(clearInterval)
    lives.forEach((live) => live.controller.abort())
    waiters.forEach((wake) => wake())
  }

  return { fetch, websocket, start, close, upsert, control, ticket, probe, expire, claim, view, entries, locks }
}

export function idFor(meta: Resources.Meta) {
  if (meta.kind === "ios-simulator") return `ios-simulator:${meta.udid}`
  if (meta.kind === "android-emulator") return `android-emulator:${meta.avd ?? meta.serial ?? "unknown"}`
  if (meta.session === "default" && meta.workspace) return `chrome:default@${path.basename(meta.workspace)}`
  return `chrome:${meta.session ?? meta.cdp ?? "unknown"}`
}

/** Whether two metadata records name the same resource (shared UDID, adb serial, AVD, session or CDP endpoint). */
export function sameResource(a: Resources.Meta, b: Resources.Meta) {
  if (a.kind === "ios-simulator" && b.kind === "ios-simulator") return a.udid === b.udid
  if (a.kind === "android-emulator" && b.kind === "android-emulator")
    return (a.avd !== undefined && a.avd === b.avd) || (a.serial !== undefined && a.serial === b.serial)
  if (a.kind === "chrome" && b.kind === "chrome")
    return (
      (a.session !== undefined &&
        a.session === b.session &&
        (a.session !== "default" ||
          a.workspace === undefined ||
          b.workspace === undefined ||
          a.workspace === b.workspace)) ||
      (a.cdp !== undefined && a.cdp === b.cdp)
    )
  return false
}

function mergeMeta(current: Resources.Meta, next: Resources.Meta): Resources.Meta {
  if (current.kind !== next.kind) return next
  const defined = Object.fromEntries(Object.entries(next).filter(([, value]) => value !== undefined))
  return { ...current, ...defined } as Resources.Meta
}

export function label(entry: Pick<Entry, "name" | "meta">) {
  if (entry.name) return entry.name
  const meta = entry.meta
  const join = (parts: readonly (string | undefined)[]) =>
    [...new Set(parts.filter((part): part is string => Boolean(part)))].join(" · ")
  if (meta.kind === "ios-simulator") return join([meta.device, meta.name]) || `Simulador ${meta.udid.slice(0, 8)}`
  if (meta.kind === "android-emulator")
    return join([meta.device, meta.avd?.replaceAll("_", " ")]) || meta.serial || "Emulador Android"
  return page(meta.url) ?? meta.title ?? meta.session ?? "Chrome"
}

function page(value: string | undefined) {
  if (!value) return undefined
  const url = URL.parse(value)
  if (!url || url.protocol === "about:") return value === "about:blank" ? undefined : value
  return `${url.host}${url.pathname === "/" ? "" : url.pathname}`
}

function status(code: number) {
  return new Response(null, { status: code })
}
