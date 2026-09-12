export * as ComputerUse from "./computer-use.js"

import { Effect } from "effect"
import type { Mcp } from "./index.js"
import type { ComputerUseApp } from "@opencode/schema/mcp"

// Open Computer Use: name — bundleID [flags]. Legacy Codex also includes an absolute .app path.
// Missing paths are never inferred from names or from the OpenCode host's filesystem.
export function parseApps(text: string, server: string): ComputerUseApp[] {
  const apps = text.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^((?:(?! — ).)+) — (?:(\/.+?\.app\/?) — )?([\w-]+(?:\.[\w-]+)+)(?: \[([^\]]*)\])?$/)
    if (!match) return []
    return [
      {
        server,
        name: match[1],
        ...(match[2] ? { path: match[2] } : {}),
        bundleID: match[3],
        running: /(?:^|, )running(?:,|$)/.test(match[4] ?? ""),
      },
    ]
  })
  return apps.filter((app, index) => apps.findIndex((other) => other.bundleID === app.bundleID) === index)
}

export const apps = Effect.fn("ComputerUse.apps")(function* (mcp: Mcp.Interface) {
  const servers = yield* mcp.servers()
  const server = ["open-computer-use", "codex-computer-use"].find((name) =>
    servers.some((server) => server.name === name && server.status.status === "connected"),
  )
  if (!server) return []
  const result = yield* mcp.callTool({ server, name: "list_apps", args: {} }).pipe(
    Effect.timeout("5 seconds"),
    Effect.orElseSucceed(() => undefined),
  )
  if (!result || result.isError) return []
  return parseApps(
    result.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
    result.server,
  )
})
