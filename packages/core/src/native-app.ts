export * as NativeApp from "./native-app.js"

import os from "node:os"
import path from "node:path"
import { Context, Effect, Layer, Schema } from "effect"
import { ChildProcess } from "effect/unstable/process"
import { NativeApp } from "@opencode/schema/native-app"
import { FSUtil } from "@opencode/util/fs-util"
import { AppProcess } from "@opencode/util/process"
import { makeGlobalNode } from "@opencode/util/effect/app-node"

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
} satisfies Record<NativeApp.ID, string>

export class OpenError extends Schema.TaggedError<OpenError>()("NativeApp.OpenError", {
  reason: Schema.Literals(["unsupported", "unavailable", "invalid-path", "launch-failed"]),
  message: Schema.String,
}) {}

export interface Interface {
  readonly list: () => Effect.Effect<NativeApp.Availability>
  readonly open: (input: NativeApp.OpenInput) => Effect.Effect<void, OpenError>
}

export class Service extends Context.Service<Service, Interface>()("@opencode/NativeApp") {}

export const layer = (options: { platform?: string; directories?: readonly string[] } = {}) =>
  Layer.effect(
    Service,
    Effect.gen(function* () {
      const fs = yield* FSUtil.Service
      const runner = yield* AppProcess.Service
      const supported = (options.platform ?? process.platform) === "darwin"
      const directories = options.directories ?? [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
        path.join(os.homedir(), "Applications"),
      ]

      const resolve = Effect.fn("NativeApp.resolve")(function* (id: NativeApp.ID) {
        const candidates = directories.map((directory) => path.join(directory, `${applications[id]}.app`))
        const exists = yield* Effect.forEach(candidates, (candidate) => fs.isDir(candidate), {
          concurrency: "unbounded",
        })
        return candidates.find((_, index) => exists[index])
      })

      return Service.of({
        list: Effect.fn("NativeApp.list")(function* () {
          if (!supported) return { os: null, apps: [] }
          const apps = yield* Effect.forEach(
            NativeApp.ID.literals,
            (id) => resolve(id).pipe(Effect.map((bundle) => (bundle ? [id] : []))),
            { concurrency: "unbounded" },
          )
          return { os: "macos", apps: apps.flat() }
        }),
        open: Effect.fn("NativeApp.open")(function* (input) {
          if (!supported)
            return yield* new OpenError({ reason: "unsupported", message: "Native applications require a macOS host" })
          if (!path.isAbsolute(input.path) || !(yield* fs.existsSafe(input.path)))
            return yield* new OpenError({
              reason: "invalid-path",
              message: "The target must be an existing absolute path",
            })
          const bundle = yield* resolve(input.app)
          if (!bundle)
            return yield* new OpenError({
              reason: "unavailable",
              message: "The application is not installed on this host",
            })
          // Argument vectors preserve worktree names verbatim, including spaces and shell metacharacters.
          yield* runner
            .run(
              ChildProcess.make(
                "/usr/bin/open",
                input.app === "finder" && input.reveal ? ["-R", input.path] : ["-a", bundle, input.path],
              ),
            )
            .pipe(
              Effect.flatMap(AppProcess.requireSuccess),
              Effect.mapError(
                () => new OpenError({ reason: "launch-failed", message: "The application could not be opened" }),
              ),
            )
        }),
      })
    }),
  )

export const configured = (options?: Parameters<typeof layer>[0]) =>
  makeGlobalNode({ service: Service, layer: layer(options), deps: [FSUtil.node, AppProcess.node] })

export const node = configured()
