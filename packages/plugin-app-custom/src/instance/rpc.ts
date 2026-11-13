export * as Instance from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export interface Identity extends Schema.Schema.Type<typeof Identity> {}
export const Identity = Schema.Struct({
  /** The contract's number (`docs/instance.md`). */
  version: Schema.Literal(1),
  /** Random, made once and kept in the plugin's storage: the same server whatever address a client saved it under. */
  instanceID: Schema.String,
  /** The server's name as the Live Activity card shows it: `OPENCODE_HOST_NAME`, else macOS's ComputerName. */
  name: Schema.String,
  /** The deployment declares this server the hub (`OPENCODE_HUB=1`), the one that writes the single Live Activity. */
  hub: Schema.Boolean,
}).annotate({ identifier: "Instance.Identity" })

export const Definition = Rpc.define({
  id: "custom.instance",
  methods: {
    get: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Identity),
    },
  },
  events: {},
})
