export * as Resources from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

/**
 * Contract shared by the plugin, the resources hub, the adapters and the iOS mirror
 * (`OpenCodeKit/SessionResources.swift`). Change it only compatibly: add optional fields, never rename or
 * narrow existing ones. The full specification lives in `docs/resources.md`.
 */
export const Kind = Schema.Literals(["ios-simulator", "android-emulator", "chrome"]).annotate({
  identifier: "Resources.Kind",
})
export type Kind = typeof Kind.Type

/** `<kind>:<native id>`, for example `ios-simulator:4D3C…` or `chrome:abacato-login`. */
export const ID = Schema.String.check(Schema.isMinLength(3), Schema.isMaxLength(300)).annotate({
  identifier: "Resources.ID",
})

/**
 * What the lists show, in priority order: `user` (Alexandre holds control), `agent` (an agent used it in the last
 * 90 seconds), `live` (running, used in the last 10 minutes), `idle` (running, unused for longer: "Livre"),
 * `stopped` (exists but is not running) and `gone` (no longer exists).
 */
export const State = Schema.Literals(["user", "agent", "live", "idle", "stopped", "gone"]).annotate({
  identifier: "Resources.State",
})
export type State = typeof State.Type

export interface Owner extends Schema.Schema.Type<typeof Owner> {}
export const Owner = Schema.Struct({
  /** Session whose tool call used the resource; a subagent's own session when a subagent used it. */
  sessionID: Schema.String,
  /** Top-level session of that family; lists group by it. Equals `sessionID` for root sessions. */
  rootSessionID: Schema.String,
  /** Agent of `sessionID`, for "via <subagente>". */
  agent: optional(Schema.String),
}).annotate({ identifier: "Resources.Owner" })

export interface IOSSimulatorMeta extends Schema.Schema.Type<typeof IOSSimulatorMeta> {}
export const IOSSimulatorMeta = Schema.Struct({
  kind: Schema.Literal("ios-simulator"),
  udid: Schema.String,
  /** Simulator name, for example `OpenCode Salto Turno`. */
  name: optional(Schema.String),
  /** Device type, for example `iPhone 17`. */
  device: optional(Schema.String),
  runtime: optional(Schema.String),
}).annotate({ identifier: "Resources.IOSSimulatorMeta" })

export interface AndroidEmulatorMeta extends Schema.Schema.Type<typeof AndroidEmulatorMeta> {}
export const AndroidEmulatorMeta = Schema.Struct({
  kind: Schema.Literal("android-emulator"),
  /** adb serial, for example `emulator-5554`. Missing until the emulator is attached to adb. */
  serial: optional(Schema.String),
  avd: optional(Schema.String),
  consolePort: optional(Schema.Int),
  grpcPort: optional(Schema.Int),
  /** Device model, for example `Pixel 9`. */
  device: optional(Schema.String),
}).annotate({ identifier: "Resources.AndroidEmulatorMeta" })

export interface ChromeMeta extends Schema.Schema.Type<typeof ChromeMeta> {}
export const ChromeMeta = Schema.Struct({
  kind: Schema.Literal("chrome"),
  /** `playwright-cli -s=<session>` name. */
  session: optional(Schema.String),
  /** CDP HTTP endpoint, for example `http://127.0.0.1:9333`. */
  cdp: optional(Schema.String),
  /** CDP target (page) the viewer follows. */
  targetID: optional(Schema.String),
  url: optional(Schema.String),
  title: optional(Schema.String),
}).annotate({ identifier: "Resources.ChromeMeta" })

export const Meta = Schema.Union([IOSSimulatorMeta, AndroidEmulatorMeta, ChromeMeta]).annotate({
  identifier: "Resources.Meta",
})
export type Meta = typeof Meta.Type

export interface Control extends Schema.Schema.Type<typeof Control> {}
export const Control = Schema.Struct({
  holder: Schema.Literal("user"),
  since: Schema.Number,
  /** Epoch milliseconds; every input renews it by `limits.controlIdleMs`. */
  expiresAt: Schema.Number,
}).annotate({ identifier: "Resources.Control" })

