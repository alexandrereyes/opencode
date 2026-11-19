export * as BancadaProtocol from "./protocol.js"

import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

/**
 * Messages between a machine and the hub (`docs/bancada.md`, "Protocol"). The machine always calls the hub
 * (`custom.bancada/sync`); the hub answers with what it has for that machine. Delivery is at least once and in order,
 * per pair: each side keeps its outbox until the other acknowledges it and applies only the next sequence number, so
 * a message repeated, lost and sent again, or arriving late never changes anything twice.
 */

/** Changes only with an incompatible change of these messages; a peer of another version is refused by name. */
export const version = 1

export const JobID = Schema.String.check(Schema.isPattern(/^j-[0-9a-hjkmnp-tv-z]{8}$/)).annotate({
  identifier: "Bancada.JobID",
})
/** A test of the project's `.bancada.toml`; one part of a request. */
export const PartName = Schema.String.check(Schema.isPattern(/^[a-z0-9-]{1,40}$/)).annotate({
  identifier: "Bancada.PartName",
})
/** The alphabet of request ids: digits and lowercase letters without `i`, `l`, `o` and `u` (never misread). */
const alphabet = "0123456789abcdefghjkmnpqrstvwxyz"

/**
 * A request id from a seed: `j-` and 8 characters of SHA-256. The tool seeds it with its server and its call, so a call
 * made again (the server restarted meanwhile) is the same request; anything else seeds it with random bytes.
 */
export function jobID(seed: string) {
  const digest = new Bun.CryptoHasher("sha256").update(seed).digest()
  return `j-${Array.from(digest.subarray(0, 8), (byte) => alphabet[byte % 32]).join("")}`
}

const Seq = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))
const Count = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))

/**
 * The state of a part. `oferecido`: a machine was asked; `aceito`: that machine reserved it (and prepares code and
 * devices, `phase`); `incerto`: its machine went silent while it ran. The last four are final.
 */
export const PartState = Schema.Literals([
  "na_fila",
  "oferecido",
  "aceito",
  "compilando",
  "rodando",
  "incerto",
  "concluido",
  "perdido",
  "cancelado",
  "invalido",
]).annotate({ identifier: "Bancada.PartState" })
export type PartState = typeof PartState.Type
export const finalStates: ReadonlySet<PartState> = new Set(["concluido", "perdido", "cancelado", "invalido"])

/** What an executor reports about its attempt; `aceito` travels as the offer's reply. */
export const AttemptState = Schema.Literals(["compilando", "rodando", "concluido", "perdido", "cancelado"]).annotate({
  identifier: "Bancada.AttemptState",
})
export type AttemptState = typeof AttemptState.Type

/** Why a part waits, ready for the apps (`docs/bancada.md`, "Reason"). */
export const Reason = Schema.Struct({
  code: Schema.Literals([
    "fila",
    "orcamento",
    "freio",
    "sem_maquina",
    "maquina_fora",
    "aparelho_ocupado",
    "trava",
    "aguardando_hub",
    "aguardando_confirmacao",
    "aguardando_codigo",
    "reconciliando",
  ]),
  detail: optional(Schema.String),
  text: Schema.String,
}).annotate({ identifier: "Bancada.Reason" })
export type Reason = typeof Reason.Type

/**
 * Free capacity of a machine as its executor counts it: memory, CPU and builds, and how many more Android emulators
 * and iOS simulators its ceilings allow.
 */
export const Vector = Schema.Struct({
  memMb: Schema.Number,
  cpuMilli: Schema.Number,
  builds: Count,
  android: Count,
  ios: Count,
}).annotate({ identifier: "Bancada.Vector" })
export type Vector = typeof Vector.Type

/** The kind of device a part asks for; `none` is a test without devices. */
export const Platform = Schema.Literals(["android", "ios", "none"]).annotate({ identifier: "Bancada.Platform" })
export type Platform = typeof Platform.Type

/** The project's `aparelho`, resolved. */
export const DeviceSpec = Schema.Struct({
  api: optional(Schema.String),
  ios: optional(Schema.String),
  model: optional(Schema.String),
  googlePlay: optional(Schema.Boolean),
  slim: optional(Schema.Literals(["aceita", "exige", "recusa"])),
  tags: optional(Schema.Array(Schema.String)),
}).annotate({ identifier: "Bancada.DeviceSpec" })
export type DeviceSpec = typeof DeviceSpec.Type

