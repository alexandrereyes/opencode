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
  esperar: optional(Schema.Boolean),
}).annotate({ identifier: "Bancada.Request" })
export type Request = typeof Request.Type

export const Submitted = Schema.Struct({
  job: BancadaProtocol.JobID,
  state: Schema.String,
  commit: Schema.String,
  snapshot: optional(
    Schema.Struct({
      arquivos: Schema.Array(
        Schema.Struct({ caminho: Schema.String, mudanca: Schema.Literals(["novo", "alterado", "removido"]) }),
      ),
      naoIncluidos: optional(Schema.Int),
    }),
  ),
  partes: Schema.Array(
    Schema.Struct({
      teste: Schema.String,
      posicao: optional(Schema.Int),
      etaMs: optional(Schema.Number),
      motivo: optional(BancadaProtocol.Reason),
    }),
  ),
}).annotate({ identifier: "Bancada.Submitted" })
export type Submitted = typeof Submitted.Type

const errors = { unavailable: Schema.toStandardSchemaV1(Unavailable) }

export const Definition = Rpc.define({
  id: "custom.bancada",
  methods: {
    /** Makes sure this machine's process runs; any call also loads the plugin of a server nobody opened yet. */
    wake: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Wake),
      errors,
    },
  },
  events: {},
})
