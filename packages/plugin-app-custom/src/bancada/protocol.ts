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

/** A hold id (`r-` and 8 characters), seeded like `jobID`: the tool's call made again is the same hold. */
export function holdID(seed: string) {
  return `r-${jobID(seed).slice(2)}`
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
  /** A phone besides the devices (`celular`); a test with a phone only asks for it by `needs` and `device.tags`. */
  phone: optional(Schema.Struct({ tags: Schema.Array(Schema.String) })),
  exclusive: Schema.Array(Schema.String),
  secrets: optional(Schema.String),
  unsafe: Schema.Boolean,
  /** The test has a `build`: its attempt reserves a build (one per group: the group builds once). */
  build: Schema.Boolean,
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

/**
 * What comes in a message never becomes a command option: a commit is a full SHA (SHA-1 or SHA-256), a remote has the
 * shape of a remote (`scheme://…` or `user@host:path`), and neither can start with `-`.
 */
export const Commit = Schema.String.check(Schema.isPattern(/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/)).annotate({
  identifier: "Bancada.Commit",
})
export const RemoteURL = Schema.String.check(
  Schema.isPattern(/^(?:[a-z][a-z0-9+.-]*:\/\/[^\s]+|[^\s@/:-][^\s@/:]*@[^\s:/]+:[^\s]+)$/i),
).annotate({ identifier: "Bancada.RemoteURL" })

/** The frozen code: the project, the commit, the project's remotes (no credentials) and whether one has the commit. */
export const Code = Schema.Struct({
  project: Schema.String,
  commit: Commit,
  remotes: Schema.Array(RemoteURL),
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
  /** A new attempt ran: how many scenarios it ran again, and why the first left them without result. */
  retried: optional(Schema.Struct({ count: Count, reason: optional(Schema.String) })),
}).annotate({ identifier: "Bancada.Outcome" })
export type Outcome = typeof Outcome.Type

export const MachineRef = Schema.Struct({
  machineID: Schema.String,
  name: Schema.String,
  /** The `custom.instance` id of the server that owns that machine's Bancada (what the apps key servers by). */
  instanceID: optional(Schema.String),
}).annotate({
  identifier: "Bancada.MachineRef",
})
/**
 * A device an attempt uses, as the apps show it (`docs/bancada.md`, "App surface"): its kind, the Bancada's name for
 * it, and its id in the resources hub when it has one (`android-emulator:<AVD>`, `ios-simulator:<UDID>`).
 */
export const UsedDevice = Schema.Struct({
  kind: Schema.String,
  id: Schema.String,
  resourceID: optional(Schema.String),
})

export const File = Schema.Struct({
  index: Count,
  path: Schema.String,
  size: Count,
  sha256: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
})
export type File = typeof File.Type
export const Transfer = Schema.Struct({ id: Schema.String, files: Schema.Array(File) })
export type Transfer = typeof Transfer.Type
export const HoldTarget = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("vaga"), platform: Schema.Literals(["android", "ios"]), name: Schema.String }),
  Schema.Struct({ kind: Schema.Literal("fisico"), device: Schema.String }),
])

// Machine → hub.

