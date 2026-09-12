import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"
import { NativeApps } from "./rpc.js"

const applications = {
  finder: "Finder",
  vscode: "Visual Studio Code",
  cursor: "Cursor",
  zed: "Zed",
  textmate: "TextMate",
  antigravity: "Antigravity",
  terminal: "Terminal",
  iterm2: "iTerm",
  ghostty: "Ghostty",
  warp: "Warp",
  xcode: "Xcode",
  "android-studio": "Android Studio",
  "sublime-text": "Sublime Text",
  rider: "Rider",
} satisfies Record<NativeApps.ID, string>

export interface NativeAppsOptions {
  readonly platform?: string
  readonly directories?: readonly string[]
  readonly isDirectory?: (target: string) => Promise<boolean>
  readonly exists?: (target: string) => Promise<boolean>
  readonly launch?: (command: string, args: readonly string[], signal: AbortSignal) => Promise<boolean>
}

export const registerNativeApps = Effect.fn("NativeApps.register")(function* (
  ctx: Plugin.Context,
  options: NativeAppsOptions = {},
) {
  const apps = makeNativeApps(options)
  yield* ctx.rpc
    .register(NativeApps.Definition, {
      list: () => Effect.promise(apps.list),
      open: (input, context) =>
        apps
          .open(input)
          .pipe(
            Effect.flatMap((reason) =>
              reason ? Effect.fail(context.error("open_failed", message(reason), { reason })) : Effect.succeed({}),
            ),
          ),
    })
    .pipe(Effect.orDie)
})

export function makeNativeApps(options: NativeAppsOptions = {}) {
  const supported = (options.platform ?? process.platform) === "darwin"
  const directories = options.directories ?? [
    "/Applications",
    "/System/Applications",
    "/System/Applications/Utilities",
    "/System/Library/CoreServices",
    path.join(os.homedir(), "Applications"),
  ]
  const isDirectory =
    options.isDirectory ??
    ((target) =>
      fs
        .stat(target)
        .then((stat) => stat.isDirectory())
        .catch(() => false))
  const exists =
    options.exists ??
    ((target) =>
      fs
        .access(target)
        .then(() => true)
        .catch(() => false))
  const launch =
    options.launch ??
    ((command, args, signal) =>
      Promise.resolve()
        .then(() => Bun.spawn([command, ...args], { stdin: "ignore", stdout: "ignore", stderr: "ignore", signal }))
        .then((child) => child.exited)
        .then((code) => code === 0)
        .catch(() => false))

  const resolve = async (id: NativeApps.ID) => {
    const candidates = directories.map((directory) => path.join(directory, `${applications[id]}.app`))
    const found = await Promise.all(candidates.map(isDirectory))
    return candidates.find((_, index) => found[index])
  }

  return {
    list: async (): Promise<NativeApps.Availability> => {
      if (!supported) return { os: null, apps: [] }
      const found = await Promise.all(NativeApps.ID.literals.map(async (id) => ((await resolve(id)) ? [id] : [])))
      return { os: "macos", apps: found.flat() }
    },
    open: (input: { app: NativeApps.ID; path: string; reveal?: boolean }) =>
      Effect.gen(function* () {
        if (!supported) return "unsupported" as const
        if (!path.isAbsolute(input.path) || !(yield* Effect.promise(() => exists(input.path))))
          return "invalid-path" as const
        const bundle = yield* Effect.promise(() => resolve(input.app))
        if (!bundle) return "unavailable" as const
        // Argument vectors preserve worktree names verbatim, including spaces and shell metacharacters.
        const args = input.app === "finder" && input.reveal ? ["-R", input.path] : ["-a", bundle, input.path]
        const launched = yield* Effect.tryPromise((signal) => launch("/usr/bin/open", args, signal)).pipe(
          Effect.orElseSucceed(() => false),
        )
        if (!launched) return "launch-failed" as const
        return undefined
      }),
  }
}

function message(reason: "unsupported" | "unavailable" | "invalid-path" | "launch-failed") {
  if (reason === "unsupported") return "Native applications require a macOS host"
  if (reason === "unavailable") return "The application is not installed on this host"
  if (reason === "invalid-path") return "The target must be an existing absolute path"
  return "The application could not be opened"
}
