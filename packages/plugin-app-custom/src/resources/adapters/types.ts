import type { Hello, Input } from "../protocol.js"
import type { Resources } from "../rpc.js"

/** Registry entry as the hub stores it. `Resource` (the RPC shape) is derived from it plus control and time. */
export interface Entry {
  readonly id: string
  readonly kind: Resources.Kind
  /** Explicit display name from registration; otherwise the hub derives the label from `meta`. */
  readonly name?: string
  readonly purpose?: string
  readonly owner?: Resources.Owner
  readonly meta: Resources.Meta
  readonly status: "running" | "stopped" | "gone"
  readonly discoveredAt: number
  readonly lastUsedAt: number
  readonly updatedAt: number
}

export interface Probe {
  readonly status: Entry["status"]
  /** Refreshed metadata (for example the URL Chrome now shows); merged over the stored one. */
  readonly meta?: Resources.Meta
}

export interface Image {
  readonly mime: "image/jpeg" | "image/png"
  readonly data: Uint8Array<ArrayBuffer>
  readonly width?: number
  readonly height?: number
}

/** Where a live stream writes. The hub fans it out to every viewer and caches `hello` and the last keyframe. */
export interface StreamSink {
  hello(hello: Omit<Hello, "type">): void
  /** One frame payload in the `hello` format. JPEG/PNG frames are always keyframes. */
  frame(payload: Uint8Array, options?: { readonly keyframe?: boolean; readonly capturedAt?: number }): void
  /** Kind-specific state for the viewer, for example `{ url, title }` for Chrome or `{ orientation }`. */
  meta(value: Record<string, unknown>): void
}

/**
 * One per kind, in `adapters/<kind>.ts`, registered in `adapters/index.ts`. The hub calls it; nothing else does.
 *
 * - `probe` runs every few seconds for the known entries of this kind; a missing id means `gone`.
 * - `snapshot` returns the current screen at full size; the hub resizes and caches it.
 * - `stream` runs while at least one viewer is connected and must return (or throw) when `signal` aborts. The hub
 *   starts it once per resource and shares it. Without `stream`, viewers fall back to snapshot polling.
 * - `input` applies one event; the hub only calls it while Alexandre holds control with a matching ticket.
 *   Never log `text` events.
 */
export interface Adapter {
  readonly kind: Resources.Kind
  probe(entries: readonly Entry[]): Promise<ReadonlyMap<string, Probe>>
  snapshot(entry: Entry): Promise<Image>
  stream?(entry: Entry, sink: StreamSink, signal: AbortSignal): Promise<void>
  input?(entry: Entry, event: Input): Promise<void>
}
