import { expect, test } from "bun:test"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { activate, atomic, command, locked, retry, synchronize } from "../script/custom/update"

async function fixture(conflict = false) {
  await mkdir(path.join(os.tmpdir(), "opencode"), { recursive: true })
  const home = await mkdtemp(path.join(os.tmpdir(), "opencode/custom-update-"))
  const git = async (cwd: string, ...args: string[]) => {
    const result = await command(["git", ...args], cwd)
    if (result.code) throw new Error(result.err)
    return result.out
  }
  const origin = path.join(home, "origin.git")
  const upstream = path.join(home, "upstream.git")
  const seed = path.join(home, "seed")
  const repository = path.join(home, "repository")
  await git(home, "init", "--bare", origin)
  await git(home, "init", "--bare", upstream)
  await git(home, "init", "-b", "beta", seed)
  await git(seed, "config", "user.name", "Update Test")
  await git(seed, "config", "user.email", "update@example.invalid")
  await Bun.write(path.join(seed, "shared"), "base\n")
  await git(seed, "add", ".")
  await git(seed, "commit", "-m", "test: base")
  await git(seed, "remote", "add", "origin", origin)
  await git(seed, "remote", "add", "upstream", upstream)
  await git(seed, "push", "upstream", "beta")
  await git(seed, "checkout", "-b", "custom")
  await Bun.write(path.join(seed, "custom"), "approved feature\n")
  if (conflict) await Bun.write(path.join(seed, "shared"), "custom\n")
  await git(seed, "add", ".")
  await git(seed, "commit", "-m", "feat: custom")
  await git(seed, "push", "origin", "custom")
  const base = await git(seed, "rev-parse", "HEAD")
  await git(seed, "checkout", "beta")
  await Bun.write(path.join(seed, "shared"), "upstream\n")
  await git(seed, "add", ".")
  await git(seed, "commit", "-m", "feat: upstream")
  await git(seed, "push", "upstream", "beta")
  await git(home, "clone", "--no-checkout", origin, repository)
  await git(repository, "config", "user.name", "Update Test")
  await git(repository, "config", "user.email", "update@example.invalid")
  await git(repository, "remote", "add", "upstream", upstream)
  return {
    home,
    repository,
    seed,
    origin,
    base,
    git,
    worktrees: path.join(home, "worktrees"),
    [Symbol.asyncDispose]: () => rm(home, { recursive: true, force: true }),
  }
}

test("clean sync preserves custom changes and integrates only after checks", async () => {
  await using f = await fixture()
  const result = await synchronize({
    ...f,
    check: async (directory) => {
      expect(await Bun.file(path.join(directory, "custom")).text()).toContain("approved")
      expect(await f.git(f.origin, "rev-parse", "custom")).toBe(f.base)
    },
    repair: async () => {
      throw new Error("must not invoke repair")
    },
  })
  expect(result.kind).toBe("integrated")
  expect(await f.git(f.origin, "rev-parse", "custom")).not.toBe(f.base)
})

test("conflict repair publishes a review branch without updating custom", async () => {
  await using f = await fixture(true)
  const result = await synchronize({
    ...f,
    check: async (directory) => {
      expect(await Bun.file(path.join(directory, "shared")).text()).toBe("custom + upstream\n")
    },
    repair: async (directory) => {
      await Bun.write(path.join(directory, "shared"), "custom + upstream\n")
      await f.git(directory, "add", "shared")
    },
  })
  expect(result.kind).toBe("review")
  expect(await f.git(f.origin, "rev-parse", "custom")).toBe(f.base)
  expect(await f.git(f.origin, "rev-parse", result.branch)).not.toBe(f.base)
})

test("failed validation invokes repair and still requires review", async () => {
  await using f = await fixture()
  const result = await synchronize({
    ...f,
    check: async (directory) => {
      if (!(await Bun.file(path.join(directory, "fixed")).exists())) throw new Error("compiler failure")
    },
    repair: async (directory) => {
      await Bun.write(path.join(directory, "fixed"), "fix\n")
    },
  })
  expect(result.kind).toBe("review")
  expect(await f.git(f.origin, "rev-parse", "custom")).toBe(f.base)
})