/**
 * One part as the hub chooses a machine for it. The commands are not here: an executor runs only what the
 * `.bancada.toml` of the checked-out commit says. `unsafe`: a physical device, real accounts, an exclusive lock or
 * secrets; such a part runs again only after its machine confirmed the earlier attempt ended.
 */
export const PartSpec = Schema.Struct({
  part: PartName,
  label: Schema.String,
  platform: Platform,
  needs: Schema.Array(Schema.String),
  device: DeviceSpec,
  devices: Schema.Struct({ min: Count, max: Count }),
  exclusive: Schema.Array(Schema.String),
  secrets: optional(Schema.String),
  unsafe: Schema.Boolean,
  args: Schema.Array(Schema.String),
}).annotate({ identifier: "Bancada.PartSpec" })
export type PartSpec = typeof PartSpec.Type

/** The session that asked, on the server where it lives, and the root of its family; titles as when it asked. */
export const Origin = Schema.Struct({
  instanceID: Schema.String,
  machineID: Schema.String,
  name: Schema.String,
  sessionID: Schema.String,
  rootSessionID: Schema.String,
  sessionTitle: optional(Schema.String),
  rootTitle: optional(Schema.String),
}).annotate({ identifier: "Bancada.Origin" })
export type Origin = typeof Origin.Type

/** The frozen code: the project, the commit, the project's remotes (no credentials) and whether one has the commit. */
export const Code = Schema.Struct({
  project: Schema.String,
  commit: Schema.String,
  remotes: Schema.Array(Schema.String),
  inRemote: Schema.Boolean,
}).annotate({ identifier: "Bancada.Code" })
export type Code = typeof Code.Type

export const Scenario = Schema.Struct({
  id: Schema.String,
  name: optional(Schema.String),
  result: Schema.Literals(["passou", "falhou", "ignorado"]),
  message: optional(Schema.String),
  durationMs: optional(Schema.Number),
  device: optional(Schema.String),
  evidence: optional(Schema.Array(Schema.String)),
}).annotate({ identifier: "Bancada.Scenario" })
export type Scenario = typeof Scenario.Type

/**
 * How an attempt ended, as its executor judged it against false green (`results.ts`): `approved` only with exit 0,
 * every planned scenario with a result and none failed. `planned`: the scenarios expected of this attempt (those asked
 * again, on a new attempt); `lost`: those without a result. `verdict` says why it is not approved: `compilacao` (the
 * build failed), `sem_relatorio` (exit 1 with no failed scenario), `incompleto` (exit 0 without every result),
 * `infraestrutura` (exit 75, another code, a deadline or a dead runner), `invalido` (exit 2), `cancelado`.
 */
export const Outcome = Schema.Struct({
  exit: optional(Schema.Int),
  verdict: Schema.Literals([
    "aprovado",
    "falhou",
    "incompleto",
    "sem_relatorio",
    "compilacao",
    "infraestrutura",
    "invalido",
    "cancelado",
  ]),
  reason: optional(Schema.String),
  planned: Schema.Array(Schema.String),
  scenarios: Schema.Array(Scenario),
  lost: Schema.Array(Schema.String),
  approved: Schema.Boolean,
  /** The end of the command's log, for a failure the scenarios do not explain. */
  logTail: optional(Schema.String),
}).annotate({ identifier: "Bancada.Outcome" })
export type Outcome = typeof Outcome.Type

export const MachineRef = Schema.Struct({ machineID: Schema.String, name: Schema.String }).annotate({
  identifier: "Bancada.MachineRef",
})

const File = Schema.Struct({ index: Count, path: Schema.String, size: Count, sha256: Schema.String })
const Transfer = Schema.Struct({ id: Schema.String, files: Schema.Array(File) })
const HoldTarget = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("vaga"), platform: Schema.Literals(["android", "ios"]), name: Schema.String }),
  Schema.Struct({ kind: Schema.Literal("fisico"), device: Schema.String }),
])

// Machine → hub.

