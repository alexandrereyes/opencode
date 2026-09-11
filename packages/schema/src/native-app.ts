export * as NativeApp from "./native-app.js"

import { Schema } from "effect"
import { AbsolutePath, optional } from "./schema.js"

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
]).annotate({ identifier: "NativeApp.ID" })
export type ID = typeof ID.Type

export interface Availability extends Schema.Schema.Type<typeof Availability> {}
export const Availability = Schema.Struct({
  os: Schema.NullOr(Schema.Literal("macos")),
  apps: Schema.Array(ID),
}).annotate({ identifier: "NativeApp.Availability" })

export interface OpenInput extends Schema.Schema.Type<typeof OpenInput> {}
export const OpenInput = Schema.Struct({
  app: ID,
  path: AbsolutePath,
  reveal: optional(Schema.Boolean),
}).annotate({ identifier: "NativeApp.OpenInput" })
