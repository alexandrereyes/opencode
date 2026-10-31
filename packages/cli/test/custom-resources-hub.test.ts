import { afterEach, expect, test } from "bun:test"
import { mkdtemp, readlink, realpath, rm, stat, utimes } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import {
  command,
  publishResourcesHub,
  resourcesHubLabel,
  resourcesHubPaths,
  resourcesHubPlist,
  resourcesHubPort,
  systemd,
} from "../script/custom-release"

const directories: string[] = []
const commit = (letter: string) => letter.repeat(40)

afterEach(async () => {
  for (const directory of directories.splice(0)) {
    await command(["chmod", "-R", "u+w", directory]).catch(() => undefined)
    await rm(directory, { recursive: true, force: true })
  }
})

/** The real host-side publisher writes a temporary Mac home; only process control is simulated. */
async function fixture(options: { installed?: boolean; kickstart?: number } = {}) {
  const root = await realpath(await mkdtemp(path.join(os.tmpdir(), "opencode-hub-publish-")))
  directories.push(root)
  const home = path.join(root, "Users/u")
  const paths = resourcesHubPaths(home)
  if (options.installed ?? true) await Bun.write(paths.plist, resourcesHubPlist(home))
  const release = async (sha: string) => {
    const directory = path.join(root, "runtime/releases", sha)
    await Bun.write(path.join(directory, "plugin/index.js"), `// ${sha}`)
    await Bun.write(path.join(directory, "serve-sim/node_modules/@expo/serve-sim/dist/serve-sim.js"), "// serve-sim")
    await Bun.write(path.join(directory, "bin/opencode"), "linux binary")
    await command(["chmod", "-R", "a-w", directory])
    return { commit: sha, directory }
  }
  const calls: string[][] = []
  const host = {
    home,
    async mac(args: string[], input?: Uint8Array) {
      calls.push(args)
      if (args[0] === "python3") {
        const child = Bun.spawn(args, { stdin: input ?? "ignore", stdout: "pipe", stderr: "pipe" })
        const [stdout, stderr, code] = await Promise.all([
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
          child.exited,
        ])
        return { code, stdout, stderr }
      }
      if (args[0] === "id") return { code: 0, stdout: "501\n", stderr: "" }
      return { code: options.kickstart ?? 0, stdout: "", stderr: options.kickstart ? "Could not find service" : "" }
    },
  }
  return { home, paths, release, calls, host }
}

test("the hub LaunchAgent runs the current release's plugin with the Mac's Bun, without a parent", async () => {
  const text = resourcesHubPlist("/Users/u")
  expect(text).toContain(`<key>Label</key><string>${resourcesHubLabel}</string>`)
  expect(text).toContain(
    "<array><string>/Users/u/.local/share/opencode-custom-v2/bin/bun</string><string>/Users/u/.local/share/opencode-resources-hub/current/plugin/index.js</string><string>--opencode-resources-hub</string></array>",
  )
  expect(text).toContain(
    "<key>OPENCODE_RESOURCES_HUB_STATE</key><string>/Users/u/.local/share/opencode-resources-hub/state</string>",
  )
  expect(text).toContain(`<key>OPENCODE_RESOURCES_HUB_PORT</key><string>${resourcesHubPort}</string>`)
  expect(text).toContain(
    "<key>OPENCODE_SERVE_SIM</key><string>/Users/u/.local/share/opencode-resources-hub/current/serve-sim/node_modules/@expo/serve-sim/dist/serve-sim.js</string>",
  )
  expect(text).toContain("<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>")
  expect(text).not.toContain("OPENCODE_RESOURCES_HUB_PARENT")
  expect(resourcesHubPaths("/Users/u").info).toBe("/Users/u/.local/share/opencode-resources-hub/state/hub.json")
  if (process.platform === "darwin") {
    const file = path.join(await realpath(os.tmpdir()), `hub-${process.pid}.plist`)
    await Bun.write(file, text)
    try {
      expect(await command(["/usr/bin/plutil", "-lint", file])).toEndWith("OK")
    } finally {
      await rm(file, { force: true })
    }
  }
})

test("publication copies plugin and serve-sim, points current and restarts the job on the Mac", async () => {
  const { home, paths, release, calls, host } = await fixture()
  const target = await release(commit("a"))
  expect(await publishResourcesHub(target, host)).toContain("published and restarted")
  const copy = path.join(paths.root, "releases", commit("a"))
  expect(await readlink(paths.current)).toBe(`releases/${commit("a")}`)
  expect(await Bun.file(path.join(paths.current, "plugin/index.js")).text()).toBe(`// ${commit("a")}`)
  expect(await Bun.file(path.join(copy, "serve-sim/node_modules/@expo/serve-sim/dist/serve-sim.js")).exists()).toBe(
    true,
  )
  // Only the hub's files go to the Mac, and they stay writable so old copies can be pruned.
  expect(await Bun.file(path.join(copy, "bin/opencode")).exists()).toBe(false)
  expect((await stat(path.join(copy, "plugin/index.js"))).mode & 0o200).toBe(0o200)
  expect(calls[0]?.slice(3)).toEqual(["hub", home, commit("a")])
  expect(calls.slice(1)).toEqual([
    ["id", "-u"],
    ["launchctl", "kickstart", "-k", `gui/501/${resourcesHubLabel}`],
  ])
  // Publishing the same release again reuses the copy and restarts the job once more.
  await publishResourcesHub(target, host)
  expect(calls).toHaveLength(6)
})

test("publication skips a Mac without the hub LaunchAgent and reports a failed restart", async () => {
  const skipped = await fixture({ installed: false })
  expect(await publishResourcesHub(await skipped.release(commit("a")), skipped.host)).toContain("skipped")
  expect(skipped.calls).toHaveLength(1)
  expect(await Bun.file(skipped.paths.root).exists()).toBe(false)

  const failing = await fixture({ kickstart: 113 })
  await expect(publishResourcesHub(await failing.release(commit("b")), failing.host)).rejects.toThrow(
    "restart failed (113)",
  )
  // The copy and pointer are already in place; the next launch of the job picks them up.
  expect(await readlink(failing.paths.current)).toBe(`releases/${commit("b")}`)
})

test("publication keeps the three newest hub releases besides current", async () => {
  const { paths, release, host } = await fixture()
  const letters = ["a", "b", "c", "d", "e"]
  for (const [index, letter] of letters.entries()) {
    await publishResourcesHub(await release(commit(letter)), host)
    const time = new Date(Date.now() - (letters.length - index) * 60_000)
    await utimes(path.join(paths.root, "releases", commit(letter)), time, time)
  }
  const kept = Array.from(new Bun.Glob("*").scanSync({ cwd: path.join(paths.root, "releases"), onlyFiles: false }))
  expect(kept.toSorted()).toEqual(["b", "c", "d", "e"].map(commit))
})

test("the Linux service publishes the hub after activation", async () => {
  const published: string[] = []
  const service = systemd(
    "/runtime",
    {
      run: async () => ({ code: 0, stdout: "", stderr: "" }),
      directory: os.tmpdir(),
      alive: async () => false,
      now: Date.now,
      sleep: async () => {},
    },
    async (release) => {
      published.push(release.commit)
      return "ok"
    },
  )
  expect(await service.hub!({ commit: commit("a"), directory: "/runtime/releases/a" })).toBe("ok")
  expect(published).toEqual([commit("a")])
})
