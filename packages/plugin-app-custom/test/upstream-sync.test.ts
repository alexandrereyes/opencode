import { afterEach, describe, expect, test } from "bun:test"
import { chmod, lstat, mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { defaultValidation, syncUpstream } from "../src/updates/upstream-sync"
import { artifacts, pointRelease, sha256 } from "../src/updates/release"

const temporary: string[] = []

afterEach(async () => {
  await Promise.all(temporary.splice(0).map((directory) => rm(directory, { recursive: true, force: true })))
})

describe("upstream synchronization", () => {
  test("merges, validates and non-force pushes a clean upstream target", async () => {
    const fixture = await createFixture("clean")
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready" })
    const published = (await git(["rev-parse", "refs/heads/custom"], fixture.origin)).trim()
    expect(await isAncestor(fixture.upstreamCommit, published, fixture.origin)).toBe(true)
    expect((await git(["show", "-s", "--format=%s", published], fixture.origin)).trim()).toBe(
      "chore: merge upstream v2",
    )
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeUndefined()
    expect((await git(["remote", "get-url", "upstream"], path.join(fixture.home, "repository"))).trim()).toBe(
      fixture.upstream,
    )
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready", custom: published })
    expect((await git(["rev-parse", "refs/heads/custom"], fixture.origin)).trim()).toBe(published)
  })

  test("preserves a conflicted index and creates one deterministic dashboard session", async () => {
    const fixture = await createFixture("conflict")
    const requests: { path: string; body: Record<string, unknown> }[] = []
    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        const body = (await request.json()) as Record<string, unknown>
        requests.push({ path: new URL(request.url).pathname, body })
        return Response.json({ data: body })
      },
    })
    await using stop = { [Symbol.asyncDispose]: async () => server.stop(true) }
    if (!server.port) throw new Error("Expected test server port")
    await writeService(fixture.home, server.port)

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "merging" })
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "merging" })
    const state = await readState(fixture.home)
    expect(state).toMatchObject({
      status: "blocked",
      phase: "merging",
      custom: fixture.customCommit,
      upstream: fixture.upstreamCommit,
      sessionCreated: true,
      promptSent: true,
    })
    expect(requests.filter((request) => request.path === "/api/session")).toHaveLength(1)
    expect(requests.filter((request) => request.path.endsWith("/prompt"))).toHaveLength(1)
    expect(requests[0].body).toMatchObject({
      id: state.sessionID,
      title: "Resolve upstream merge",
      location: { directory: fixture.worktree },
    })
    expect(String(requests[1].body.text)).toContain("Do not edit files")
    expect((await git(["diff", "--name-only", "--diff-filter=U"], fixture.worktree)).trim()).toBe("shared.txt")
  })

  test.skipIf(process.platform !== "darwin")(
    "the entrypoint prepares initial custom directly, then requires synchronization on later cycles",
    async () => {
    const fixture = await createFixture("conflict")
    await cacheRelease(fixture.home, fixture.customCommit)
    const initial = Bun.spawn([process.execPath, "script/prepare.ts", fixture.home], {
      cwd: path.resolve(import.meta.dirname, ".."),
      stdout: "pipe",
      stderr: "pipe",
    })
    const [initialOutput, initialError, initialCode] = await Promise.all([
      new Response(initial.stdout).text(),
      new Response(initial.stderr).text(),
      initial.exited,
    ])
    if (initialCode !== 0) throw new Error(initialError)
    expect(initialOutput).toContain(`Prepared 0.0.0-custom-1.0 (${fixture.customCommit})`)
    expect(await Bun.file(path.join(fixture.home, "state/upstream-sync.json")).exists()).toBe(false)
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeUndefined()
    await pointRelease(fixture.home, "current", fixture.customCommit)

    const later = Bun.spawn([process.execPath, "script/prepare.ts", fixture.home], {
      cwd: path.resolve(import.meta.dirname, ".."),
      stdout: "pipe",
      stderr: "pipe",
    })
    expect(await later.exited).toBe(0)
    expect(await new Response(later.stdout).text()).toContain("release preparation skipped")
    expect(await readState(fixture.home)).toMatchObject({ status: "blocked", phase: "merging" })
    expect(await lstat(path.join(fixture.home, "builds")).catch(() => undefined)).toBeUndefined()
  },
  )

  test("keeps the conflict and retries session creation after the server becomes available", async () => {
    const fixture = await createFixture("conflict")
    await writeService(fixture.home, 1)
    await syncUpstream(fixture.home)
    expect(await readState(fixture.home)).toMatchObject({ sessionCreated: false, promptSent: false })

    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        return Response.json({ data: await request.json() })
      },
    })
    await using stop = { [Symbol.asyncDispose]: async () => server.stop(true) }
    if (!server.port) throw new Error("Expected test server port")
    await writeService(fixture.home, server.port)
    await syncUpstream(fixture.home)
    expect(await readState(fixture.home)).toMatchObject({ sessionCreated: true, promptSent: true })
  })

  test("freezes the upstream SHA while a conflict is blocked", async () => {
    const fixture = await createFixture("conflict")
    await syncUpstream(fixture.home)
    await git(["checkout", "v2"], fixture.source)
    await Bun.write(path.join(fixture.source, "later.txt"), "later\n")
    await git(["add", "later.txt"], fixture.source)
    await commit(fixture.source, "upstream later")
    await git(["push", "upstream", "v2"], fixture.source)
    const later = (await git(["rev-parse", "HEAD"], fixture.source)).trim()

    await syncUpstream(fixture.home)
    expect(await readState(fixture.home)).toMatchObject({ upstream: fixture.upstreamCommit })
    expect((await git(["rev-parse", "MERGE_HEAD"], fixture.worktree)).trim()).toBe(fixture.upstreamCommit)
    expect(later).not.toBe(fixture.upstreamCommit)
  })

  test("preserves a clean merge commit when the remote rejects its push", async () => {
    const fixture = await createFixture("clean")
    const hook = path.join(fixture.origin, "hooks/pre-receive")
    await Bun.write(hook, "#!/bin/sh\nexit 1\n")
    await chmod(hook, 0o755)

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "push-rejected" })
    expect(await readState(fixture.home)).toMatchObject({ status: "active", phase: "pushing" })
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeDefined()
    expect(await git(["status", "--porcelain=v1"], fixture.worktree)).toBe("")
    expect(await isAncestor(fixture.upstreamCommit, fixture.customCommit, fixture.origin)).toBe(false)
    await rm(hook)
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready" })
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeUndefined()
  })

  test("preserves a validated merge for review if origin advances concurrently", async () => {
    const fixture = await createFixture("clean")
    const script = path.join(fixture.directory, "advance.ts")
    await Bun.write(
      script,
      [
        'import path from "node:path"',
        'import { mkdtemp } from "node:fs/promises"',
        'import { tmpdir } from "node:os"',
        "const run = (args: string[], cwd?: string) => {",
        '  const result = Bun.spawnSync(args, { cwd, stdout: "pipe", stderr: "pipe" })',
        '  if (result.exitCode !== 0) throw new Error(result.stderr.toString())',
        "}",
        'const work = await mkdtemp(path.join(tmpdir(), "origin-advance-"))',
        'run(["git", "clone", "--branch", "custom", process.argv[2], work])',
        'await Bun.write(path.join(work, "concurrent.txt"), "concurrent\\n")',
        'run(["git", "add", "concurrent.txt"], work)',
        'run(["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "concurrent"], work)',
        'run(["git", "push", "origin", "HEAD:custom"], work)',
      ].join("\n"),
    )
    const config = await Bun.file(path.join(fixture.home, "deployment.json")).json()
    config.validation = [{ cwd: ".", argv: [process.execPath, script, fixture.origin] }]
    await Bun.write(path.join(fixture.home, "deployment.json"), JSON.stringify(config))

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "validated" })
    expect(await readState(fixture.home)).toMatchObject({
      status: "blocked",
      phase: "validated",
      error: expect.stringContaining("origin/custom advanced"),
    })
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeDefined()
  })

  test("removes only a clean published conflict worktree after human resolution", async () => {
    const fixture = await createFixture("conflict")
    await syncUpstream(fixture.home)
    await Bun.write(path.join(fixture.worktree, "shared.txt"), "resolved\n")
    await git(["add", "shared.txt"], fixture.worktree)
    await commit(fixture.worktree, "chore: merge upstream v2")
    await git(["push", "origin", "HEAD:custom"], fixture.worktree)

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready" })
    expect(await readState(fixture.home)).toMatchObject({ status: "resolved" })
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeUndefined()
  })

  test("composes the default pre-push gate with configured Bun and package-local commands", () => {
    const gates = defaultValidation("/configured/bun")
    expect(gates[0]).toEqual({ cwd: ".", argv: ["/configured/bun", "install", "--frozen-lockfile"] })
    expect(gates.filter((gate) => gate.argv[1] === "typecheck").map((gate) => gate.cwd)).toEqual([
      "packages/app",
      "packages/cli",
      "packages/client",
      "packages/core",
      "packages/plugin",
      "packages/plugin-app-custom",
      "packages/server",
    ])
    expect(gates).toContainEqual({ cwd: "packages/client", argv: ["/configured/bun", "run", "check:generated"] })
    expect(gates).toContainEqual({ cwd: "packages/plugin-app-custom", argv: ["/configured/bun", "test"] })
    expect(gates.at(-1)).toEqual({
      cwd: ".",
      argv: ["/configured/bun", "run", "packages/cli/script/build.ts", "--single", "--skip-install"],
    })
  })

  test("recovers crashes before merge, after merge starts, and after a clean merge", async () => {
    for (const checkpoint of ["worktree-created", "merging", "merge-finished"] as const) {
      const fixture = await createFixture("clean")
      await expect(
        syncUpstream(fixture.home, {
          checkpoint(phase) {
            if (phase === checkpoint) throw new Error(`crash at ${phase}`)
          },
        }),
      ).rejects.toThrow(`crash at ${checkpoint}`)
      expect(await readState(fixture.home)).toMatchObject({
        status: "active",
        phase: checkpoint === "worktree-created" ? "worktree-created" : "merging",
      })
      expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready" })
    }
  })

  test("recovers a completed no-commit merge whose divergent histories have identical trees", async () => {
    const fixture = await createFixture("empty-tree")
    await expect(
      syncUpstream(fixture.home, {
        checkpoint(phase) {
          if (phase === "merge-finished") throw new Error("crash after empty-tree merge")
        },
      }),
    ).rejects.toThrow("crash after empty-tree merge")
    expect(await git(["status", "--porcelain=v1"], fixture.worktree)).toBe("")
    expect((await git(["rev-parse", "MERGE_HEAD"], fixture.worktree)).trim()).toBe(fixture.upstreamCommit)
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready" })
    expect(
      await isAncestor(
        fixture.upstreamCommit,
        await git(["rev-parse", "refs/heads/custom"], fixture.origin),
        fixture.origin,
      ),
    ).toBe(true)
  })

  test("blocks an unexpected MERGE_HEAD instead of accepting another target", async () => {
    const fixture = await createFixture("empty-tree")
    await expect(
      syncUpstream(fixture.home, {
        checkpoint(phase) {
          if (phase === "merge-finished") throw new Error("replace merge head")
        },
      }),
    ).rejects.toThrow("replace merge head")
    const mergeHead = (await git(["rev-parse", "--git-path", "MERGE_HEAD"], fixture.worktree)).trim()
    await Bun.write(path.resolve(fixture.worktree, mergeHead), `${fixture.customCommit}\n`)

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "merging" })
    expect(await readState(fixture.home)).toMatchObject({
      status: "blocked",
      error: "MERGE_HEAD does not match the frozen upstream SHA",
    })
  })

  test("recovers a local merge commit and a push published before durable acknowledgement", async () => {
    for (const checkpoint of ["committed", "pushed"] as const) {
      const fixture = await createFixture("clean")
      await expect(
        syncUpstream(fixture.home, {
          checkpoint(phase) {
            if (phase === checkpoint) throw new Error(`crash at ${phase}`)
          },
        }),
      ).rejects.toThrow(`crash at ${checkpoint}`)
      expect(await syncUpstream(fixture.home)).toMatchObject({ status: "ready" })
      expect(await lstat(fixture.worktree).catch(() => undefined)).toBeUndefined()
      expect(
        await isAncestor(
          fixture.upstreamCommit,
          await git(["rev-parse", "refs/heads/custom"], fixture.origin),
          fixture.origin,
        ),
      ).toBe(true)
    }
  })

  test("reconciles a conflict left after merge before the blocked state was finalized", async () => {
    const fixture = await createFixture("conflict")
    await expect(
      syncUpstream(fixture.home, {
        checkpoint(phase) {
          if (phase === "merge-finished") throw new Error("crash after conflicted merge")
        },
      }),
    ).rejects.toThrow("crash after conflicted merge")
    expect(await readState(fixture.home)).toMatchObject({ status: "active", phase: "merging" })
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "merging" })
    expect(await readState(fixture.home)).toMatchObject({
      status: "blocked",
      error: expect.stringContaining("Merge conflicts"),
    })
  })

  test("blocks an interrupted validation without rerunning potentially mutating gates", async () => {
    const fixture = await createFixture("clean")
    await expect(
      syncUpstream(fixture.home, {
        checkpoint(phase) {
          if (phase === "validating") throw new Error("validation process died")
        },
      }),
    ).rejects.toThrow("validation process died")
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "validating" })
    expect(await readState(fixture.home)).toMatchObject({
      status: "blocked",
      error: expect.stringContaining("Validation was interrupted"),
    })
  })

  test("preserves validation changes and opens one review session with the gate error", async () => {
    const fixture = await createFixture("clean")
    const script = path.join(fixture.directory, "validation-failure.ts")
    await Bun.write(script, 'await Bun.write("validation-output.txt", "review me\\n")\nprocess.exit(7)\n')
    await setValidation(fixture.home, [{ cwd: ".", argv: [process.execPath, script] }])
    const requests: { path: string; body: Record<string, unknown> }[] = []
    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        const body = (await request.json()) as Record<string, unknown>
        requests.push({ path: new URL(request.url).pathname, body })
        return Response.json({ data: body })
      },
    })
    await using stop = { [Symbol.asyncDispose]: async () => server.stop(true) }
    if (!server.port) throw new Error("Expected test server port")
    await writeService(fixture.home, server.port)

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "validating" })
    expect(await readState(fixture.home)).toMatchObject({
      status: "blocked",
      phase: "validating",
      error: expect.stringContaining("Validation failed"),
      sessionCreated: true,
      promptSent: true,
    })
    expect(await Bun.file(path.join(fixture.worktree, "validation-output.txt")).text()).toBe("review me\n")
    expect(String(requests.find((request) => request.path.endsWith("/prompt"))?.body.text)).toContain(
      "Validation failed",
    )
    await syncUpstream(fixture.home)
    expect(requests.filter((request) => request.path === "/api/session")).toHaveLength(1)
  })

  test("preserves a failed commit hook and blocks for session review", async () => {
    const fixture = await createFixture("clean")
    const repository = path.join(fixture.home, "repository")
    const server = Bun.serve({
      port: 0,
      async fetch(request) {
        return Response.json({ data: await request.json() })
      },
    })
    await using stop = { [Symbol.asyncDispose]: async () => server.stop(true) }
    if (!server.port) throw new Error("Expected test server port")
    await writeService(fixture.home, server.port)
    await expect(
      syncUpstream(fixture.home, {
        checkpoint(phase) {
          if (phase !== "validated") return
          throw new Error("install hook")
        },
      }),
    ).rejects.toThrow("install hook")
    const hook = path.join(repository, "hooks/pre-commit")
    await Bun.write(hook, "#!/bin/sh\nexit 1\n")
    await chmod(hook, 0o755)
    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "committing" })
    await syncUpstream(fixture.home)
    expect(await readState(fixture.home)).toMatchObject({
      status: "blocked",
      phase: "committing",
      error: expect.stringContaining("commit or hook failed"),
      sessionCreated: true,
      promptSent: true,
    })
  })

  test("does not clean an unsafe persisted attempt merely because another worktree published upstream", async () => {
    const fixture = await createFixture("conflict")
    await syncUpstream(fixture.home)
    const publisher = path.join(fixture.directory, "publisher")
    await git(["clone", "--branch", "custom", fixture.origin, publisher], fixture.directory)
    await git(["merge", "--no-edit", fixture.upstreamCommit], publisher).catch(async () => {
      await Bun.write(path.join(publisher, "shared.txt"), "published elsewhere\n")
      await git(["add", "shared.txt"], publisher)
      await commit(publisher, "chore: merge upstream v2")
    })
    await git(["push", "origin", "HEAD:custom"], publisher)

    expect(await syncUpstream(fixture.home)).toMatchObject({ status: "blocked", reason: "merging" })
    expect(await lstat(fixture.worktree).catch(() => undefined)).toBeDefined()
    expect((await git(["diff", "--name-only", "--diff-filter=U"], fixture.worktree)).trim()).toBe("shared.txt")
  })
})

