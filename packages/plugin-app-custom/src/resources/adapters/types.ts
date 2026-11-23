import type { Hello, Input, Profile } from "../protocol.js"
import type { Resources } from "../rpc.js"
import type { BrowseTab } from "./browse-relay.js"

/** Registry entry as the hub stores it. `Resource` (the RPC shape) is derived from it plus control and time. */
export interface Entry {
  readonly id: string
  readonly kind: Resources.Kind
  /** Explicit display name from registration; otherwise the hub derives the label from `meta`. */
  readonly name?: string
  readonly purpose?: string
  readonly owner?: Resources.Owner
  /** Who started it (`Resources.StartedBy`), until it stops. */
  readonly startedBy?: Resources.StartedBy
  readonly meta: Resources.Meta
  readonly status: "running" | "stopped" | "gone"
  readonly discoveredAt: number
  readonly lastUsedAt: number
  readonly updatedAt: number
  /** The agents' latest shell commands that named it, oldest first (`Resources.limits.activityKept`). */
  readonly activity?: readonly StoredActivity[]
  /**
   * What the viewer may offer (`Resources.Capabilities`) when it differs from the kind's default: a browse handoff's
   * locks (`Resources.handoffCapabilities`) while it waits. Never persisted.
   */
  readonly capabilities?: Resources.Capabilities
  /** The browse handoff that waits on this resource's tab (`browse-handoff-remoto.md`). Never persisted. */
  readonly handoff?: Resources.Handoff
  /** A browse resource's machine (`Resources.Resource.machine`), computed by the hub. Never persisted. */
  readonly machine?: string
  /**
   * rev. 2026-11-22 (browse 0.1.5): a browse resource's tabs, the ones its session's calls named or opened and the
   * popups those opened; each tab is one resource's at a time. Persisted; not in `Resources.Resource`.
   */
  readonly tabs?: readonly BrowseTab[]
}

/** One agent shell command that named a resource; `call` is its tool call, open until the command ends. */
export interface StoredActivity {
  readonly call: string
  readonly command: string
  readonly at: number
  readonly sessionID?: string
  readonly agent?: string
  readonly endedAt?: number
}

export interface Probe {
  readonly status: Entry["status"]
  /** Refreshed metadata (for example the URL Chrome now shows); merged over the stored one. */
  readonly meta?: Resources.Meta
  /** `meta` replaces the stored metadata instead of merging, so fields that no longer hold (a stale serial) go. */
  readonly exact?: boolean
  /** A browse resource's tabs as the relay lists them now (closed ones gone, popups added); absent leaves them. */
  readonly tabs?: readonly BrowseTab[]
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
  /**
   * Kind-specific state for the viewer, for example `{ url, title }` for Chrome. `rotation` (clockwise degrees) is
   * reserved for the turn the viewer must still apply to show frames upright (the iOS Simulator streams its portrait
   * framebuffer); a device's own orientation, when frames already arrive upright, goes in `orientation`.
   */
  meta(value: Record<string, unknown>): void
  /** The quality the viewers currently ask for (`standard` when none says otherwise); read it per frame. */
  profile?(): Profile
  /** Shows the viewers a short, discreet message (a diagnosis such as "aberto sem porta CDP"). Never secrets. */
  notice?(message: string): void
  /**
   * Whether some viewer can take another frame now: it is within its byte budget and, if it acknowledges frames
   * (`ack`), has fewer than `maxFramesInFlight` unacknowledged. Adapters that capture on demand (Chrome's
   * screencast acknowledgements) pace themselves with `ready`/`whenReady` instead of producing frames nobody can
   * receive; push-only adapters can ignore them, since the hub keeps just the newest frame per slow viewer.
   */
  ready?(): boolean
  /** Resolves as soon as `ready()` holds (at once if it already does), or when `signal` aborts. */
  whenReady?(signal?: AbortSignal): Promise<void>
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
 * - `recover` runs once when a hub starts (holding its state directory's lock), before it serves: clean up what a
 *   previous hub of the same directory left behind when it died abruptly (helper processes).
 */
export interface Adapter {
  readonly kind: Resources.Kind
  probe(entries: readonly Entry[]): Promise<ReadonlyMap<string, Probe>>
  /**
   * rev. 2026-11-18: every resource of this kind running on the hub's machine now, known or not (a simulator booted, an
   * emulator attached), so the hub lists them all. Simulators and emulators only.
   */
  inventory?(): Promise<readonly Resources.Meta[]>
  snapshot(entry: Entry): Promise<Image>
  stream?(entry: Entry, sink: StreamSink, signal: AbortSignal): Promise<void>
  input?(entry: Entry, event: Input): Promise<void>
  /**
   * Completes a registration's metadata from the device before the hub matches it (Android: the AVD that runs on a
   * bare serial now; browse: browse's integer for the tab `targetID` names by integer or chosen id, which must be
   * open). Failures leave the metadata as it was.
   */
  identify?(meta: Resources.Meta): Promise<Resources.Meta>
  recover?(): Promise<void>
  /** Alexandre's control ended (returned or expired): undo viewer-only behavior, such as Chrome's sharp stills. */
  released?(entry: Entry): Promise<void>
  /** Brings the resource to the front where it runs (`custom.resources/focus`); only for `capabilities.focus`. */
  focus?(entry: Entry): Promise<void>
  /**
   * Shuts the resource down on the hub's machine (`custom.resources/stop`), after proving it is the one running there;
   * throws when it cannot. Only Android emulators have it.
   */
  stop?(entry: Entry): Promise<void>
  /** The resource left the registry: close what the adapter keeps open for it. */
  forget?(entry: Entry): Promise<void>
  /**
   * The entry's followed target, tabs or capabilities changed while it may be streaming (a browse handoff started, the
   * session moved to another tab or gained or lost one): follow the new target and apply the new locks without ending
   * the stream.
   */
  update?(entry: Entry): Promise<void>
}
