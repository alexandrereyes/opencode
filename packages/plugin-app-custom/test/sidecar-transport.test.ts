import { expect, test } from "bun:test"
import { Schema } from "effect"
import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import type { Updates } from "../src/updates/rpc"
import type { Worktrees } from "../src/worktrees/rpc"
import { AbsolutePath } from "@opencode/schema/schema"

test("the bundle boundary executes foreign codecs without changing existing RPC contracts or encode direction", async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "opencode-sidecar-codecs-"))
  await using cleanup = {
    async [Symbol.asyncDispose]() {
      await rm(directory, { recursive: true, force: true })
    },
  }
  const entry = path.join(directory, "fixture.ts")
  await Bun.write(
    entry,
    `
    import { Updates } from ${JSON.stringify(path.resolve("src/updates/rpc.ts"))}
    import { Worktrees } from ${JSON.stringify(path.resolve("src/worktrees/rpc.ts"))}
    import { transportDefinition } from ${JSON.stringify(path.resolve("src/updates/transport.ts"))}
    export const original = Updates.Definition
    export const updates = transportDefinition(Updates.Definition)
    export const worktrees = transportDefinition(Worktrees.Definition)
  `,
  )
  const built = await Bun.build({ entrypoints: [entry], outdir: directory, target: "bun" })
  expect(built.success).toBe(true)
  const bundled: {
    original: typeof Updates.Definition
    updates: typeof Updates.Definition
    worktrees: typeof Worktrees.Definition
  } = await import(pathToFileURL(path.join(directory, "fixture.js")).href)

  // Normal Bun can share internals that a compiled host cannot. The deployed
  // registration must not expose a foreign AST for either host to interpret.
  expect(Schema.isSchema(bundled.original.methods.check.output)).toBe(true)
  expect(Schema.isSchema(bundled.updates.methods.check.output)).toBe(false)
  expect(await bundled.updates.methods.check.output["~standard"].validate({ status: "up-to-date" })).toEqual({
    value: { status: "up-to-date" },
  })
  const inspection = {
    directory: AbsolutePath.make("/worktree"),
    identity: "fixture",
    dirty: false,
    branch: undefined,
    localBranch: undefined,
    remoteBranch: undefined,
  }
  expect(await bundled.worktrees.methods.inspect.output["~standard"].validate(inspection)).toEqual({
    value: { directory: AbsolutePath.make("/worktree"), identity: "fixture", dirty: false },
  })
  expect(
    await bundled.worktrees.methods.inspect.errors.operation_failed["~standard"].validate({
      message: "failed",
      forceRequired: undefined,
    }),
  ).toEqual({ value: { message: "failed" } })
  const input = { directory: AbsolutePath.make("/worktree"), force: false, identity: "fixture", branch: null }
  expect(await bundled.worktrees.methods.delete.input["~standard"].validate(input)).toEqual({ value: input })
  expect(
    (await bundled.worktrees.methods.delete.input["~standard"].validate({ ...input, force: "invalid" })).issues,
  ).toBeDefined()
})