export interface Resource extends Schema.Schema.Type<typeof Resource> {}
export const Resource = Schema.Struct({
  id: ID,
  kind: Kind,
  /** Short display name, for example `iPhone 17 · OpenCode Salto Turno` or `localhost:5173/login`. */
  label: Schema.String,
  /** Optional purpose given by explicit registration. */
  purpose: optional(Schema.String),
  owner: optional(Owner),
  state: State,
  control: optional(Control),
  meta: Meta,
  discoveredAt: Schema.Number,
  lastUsedAt: Schema.Number,
  updatedAt: Schema.Number,
  /** Whether the hub can stream it live and accept input (an adapter implements them). */
  live: Schema.Struct({ stream: Schema.Boolean, input: Schema.Boolean }),
}).annotate({ identifier: "Resources.Resource" })

export const Capability = Schema.Literals(["view", "control"]).annotate({ identifier: "Resources.Capability" })
export type Capability = typeof Capability.Type

export interface Ticket extends Schema.Schema.Type<typeof Ticket> {}
export const Ticket = Schema.Struct({
  ticket: Schema.String,
  /** Epoch milliseconds; open the connection before this. Open connections outlive the ticket. */
  expiresAt: Schema.Number,
  /** Hub path relative to the server origin (`/resources/<encoded id>`); append `/snapshot`, `/stream`, `/input`. */
  path: Schema.String,
  /** Hub loopback port: clients on the Mac itself (simulators, tests) connect to `127.0.0.1:<port>` directly. */
  loopbackPort: Schema.Int,
}).annotate({ identifier: "Resources.Ticket" })

export interface Snapshot extends Schema.Schema.Type<typeof Snapshot> {}
export const Snapshot = Schema.Struct({
  mime: Schema.Literals(["image/jpeg", "image/png"]),
  /** Base64 without a data URI prefix. */
  data: Schema.String,
  takenAt: Schema.Number,
  width: optional(Schema.Int),
  height: optional(Schema.Int),
}).annotate({ identifier: "Resources.Snapshot" })

export const Unavailable = Schema.Struct({
  reason: Schema.Literals(["not_found", "gone", "unsupported", "hub", "failed"]),
})

export const limits = {
  /** Alexandre's control expires after this long without input. */
  controlIdleMs: 120_000,
  /** Tickets must be redeemed within this window. */
  ticketMs: 60_000,
  agentRecentMs: 90_000,
  liveRecentMs: 600_000,
  snapshotMaxWidth: 1_600,
}

const error = { unavailable: Schema.toStandardSchemaV1(Unavailable) }

export const Definition = Rpc.define({
  id: "custom.resources",
  methods: {
    /** Resources of one session family (by its root) or, without `sessionID`, every known resource. */
    list: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: optional(Schema.String) })),
      output: Schema.toStandardSchemaV1(Schema.Struct({ resources: Schema.Array(Resource) })),
      errors: error,
    },
    get: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ id: ID })),
      output: Schema.toStandardSchemaV1(Resource),
      errors: error,
    },
    snapshot: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({
          id: ID,
          maxWidth: optional(Schema.Int.check(Schema.isBetween({ minimum: 64, maximum: limits.snapshotMaxWidth }))),
        }),
      ),
      output: Schema.toStandardSchemaV1(Snapshot),
      errors: error,
    },
    /** A short view ticket for `/snapshot` and `/stream`. Control tickets come only from `control`. */
    ticket: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ id: ID })),
      output: Schema.toStandardSchemaV1(Ticket),
      errors: error,
    },
    /**
     * `take` gives Alexandre control (the agent's shell commands naming the resource are refused) and returns a
     * control ticket; `renew` returns a fresh control ticket; `release` hands control back and tells the session.
     */
    control: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({ id: ID, action: Schema.Literals(["take", "renew", "release"]) }),
      ),
      output: Schema.toStandardSchemaV1(Schema.Struct({ resource: Resource, ticket: optional(Ticket) })),
      errors: error,
    },
    /** Removes a resource from the lists; it reappears if an agent uses it again. */
    dismiss: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ id: ID })),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
      errors: error,
    },
  },
  events: {
    /** Something changed; clients reload `list`. `ids` is a hint, not a complete diff. */
    changed: { schema: Schema.toStandardSchemaV1(Schema.Struct({ ids: Schema.Array(Schema.String) })) },
  },
})
