import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rename, rm, symlink } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { artifacts, pointRelease, readManifest, readRelease, sha256 } from "../src/updates/release"
import { createExecutor } from "../src/updates/executor"
import { prepare } from "../src/updates/prepare"
import { Flock } from "@opencode/util/flock"

const macTest = test.skipIf(process.platform !== "darwin")

async function fixture(commits?: string[]) {
  const home = await mkdtemp(path.join(tmpdir(), "opencode-custom-updates-"))
  const releases = await Promise.all(
    ["a", "b", "c"].map(async (name, index) => {
      const target = { commit: commits?.[index] ?? name.repeat(40), version: `0.0.0-custom-${index + 1}.0` }
      const directory = path.join(home, "releases", target.commit)
      await mkdir(path.join(directory, "bin"), { recursive: true })
      await mkdir(path.join(directory, "plugin"))
      await Promise.all(artifacts.map((file) => Bun.write(path.join(directory, file), `${name}:${file}`)))
      await Bun.write(
        path.join(directory, "manifest.json"),
        JSON.stringify({
          format: 1,
          ...target,
          platform: process.platform,
          arch: process.arch,
          files: Object.fromEntries(
            await Promise.all(artifacts.map(async (file) => [file, await sha256(path.join(directory, file))])),
          ),
        }),
      )
      return target
    }),
  )
  await pointRelease(home, "current", releases[0].commit)
  let restarts = 0
  let shutdowns = 0
  return {
    home,
    releases,
    get restarts() {
      return restarts
    },
    get shutdowns() {
      return shutdowns
    },
    owner: (running = releases[0]) =>
      createExecutor({
        home,
        running,
        prepareRestart: async () => {
          restarts++
        },
        shutdown: () => {
          shutdowns++
        },
      }),
    async [Symbol.asyncDispose]() {
      await rm(home, { recursive: true, force: true })
    },
  }
}

macTest("the local preparation job publishes a verified cached release and never switches current", async () => {
  const repository = await mkdtemp(path.join(tmpdir(), "opencode-prepare-source-"))
  await using cleanup = {
    async [Symbol.asyncDispose]() {
      await rm(repository, { recursive: true, force: true })
    },
  }
  const git = async (...args: string[]) => {
    const child = Bun.spawn(["git", ...args], { cwd: repository, stdout: "pipe", stderr: "pipe" })
    const output = (await new Response(child.stdout).text()).trim()
    if ((await child.exited) !== 0) throw new Error(await new Response(child.stderr).text())
    return output
  }
  await git("init", "-b", "custom")
  await git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial")
  const first = await git("rev-parse", "HEAD")
  await git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "candidate")
  const second = await git("rev-parse", "HEAD")
  await using f = await fixture([first, second])
  await Bun.write(
    path.join(f.home, "deployment.json"),
    JSON.stringify({ repository, branch: "custom", bun: process.execPath }),
  )
  expect((await prepare(f.home)).commit).toBe(second)
  expect((await readRelease(f.home, "prepared"))?.commit).toBe(second)
  expect((await readRelease(f.home, "current"))?.commit).toBe(first)
  await pointRelease(f.home, "prepared", first)
  const existing = path.join(f.home, "releases", second)
  const cached = await readManifest(existing)
  // Neither an existing different release nor an absent commit may redirect prepared.
  for (const commit of [f.releases[2].commit, "d".repeat(40)]) {
    await Bun.write(path.join(existing, "manifest.json"), JSON.stringify({ ...cached, commit }))
    await expect(prepare(f.home)).rejects.toThrow("Cached release does not match")
    expect((await readRelease(f.home, "prepared"))?.commit).toBe(first)
  }
  await Bun.write(path.join(existing, "manifest.json"), JSON.stringify(cached))
  await rename(existing, path.join(f.home, "misplaced"))
  await symlink(path.join(f.home, "misplaced"), existing)
  await expect(prepare(f.home)).rejects.toThrow("Cached release does not match")
  await rm(path.join(f.home, "misplaced"), { recursive: true })
  await expect(prepare(f.home)).rejects.toThrow()
  expect((await readRelease(f.home, "prepared"))?.commit).toBe(first)
  expect((await readRelease(f.home, "current"))?.commit).toBe(first)
  // A failed preparation leaves the last verified candidate available.
  await Bun.write(
    path.join(f.home, "deployment.json"),
    JSON.stringify({ repository, branch: "missing", bun: process.execPath }),
  )
  await expect(prepare(f.home)).rejects.toThrow("Command failed")
  expect((await readRelease(f.home, "prepared"))?.commit).toBe(first)
  expect((await readRelease(f.home, "current"))?.commit).toBe(first)
})

