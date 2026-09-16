import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { AppMentions } from "./rpc.js"

export const registerAppMentions = Effect.fn("AppMentions.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(AppMentions.Definition, {
      list: () =>
        Effect.gen(function* () {
          const listed = yield* ctx.mcp.list().pipe(Effect.orElseSucceed(() => undefined))
          // This is availability only; no Safari process or WebDriver session is implied.
          const safari = listed?.data.some(
            (candidate) =>
              candidate.name === AppMentions.SafariDevTools.server && candidate.status.status === "connected",
          )
            ? [{ ...AppMentions.SafariDevTools, running: false }]
            : []
          const server = ["codex-computer-use", "open-computer-use"].find((name) =>
            listed?.data.some((candidate) => candidate.name === name && candidate.status.status === "connected"),
          )
          if (!server) return { apps: safari }
          const result = yield* ctx.mcp.callTool({ server, name: "list_apps", args: {} }).pipe(
            Effect.timeout(server === "codex-computer-use" ? "30 seconds" : "5 seconds"),
            Effect.orElseSucceed(() => undefined),
          )
          if (!result || result.isError) return { apps: safari }
          return {
            apps: [
              ...safari,
              ...parseApps(
                result.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
                result.server,
              ),
            ],
          }
        }),
    })
    .pipe(Effect.orDie)
})

// Open Computer Use: name — bundleID [flags]. Legacy Codex also includes an absolute .app path.
// Missing paths are never inferred from names or from the OpenCode host's filesystem.
export function parseApps(text: string, server: string): AppMentions.App[] {
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
