import { $ } from "bun"
import { afterEach, describe, expect, test } from "bun:test"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { Effect, Schema } from "effect"
import { AbsolutePath } from "@opencode/schema/schema"
import {
  checkWorktrees,
  inspectWorktree,
  locateDirectories,
  operationFailed,
  removeWorktree,
  worktreeBranches,
  type WorktreeContext,
} from "../src/worktrees"
import { Worktrees } from "../src/worktrees/rpc"

const directories: string[] = []

afterEach(async () => {
  await Promise.all(directories.splice(0).map((directory) => fs.rm(directory, { recursive: true, force: true })))
})

describe("worktrees", () => {
  test("publishes the frozen browser-safe RPC contract", () => {
    expect(Worktrees.Definition.id).toBe("custom.worktrees")
    expect(Object.keys(Worktrees.Definition.methods)).toEqual(["inspect", "delete", "branches", "locate", "check"])
    expect(Object.keys(Worktrees.Definition.methods.inspect.errors)).toEqual(["operation_failed"])
    expect(
      Schema.encodeSync(Worktrees.DeleteInput)(
        Schema.decodeUnknownSync(Worktrees.DeleteInput)({
          directory: "/repo/task",
          force: false,
          identity: "identity",
          branch: null,
        }),
      ),
    ).toEqual({ directory: "/repo/task", force: false, identity: "identity", branch: null })
  })

  test("preserves a structured force requirement in RPC error data", () => {
    const error = new Error("Removal rejected", { cause: { forceRequired: true } })
    const result = operationFailed(error, (type, message, data) => ({ type, message, data }))
    expect(result).toEqual({
      type: "operation_failed",
      message: "Removal rejected",
      data: { message: "Removal rejected", forceRequired: true },
    })
  })

  test("checks unchanged inventory, additions, claims, stale root ownership and removals", async () => {
    const fixture = await repository("check")
    const rows = [{ directory: fixture.root }, { directory: fixture.linked, strategy: "git" }]
    const check = (items = rows) => Effect.runPromise(checkWorktrees(inventory(items), fixture.root))
    expect(await check()).toEqual({ drift: false })
    const alias = path.join(path.dirname(fixture.root), "alias")
    await fs.symlink(fixture.root, alias)
    expect(await Effect.runPromise(checkWorktrees(inventory(rows), alias))).toEqual({ drift: false })
    expect(await check([{ directory: fixture.root, strategy: "git" }, rows[1]])).toEqual({ drift: false })
    expect(await check([{ directory: fixture.root }, { directory: fixture.linked }])).toEqual({ drift: true })
    expect(await check([{ directory: fixture.root, strategy: "copy" }, rows[1]])).toEqual({ drift: true })
    const added = path.join(path.dirname(fixture.root), "added")
    await $`git worktree add -b added ${added}`.cwd(fixture.root).quiet()
    expect(await check()).toEqual({ drift: true })
    await fs.rm(added, { recursive: true })
    // A dangling Git entry must not hide valid discoveries or cause drift on its own.
    expect(await check()).toEqual({ drift: false })
    expect(await check([{ directory: fixture.root }])).toEqual({ drift: true })
    await fs.rm(fixture.linked, { recursive: true })
    expect(await check()).toEqual({ drift: true })
  })

  test("checks non-git directories and discovers every stored unowned root", async () => {
    const fixture = await repository("roots")
    const outside = path.dirname(fixture.root)
    expect(await Effect.runPromise(checkWorktrees(inventory([{ directory: outside }]), outside))).toEqual({
      drift: false,
    })
    expect(
      await Effect.runPromise(
        checkWorktrees(inventory([{ directory: outside }, { directory: fixture.root }]), outside),
      ),
    ).toEqual({ drift: true })
    expect(
      await Effect.runPromise(
        checkWorktrees(
          inventory([
            { directory: outside },
            { directory: fixture.root },
            { directory: fixture.linked, strategy: "git" },
          ]),
          outside,
        ),
      ),
    ).toEqual({ drift: false })
    expect(
      await Effect.runPromise(checkWorktrees(inventory([{ directory: path.join(outside, "missing") }]), outside)),
    ).toEqual({ drift: true })
  })

  test("inspects, force-removes, and cleans local and remote branches", async () => {
    const fixture = await repository()
    const ctx = context(fixture.root, fixture.linked)
    const clean = await Effect.runPromise(inspectWorktree(ctx, fixture.linked))
    expect(clean).toMatchObject({
      directory: AbsolutePath.make(fixture.linked),
      branch: "feature",
      dirty: false,
      localBranch: { name: "feature" },
      remoteBranch: { name: "origin", branch: "feature" },
    })

    await fs.writeFile(path.join(fixture.linked, "dirty.txt"), "dirty")
    expect((await Effect.runPromise(inspectWorktree(ctx, fixture.linked))).dirty).toBe(true)
    await expect(Effect.runPromise(removeWorktree(ctx, { ...clean, branch: "changed", force: true }))).rejects.toThrow(
      "The worktree branch changed",
    )

    const result = await Effect.runPromise(
      removeWorktree(ctx, {
        directory: AbsolutePath.make(fixture.linked),
        force: true,
        identity: clean.identity,
        branch: clean.branch ?? null,
        remote: clean.remoteBranch,
        deleteLocalBranch: true,
        deleteRemoteBranch: true,
      }),
    )
    expect(result).toEqual({
      directory: AbsolutePath.make(fixture.linked),
      localBranch: { name: "feature", remote: undefined, deleted: true },
      remoteBranch: { name: "feature", remote: "origin", deleted: true },
    })
    expect(await Bun.file(fixture.linked).exists()).toBe(false)
    expect((await $`git branch --list feature`.cwd(fixture.root).text()).trim()).toBe("")
    expect((await $`git --git-dir ${fixture.remote} branch --list feature`.text()).trim()).toBe("")
  })

  test("lists the branch of every checkout from any worktree of the repository", async () => {
    const fixture = await repository("branches")
    const detached = path.join(path.dirname(fixture.root), "detached")
    await $`git worktree add --detach ${detached}`.cwd(fixture.root).quiet()
    const expected = [
      { directory: AbsolutePath.make(fixture.root), branch: "main" },
      { directory: AbsolutePath.make(await fs.realpath(detached)), branch: undefined },
      { directory: AbsolutePath.make(fixture.linked), branch: "feature" },
    ]
    expect(await Effect.runPromise(worktreeBranches(fixture.root))).toEqual(expected)
    expect(await Effect.runPromise(worktreeBranches(fixture.linked))).toEqual(expected)
    expect(await Effect.runPromise(worktreeBranches(path.dirname(fixture.root)))).toEqual([])
  })

  test("locates worktree roots, the main checkout, and branches without Location services", async () => {
    const fixture = await repository("locate")
    const nested = path.join(fixture.linked, "nested")
    await fs.mkdir(nested)
    const detached = path.join(path.dirname(fixture.root), "detached")
    await $`git worktree add --detach ${detached}`.cwd(fixture.root).quiet()
    const outside = path.dirname(fixture.root)
    const located = await Effect.runPromise(locateDirectories([fixture.root, nested, detached, outside]))
    expect(located).toEqual([
      {
        directory: AbsolutePath.make(fixture.root),
        worktree: AbsolutePath.make(fixture.root),
        canonical: AbsolutePath.make(fixture.root),
        branch: "main",
      },
      {
        directory: AbsolutePath.make(nested),
        worktree: AbsolutePath.make(fixture.linked),
        canonical: AbsolutePath.make(fixture.root),
        branch: "feature",
      },
      {
        directory: AbsolutePath.make(detached),
        worktree: AbsolutePath.make(await fs.realpath(detached)),
        canonical: AbsolutePath.make(fixture.root),
        branch: undefined,
      },
    ])
  })

  test("rejects roots, wrong owners, changed identities, and unsupported strategies", async () => {
    const first = await repository("first")
    const second = await repository("second")
    await expect(Effect.runPromise(inspectWorktree(context(first.root, first.linked), first.root))).rejects.toThrow(
      `Invalid worktree directory: ${first.root}`,
    )
    await expect(
      Effect.runPromise(
        inspectWorktree(
          inventory([{ directory: first.root }, { directory: second.linked, strategy: "git" }]),
          second.linked,
        ),
      ),
    ).rejects.toThrow(`Directory is not a worktree of the requested project: ${second.linked}`)
    await expect(
      Effect.runPromise(inspectWorktree(inventory([{ directory: first.linked, strategy: "copy" }]), first.linked)),
    ).rejects.toThrow("Worktree strategy copy cannot inspect removal")

    const ctx = context(first.root, first.linked)
    const inspection = await Effect.runPromise(inspectWorktree(ctx, first.linked))
    await $`git worktree remove ${first.linked}`.cwd(first.root).quiet()
    await $`git worktree add ${first.linked} feature`.cwd(first.root).quiet()
    await expect(
      Effect.runPromise(
        removeWorktree(ctx, {
          directory: AbsolutePath.make(first.linked),
          force: false,
          identity: inspection.identity,
          branch: inspection.branch ?? null,
        }),
      ),
    ).rejects.toThrow("The worktree identity changed")
  })

  test("inspects a worktree when the main checkout row carries a stale strategy and a sibling is gone", async () => {
    const fixture = await repository("stale-root")
    const inspection = await Effect.runPromise(
      inspectWorktree(
        inventory([
          { directory: fixture.root, strategy: "git" },
          { directory: fixture.linked, strategy: "git" },
          { directory: path.join(path.dirname(fixture.root), "gone"), strategy: "git" },
        ]),
        fixture.linked,
      ),
    )
    expect(inspection).toMatchObject({ directory: AbsolutePath.make(fixture.linked), branch: "feature" })
  })

  test("reports a stored worktree removed outside OpenCode as missing", async () => {
    const fixture = await repository("missing")
    await $`git worktree remove ${fixture.linked}`.cwd(fixture.root).quiet()
    const error = await Effect.runPromise(
      inspectWorktree(context(fixture.root, fixture.linked), fixture.linked).pipe(Effect.flip),
    )
    expect(error.message).toBe(`Worktree directory no longer exists: ${fixture.linked}`)
    expect(operationFailed(error, (type, message, data) => data)).toEqual({
      message: error.message,
      missing: true,
    })

    const unknown = await Effect.runPromise(
      inspectWorktree(inventory([{ directory: fixture.root }]), fixture.linked).pipe(Effect.flip),
    )
    expect(unknown.message).toContain("ENOENT")
    expect(operationFailed(unknown, (type, message, data) => data).missing).toBeUndefined()
  })

  test("returns partial cleanup failures after the worktree is removed", async () => {
    const fixture = await repository("partial")
    const ctx = context(fixture.root, fixture.linked)
    await fs.writeFile(path.join(fixture.linked, "feature.txt"), "feature")
    await $`git add feature.txt`.cwd(fixture.linked).quiet()
    await $`git commit -m feature`.cwd(fixture.linked).quiet()
    const inspection = await Effect.runPromise(inspectWorktree(ctx, fixture.linked))
    await fs.rm(fixture.remote, { recursive: true })
    const result = await Effect.runPromise(
      removeWorktree(ctx, {
        directory: AbsolutePath.make(fixture.linked),
        force: false,
        identity: inspection.identity,
        branch: inspection.branch ?? null,
        remote: inspection.remoteBranch,
        deleteLocalBranch: true,
        deleteRemoteBranch: true,
      }),
    )
    expect(result.localBranch).toMatchObject({ name: "feature", deleted: false })
    expect(result.localBranch?.error).toContain("not fully merged")
    expect(result.remoteBranch).toMatchObject({ name: "feature", remote: "origin", deleted: false })
    expect(await Bun.file(fixture.linked).exists()).toBe(false)
  })

  test("does not delete a branch used by another worktree", async () => {
    const fixture = await repository("branch-in-use")
    const sibling = path.join(path.dirname(fixture.root), "sibling")
    await $`git worktree add --force ${sibling} feature`.cwd(fixture.root).quiet()
    const inspection = await Effect.runPromise(inspectWorktree(context(fixture.root, fixture.linked), fixture.linked))
    const result = await Effect.runPromise(
      removeWorktree(context(fixture.root, fixture.linked), {
        directory: AbsolutePath.make(fixture.linked),
        force: false,
        identity: inspection.identity,
        branch: inspection.branch ?? null,
        deleteLocalBranch: true,
      }),
    )
    expect(result.localBranch).toMatchObject({ name: "feature", deleted: false })
    expect(result.localBranch?.error).toContain("used by worktree")
    expect((await fs.stat(sibling)).isDirectory()).toBe(true)
  })
})

