export * as NativeApps from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const ID = Schema.Literals([
  "finder",
  "vscode",
  "cursor",
  "zed",
  "textmate",
  "antigravity",
  "terminal",
  "iterm2",
  "ghostty",
  "warp",
  "xcode",
  "android-studio",
  "sublime-text",
  "rider",
]).annotate({ identifier: "NativeApps.ID" })
export type ID = typeof ID.Type

export interface Availability extends Schema.Schema.Type<typeof Availability> {}
export const Availability = Schema.Struct({
  os: Schema.NullOr(Schema.Literal("macos")),
  apps: Schema.Array(ID),
}).annotate({ identifier: "NativeApps.Availability" })

export const Definition = Rpc.define({
  id: "custom.native-apps",
  methods: {
    list: {
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Availability),
    },
    open: {
      input: Schema.toStandardSchemaV1(
        Schema.Struct({ app: ID, path: Schema.String, reveal: Schema.optionalKey(Schema.Boolean) }),
      ),
      output: Schema.toStandardSchemaV1(Schema.Struct({})),
      errors: {
        open_failed: Schema.toStandardSchemaV1(
          Schema.Struct({ reason: Schema.Literals(["unsupported", "unavailable", "invalid-path", "launch-failed"]) }),
        ),
      },
    },
  },
  events: {},
})