/** Who the machine is and what it offers; sent when it starts, when it changes and when the hub forgot it. */
/** A phone of a machine's catalog, as the hook of every machine must recognise it (`docs/bancada.md`, "Hook"). */
export const CatalogPhone = Schema.Struct({
  alias: Schema.String,
  id: Schema.String,
  platform: Schema.Literals(["android", "ios"]),
  policy: Schema.Literals(["reservavel", "negar"]),
  /** What adb calls it now besides its id (a Wi-Fi phone's `ip:porta` or mDNS name): commands cite it so too. */
  serials: optional(Schema.Array(Schema.String)),
})
export const Hello = Schema.Struct({
  type: Schema.Literal("hello"),
  platform: Schema.Literals(["darwin", "linux"]),
  capabilities: Schema.Record(Schema.String, Schema.Unknown),
  speed: Schema.Literals(["normal", "lento"]),
  /** Its phones, `negar` ones included. */
  phones: optional(Schema.Array(CatalogPhone)),
  /**
   * Its hardware identity, for a machine that reaches it through a bridge (`mac`): `machineID()` of
   * `resources/machine.ts` over its `IOPlatformUUID` (a hash; the raw UUID never leaves the machine).
   */
  hardware: optional(Schema.String),
})
export const Submit = Schema.Struct({
  type: Schema.Literal("submit"),
  job: JobID,
  origin: Origin,
  code: Code,
  parts: Schema.Array(PartSpec).check(Schema.isMinLength(1), Schema.isMaxLength(8)),
  createdAt: Schema.Number,
  /** Sent again to a hub that forgot (another stream): it waits for the machines to list what runs before offering. */
  again: optional(Schema.Boolean),
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
  /** With `rodando`: the devices it got. */
  devices: optional(Schema.Array(UsedDevice)),
  /** It ran only some scenarios (`only`): a new attempt, whose result joins an earlier one's. */
  partial: optional(Schema.Literal(true)),
  /** At its end: what it keeps for the notice (failed scenarios' evidence, the log of a failure without them). */
  evidence: optional(Schema.Array(File)),
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
/**
 * The machine that has the device, on a hold the hub relayed to it (`hold.ask`): where it stands now. `concedida` with
 * the device as it is now (serial, UDID) and when it ends at the latest; `esperando` with its place; `negada` with why;
 * `vencida` or `solta` when it ended.
 */
export const HoldState = Schema.Struct({
  type: Schema.Literal("hold.state"),
  hold: Schema.String,
  state: Schema.Literals(["concedida", "esperando", "negada", "vencida", "solta"]),
  device: optional(Schema.Record(Schema.String, Schema.String)),
  expiresAt: optional(Schema.Number),
  position: optional(Count),
  reason: optional(Reason),
})
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
  HoldState,
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
  devices: optional(Schema.Array(UsedDevice)),
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
    Schema.Struct({ remote: Schema.Struct({ url: RemoteURL, commit: Commit }) }),
    Schema.Struct({ transfer: Transfer }),
  ]),
})
/**
 * Evidence of an attempt, for the notice: in a transfer from its executor to the origin, or (no transfer) on the
 * origin's own machine, in the attempt's folder.
 */
export const Evidence = Schema.Struct({
  attempt: Count,
  transfer: optional(Schema.String),
  files: Schema.Array(File),
})
export type Evidence = typeof Evidence.Type
export const PartResult = Schema.Struct({
  part: PartName,
  state: PartState,
  /** Offers made, not executions: never to be told as runs. */
  attempts: Count,
  machine: optional(MachineRef),
  outcome: optional(Outcome),
  /** How long its last attempt took, from its acceptance to its end. */
  ms: optional(Schema.Number),
  /** For each failed scenario: how many of its last results (this one included) failed. */
  history: optional(Schema.Record(Schema.String, Schema.Struct({ failed: Count, of: Count }))),
  evidence: optional(Schema.Array(Evidence)),
})
export type PartResult = typeof PartResult.Type
export const Result = Schema.Struct({
  type: Schema.Literal("result"),
  job: JobID,
  parts: Schema.Array(PartResult),
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
  /** The name of the machine that has the device, when one was found. */
  machine: optional(Schema.String),
  /** While waiting: when the device's current hold ends at the latest. */
  expiresAt: optional(Schema.Number),
})
export const HoldExpire = Schema.Struct({
  type: Schema.Literal("hold.expire"),
  hold: Schema.String,
  reason: optional(Schema.String),
})
/** To the machine that has the device: a hold another machine's session asks (`hold.request`, relayed). */
export const HoldAsk = Schema.Struct({
  type: Schema.Literal("hold.ask"),
  hold: Schema.String,
  origin: Origin,
  target: HoldTarget,
})
/** Relayed `hold.touch` and `hold.release`. */
export const HoldRenew = Schema.Struct({ type: Schema.Literal("hold.renew"), hold: Schema.String, at: Schema.Number })
export const HoldDrop = Schema.Struct({ type: Schema.Literal("hold.drop"), hold: Schema.String })
export const Cleanup = Schema.Struct({ type: Schema.Literal("cleanup"), job: JobID })
/** To the executor: send this attempt's evidence in the transfer the hub named, to the origin. */
export const EvidenceRequest = Schema.Struct({
  type: Schema.Literal("evidence.request"),
  job: JobID,
  part: PartName,
  attempt: Count,
  transfer: Schema.String,
})

/**
 * From the hub to every machine, when a machine said hello: the machines and their phones, so each machine's hook knows
 * a phone of another machine's catalog and which machine is behind its `mac` bridge, without asking anyone.
 */
