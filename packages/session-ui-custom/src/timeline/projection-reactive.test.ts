import { expect, test } from "bun:test"
import { fileURLToPath } from "node:url"

test("final answer boundaries update through the Solid browser runtime", async () => {
  const child = Bun.spawn(
    [process.execPath, "test", "--conditions=browser", "./src/timeline/fixtures/final-answer-reactive.ts"],
    { cwd: fileURLToPath(new URL("../..", import.meta.url)), stdout: "pipe", stderr: "pipe" },
  )
  const [status, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  expect(status, stdout + stderr).toBe(0)
}, 30_000)
