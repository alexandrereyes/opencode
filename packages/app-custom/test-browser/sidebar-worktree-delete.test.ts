import { expect, test } from "bun:test"
import { fileURLToPath } from "node:url"

test("sidebar worktree deletion with real lifecycle actions and dialog", async () => {
  const child = Bun.spawn(
    [
      process.execPath,
      "test",
      "--conditions=browser",
      "--preload",
      "./happydom.ts",
      "./test-browser/fixtures/sidebar-worktree-delete.ts",
    ],
    {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      stdout: "pipe",
      stderr: "pipe",
    },
  )
  const [status, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  expect(status, stdout + stderr).toBe(0)
}, 30_000)