async function createFixture(mode: "clean" | "conflict" | "empty-tree") {
  const directory = await mkdtemp(path.join(tmpdir(), "opencode-upstream-sync-"))
  temporary.push(directory)
  const source = path.join(directory, "source")
  const origin = path.join(directory, "origin.git")
  const upstream = path.join(directory, "upstream.git")
  const home = path.join(directory, "installation")
  const worktreeRoot = path.join(directory, "Worktrees")
  const worktree = path.join(worktreeRoot, "opencode2-upstream-merge")
  await mkdir(source)
  await mkdir(home)
  await git(["init", "-b", "custom"], source)
  await Bun.write(path.join(source, "shared.txt"), "base\n")
  await git(["add", "shared.txt"], source)
  await commit(source, "base")
  const base = (await git(["rev-parse", "HEAD"], source)).trim()
  await git(["init", "--bare", origin], directory)
  await git(["init", "--bare", upstream], directory)
  await git(["remote", "add", "origin", origin], source)
  await git(["remote", "add", "upstream", upstream], source)

  if (mode === "empty-tree") await commit(source, "custom", true)
  if (mode !== "empty-tree") {
    await Bun.write(path.join(source, mode === "clean" ? "custom.txt" : "shared.txt"), "custom\n")
    await git(["add", "."], source)
    await commit(source, "custom")
  }
  await git(["push", "origin", "HEAD:custom"], source)
  const customCommit = (await git(["rev-parse", "HEAD"], source)).trim()

  await git(["checkout", "-b", "v2", base], source)
  if (mode === "empty-tree") await commit(source, "upstream", true)
  if (mode !== "empty-tree") {
    await Bun.write(path.join(source, mode === "clean" ? "upstream.txt" : "shared.txt"), "upstream\n")
    await git(["add", "."], source)
    await commit(source, "upstream")
  }
  await git(["push", "upstream", "HEAD:v2"], source)
  const upstreamCommit = (await git(["rev-parse", "HEAD"], source)).trim()
  await Bun.write(
    path.join(home, "deployment.json"),
    JSON.stringify({
      repository: origin,
      branch: "custom",
      bun: process.execPath,
      upstream,
      upstreamBranch: "v2",
      worktreeRoot,
      worktreeName: "opencode2",
      validation: [],
    }),
  )
  return { directory, source, origin, upstream, home, worktree, customCommit, upstreamCommit }
}

