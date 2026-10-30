import { randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import type { Server, ServerWebSocket } from "bun"
import { optional } from "@opencode/schema/schema"
import { Option, Schema } from "effect"
import { namespaceOf, sameNamespace } from "../adapters/chrome.js"
import { jpeg, size } from "../adapters/process.js"
import type { Adapter, Entry, Image, StoredActivity, StreamSink } from "../adapters/types.js"
import { ResourceProtocol } from "../protocol.js"
import { Resources } from "../rpc.js"
import { makeInputQueue } from "./input-queue.js"
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
  /**
   * The shell command that named it (`call` is its tool call). `running` keeps the resource `agent` until the same call
   * comes back with `running: false` or `POST /admin/calls/<call>/end` closes it.
   */
  activity: optional(Schema.Struct({ call: Schema.String, command: Schema.String, running: Schema.Boolean })),
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
  activity: optional(
    Schema.Array(
      Schema.Struct({
        call: Schema.String,
        command: Schema.String,
        at: Schema.Number,
        sessionID: optional(Schema.String),
        agent: optional(Schema.String),
        endedAt: optional(Schema.Number),
      }),
    ),
  ),
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

type Frame = { readonly encoded: Uint8Array; readonly payload: Uint8Array; readonly keyframe: boolean }

/** Per-viewer stream counters, for `GET /admin/streams` and measurements. */
type ViewerStats = { frames: number; bytes: number; replaced: number; dropped: number }

interface Viewer {
  /** Updated in place when the client upgrades its socket with a control ticket (`auth`). */
  lock?: string
  capability: Resources.Capability
  live?: Live
  waitingKeyframe: boolean
  /** Newest image frame that did not fit yet; sent as soon as the viewer catches up, replaced by newer ones. */
  pending?: Frame
  retry?: ReturnType<typeof setTimeout>
  /** Frames sent on this connection and, once the client acknowledges, how many it has received. */
  sent: number
  acked?: number
  profile: ResourceProtocol.Profile
  readonly stats: ViewerStats
  text(message: ResourceProtocol.ServerMessage): void
  frame(frame: Frame): void
  buffered(): number
  close(): void
}

interface Live {
  readonly controller: AbortController
  readonly viewers: Set<Viewer>
  hello?: ResourceProtocol.Hello
  /** Latest `meta`, replayed to viewers that join later (an iOS Simulator's rotation). */
  meta?: Record<string, unknown>
  keyframe?: Frame
  /** Capture → hub ages (ms) since the last `stats`, for frames whose adapter reported `capturedAt`. */
  readonly captures: number[]
  /** Adapters waiting in `whenReady`. */
  readonly waiters: Set<() => void>
  linger?: ReturnType<typeof setTimeout>
  ticker?: ReturnType<typeof setInterval>
}

/**
 * Bytes a viewer may have waiting in its connection before the hub holds frames back. Images keep only the newest
 * held-back frame and send it once the viewer drains, so a slow viewer sees the latest screen a little late instead of
 * an ever older one; this budget (a few JPEG frames) bounds that lateness for clients that do not acknowledge.
 * H.264 cannot skip frames, so it keeps the larger budget and resumes at the next keyframe.
 */
const maxBufferedImages = 512 * 1024
const maxBufferedVideo = 2 * 1024 * 1024
const retryMs = 30
const lingerMs = 5_000
const statsMs = 2_000
const mjpegRepeatMs = 100
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
  const queues = new Map<string, ReturnType<typeof makeInputQueue>>()
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
    const open = (item: StoredActivity) => item.endedAt === undefined && at - item.at < Resources.limits.activityOpenMs
    const state: Resources.State = lock
      ? "user"
      : entry.status !== "running"
        ? entry.status
        : at - entry.lastUsedAt < Resources.limits.agentRecentMs || entry.activity?.some(open)
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
      ...(entry.activity?.length
        ? {
            activity: entry.activity.toReversed().map((item) => ({
              at: item.at,
              command: item.command,
              ...(item.sessionID ? { sessionID: item.sessionID } : {}),
              ...(item.agent ? { agent: item.agent } : {}),
              ...(open(item) ? { running: true } : {}),
            })),
          }
        : {}),
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
      ...(input.activity || existing?.activity
        ? { activity: record(existing?.activity ?? [], input.activity, input.owner, at) }
        : {}),
    }
    entries.set(id, entry)
    changed(id)
    void probe([entry.kind])
    return view(entry)
  }

  /** Closes a shell command on every resource it named: the resource stops counting as in use for it. */
  const end = (call: string) => {
    const at = now()
    const ended = [...entries.values()].filter((entry) =>
      entry.activity?.some((item) => item.call === call && item.endedAt === undefined),
    )
    ended.forEach((entry) =>
      entries.set(entry.id, {
        ...entry,
        lastUsedAt: at,
        activity: entry.activity?.map((item) => (item.call === call ? { ...item, endedAt: item.endedAt ?? at } : item)),
      }),
    )
    if (ended.length > 0) changed(...ended.map((entry) => entry.id))
  }

  const remove = (id: string) => {
    const live = lives.get(id)
    live?.controller.abort()
    if (locks.has(id)) void release(id, "returned").then(() => queues.delete(id))
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

  /**
   * Ends Alexandre's control. New inputs are refused at once and pending ones are dropped; the input in flight
   * finishes and fingers still down are lifted before viewers and the session hear about the hand-back.
   */
  const release = async (id: string, reason: "returned" | "expired") => {
    if (!locks.delete(id)) return
    await queues.get(id)?.reset()
    const entry = entries.get(id)
    // Adapters undo viewer-only behavior, such as Chrome's sharp stills through the agent's playwright-cli session.
    if (entry) void options.adapters[entry.kind].released?.(entry).catch(() => undefined)
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

  const control = async (id: string, action: "take" | "renew" | "release") => {
    const entry = entries.get(id)
    if (!entry) return undefined
    const at = now()
    if (action === "release") {
      await release(id, "returned")
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
    return Promise.all(
      [...locks.entries()].filter(([, lock]) => lock.expiresAt <= at).map(([id]) => release(id, "expired")),
    )
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

  const controlMessage = (id: string, viewer: Viewer): ResourceProtocol.ServerMessage => {
    const lock = locks.get(id)
    return {
      type: "control",
      holder: lock ? "user" : null,
      ...(lock ? { expiresAt: lock.expiresAt } : {}),
      mine: lock !== undefined && viewer.lock === lock.token,
    }
  }

  const subscribe = (id: string, viewer: Viewer) => {
    const entry = entries.get(id)
    if (!entry) return viewer.close()
    const existing = lives.get(id)
    const live: Live = existing ?? {
      controller: new AbortController(),
      viewers: new Set(),
      captures: [],
      waiters: new Set(),
    }
    clearTimeout(live.linger)
    live.linger = undefined
    live.viewers.add(viewer)
    viewer.live = live
    viewer.text(controlMessage(id, viewer))
    if (live.hello) viewer.text(live.hello)
    if (live.meta) viewer.text({ type: "meta", value: live.meta })
    if (live.keyframe) offer(viewer, live.keyframe, live.hello?.format === "h264")
    if (existing) return
    lives.set(id, live)
    const sink: StreamSink = {
      hello: (hello) => {
        live.hello = { type: "hello", ...hello }
        live.keyframe = undefined
        live.viewers.forEach((item) => {
          item.pending = undefined
          item.text({ type: "hello", ...hello })
        })
      },
      frame: (payload, options = {}) => {
        const video = live.hello?.format === "h264"
        const keyframe = !video || options.keyframe === true
        const at = now()
        if (options.capturedAt !== undefined) live.captures.push(at - options.capturedAt)
        const frame = {
          encoded: ResourceProtocol.encodeFrame(payload, options.capturedAt ?? at, keyframe),
          payload,
          keyframe,
        }
        if (keyframe) live.keyframe = frame
        live.viewers.forEach((item) => offer(item, frame, video))
      },
      meta: (value) => {
        live.meta = value
        live.viewers.forEach((item) => item.text({ type: "meta", value }))
      },
      notice: (message) => live.viewers.forEach((item) => item.text({ type: "notice", message })),
      profile: () =>
        live.viewers.size > 0 && [...live.viewers].every((item) => item.profile === "economy") ? "economy" : "standard",
      ready: () => anyReady(live),
      whenReady: (signal) =>
        new Promise<void>((resolve) => {
          if (anyReady(live) || signal?.aborted) return resolve()
          const done = () => {
            live.waiters.delete(done)
            signal?.removeEventListener("abort", done)
            resolve()
          }
          live.waiters.add(done)
          signal?.addEventListener("abort", done, { once: true })
        }),
    }
    live.ticker = setInterval(() => report(live), statsMs)
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
        clearInterval(live.ticker)
        clearTimeout(live.linger)
        live.waiters.forEach((wake) => wake())
        if (lives.get(id) !== live) return
        lives.delete(id)
        if (live.controller.signal.aborted && live.viewers.size === 0) return
        live.viewers.forEach((item) => {
          item.text(message)
          item.close()
        })
      })
  }

  /** Per-viewer delivery counters plus the capture → hub age of the last interval, every `statsMs`. */
  const report = (live: Live) => {
    const ages = live.captures.splice(0).toSorted((a, b) => a - b)
    const capture =
      ages.length > 0
        ? {
            p50: Math.round(ages[Math.floor(ages.length / 2)] ?? 0),
            p95: Math.round(ages[Math.floor(ages.length * 0.95)] ?? 0),
          }
        : undefined
    live.viewers.forEach((viewer) =>
      viewer.text({
        type: "stats",
        hub: now(),
        ...(capture ? { capture } : {}),
        ...viewer.stats,
        ...(viewer.acked === undefined ? {} : { inFlight: viewer.sent - viewer.acked }),
      }),
    )
  }

  /** Whether `viewer` can take another frame now: within its byte budget and, if it acknowledges, its frames in flight. */
  const ready = (viewer: Viewer, video: boolean) =>
    viewer.buffered() <= (video ? maxBufferedVideo : maxBufferedImages) &&
    (viewer.acked === undefined || viewer.sent - viewer.acked < ResourceProtocol.maxFramesInFlight)

  /** Some viewer could take a new frame right now (adapters that capture on demand pace themselves by this). */
  const anyReady = (live: Live) =>
    live.viewers.size === 0 ||
    [...live.viewers].some((viewer) => !viewer.pending && ready(viewer, live.hello?.format === "h264"))

  const wake = (live: Live | undefined) => {
    if (!live || live.waiters.size === 0 || !anyReady(live)) return
    live.waiters.forEach((done) => done())
  }

  const send = (viewer: Viewer, frame: Frame) => {
    viewer.waitingKeyframe = false
    viewer.sent++
    viewer.stats.frames++
    viewer.stats.bytes += frame.encoded.byteLength
    viewer.frame(frame)
  }

  /**
   * Delivers one frame to one viewer, so a slow viewer never holds back a fast one. Images that do not fit replace
   * the viewer's held-back frame, sent by `flush` when it catches up. H.264 deltas that do not fit are dropped and the
   * viewer waits for the next keyframe.
   */
  const offer = (viewer: Viewer, frame: Frame, video: boolean) => {
    if (viewer.waitingKeyframe && !frame.keyframe) return void viewer.stats.dropped++
    if (ready(viewer, video)) {
      if (viewer.pending) viewer.stats.replaced++
      viewer.pending = undefined
      return send(viewer, frame)
    }
    if (video) {
      viewer.waitingKeyframe = true
      viewer.stats.dropped++
      return
    }
    if (viewer.pending) viewer.stats.replaced++
    viewer.pending = frame
    schedule(viewer)
  }

  /** Sends the held-back frame once the viewer has room; called on drain, acknowledgement and a short retry. */
  const flush = (viewer: Viewer) => {
    const frame = viewer.pending
    if (frame && !ready(viewer, false)) return schedule(viewer)
    if (frame) {
      viewer.pending = undefined
      send(viewer, frame)
    }
    wake(viewer.live)
  }

  // Bun reports drain only past its own backpressure limit, far above the image budget, so also poll briefly.
  const schedule = (viewer: Viewer) => {
    if (viewer.retry) return
    viewer.retry = setTimeout(() => {
      viewer.retry = undefined
      flush(viewer)
    }, retryMs)
  }

  /**
   * The stream outlives its last viewer by `lingerMs`, so a viewer that reconnects (app back from the background, a
   * network change) gets the cached frame at once and the adapter does not restart its capture.
   */
  const unsubscribe = (id: string, viewer: Viewer) => {
    clearTimeout(viewer.retry)
    viewer.pending = undefined
    viewer.live = undefined
    const live = lives.get(id)
    if (!live) return
    live.viewers.delete(viewer)
    if (live.viewers.size > 0) return wake(live)
    live.linger = setTimeout(() => {
      if (live.viewers.size > 0 || lives.get(id) !== live) return
      lives.delete(id)
      clearInterval(live.ticker)
      live.controller.abort()
    }, lingerMs)
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
    if (!lock || !token || lock.token !== token) return "not_in_control" as const
    const adapter = options.adapters[entry.kind]
    if (!adapter.input) return "unsupported" as const
    locks.set(id, { ...lock, expiresAt: now() + Resources.limits.controlIdleMs })
    const queue = queues.get(id) ?? inputQueue(id)
    return queue.enqueue(token, events) ? ("ok" as const) : ("input_overflow" as const)
  }

  const inputQueue = (id: string) => {
    const queue = makeInputQueue({
      apply: async (event) => {
        const entry = entries.get(id)
        const input = entry ? options.adapters[entry.kind].input : undefined
        if (entry && input) await input.call(options.adapters[entry.kind], entry, event)
      },
      holds: (token) => locks.get(id)?.token === token,
      failed: (error) => {
        // Text may be a password: report the failure without the event.
        console.error(`resources hub: ${id} input failed`, error instanceof Error ? error.message : "unknown")
        const lock = locks.get(id)
        lives
          .get(id)
          ?.viewers.forEach(
            (viewer) => lock && viewer.lock === lock.token && viewer.text({ type: "error", message: "input_failed" }),
          )
      },
    })
    queues.set(id, queue)
    return queue
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
    if (resource === "streams")
      return Response.json({
        streams: [...lives.entries()].map(([streamID, live]) => ({
          id: streamID,
          hello: live.hello,
          viewers: [...live.viewers].map((viewer) => ({
            capability: viewer.capability,
            profile: viewer.profile,
            acknowledging: viewer.acked !== undefined,
            inFlight: viewer.acked === undefined ? undefined : viewer.sent - viewer.acked,
            buffered: viewer.buffered(),
            ...viewer.stats,
          })),
        })),
      })
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
    if (resource === "calls" && id && action === "end" && request.method === "POST") {
      end(decodeURIComponent(id))
      return Response.json({})
    }
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
      return Response.json(await control(decoded, input.value.action))
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
    let repeat: ReturnType<typeof setTimeout> | undefined
    // Counted in bytes (not chunks): `desiredSize` is the room left below the image budget, negative past it.
    const body = new ReadableStream<Uint8Array>(
      {
        start(controller) {
          viewer = {
            capability: data.capability,
            waitingKeyframe: false,
            sent: 0,
            profile: "standard",
            stats: { frames: 0, bytes: 0, replaced: 0, dropped: 0 },
            text: () => {},
            frame: (frame) => {
              if (lives.get(id)?.hello?.format !== "jpeg") return
              const head = encoder.encode(
                `--${boundary}\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.payload.byteLength}\r\n\r\n`,
              )
              const part = new Uint8Array(head.byteLength + frame.payload.byteLength + 2)
              part.set(head)
              part.set(frame.payload, head.byteLength)
              part.set([13, 10], head.byteLength + frame.payload.byteLength)
              controller.enqueue(part)
              // HTTP clients show a part only when the next boundary arrives; screens that only send changes would
              // leave the newest one hidden, so repeat it once if nothing newer follows.
              clearTimeout(repeat)
              repeat = setTimeout(() => {
                if ((controller.desiredSize ?? 0) > 0) controller.enqueue(part)
              }, mjpegRepeatMs)
            },
            buffered: () => Math.max(0, maxBufferedImages - (controller.desiredSize ?? 0)),
            close: () => {
              clearTimeout(repeat)
              controller.close()
            },
          }
          subscribe(id, viewer)
        },
        pull() {
          if (viewer) flush(viewer)
        },
        cancel() {
          clearTimeout(repeat)
          if (viewer) unsubscribe(id, viewer)
        },
      },
      new ByteLengthQueuingStrategy({ highWaterMark: maxBufferedImages }),
    )
    return new Response(body, {
      headers: {
        "content-type": `multipart/x-mixed-replace; boundary=${boundary}`,
        "cache-control": "no-store, no-transform",
        "x-accel-buffering": "no",
      },
    })
  }

  const sockets = new WeakMap<ServerWebSocket<SocketData>, Viewer>()
  const websocket = {
    open(socket: ServerWebSocket<SocketData>) {
      const viewer: Viewer = {
        capability: socket.data.capability,
        ...(socket.data.lock ? { lock: socket.data.lock } : {}),
        waitingKeyframe: true,
        sent: 0,
        profile: "standard",
        stats: { frames: 0, bytes: 0, replaced: 0, dropped: 0 },
        text: (message) => void socket.send(JSON.stringify(message)),
        frame: (frame) => void socket.send(frame.encoded),
        buffered: () => socket.getBufferedAmount(),
        close: () => socket.close(1000),
      }
      sockets.set(socket, viewer)
      viewer.text({ type: "features", ack: true, auth: true, profiles: ResourceProtocol.Profile.literals })
      subscribe(socket.data.id, viewer)
    },
    message(socket: ServerWebSocket<SocketData>, message: string | Buffer) {
      if (typeof message !== "string") return
      const parsed = decodeClient(message)
      if (Option.isNone(parsed)) return void socket.send(JSON.stringify({ type: "error", message: "invalid message" }))
      if (parsed.value.type === "ping")
        return void socket.send(JSON.stringify({ type: "pong", t: parsed.value.t, hub: now() }))
      const viewer = sockets.get(socket)
      if (!viewer) return
      if (parsed.value.type === "ack") {
        viewer.acked = Math.min(viewer.sent, Math.max(viewer.acked ?? 0, parsed.value.n))
        return flush(viewer)
      }
      if (parsed.value.type === "profile") {
        viewer.profile = parsed.value.value
        return
      }
      if (parsed.value.type === "auth") {
        // Taking control upgrades this socket instead of opening another, so the stream keeps running.
        const claims = verify(options.secret, parsed.value.ticket, socket.data.id, now())
        if (!claims) return void socket.send(JSON.stringify({ type: "error", message: "invalid_ticket" }))
        viewer.capability = claims.c
        viewer.lock = claims.l
        return viewer.text(controlMessage(socket.data.id, viewer))
      }
      if (viewer.capability !== "control")
        return void socket.send(JSON.stringify({ type: "error", message: "not_in_control" }))
      const result = applyInput(socket.data.id, viewer.lock, parsed.value.events)
      if (result !== "ok") socket.send(JSON.stringify({ type: "error", message: result }))
    },
    drain(socket: ServerWebSocket<SocketData>) {
      const viewer = sockets.get(socket)
      if (viewer) flush(viewer)
    },
    close(socket: ServerWebSocket<SocketData>) {
      const viewer = sockets.get(socket)
      if (viewer) unsubscribe(socket.data.id, viewer)
    },
  }

  const timers: ReturnType<typeof setInterval>[] = []
  const start = async () => {
    await load()
    timers.push(setInterval(() => void expire(), 1_000))
    timers.push(setInterval(() => probing === 0 && void probe(), options.probeMs ?? 5_000))
    void probe()
  }

  const close = () => {
    timers.forEach(clearInterval)
    lives.forEach((live) => {
      clearTimeout(live.linger)
      clearInterval(live.ticker)
      live.controller.abort()
    })
    waiters.forEach((wake) => wake())
  }

  return { fetch, websocket, start, close, upsert, end, control, ticket, probe, expire, claim, view, entries, locks }
}

export function idFor(meta: Resources.Meta) {
  if (meta.kind === "ios-simulator") return `ios-simulator:${meta.udid}`
  if (meta.kind === "android-emulator") return `android-emulator:${meta.avd ?? meta.serial ?? "unknown"}`
  // Sessions are per `playwright-cli` namespace: global ones keep the plain name, workspace ones add its full path.
  // Entries registered under older IDs (`chrome:default@<folder>`) keep them: `upsert` matches by `sameResource`.
  const namespace = meta.session && meta.workspace ? namespaceOf(meta.workspace) : ""
  return `chrome:${meta.session ?? meta.cdp ?? "unknown"}${namespace ? `@${namespace}` : ""}`
}

/** Whether two metadata records name the same resource (shared UDID, adb serial, AVD, session or CDP endpoint). */
/**
 * The entry's history after `input`: the call's command added at its start (a call seen only once it ended, a
 * resource found in its output, starts and ends then), or ended when it comes back with `running: false`. The oldest
 * fall off past `limits.activityKept`.
 */
export function record(
  current: readonly StoredActivity[],
  input: Upsert["activity"],
  owner: Resources.Owner | undefined,
  at: number,
): StoredActivity[] {
  if (!input) return [...current]
  if (current.some((item) => item.call === input.call))
    return current.map((item) =>
      item.call === input.call && !input.running ? { ...item, endedAt: item.endedAt ?? at } : item,
    )
  const next: StoredActivity = {
    call: input.call,
    command: shown(input.command),
    at,
    ...(owner ? { sessionID: owner.sessionID } : {}),
    ...(owner?.agent ? { agent: owner.agent } : {}),
    ...(input.running ? {} : { endedAt: at }),
  }
  return [...current, next].slice(-Resources.limits.activityKept)
}

/** The command as the history shows it: leading `NAME=value` assignments (often tokens) dropped, one short line. */
export function shown(command: string) {
  const line = command
    .replace(/\s+/g, " ")
    .trim()
    .replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)+/, "")
  const limit = Resources.limits.activityCommandLength
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line
}

export function sameResource(a: Resources.Meta, b: Resources.Meta) {
  if (a.kind === "ios-simulator" && b.kind === "ios-simulator") return a.udid === b.udid
  if (a.kind === "android-emulator" && b.kind === "android-emulator")
    return (a.avd !== undefined && a.avd === b.avd) || (a.serial !== undefined && a.serial === b.serial)
  if (a.kind === "chrome" && b.kind === "chrome")
    return (
      (a.session !== undefined && a.session === b.session && sameNamespace(a.workspace, b.workspace)) ||
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