test("failed repair leaves custom untouched", async () => {
  await using f = await fixture(true)
  await expect(
    synchronize({
      ...f,
      check: async () => {},
      repair: async () => {
        throw new Error("agent unavailable")
      },
    }),
  ).rejects.toThrow("agent unavailable")
  expect(await f.git(f.origin, "rev-parse", "custom")).toBe(f.base)
})

test("concurrent custom advancement refuses integration", async () => {
  await using f = await fixture()
  await expect(
    synchronize({
      ...f,
      check: async () => {
        await f.git(f.seed, "checkout", "custom")
        await Bun.write(path.join(f.seed, "concurrent"), "other developer\n")
        await f.git(f.seed, "add", ".")
        await f.git(f.seed, "commit", "-m", "feat: concurrent")
        await f.git(f.seed, "push", "origin", "custom")
      },
      repair: async () => {
        throw new Error("must not repair a ref race")
      },
    }),
  ).rejects.toThrow("advanced concurrently")
  expect(await f.git(f.origin, "show", "custom:concurrent")).toBe("other developer")
})

test("OS lock excludes duplicate controllers and releases after failure", async () => {
  await using f = await fixture()
  await locked(path.join(f.home, "lock"), async () => {
    await expect(locked(path.join(f.home, "lock"), async () => {})).rejects.toThrow()
  })
  await expect(
    locked(path.join(f.home, "lock"), async () => {
      throw new Error("failure")
    }),
  ).rejects.toThrow()
  await locked(path.join(f.home, "lock"), async () => {})
})

test("transient retries are bounded and do not invoke repair", async () => {
  const attempts: number[] = []
  expect(
    await retry(async () => {
      attempts.push(1)
      if (attempts.length < 3) throw new Error("network unavailable")
      return "ok"
    }, 1),
  ).toBe("ok")
  expect(attempts.length).toBe(3)
})

test("activation refuses busy or unknown health and backs up only after leased exit", async () => {
  await using f = await fixture()
  await mkdir(path.join(f.home, "data"))
  await Bun.write(path.join(f.home, "data/persistent"), "old database")
  await Bun.write(path.join(f.home, "password"), "isolated-test-credential")
  const state = { health: 503, busy: true, committed: false }
  const exit = Promise.withResolvers<number>()
  const old = { directory: f.seed, commit: "old" }
  const next = { directory: f.repository, commit: "new" }
  await atomic(path.join(f.home, "current.json"), old)
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      const route = new URL(request.url).pathname
      if (route === "/api/health")
        return Response.json({ healthy: true, version: "old", pid: 1234 }, { status: state.health })
      if (route.endsWith("/commit")) {
        state.committed = true
        exit.resolve(0)
        return Response.json({ committed: true })
      }
      return Response.json({
        reason: state.busy ? "busy" : "idle",
        lease: state.busy
          ? null
          : { identity: "test-process", token: "test-lease", expires: Date.now() + 60_000, pid: 1234 },
      })
    },
  })
  try {
    const config = { home: f.home, repository: f.repository, bun: process.execPath, port: Number(server.port) }
    const child = { pid: 1234, exited: exit.promise }
    expect(await activate(config, old, next, child)).toBe(false)
    state.health = 200
    expect(await activate(config, old, next, child)).toBe(false)
    expect(state.committed).toBe(false)
    state.busy = false
    expect(await activate(config, old, next, child)).toBe(true)
    const previous = await Bun.file(path.join(f.home, "previous.json")).json()
    expect(await Bun.file(path.join(previous.backup, "data/persistent")).text()).toBe("old database")
    expect((await Bun.file(path.join(f.home, "current.json")).json()).commit).toBe("new")
  } finally {
    server.stop(true)
  }
})
