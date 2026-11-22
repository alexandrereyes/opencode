export * as Bancada from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"
import { BancadaProtocol } from "./protocol.js"

/**
 * The Bancada (`docs/bancada.md`): one process per machine that owns its test devices and runs tests away from the
 * server; the hub's also keeps the queue of every machine. `custom.bancada` is how tools, apps and other servers
 * reach it; every handler only relays to this machine's process.
 */

/** Version of the protocol between servers; a server of another version is refused by name, never half understood. */
export const protocol = BancadaProtocol.version

/** `reconciling`: the process came back and checks what ran while it was away before it takes new work. */
export const State = Schema.Literals(["ok", "reconciling"]).annotate({ identifier: "Bancada.State" })
export type State = typeof State.Type

export const Owner = Schema.Struct({ instanceID: Schema.String, name: Schema.String }).annotate({
  identifier: "Bancada.Owner",
})
export type Owner = typeof Owner.Type

/**
 * `off`: `OPENCODE_BANCADA=0` on this server. `process`: this machine's process does not answer. `owner`: it serves
 * another server of this machine (`owner`). `reconciling`: it is back and still checking what ran meanwhile.
 */
export const Unavailable = Schema.Struct({
  reason: Schema.Literals(["off", "process", "owner", "reconciling"]),
  owner: optional(Owner),
}).annotate({ identifier: "Bancada.Unavailable" })
export type Unavailable = typeof Unavailable.Type

export const Wake = Schema.Struct({ protocol: Schema.Number, state: State }).annotate({ identifier: "Bancada.Wake" })
export type Wake = typeof Wake.Type

/**
 * A request to run tests of the session's `.bancada.toml` (`docs/bancada.md`, "Request"). Keys in Portuguese: the
 * agent writes it. `id` is required: the tool derives it from its call, so a call made again (after a deadline, or a
 * restart) is the same request, never a second one.
 */
export const Request = Schema.Struct({
  id: BancadaProtocol.JobID,
  sessionID: Schema.String,
  rootSessionID: optional(Schema.String),
  sessionTitle: optional(Schema.String),
  rootTitle: optional(Schema.String),
  toolCallID: optional(Schema.String),
  diretorio: Schema.String,
  testes: Schema.Array(
    Schema.Struct({ teste: BancadaProtocol.PartName, args: optional(Schema.Array(Schema.String)) }),
  ).check(Schema.isMinLength(1), Schema.isMaxLength(8)),
  snapshot: optional(Schema.Boolean),
  commit: optional(Schema.String),
}).annotate({ identifier: "Bancada.Request" })
export type Request = typeof Request.Type

export const Submitted = Schema.Struct({
  job: BancadaProtocol.JobID,
  state: Schema.String,
  /** The frozen commit (in a snapshot, one the Bancada made). */
  commit: Schema.String,
  /** The owner's commit: `HEAD` at the request, or the commit asked. What the tool and the notice show. */
  base: Schema.String,
  snapshot: optional(
    Schema.Struct({
      arquivos: Schema.Array(
        Schema.Struct({ caminho: Schema.String, mudanca: Schema.Literals(["novo", "alterado", "removido"]) }),
      ),
      naoIncluidos: optional(Schema.Int),
    }),
  ),
  /** Earlier requests of this session this one replaced while they waited. */
  substituiu: optional(Schema.Array(Schema.String)),
  partes: Schema.Array(
    Schema.Struct({
      teste: Schema.String,
      rotulo: Schema.String,
      posicao: optional(Schema.Int),
      etaMs: optional(Schema.Number),
      motivo: optional(BancadaProtocol.Reason),
    }),
  ),
}).annotate({ identifier: "Bancada.Submitted" })
export type Submitted = typeof Submitted.Type

/** Where a part of a request stands, as its origin knows it (`docs/bancada.md`, "status"). */
export const PartView = Schema.Struct({
  state: BancadaProtocol.PartState,
  attempt: Schema.Number,
  machine: optional(BancadaProtocol.MachineRef),
  position: optional(Schema.Number),
  etaMs: optional(Schema.Number),
  reason: optional(BancadaProtocol.Reason),
  devices: optional(Schema.Array(BancadaProtocol.UsedDevice)),
}).annotate({ identifier: "Bancada.PartView" })
export const JobView = Schema.Struct({
  job: Schema.String,
  /** `aguardando_confirmacao`, `na_fila`, `recebido` (its notice is being made), `concluido` (notice ready). */
  state: Schema.String,
  sessionID: Schema.String,
  /** The session's title, when the request is a subagent's (its session is not the family's root). */
  sessionTitle: optional(Schema.String),
  rootSessionID: Schema.String,
  commit: Schema.String,
  base: Schema.String,
  /** How many uncommitted files the snapshot took beyond `base`. */
  snapshotFiles: optional(Schema.Number),
  replaced: optional(Schema.Array(Schema.String)),
  labels: Schema.Record(Schema.String, Schema.String),
  parts: Schema.Record(Schema.String, PartView),
  result: optional(Schema.Array(BancadaProtocol.PartResult)),
  /** The notice's text, once made. */
  notice: optional(Schema.String),
}).annotate({ identifier: "Bancada.JobView" })
export type JobView = typeof JobView.Type

