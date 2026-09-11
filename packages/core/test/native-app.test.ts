import { expect } from "bun:test"
import path from "node:path"
import { Effect, Layer } from "effect"
import { ChildProcess } from "effect/unstable/process"
import { AbsolutePath } from "@opencode/schema/schema"
import { FSUtil } from "@opencode/util/fs-util"
import { AppProcess } from "@opencode/util/process"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { NativeApp } from "../src/native-app"
import { testEffect } from "./lib/effect"

const it = testEffect(LayerNode.compile(LayerNode.group([FSUtil.node, AppProcess.node])))

it.live("discovers installed bundles and opens the exact Rider worktree without a shell", () =>
  Effect.gen(function* () {
    const fixture = yield* setup()
    expect(yield* fixture.apps.list()).toEqual({ os: "macos", apps: ["finder", "rider"] })
    yield* fixture.apps.open({ app: "rider", path: fixture.target })
    expect(fixture.commands).toHaveLength(1)
    expect(fixture.commands[0]).toMatchObject({
      _tag: "StandardCommand",
      command: "/usr/bin/open",
      args: ["-a", path.join(fixture.directory, "Rider.app"), fixture.target],
    })
    yield* fixture.apps.open({ app: "finder", path: fixture.target, reveal: true })
    expect(fixture.commands[1]).toMatchObject({ command: "/usr/bin/open", args: ["-R", fixture.target] })
  }),
)

it.live("rejects missing targets and unavailable applications without launching", () =>
  Effect.gen(function* () {
    const fixture = yield* setup()
    expect(
      (yield* fixture.apps.open({ app: "rider", path: AbsolutePath.make("relative") }).pipe(Effect.flip)).reason,
    ).toBe("invalid-path")
    expect(
      (yield* fixture.apps
        .open({ app: "rider", path: AbsolutePath.make(`${fixture.target}/missing`) })
        .pipe(Effect.flip)).reason,
    ).toBe("invalid-path")
    expect((yield* fixture.apps.open({ app: "vscode", path: fixture.target }).pipe(Effect.flip)).reason).toBe(
      "unavailable",
    )
    expect(fixture.commands).toHaveLength(0)
  }),
)

it.live("reports unsupported hosts and failed launches honestly", () =>
  Effect.gen(function* () {
    const unsupported = yield* setup({ platform: "linux" })
    expect(yield* unsupported.apps.list()).toEqual({ os: null, apps: [] })
    expect((yield* unsupported.apps.open({ app: "rider", path: unsupported.target }).pipe(Effect.flip)).reason).toBe(
      "unsupported",
    )
    expect(unsupported.commands).toHaveLength(0)

    const failed = yield* setup({ exitCode: 1 })
    expect((yield* failed.apps.open({ app: "rider", path: failed.target }).pipe(Effect.flip)).reason).toBe(
      "launch-failed",
    )
  }),
)

function setup(options: { platform?: string; exitCode?: number } = {}) {
  return Effect.gen(function* () {
    const fs = yield* FSUtil.Service
    const runner = yield* AppProcess.Service
    const directory = yield* fs.makeTempDirectoryScoped()
    const target = AbsolutePath.make(path.join(directory, "worktree spaces ' ; $(literal)"))
    yield* fs.makeDirectory(target)
    yield* fs.makeDirectory(path.join(directory, "Rider.app"))
    yield* fs.makeDirectory(path.join(directory, "Finder.app"))
    // A plain file with the right name is not an installed application bundle.
    yield* fs.writeFileString(path.join(directory, "Visual Studio Code.app"), "not a bundle")
    const commands: ChildProcess.Command[] = []
    const apps = yield* NativeApp.Service.pipe(
      Effect.provide(
        NativeApp.layer({ platform: options.platform ?? "darwin", directories: [directory] }).pipe(
          Layer.provide(
            Layer.succeed(AppProcess.Service, {
              ...runner,
              run: (command) => {
                commands.push(command)
                return Effect.succeed({
                  command: "/usr/bin/open",
                  exitCode: options.exitCode ?? 0,
                  stdout: Buffer.alloc(0),
                  stderr: Buffer.alloc(0),
                  stdoutTruncated: false,
                  stderrTruncated: false,
                })
              },
            }),
          ),
        ),
      ),
    )
    return { directory, target, apps, commands }
  })
}