/** Who the machine is and what it offers; sent when it starts, when it changes and when the hub forgot it. */
export const Hello = Schema.Struct({
  type: Schema.Literal("hello"),
  platform: Schema.Literals(["darwin", "linux"]),
  capabilities: Schema.Record(Schema.String, Schema.Unknown),
  speed: Schema.Literals(["normal", "lento"]),
})
export const Submit = Schema.Struct({
  type: Schema.Literal("submit"),
  job: JobID,
  origin: Origin,
  code: Code,
  parts: Schema.Array(PartSpec).check(Schema.isMinLength(1), Schema.isMaxLength(8)),
  createdAt: Schema.Number,
})
export const Cancel = Schema.Struct({ type: Schema.Literal("cancel"), job: JobID })
export const OfferAccepted = Schema.Struct({
  type: Schema.Literal("offer.reply"),
  job: JobID,
  part: PartName,
  attempt: Count,
  accepted: Schema.Literal(true),
  devices: Count,
})
export const OfferRefused = Schema.Struct({
  type: Schema.Literal("offer.reply"),
  job: JobID,
  part: PartName,
  attempt: Count,
  accepted: Schema.Literal(false),
  reason: Reason,
})
export const AttemptReport = Schema.Struct({
  type: Schema.Literal("attempt"),
  job: JobID,
  part: PartName,
  attempt: Count,
  state: AttemptState,
  phase: optional(Schema.Literals(["codigo", "aparelhos"])),
  planned: optional(Count),
  outcome: optional(Outcome),
  /** A device that fell during this attempt (a fault for it; not returned to this attempt). */
  fell: optional(Schema.String),
})
export const CodeHave = Schema.Struct({
  type: Schema.Literal("code.have"),
  job: JobID,
  have: Schema.Array(Schema.String),
})
export const BlobReady = Schema.Struct({ type: Schema.Literal("blob.ready"), transfer: Transfer })
export const HoldRequest = Schema.Struct({
  type: Schema.Literal("hold.request"),
  hold: Schema.String,
  origin: Origin,
  machineID: Schema.String,
  target: HoldTarget,
})
export const HoldTouch = Schema.Struct({ type: Schema.Literal("hold.touch"), hold: Schema.String, at: Schema.Number })
export const HoldRelease = Schema.Struct({ type: Schema.Literal("hold.release"), hold: Schema.String })
export const Delivered = Schema.Struct({ type: Schema.Literal("delivered"), job: JobID })
export const LocalJob = Schema.Struct({
  type: Schema.Literal("local.job"),
  job: JobID,
  origin: Origin,
  code: Code,
  parts: Schema.Array(Schema.Struct({ spec: PartSpec, state: PartState, outcome: optional(Outcome) })),
})

export const FromMachine = Schema.Union([
  Hello,
  Submit,
  Cancel,
  OfferAccepted,
  OfferRefused,
  AttemptReport,
  CodeHave,
  BlobReady,
  HoldRequest,
  HoldTouch,
  HoldRelease,
  Delivered,
  LocalJob,
]).annotate({ identifier: "Bancada.FromMachine" })
export type FromMachine = typeof FromMachine.Type

// Hub → machine.