export const Catalog = Schema.Struct({
  type: Schema.Literal("catalog"),
  machines: Schema.Array(
    Schema.Struct({
      machineID: Schema.String,
      name: Schema.String,
      platform: optional(Schema.String),
      hardware: optional(Schema.String),
      instanceID: optional(Schema.String),
    }),
  ),
  phones: Schema.Array(Schema.Struct({ ...CatalogPhone.fields, machineID: Schema.String })),
})

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
  EvidenceRequest,
  HoldAsk,
  HoldRenew,
  HoldDrop,
  Catalog,
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
  /** Live attempts. */
  running: Schema.Array(AttemptRef),
  /** Ended attempts this machine still keeps (no `cleanup` yet): a hub that forgot adopts them too. */
  kept: Schema.Array(AttemptRef),
})
export type Pulse = typeof Pulse.Type

const syncInput = <S extends Schema.Top>(message: S) =>
  Schema.Struct({
    protocol: Schema.Number,
    machineID: Schema.String,
    instanceID: Schema.String,
    name: Schema.String,
    out: stream(message),
    ack: Ack,
    pulse: Pulse,
    leaving: optional(Schema.Literals(["restart", "stop"])),
    /** 0 answers at once; up to `limits.waitMs`, the hub holds the call until it has something for this machine. */
    waitMs: Schema.Number.check(Schema.isBetween({ minimum: 0, maximum: 25_000 })),
  })
const syncOutput = <S extends Schema.Top>(message: S) =>
  Schema.Struct({ protocol: Schema.Number, out: stream(message), ack: Ack })

export const SyncInput = syncInput(FromMachine).annotate({ identifier: "Bancada.SyncInput" })
export type SyncInput = typeof SyncInput.Type
export const SyncOutput = syncOutput(FromHub).annotate({ identifier: "Bancada.SyncOutput" })
export type SyncOutput = typeof SyncOutput.Type

/**
 * The call as it is read first (`docs/bancada.md`, "sync", rule 6): the envelope strictly, each message's body alone
 * when it is applied. One body that does not decode goes to `dead_letter`; it never refuses the call around it.
 */
export const SyncInputEnvelope = syncInput(Schema.Unknown).annotate({ identifier: "Bancada.SyncInputEnvelope" })
export type SyncInputEnvelope = typeof SyncInputEnvelope.Type
export const SyncOutputEnvelope = syncOutput(Schema.Unknown).annotate({ identifier: "Bancada.SyncOutputEnvelope" })
export type SyncOutputEnvelope = typeof SyncOutputEnvelope.Type

export type Envelope<M> = { readonly seq: number; readonly body: M }

// Bytes through the hub (`docs/bancada.md`, "Blobs"): only the machine the hub named for a transfer writes or reads it.

/** Who calls, as in `sync`: a transfer is written only by its sender and read only by its receiver. */
const Caller = { protocol: Schema.Number, machineID: Schema.String, instanceID: Schema.String }

/** A chunk of a file at `offset`, which must be what the hub already has of it; `end` with its last byte. */
export const BlobPut = Schema.Struct({
  ...Caller,
  transfer: Schema.String,
  file: File,
  offset: Count,
  /** Base64, at most 1 MiB once decoded. */
  data: Schema.String,
  end: optional(Schema.Boolean),
}).annotate({ identifier: "Bancada.BlobPut" })
export type BlobPut = typeof BlobPut.Type
/** `offset`: the hub has another size of the file (`received`), from which the sender resumes. */
export const BlobPutOutput = Schema.Union([
  Schema.Struct({ ok: Schema.Literal(true), received: Count, done: Schema.Boolean }),
  Schema.Struct({
    ok: Schema.Literal(false),
    reason: Schema.Literals(["unknown", "expired", "offset", "limit", "size", "sha256"]),
    received: optional(Count),
  }),
]).annotate({ identifier: "Bancada.BlobPutOutput" })
export type BlobPutOutput = typeof BlobPutOutput.Type

export const BlobGet = Schema.Struct({
  ...Caller,
  transfer: Schema.String,
  index: Count,
  offset: Count,
  size: Count,
}).annotate({ identifier: "Bancada.BlobGet" })
export type BlobGet = typeof BlobGet.Type
export const BlobGetOutput = Schema.Union([
  Schema.Struct({ ok: Schema.Literal(true), data: Schema.String, end: Schema.Boolean }),
  Schema.Struct({ ok: Schema.Literal(false), reason: Schema.Literals(["unknown", "expired", "incomplete"]) }),
]).annotate({ identifier: "Bancada.BlobGetOutput" })
export type BlobGetOutput = typeof BlobGetOutput.Type
