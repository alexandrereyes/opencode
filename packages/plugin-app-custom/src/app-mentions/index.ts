import { Plugin } from "@opencode/plugin/effect"
import { Effect, Option, Schema } from "effect"
import { AppMentions } from "./rpc.js"

// Computer Use lists the host's apps, which do not depend on the Location. Plugin storage is shared by
// every Location, so the latest listing answers a Location that will only enable the server later,
// such as a new chat whose directory does not exist yet.
const known = "app-mentions:computer-use"
const decode = Schema.decodeUnknownOption(Schema.Array(AppMentions.App))
const encode = Schema.encodeSync(Schema.Array(AppMentions.App))

export const registerAppMentions = Effect.fn("AppMentions.register")(function* (ctx: Plugin.Context) {
  yield* ctx.rpc
    .register(AppMentions.Definition, {
      list: (input) =>
        Effect.gen(function* () {
          const listed = yield* ctx.mcp.list().pipe(Effect.orElseSucceed(() => undefined))
          const connected = (server: string) =>
            !!listed?.data.some((candidate) => candidate.name === server && candidate.status.status === "connected")
          const enabled = (server: string) => (input.enabled ? input.enabled.includes(server) : connected(server))
          // This is availability only; no Safari process or WebDriver session is implied.
          const safari = enabled(AppMentions.SafariDevTools.server)
            ? [{ ...AppMentions.SafariDevTools, running: false }]
            : []
          const server = AppMentions.ComputerUse.server
          if (!enabled(server)) return { apps: safari }
          if (!connected(server)) {
            const stored = yield* ctx.storage.get(known)
            return { apps: [...safari, ...Option.getOrElse(decode(stored ?? []), () => [])] }
          }
          const result = yield* ctx.mcp.callTool({ server, name: "list_apps", args: {} }).pipe(
            Effect.timeout("30 seconds"),
            Effect.orElseSucceed(() => undefined),
          )
          if (!result || result.isError) return { apps: safari }
          const apps = parseApps(
            result.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
            result.server,
          )
          yield* ctx.storage.set(known, encode(apps))
          return { apps: [...safari, ...apps] }
        }),
    })
    .pipe(Effect.orDie)
})

// Codex Computer Use: name — optional absolute .app path — bundleID [flags].
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
