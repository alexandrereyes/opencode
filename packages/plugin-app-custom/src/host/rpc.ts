export * as Host from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { optional } from "@opencode/schema/schema"
import { Schema } from "effect"

export const Part = Schema.Literals(["cpu", "memory", "disk"]).annotate({ identifier: "Host.Part" })
export type Part = typeof Part.Type

export interface Cpu extends Schema.Schema.Type<typeof Cpu> {}
export const Cpu = Schema.Struct({
  /** The whole machine's busy share since the previous reading, 0–100. */
  percent: Schema.Number,
  cores: Schema.Number,
}).annotate({ identifier: "Host.Cpu" })

export interface Memory extends Schema.Schema.Type<typeof Memory> {}
export const Memory = Schema.Struct({
  /** Bytes in use, the system's cache counted as free (Activity Monitor's "Memory Used", Linux's total − available). */
  used: Schema.Number,
  total: Schema.Number,
}).annotate({ identifier: "Host.Memory" })

export interface Disk extends Schema.Schema.Type<typeof Disk> {}
export const Disk = Schema.Struct({
  /** Bytes available to the server's user on the volume of its home folder. */
  free: Schema.Number,
  total: Schema.Number,
  path: Schema.String,
}).annotate({ identifier: "Host.Disk" })

export interface Snapshot extends Schema.Schema.Type<typeof Snapshot> {}
export const Snapshot = Schema.Struct({
  /** `OPENCODE_HOST_NAME`, else macOS's ComputerName, else the host name. */
  name: Schema.String,
  platform: Schema.String,
  /** Always the whole machine, never a container's cgroup (`docs/host.md`). */
  scope: Schema.Literal("machine"),
  /** Each part is left out when it cannot be read; the apps then hide only that meter. */
  cpu: optional(Cpu),
  memory: optional(Memory),
  disk: optional(Disk),
  at: Schema.Number,
}).annotate({ identifier: "Host.Snapshot" })

export const Definition = Rpc.define({
  id: "custom.host",
  methods: {
    get: {
      input: Schema.toStandardSchemaV1(Schema.Struct({ parts: optional(Schema.Array(Part)) })),
      output: Schema.toStandardSchemaV1(Snapshot),
    },
  },
  events: {},
})
