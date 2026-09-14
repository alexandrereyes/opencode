import { expect, test } from "bun:test"
import { createServer } from "node:net"
import { mkdir, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"
import { OpenCode } from "@opencode/client/promise"
import { stageRelease } from "../src/updates/prepare"
import { pointRelease, readRelease } from "../src/updates/release"
import { Updates } from "../src/updates/rpc"
import { waitForRelease } from "../src/updates/client"
import type { createUpdater } from "../src/updates/tui"
import { Navigation } from "../src/navigation/rpc"
import { NativeApps } from "../src/native-apps/rpc"
import { Snippets } from "../src/snippets/rpc"

const binary = process.env.OPENCODE_CUSTOM_TEST_BINARY
const nextBinary = process.env.OPENCODE_CUSTOM_TEST_NEXT_BINARY

test.skipIf(process.platform !== "darwin" || !binary || !nextBinary)(
  "packaged releases use native HTTP, graceful shutdown, session persistence and PTY handoff",
  async () => {
    if (!binary || !nextBinary) return
    const directory = await mkdtemp(path.join(tmpdir(), "opencode-release-smoke-"))
    await using cleanup = {
      async [Symbol.asyncDispose]() {
        await rm(directory, { recursive: true, force: true })
      },
    }
    const home = path.join(directory, "installation")
    const socket = createServer()
    await new Promise<void>((resolve) => socket.listen(0, "127.0.0.1", resolve))
    const address = socket.address()
    if (!address || typeof address === "string") throw new Error("Expected a TCP port")
    await new Promise<void>((resolve) => socket.close(() => resolve()))
    const bootstrap = Bun.spawn(
      [process.execPath, "script/bootstrap.ts", "--home", home, "--repository", ".", "--port", String(address.port)],
      { stdout: "pipe", stderr: "inherit" },
    )
    expect(await bootstrap.exited).toBe(0)
    const env = {
      ...process.env,
      OPENCODE_TEST_HOME: directory,
      XDG_DATA_HOME: path.join(home, "data"),
      XDG_CONFIG_HOME: path.join(home, "config"),
      XDG_STATE_HOME: path.join(home, "state"),
      XDG_CACHE_HOME: path.join(home, "cache"),
      OPENCODE_DISABLE_MODELS_FETCH: "1",
      OPENCODE_CONFIG_PROJECT_DISABLE: "1",
      OPENCODE_FILEWATCHER_DISABLE: "1",
      OPENCODE_PRINT_LOGS: "1",
    }
    const releases = []
    for (const [index, executable] of [binary, nextBinary].entries()) {
      const version = Bun.spawn([executable, "--version"], { env, stdout: "pipe" })
      const reported = (await new Response(version.stdout).text()).trim().replace(/^opencode v/, "")
      expect(await version.exited).toBe(0)
      releases.push(
        await stageRelease({
          home,
          source: path.resolve("../.."),
          commit: (index === 0 ? "a" : "b").repeat(40),
          version: reported,
          bun: process.execPath,
          binary: executable,
          directory: path.join(directory, `stage-${index}`),
        }),
      )
    }
    await pointRelease(home, "current", releases[0].commit)
    const service: { password: string } = await Bun.file(path.join(home, "config/opencode/service-custom.json")).json()
    const client = OpenCode.make({
      baseUrl: `http://127.0.0.1:${address.port}`,
      headers: { authorization: `Basic ${btoa(`opencode:${service.password}`)}` },
    })
    const first = Bun.spawn(["/bin/sh", path.join(home, "bin/serve.sh")], {
      cwd: directory,
      env,
      stdout: "pipe",
      stderr: Bun.file(path.join(directory, "first.log")),
    })
    await using firstCleanup = {
      async [Symbol.asyncDispose]() {
        if (first.exitCode === null) first.kill("SIGTERM")
        await first.exited
      },
    }
    await waitForRelease(client, releases[0].version, AbortSignal.timeout(30_000)).catch(async (error) => {
      throw new Error(await Bun.file(path.join(directory, "first.log")).text(), { cause: error })
    })
    expect(
      await client
        .rpc(Updates.Definition)
        .check({})
        .catch(async (error) => {
          throw new Error(await Bun.file(path.join(directory, "first.log")).text(), { cause: error })
        }),
    ).toEqual({ status: "ready", commit: releases[1].commit, version: releases[1].version })
    const session = await client.session.create({ title: "Release continuity" })
    const snippet = {
      id: "bundle-smoke",
      name: "bundle-smoke",
      description: "",
      aliases: [],
      content: "Portable wire output",
    }
    expect(await client.rpc(Snippets.Definition).save(snippet)).toEqual(snippet)
    expect(await client.rpc(Snippets.Definition).list({})).toEqual({ items: [snippet] })
    await expect(
      client.rpc(NativeApps.Definition).open({ app: "finder", path: "relative-path" }),
    ).rejects.toMatchObject({
      type: "open_failed",
      data: { reason: "invalid-path" },
    })
    const other = path.join(directory, "second-location")
    await mkdir(other)
    expect(await client.rpc(Updates.Definition).check({}, { location: { directory: other } })).toEqual({
      status: "ready",
      commit: releases[1].commit,
      version: releases[1].version,
    })
    expect(
      (await client.rpc(Navigation.Definition).list({ limit: 10 })).data.some((row) => row.session.id === session.id),
    ).toBe(true)
    const module: { createUpdater: typeof createUpdater } = await import(
      pathToFileURL(path.join(home, "current/plugin/tui.js")).href
    )
    const updater = module.createUpdater({
      endpoint: {
        url: `http://127.0.0.1:${address.port}`,
        auth: { type: "basic", username: "opencode", password: service.password },
      },
    })
    expect(await updater.check(AbortSignal.timeout(5_000))).toEqual({ type: "available", version: releases[1].version })
    const terminal = await client.experimental.persistentPty.create({
      sessionID: session.id,
      command: "/bin/sh",
      args: ["-c", "printf ready; sleep 120"],
      title: "release smoke",
      cwd: directory,
      env: {},
    })
    // The launcher resolves current once; a prepared release has not changed the running binary.
    expect((await client.health.get()).version).toBe(releases[0].version)
    const selected = await client
      .rpc(Updates.Definition)
      .install({ commit: releases[1].commit, version: releases[1].version }, { location: { directory: other } })
    expect(selected).toEqual({ commit: releases[1].commit, version: releases[1].version })
    await first.exited
    expect(await Bun.file(path.join(home, "state/opencode/service-custom.json")).exists()).toBe(false)
    expect((await readRelease(home, "current"))?.commit).toBe(releases[1].commit)
    // A test-owned second process exercises the same launcher launchd will execute.
    const second = Bun.spawn(["/bin/sh", path.join(home, "bin/serve.sh")], {
      cwd: directory,
      env,
      stdout: "pipe",
      stderr: Bun.file(path.join(directory, "second.log")),
    })
    await using secondCleanup = {
      async [Symbol.asyncDispose]() {
        if (second.exitCode === null) second.kill("SIGTERM")
        await second.exited
      },
    }
    await waitForRelease(client, releases[1].version, AbortSignal.timeout(30_000)).catch(async (error) => {
      throw new Error(await Bun.file(path.join(directory, "second.log")).text(), { cause: error })
    })
    expect(await client.rpc(Updates.Definition).check({})).toEqual({ status: "up-to-date" })
    expect((await client.session.get({ sessionID: session.id })).title).toBe("Release continuity")
    const adopted = await client.experimental.persistentPty.get({ ptyID: terminal.id })
    expect(adopted.pid).toBe(terminal.pid)
    expect(adopted.status).toBe("running")
    await client.experimental.persistentPty.shutdown()
  },
  120_000,
)
