import { expect, test } from "bun:test"
import { chmod, copyFile, mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

test("manual command failures remain consultable after a later operation", async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), "opencode", "operation-"))
  try {
    const run = async () => {
      const child = Bun.spawn(
        [process.execPath, path.resolve(import.meta.dirname, "../script/custom-release.ts"), "activate"],
        {
          env: { ...process.env, OPENCODE_CUSTOM_HOME: home },
          stdout: "pipe",
          stderr: "pipe",
        },
      )
      const [code] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
      ])
      return code
    }
    expect(await run()).not.toBe(0)
    const file = (await readdir(`${home}/logs/operations`))[0]
    const original = await Bun.file(`${home}/logs/operations/${file}`).text()
    const record = JSON.parse(original)
    expect(record.outcome).toBe("failed")
    expect(record.error).toContain("No prepared/previous release")
    expect(record.events.length).toBeGreaterThan(0)
    expect((await stat(`${home}/logs/operations/${file}`)).mode & 0o777).toBe(0o600)
    expect(await run()).not.toBe(0)
    expect(await readdir(`${home}/logs/operations`)).toHaveLength(2)
    expect(await Bun.file(`${home}/logs/operations/${file}`).text()).toBe(original)
    expect(await Bun.file(`${home}/.manual-lock`).exists()).toBe(false)
  } finally {
    await rm(home, { recursive: true, force: true })
  }
})

test.each(["update-failure", "wrong-version", "notification-failure", "success", "dirty", "branch"])(
  "detached runner persists %s after exit using an isolated command boundary",
  async (scenario) => {
    const home = await mkdtemp(path.join(os.tmpdir(), "opencode", "runner-"))
    const sha = "a".repeat(40)
    try {
      await mkdir(`${home}/Dev/opencode2`, { recursive: true })
      await mkdir(`${home}/bin`)
      await copyFile(
        path.resolve(import.meta.dirname, "../../../.opencode/skills/update-custom-app/scripts/run-update.zsh"),
        `${home}/runner.zsh`,
      )
      await Bun.write(
        `${home}/bin/git`,
        `#!/bin/sh
case "$1" in
branch) echo ${scenario === "branch" ? "update-recovery" : "custom"};;
status) ${scenario === "dirty" ? "echo ' M user-work'" : ":"};;
pull) echo pull >> "$HOME/calls";;
rev-parse) echo ${sha};;
esac
`,
      )
      await Bun.write(
        `${home}/bin/bun`,
        `#!/bin/sh
if [ "$1" = run ]; then
  echo update >> "$HOME/calls"
  ${scenario === "update-failure" ? "echo 'original bootstrap error' >&2; exit 17" : "exit 0"}
fi
echo '${JSON.stringify({ prepared: sha, current: sha, running: `0.0.0-custom.${scenario === "wrong-version" ? "b".repeat(40) : sha}`, health: "ready" })}'
`,
      )
      await Bun.write(
        `${home}/.local/share/opencode-custom-v2/bin/opencode2`,
        `#!/bin/sh
echo notification >> "$HOME/calls"
exit ${scenario === "notification-failure" ? 23 : 0}
`,
      )
      for (const file of ["bin/git", "bin/bun", ".local/share/opencode-custom-v2/bin/opencode2"])
        await chmod(`${home}/${file}`, 0o700)
      const run = async () => {
        const child = Bun.spawn(["/bin/zsh", `${home}/runner.zsh`, "ses_fixture"], {
          env: { ...process.env, HOME: home, TMPDIR: home, PATH: `${home}/bin:${process.env.PATH}` },
          stdout: "pipe",
          stderr: "pipe",
        })
        const [code] = await Promise.all([
          child.exited,
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
        ])
        return code
      }
      const code = await run()
      const directory = (await readdir(`${home}/opencode`))[0]
      const result = await Bun.file(`${home}/opencode/${directory}/result.txt`).text()
      const success = scenario === "success" || scenario === "notification-failure"
      expect(code === 0).toBe(success)
      expect(result).toContain(`outcome=${success ? "succeeded" : "failed"}`)
      expect(result).toContain(
        `notification=${scenario === "success" ? "sent" : scenario === "notification-failure" ? "failed" : "skipped"}`,
      )
      expect((await stat(`${home}/opencode/${directory}/result.txt`)).mode & 0o777).toBe(0o600)
      const calls = await Bun.file(`${home}/calls`)
        .text()
        .catch(() => "")
      expect(calls.includes("notification")).toBe(success)
      if (scenario === "dirty" || scenario === "branch") {
        expect(calls).toBe("")
        expect(result).toContain("phase=preflight")
        expect(result).toContain("exit=2")
        expect(await Bun.file(`${home}/opencode/${directory}/output.log`).text()).toContain(
          scenario === "dirty"
            ? "changed or untracked paths:\n M user-work"
            : "expected branch custom; found update-recovery",
        )
      }
      if (success) {
        expect(result).toContain("exit=0")
        expect(result).toContain("phase=notification")
      }
      if (scenario === "update-failure")
        expect(await Bun.file(`${home}/opencode/${directory}/output.log`).text()).toContain("original bootstrap error")
      await run()
      expect(await Bun.file(`${home}/opencode/${directory}/result.txt`).text()).toBe(result)
      expect(await readdir(`${home}/opencode`)).toHaveLength(2)
    } finally {
      await rm(home, { recursive: true, force: true })
    }
  },
)
