import { expect, test } from "bun:test"
import { copyFile, mkdir, mkdtemp, readdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { Flock } from "@opencode/util/flock"
import { prepare } from "../src/updates/prepare"
import { readRelease } from "../src/updates/release"

test.skipIf(process.platform !== "darwin" || process.env.OPENCODE_CUSTOM_BUILD_TEST !== "1")(
  "local job builds a checkout snapshot with the native builder and holds its lock until publication",
  async () => {
    const root = path.resolve("../..")
    const temporary = await mkdtemp(path.join(tmpdir(), "opencode-prepare-build-"))
    await using cleanup = {
      async [Symbol.asyncDispose]() {
        await rm(temporary, { recursive: true, force: true })
      },
    }
    const source = path.join(temporary, "source")
    const home = path.join(temporary, "installation")
    await mkdir(source)
    await mkdir(home)
    const command = async (args: string[], cwd = root) => {
      const child = Bun.spawn(args, { cwd, stdout: "pipe", stderr: "pipe" })
      const output = await new Response(child.stdout).text()
      if ((await child.exited) !== 0) throw new Error(await new Response(child.stderr).text())
      return output
    }
    await command(["git", "archive", "HEAD", `--output=${temporary}/source.tar`])
    await command(["tar", "-xf", `${temporary}/source.tar`, "-C", source])
    await command(["git", "init", "-b", "custom"], source)
    const patch = await command(["git", "diff", "--binary", "HEAD"])
    if (patch) {
      await Bun.write(`${temporary}/source.patch`, patch)
      await command(["git", "apply", `${temporary}/source.patch`], source)
    }
    await Promise.all(
      (await command(["git", "ls-files", "--others", "--exclude-standard", "-z"]))
        .split("\0")
        .filter(Boolean)
        .map(async (file) => {
          await mkdir(path.dirname(path.join(source, file)), { recursive: true })
          await copyFile(path.join(root, file), path.join(source, file))
        }),
    )
    await command(["git", "add", "."], source)
    await command(
      ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "test: snapshot"],
      source,
    )
    const commit = (await command(["git", "rev-parse", "HEAD"], source)).trim()
    await Bun.write(
      path.join(home, "deployment.json"),
      JSON.stringify({ repository: source, branch: "custom", bun: process.execPath }),
    )
    const building = prepare(home)
    const result = building.then(
      (value) => ({ value }),
      (error: unknown) => ({ error }),
    )
    await using finish = {
      async [Symbol.asyncDispose]() {
        await result
      },
    }
    const deadline = Date.now() + 30_000
    const unpacked = async () => {
      const entries = await readdir(path.join(home, "builds")).catch(() => [])
      return (
        await Promise.all(
          entries.map((entry) => Bun.file(path.join(home, "builds", entry, "source/package.json")).exists()),
        )
      ).some(Boolean)
    }
    while (!(await unpacked())) {
      if (Date.now() > deadline) throw new Error("Preparation did not start")
      await Bun.sleep(20)
    }
    // Publication takes much longer than this lease timeout with the real native build.
    await expect(
      Flock.acquire("prepare", { dir: path.join(home, "locks"), timeoutMs: 50 }).then(async (lease) => {
        await lease.release()
        throw new Error("Preparation lock released before publication")
      }),
    ).rejects.toThrow("Timed out")
    const completed = await result
    if ("error" in completed) throw completed.error
    expect(completed.value.commit).toBe(commit)
    expect((await readRelease(home, "prepared", true))?.commit).toBe(commit)
    expect(await readRelease(home, "current")).toBeUndefined()
    await using lease = await Flock.acquire("prepare", { dir: path.join(home, "locks"), timeoutMs: 50 })
  },
  300_000,
)