function inventory(items: readonly { directory: string; strategy?: string }[]): WorktreeContext {
  return {
    list: () => Effect.succeed(items.map((item) => ({ ...item, directory: AbsolutePath.make(item.directory) }))),
    remove: () => Effect.void,
  }
}

function context(root: string, linked: string): WorktreeContext {
  return {
    list: () =>
      Effect.succeed([
        { directory: AbsolutePath.make(root) },
        { directory: AbsolutePath.make(linked), strategy: "git" },
      ]),
    remove: ({ directory, force }) =>
      Effect.tryPromise(async () => {
        const result = await $`git worktree remove ${force ? "--force" : []} ${directory}`.cwd(root).quiet().nothrow()
        if (result.exitCode === 0) return
        const error = new Error(result.stderr.toString().trim())
        Object.assign(error, { data: { forceRequired: /modified or untracked files|is dirty/i.test(error.message) } })
        throw error
      }),
  }
}

async function repository(name = "repo") {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), `opencode-plugin-worktrees-${name}-`))
  directories.push(directory)
  const root = path.join(directory, "root")
  const linked = path.join(directory, "linked")
  const remote = path.join(directory, "remote.git")
  await fs.mkdir(root)
  await $`git init`.cwd(root).quiet()
  await $`git config user.email test@opencode.test`.cwd(root).quiet()
  await $`git config user.name Test`.cwd(root).quiet()
  await $`git commit --allow-empty -m root`.cwd(root).quiet()
  await $`git branch -M main`.cwd(root).quiet()
  await $`git init --bare ${remote}`.quiet()
  await $`git remote add origin ${remote}`.cwd(root).quiet()
  await $`git push -u origin main`.cwd(root).quiet()
  await $`git --git-dir ${remote} symbolic-ref HEAD refs/heads/main`.quiet()
  await $`git remote set-head origin -a`.cwd(root).quiet()
  await $`git branch feature`.cwd(root).quiet()
  await $`git push -u origin feature`.cwd(root).quiet()
  await $`git worktree add ${linked} feature`.cwd(root).quiet()
  return { root: await fs.realpath(root), linked: await fs.realpath(linked), remote: await fs.realpath(remote) }
}
