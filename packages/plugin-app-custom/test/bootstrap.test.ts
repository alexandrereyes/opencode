import { expect, test } from "bun:test"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"

test.skipIf(process.platform !== "darwin")(
  "bootstrap renders launchd jobs without installing and refuses an existing home",
  async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "opencode-bootstrap-"))
    await using cleanup = {
      async [Symbol.asyncDispose]() {
        await rm(directory, { recursive: true, force: true })
      },
    }
    const home = path.join(directory, "release's & files")
    const args = [
      process.execPath,
      "script/bootstrap.ts",
      "--home",
      home,
      "--repository",
      "https://example.invalid/custom.git",
    ]
    const child = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" })
    expect(await child.exited).toBe(0)
    expect(await new Response(child.stdout).text()).toContain("No launchd jobs were installed")
    const deployment = await Bun.file(path.join(home, "deployment.json")).json()
    expect(deployment).toMatchObject({
      upstream: "https://github.com/anomalyco/opencode.git",
      upstreamBranch: "v2",
      worktreeName: "opencode2",
      worktreeRoot: path.join(process.env.HOME ?? path.dirname(home), "Worktrees"),
    })
    expect(deployment.validation[0]).toEqual({
      cwd: ".",
      argv: [process.execPath, "install", "--frozen-lockfile"],
    })
    expect(deployment.validation.at(-1)).toEqual({
      cwd: ".",
      argv: [process.execPath, "run", "packages/cli/script/build.ts", "--single", "--skip-install"],
    })
    const env = Bun.spawn(
      ["/bin/sh", "-c", '. "$1/environment.sh"; printf %s "$OPENCODE_DISTRIBUTION_HOME"', "test", home],
      { stdout: "pipe" },
    )
    expect(await new Response(env.stdout).text()).toBe(home)
    expect(await env.exited).toBe(0)
    const plists = Bun.spawn(
      ["plutil", "-lint", path.join(home, "plists/serve.plist"), path.join(home, "plists/prepare.plist")],
      { stdout: "pipe" },
    )
    expect(await plists.exited).toBe(0)
    expect(await Bun.file(path.join(home, "current")).exists()).toBe(false)
    const again = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" })
    expect(await again.exited).not.toBe(0)
    expect(await new Response(again.stderr).text()).toContain("EEXIST")
  },
)