const PartView = Schema.Struct({
  part: PartName,
  position: optional(Count),
  etaMs: optional(Schema.Number),
  reason: optional(Reason),
})
export const SubmitAck = Schema.Struct({
  type: Schema.Literal("submit.ack"),
  job: JobID,
  parts: Schema.Array(PartView),
  superseded: Schema.Array(JobID),
})
export const JobUpdate = Schema.Struct({
  type: Schema.Literal("job.update"),
  job: JobID,
  part: PartName,
  state: PartState,
  attempt: Count,
  machine: optional(MachineRef),
  position: optional(Count),
  etaMs: optional(Schema.Number),
  reason: optional(Reason),
})
export const Offer = Schema.Struct({
  type: Schema.Literal("offer"),
  job: JobID,
  part: PartName,
  attempt: Count,
  spec: PartSpec,
  origin: Origin,
  code: Code,
  devices: Schema.Struct({ min: Count, proposed: Count }),
  /** A new attempt runs only these scenarios (the ones without a result). */
  only: optional(Schema.Array(Schema.String)),
})
export const AttemptCancel = Schema.Struct({
  type: Schema.Literal("attempt.cancel"),
  job: JobID,
  part: PartName,
  attempt: Count,
  reason: Schema.String,
})
export const CodeRequest = Schema.Struct({
  type: Schema.Literal("code.request"),
  job: JobID,
  have: Schema.Array(Schema.String),
  transfer: Schema.String,
})
export const CodeSource = Schema.Struct({
  type: Schema.Literal("code.source"),
  job: JobID,
  source: Schema.Union([
    Schema.Struct({ remote: Schema.Struct({ url: Schema.String, commit: Schema.String }) }),
    Schema.Struct({ transfer: Transfer }),
  ]),
})
export const PartResult = Schema.Struct({
  part: PartName,
  state: PartState,
  attempts: Count,
  machine: optional(MachineRef),
  outcome: optional(Outcome),
})
export type PartResult = typeof PartResult.Type
export const Result = Schema.Struct({
  type: Schema.Literal("result"),
  job: JobID,
  parts: Schema.Array(PartResult),
  evidence: optional(Schema.String),
})
export const HoldGrant = Schema.Struct({
  type: Schema.Literal("hold.grant"),
  hold: Schema.String,
  device: Schema.Record(Schema.String, Schema.String),
  expiresAt: Schema.Number,
})
export const HoldDeny = Schema.Struct({
  type: Schema.Literal("hold.deny"),
  hold: Schema.String,
  reason: Reason,
  position: optional(Count),
})
export const HoldExpire = Schema.Struct({ type: Schema.Literal("hold.expire"), hold: Schema.String })
export const Cleanup = Schema.Struct({ type: Schema.Literal("cleanup"), job: JobID })

export const FromHub = Schema.Union([
  SubmitAck,
  JobUpdate,
  Offer,
  AttemptCancel,
  CodeRequest,
  CodeSource,
  Result,
  HoldGrant,
  HoldDeny,
  HoldExpire,
  Cleanup,
]).annotate({ identifier: "Bancada.FromHub" })
export type FromHub = typeof FromHub.Type

// The exchange.

/**
 * One side's stream of messages to the other: `stream` names it (drawn when the sender first wrote to that peer, so
 * a peer whose database was replaced is recognised), `base` is the last sequence number the receiver already
 * acknowledged, and `messages` are the rest, in order. A receiver that does not know the stream starts after `base`.
 */
const stream = <S extends Schema.Top>(message: S) =>
  Schema.Struct({
    stream: Schema.String,
    base: Seq,
    messages: Schema.Array(Schema.Struct({ seq: Seq, body: message })),
  })
/** The last message applied from the other side's stream; null before the first. */
export const Ack = Schema.NullOr(Schema.Struct({ stream: Schema.String, seq: Seq }))
export type Ack = typeof Ack.Type

export const AttemptRef = Schema.Struct({ job: JobID, part: PartName, attempt: Count })

/** The machine's state, renewed with every call: `seq` orders pulses, so a late one never overwrites a newer one. */
export const Pulse = Schema.Struct({
  seq: Seq,
  state: Schema.Literals(["ok", "reconciling"]),
  free: Vector,
  brake: Schema.Boolean,
  presence: Schema.Boolean,
  running: Schema.Array(AttemptRef),
})
export type Pulse = typeof Pulse.Type

export const SyncInput = Schema.Struct({
  protocol: Schema.Number,
  machineID: Schema.String,
  instanceID: Schema.String,
  name: Schema.String,
  out: stream(FromMachine),
  ack: Ack,
  pulse: Pulse,
  leaving: optional(Schema.Literals(["restart", "stop"])),
  /** 0 answers at once; up to `limits.waitMs`, the hub holds the call until it has something for this machine. */
  waitMs: Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 25_000 })),
}).annotate({ identifier: "Bancada.SyncInput" })
export type SyncInput = typeof SyncInput.Type

export const SyncOutput = Schema.Struct({
  protocol: Schema.Number,
  out: stream(FromHub),
  ack: Ack,
}).annotate({ identifier: "Bancada.SyncOutput" })
export type SyncOutput = typeof SyncOutput.Type

export type Envelope<M> = { readonly seq: number; readonly body: M }
