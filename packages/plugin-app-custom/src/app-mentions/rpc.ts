export * as AppMentions from "./rpc.js"

import { Rpc } from "@opencode/plugin/rpc"
import { Schema } from "effect"

export const SafariDevTools = {
  server: "safari-devtools",
  name: "Safari DevTools",
  bundleID: "mcp.safari-devtools",
} as const

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
      input: Schema.toStandardSchemaV1(Schema.Struct({})),
      output: Schema.toStandardSchemaV1(Schema.Struct({ apps: Schema.Array(App) })),
    },
  },
  events: {},
})