export const Invalid = Schema.Struct({ problems: Schema.Array(Schema.String) }).annotate({
  identifier: "Bancada.Invalid",
})

const errors = { unavailable: Schema.toStandardSchemaV1(Unavailable) }

/** Refusals between servers, by name: a call of another version or one the hub cannot read is never half applied. */
export const ProtocolMismatch = Schema.Struct({ expected: Schema.Number }).annotate({
  identifier: "Bancada.ProtocolMismatch",
})
export const MachineTaken = Schema.Struct({ instanceID: Schema.String, name: Schema.String }).annotate({
  identifier: "Bancada.MachineTaken",
})
const between = {
  ...errors,
  not_hub: Schema.toStandardSchemaV1(Schema.Struct({})),
  protocol_mismatch: Schema.toStandardSchemaV1(ProtocolMismatch),
  machine_taken: Schema.toStandardSchemaV1(MachineTaken),
  invalid: Schema.toStandardSchemaV1(Schema.Struct({})),
}
/**
 * Loose on purpose (`docs/bancada.md`, "sync"): the process reads them against the protocol, so another version is
 * refused as `protocol_mismatch`, not as a generic invalid input.
 */
const loose = Schema.toStandardSchemaV1(Schema.Record(Schema.String, Schema.Unknown))

export const Definition = Rpc.define({
  id: "custom.bancada",
  methods: {
    /** Makes sure this machine's process runs; any call also loads the plugin of a server nobody opened yet. */
    wake: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Wake),
      errors,
    },
    /**
     * A request of a session of this server (`Request`): its code frozen now, queued at the hub (or here, with the hub
     * out). The same `id` is the same request.
     */
    submit: {
      input: Schema.toStandardSchemaV1(Request),
      output: Schema.toStandardSchemaV1(Submitted),
      errors: { ...errors, invalid: Schema.toStandardSchemaV1(Invalid) },
    },
    /**
     * Requests of this server: one (`job`; with `waitMs`, held until its notice is ready, up to 25 s), or those of a
     * session's family not delivered yet (`sessionID`).
     */
    status: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({
          job: optional(Schema.String),
          sessionID: optional(Schema.String),
          waitMs: optional(Schema.Number),
        }),
      ),
      output: Schema.toStandardSchemaV1(Schema.Struct({ jobs: Schema.Array(JobView) })),
      errors,
    },
    /** Cancels a request of this server: what waits closes now, what runs stops; its notice says so. */
    cancel: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ job: Schema.String })),
      output: Schema.toStandardSchemaV1(Schema.Struct({ state: Schema.String })),
      errors,
    },
    /**
     * The devices and waits of a session's family (`docs/bancada.md`, "session"; fixture `session-a1-b1.json`): asked
     * on the session's server, for the root or any subagent.
     */
    session: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ sessionID: Schema.String })),
      output: loose,
      errors,
    },
    /**
     * The queue (`docs/bancada.md`, "queue"; fixtures `queue-c2-d1-f3.json`, `queue-local.json`): the whole one on the
     * hub, this server's own view elsewhere.
     */
    queue: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: loose,
      errors,
    },
    /** Another machine's call to the hub (`BancadaProtocol.SyncInput` → `SyncOutput`); only the hub takes it. */
    sync: { input: loose, output: loose, errors: between },
    /** A chunk of a transfer's file, from the machine the hub named its sender (`BancadaProtocol.BlobPut`). */
    "blob.put": { input: loose, output: loose, errors: between },
    /** A chunk of a transfer's file, for the machine the hub named its receiver (`BancadaProtocol.BlobGet`). */
    "blob.get": { input: loose, output: loose, errors: between },
  },
  events: {
    /**
     * A family's `session` or this server's `queue` changed (at most one a second; not for an estimate alone). No
     * counts: the apps reload what it names.
     */
    changed: {
      schema: Schema.toStandardSchemaV1(
        Schema.Struct({ sessions: Schema.Array(Schema.String), queue: Schema.Boolean }),
      ),
    },
    /** A new exception for the owner (`queue.alerts`). */
    alert: {
      schema: Schema.toStandardSchemaV1(Schema.Struct({ id: Schema.String, kind: Schema.String, text: Schema.String })),
    },
  },
})
