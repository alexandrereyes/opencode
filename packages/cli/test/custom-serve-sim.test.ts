import { afterEach, expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { bundleServeSim } from "../script/custom-release"

const directories: string[] = []

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })))
})

test.skipIf(process.platform !== "darwin" || process.arch !== "arm64")(
  "the release copy of serve-sim runs on its own beside the plugin",
  async () => {
    const staging = await mkdtemp(path.join(os.tmpdir(), "opencode-serve-sim-"))
    directories.push(staging)
    await bundleServeSim(path.resolve(import.meta.dirname, "../../.."), staging)
    const modules = path.join(staging, "serve-sim/node_modules")
    expect(await Bun.file(path.join(modules, "@expo/serve-sim/NOTICE")).exists()).toBe(true)
    expect(await Bun.file(path.join(modules, "@expo/serve-sim/dist/native/serve-sim-native.node")).exists()).toBe(true)
    // The release copy keeps our patch (no Device Hub window per simulator).
    expect(await Bun.file(path.join(modules, "@expo/serve-sim/dist/serve-sim.js")).text()).toContain(
      "SERVE_SIM_NO_HOST_WINDOW",
    )
    // `ws` must resolve from the copy alone, outside the workspace's node_modules.
    const help = Bun.spawn([process.execPath, path.join(modules, "@expo/serve-sim/dist/serve-sim.js"), "--help"], {
      cwd: staging,
      env: { ...process.env, BUN_BE_BUN: "1", NODE_PATH: "" },
      stdout: "pipe",
      stderr: "pipe",
    })
    const [output, code] = await Promise.all([new Response(help.stdout).text(), help.exited])
    expect(code).toBe(0)
    expect(output).toContain("serve-sim")
  },
)

test.skipIf(process.arch !== "arm64")("a linux-arm64 release carries serve-sim's files for the Mac's hub", async () => {
  const staging = await mkdtemp(path.join(os.tmpdir(), "opencode-serve-sim-linux-"))
  directories.push(staging)
  await bundleServeSim(path.resolve(import.meta.dirname, "../../.."), staging, "linux")
  const modules = path.join(staging, "serve-sim/node_modules")
  expect(await Bun.file(path.join(modules, "@expo/serve-sim/dist/serve-sim.js")).exists()).toBe(true)
  expect(await Bun.file(path.join(modules, "ws/package.json")).exists()).toBe(true)
  // Other platforms ship no serve-sim.
  const other = await mkdtemp(path.join(os.tmpdir(), "opencode-serve-sim-win-"))
  directories.push(other)
  await bundleServeSim(path.resolve(import.meta.dirname, "../../.."), other, "win32")
  expect(await Bun.file(path.join(other, "serve-sim/node_modules/ws/package.json")).exists()).toBe(false)
})
