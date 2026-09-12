import { describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Effect, Fiber, Schema } from "effect"
import { makeNativeApps } from "../src/native-apps"
import { NativeApps } from "../src/native-apps/rpc"

describe("native apps", () => {
  test("publishes the frozen browser-safe RPC contract", () => {
    expect(NativeApps.Definition.id).toBe("custom.native-apps")
    expect(Schema.decodeUnknownSync(NativeApps.Availability)({ os: "macos", apps: ["vscode", "rider"] })).toEqual({
      os: "macos",
      apps: ["vscode", "rider"],
    })
    expect(() => Schema.decodeUnknownSync(NativeApps.ID)("sh")).toThrow()
    expect(Object.keys(NativeApps.Definition.methods.open.errors)).toEqual(["open_failed"])
  })

  test("discovers allowlisted bundles and preserves literal argv", async () => {
    const commands: Array<{ command: string; args: readonly string[] }> = []
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-native-apps-"))
    const target = path.join(directory, "worktree spaces ' ; $(literal)")
    try {
      await Promise.all([
        fs.mkdir(path.join(directory, "Finder.app")),
        fs.mkdir(path.join(directory, "Rider.app")),
        fs.mkdir(target),
        fs.writeFile(path.join(directory, "Visual Studio Code.app"), "not a bundle"),
      ])
      const apps = makeNativeApps({
        platform: "darwin",
        directories: [directory],
        launch: async (command, args) => {
          commands.push({ command, args })
          return true
        },
      })

      expect(await apps.list()).toEqual({ os: "macos", apps: ["finder", "rider"] })
      expect(await Effect.runPromise(apps.open({ app: "rider", path: target }))).toBeUndefined()
      expect(await Effect.runPromise(apps.open({ app: "finder", path: target, reveal: true }))).toBeUndefined()
      expect(commands).toEqual([
        { command: "/usr/bin/open", args: ["-a", path.join(directory, "Rider.app"), target] },
        { command: "/usr/bin/open", args: ["-R", target] },
      ])
    } finally {
      await fs.rm(directory, { recursive: true })
    }
  })

  test("reports unsupported, invalid, unavailable, and launch failure without real processes", async () => {
    const unsupported = makeNativeApps({ platform: "linux" })
    expect(await unsupported.list()).toEqual({ os: null, apps: [] })
    expect(await Effect.runPromise(unsupported.open({ app: "rider", path: "/project" }))).toBe("unsupported")

    const apps = makeNativeApps({
      platform: "darwin",
      directories: ["/fixture/apps"],
      exists: async (target) => target === "/project",
      isDirectory: async (target) => target.endsWith("/Rider.app"),
      launch: async () => false,
    })
    expect(await Effect.runPromise(apps.open({ app: "rider", path: "relative" }))).toBe("invalid-path")
    expect(await Effect.runPromise(apps.open({ app: "vscode", path: "/project" }))).toBe("unavailable")
    expect(await Effect.runPromise(apps.open({ app: "rider", path: "/project" }))).toBe("launch-failed")
  })

  test("interruption before launch prevents spawning", async () => {
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<boolean>()
    const launched: string[] = []
    const apps = makeNativeApps({
      platform: "darwin",
      directories: ["/fixture/apps"],
      exists: async () => {
        entered.resolve()
        return release.promise
      },
      isDirectory: async () => true,
      launch: async (command) => {
        launched.push(command)
        return true
      },
    })

    const fiber = Effect.runFork(apps.open({ app: "rider", path: "/project" }))
    await entered.promise
    await Effect.runPromise(Fiber.interrupt(fiber))
    release.resolve(true)
    await Promise.resolve()
    expect(launched).toEqual([])
  })

  test("interruption aborts an in-flight launch", async () => {
    const started = Promise.withResolvers<void>()
    const state = { aborted: false }
    const apps = makeNativeApps({
      platform: "darwin",
      directories: ["/fixture/apps"],
      exists: async () => true,
      isDirectory: async () => true,
      launch: (_command, _args, signal) =>
        new Promise<boolean>((resolve) => {
          signal.addEventListener(
            "abort",
            () => {
              state.aborted = true
              resolve(false)
            },
            { once: true },
          )
          started.resolve()
        }),
    })

    const fiber = Effect.runFork(apps.open({ app: "rider", path: "/project" }))
    await started.promise
    await Effect.runPromise(Fiber.interrupt(fiber))
    expect(state.aborted).toBe(true)
  })
})
