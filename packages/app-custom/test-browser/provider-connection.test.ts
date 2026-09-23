import { expect, test } from "bun:test"
import { fileURLToPath } from "node:url"

test("provider connection controller integration", async () => {
  // Context substitutions are isolated from other browser tests.
  const child = Bun.spawn(
    [
      process.execPath,
      "test",
      "--conditions=browser",
      "--preload",
      "./happydom.ts",
      "./test-browser/fixtures/provider-connection.ts",
    ],
    { cwd: fileURLToPath(new URL("..", import.meta.url)), stdout: "pipe", stderr: "pipe" },
  )
  const [status, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  expect(status, stdout + stderr).toBe(0)
}, 30_000)
