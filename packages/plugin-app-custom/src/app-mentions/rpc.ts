export * as AppMentions from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const SafariDevTools = {
  server: "safari-devtools",
  name: "Safari DevTools",
  bundleID: "mcp.safari-devtools",
} as const

export const ComputerUse = { server: "codex-computer-use" } as const

export interface App extends Schema.Schema.Type<typeof App> {}
export const App = Schema.Struct({
  server: Schema.String,
  name: Schema.String,
  path: Schema.String.pipe(Schema.optional),
  bundleID: Schema.String,
  running: Schema.Boolean,
}).annotate({ identifier: "AppMentions.App" })

export function isSafariDevTools(app: App) {
  return app.server === SafariDevTools.server && app.bundleID === SafariDevTools.bundleID
}

export const Definition = Rpc.define({
  id: "custom.app-mentions",
  methods: {
    list: {
      // `enabled` replaces this Location's connection state with the MCP servers a client will enable
      // once the Location exists, such as a new chat whose directory is allocated only on send.
      input: Schema.toStandardSchemaV1(Schema.Struct({ enabled: Schema.Array(Schema.String).pipe(Schema.optional) })),
      output: Schema.toStandardSchemaV1(Schema.Struct({ apps: Schema.Array(App) })),
    },
  },
  events: {},
})
