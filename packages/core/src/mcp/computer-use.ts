export * as ComputerUse from "./computer-use.js"

import { Effect } from "effect"
import type { Mcp } from "./index.js"

// codex-computer-use lists running and previously used apps as one text line per app.
// Paths refer to the MCP host, which need not be the OpenCode server or browser host.
export function parseApps(text: string, server: string) {
  const apps = text.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^(.+?) — (\/.+?\.app\/?) — ([\w.-]+)(?: \[([^\]]*)\])?$/)
    if (!match) return []
    return [
      {
        server,
        name: match[1],
        path: match[2],
        bundleID: match[3],
        running: /(?:^|, )running(?:,|$)/.test(match[4] ?? ""),
      },
    ]
  })
  return apps.filter((app, index) => apps.findIndex((other) => other.bundleID === app.bundleID) === index)
}

export const apps = Effect.fn("ComputerUse.apps")(function* (mcp: Mcp.Interface) {
  const servers = yield* mcp.servers()
  if (!servers.some((server) => server.name === "codex-computer-use" && server.status.status === "connected")) return []
  const result = yield* mcp.callTool({ server: "codex-computer-use", name: "list_apps", args: {} }).pipe(
    Effect.timeout("5 seconds"),
    Effect.catch(() => Effect.succeed(undefined)),
  )
  if (!result || result.isError) return []
  return parseApps(
    result.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
    result.server,
  )
})
