export * as Rig from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

/** `missing`: no `rig` on this server's PATH. `failed`: it did not answer, ended with an error or printed no JSON. */
export const Unavailable = Schema.Struct({ reason: Schema.Literals(["missing", "failed"]) })

export const Definition = Rpc.define({
  id: "custom.rig",
  methods: {
    /**
     * The rig's queue as this server's `rig status --json` prints it, as it came (`docs/rig.md`): what runs, what waits,
     * the reservations and the machines. The apps show it; nothing here reads it.
     */
    status: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Schema.Json),
      errors: { unavailable: Schema.toStandardSchemaV1(Unavailable) },
    },
  },
  events: {},
})