async function writeService(home: string, port: number) {
  await mkdir(path.join(home, "config/opencode"), { recursive: true })
  await Bun.write(
    path.join(home, "config/opencode/service-custom.json"),
    JSON.stringify({ hostname: "127.0.0.1", port, password: "test-password" }),
  )
}

async function setValidation(home: string, validation: { cwd: string; argv: string[] }[]) {
  const config = await Bun.file(path.join(home, "deployment.json")).json()
  config.validation = validation
  await Bun.write(path.join(home, "deployment.json"), JSON.stringify(config))
}

async function cacheRelease(home: string, commit: string) {
  const directory = path.join(home, "releases", commit)
  await Promise.all(
    artifacts.map(async (artifact) => {
      await mkdir(path.dirname(path.join(directory, artifact)), { recursive: true })
      await Bun.write(path.join(directory, artifact), `${artifact}\n`)
    }),
  )
  await Bun.write(
    path.join(directory, "manifest.json"),
    JSON.stringify({
      format: 1,
      commit,
      version: "0.0.0-custom-1.0",
      platform: process.platform,
      arch: process.arch,
      files: Object.fromEntries(
        await Promise.all(artifacts.map(async (artifact) => [artifact, await sha256(path.join(directory, artifact))])),
      ),
    }),
  )
}

async function readState(home: string) {
  return (await Bun.file(path.join(home, "state/upstream-sync.json")).json()) as {
    status: string
    phase: string
    custom: string
    upstream: string
    worktree: string
    sessionID: string
    promptID: string
    sessionCreated: boolean
    promptSent: boolean
    error?: string
  }
}

async function commit(cwd: string, message: string, empty = false) {
  await git(
    [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "commit",
      ...(empty ? ["--allow-empty"] : []),
      "-m",
      message,
    ],
    cwd,
  )
}

async function isAncestor(base: string, head: string, cwd: string) {
  const child = Bun.spawn(["git", "merge-base", "--is-ancestor", base.trim(), head.trim()], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  })
  return (await child.exited) === 0
}

async function git(args: string[], cwd: string) {
  const child = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe", env: { ...process.env } })
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  if (code !== 0) throw new Error(`git ${args.join(" ")} failed: ${stderr}`)
  return stdout
}
