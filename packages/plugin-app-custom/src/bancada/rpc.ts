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