macTest("preparation and an ordinary restart never activate a candidate", async () => {
  await using f = await fixture()
  await pointRelease(f.home, "prepared", f.releases[1].commit)
  expect(await f.owner().check()).toEqual({ status: "ready", ...f.releases[1] })
  expect(await f.owner().check()).toEqual({ status: "ready", ...f.releases[1] })
  expect((await readRelease(f.home, "current"))?.commit).toBe(f.releases[0].commit)
  expect(f.restarts).toBe(0)
  expect(f.shutdowns).toBe(0)
})

macTest("initial bootstrap confirms an exact candidate and releases the activation lock before exiting", async () => {
  await using f = await fixture()
  await rm(path.join(f.home, "current"))
  await pointRelease(f.home, "prepared", f.releases[1].commit)
  const child = Bun.spawn(
    [process.execPath, "script/bootstrap.ts", "--home", f.home, "--activate", f.releases[1].commit],
    { stdout: "pipe", stderr: "pipe" },
  )
  expect(await child.exited).toBe(0)
  expect((await readRelease(f.home, "current"))?.commit).toBe(f.releases[1].commit)
  await using lock = await Flock.acquire("activation", { dir: path.join(f.home, "locks"), timeoutMs: 50 })
})

macTest("concurrent confirmations share selection; shutdown is a separate response action", async () => {
  await using f = await fixture()
  await pointRelease(f.home, "prepared", f.releases[1].commit)
  const results = await Promise.all([f.owner().install(f.releases[1]), f.owner().install(f.releases[1])])
  expect(results).toEqual([f.releases[1], f.releases[1]])
  expect(f.restarts).toBe(2)
  expect(f.shutdowns).toBe(0)
  // A dropped response is still explicitly retryable in the UI, not stuck installing.
  expect(await f.owner().check()).toEqual({ status: "ready", ...f.releases[1] })
  expect(await f.owner(f.releases[1]).check()).toEqual({ status: "up-to-date" })
  const owner = f.owner()
  owner.shutdown()
  owner.shutdown()
  expect(f.shutdowns).toBe(1)
  expect(await owner.check()).toEqual({ status: "installing", ...f.releases[1] })
})

macTest("stale confirmation cannot activate a different prepared release", async () => {
  await using f = await fixture()
  await pointRelease(f.home, "prepared", f.releases[2].commit)
  await expect(f.owner().install(f.releases[1])).rejects.toThrow("prepared release changed")
  expect((await readRelease(f.home, "current"))?.commit).toBe(f.releases[0].commit)
})

macTest("checksum failure and restart preparation failure preserve the active release", async () => {
  await using f = await fixture()
  await pointRelease(f.home, "prepared", f.releases[1].commit)
  const owner = createExecutor({
    home: f.home,
    running: f.releases[0],
    prepareRestart: async () => {
      throw new Error("handoff failed")
    },
    shutdown: () => {
      throw new Error("must not shut down")
    },
  })
  await expect(owner.install(f.releases[1])).rejects.toThrow("handoff failed")
  await Bun.write(path.join(f.home, "releases", f.releases[1].commit, "plugin/index.js"), "corrupted")
  await expect(f.owner().install(f.releases[1])).rejects.toThrow("checksum mismatch")
  expect((await readRelease(f.home, "current"))?.commit).toBe(f.releases[0].commit)
})

macTest("failed new process does not roll back a selected release", async () => {
  await using f = await fixture()
  await pointRelease(f.home, "prepared", f.releases[1].commit)
  await f.owner().install(f.releases[1])
  await pointRelease(f.home, "prepared", f.releases[2].commit)
  await expect(f.owner().install(f.releases[2])).rejects.toThrow("already been selected")
  expect((await readRelease(f.home, "current"))?.commit).toBe(f.releases[1].commit)
})

macTest("manifest boundary rejects malformed and escaped release pointers", async () => {
  await using f = await fixture()
  await pointRelease(f.home, "prepared", f.releases[1].commit)
  await Bun.write(path.join(f.home, "releases", f.releases[1].commit, "manifest.json"), '{"format":2}')
  await expect(readRelease(f.home, "prepared", true)).rejects.toThrow()
  await using other = await fixture()
  await rm(path.join(f.home, "prepared"))
  await symlink(path.join(other.home, "releases", other.releases[0].commit), path.join(f.home, "prepared"))
  await expect(readRelease(f.home, "prepared")).rejects.toThrow("escapes")
})
