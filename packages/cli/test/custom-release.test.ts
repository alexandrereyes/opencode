import { afterEach, expect, test } from "bun:test"
import { Database } from "bun:sqlite"
import { chmod, mkdir, mkdtemp, readlink, realpath, rename, rm, stat } from "node:fs/promises"
import { migrate } from "../script/custom-migrate"
import os from "node:os"
import path from "node:path"
import { serverConfig } from "../script/custom-config"
import {
  activate,
  artifacts,
  digest,
  backup,
  command,
  health,
  launchd,
  label,
  manifest,
  plist,
  point,
  pointer,
  prune,
  publish,
  seal,
  scripts,
  settings,
} from "../script/custom-release"

const first = "a".repeat(40)
const second = "b".repeat(40)
const homes: string[] = []

function launchHost(home: string) {
  const state = {
    time: 0,
    registered: true,
    alive: true,
    bootouts: 0,
    bootstraps: 0,
    owner: home,
    queryError: false,
    transient: 0,
    permanent: false,
    stuck: false,
  }
  const host = {
    async run(args: string[]) {
      if (args[0] === "print") {
        if (state.queryError) return { code: 1, stdout: "", stderr: "Permission denied" }
        return state.registered
          ? { code: 0, stdout: `program = ${state.owner}/bin/serve\npid = 12345\n`, stderr: "" }
          : { code: 113, stdout: "", stderr: `Could not find service "${label}" in domain for user gui` }
      }
      if (args[0] === "bootout") {
        state.bootouts++
        return { code: 0, stdout: "", stderr: "" }
      }
      state.bootstraps++
      if (state.permanent) return { code: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error" }
      if (state.bootstraps <= state.transient) return { code: 37, stdout: "", stderr: "Operation already in progress" }
      state.registered = true
      return { code: 0, stdout: "", stderr: "" }
    },
    async alive() {
      return state.alive
    },
    now: () => state.time,
    async sleep(ms: number) {
      state.time += ms
      if (state.stuck || !state.bootouts) return
      if (state.time >= 500) state.registered = false
      if (state.time >= 1000) state.alive = false
    },
  }
  return { state, host }
}

test("launchd waits for both removal and process exit even with a free port", async () => {
  const home = await fixture()
  const fixtureHost = launchHost(home)
  const socket = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  const port = socket.port
  socket.stop(true)
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port }))
  const service = launchd(home, fixtureHost.host)
  const server = { value: undefined as ReturnType<typeof Bun.serve> | undefined }
  const run = fixtureHost.host.run
  fixtureHost.host.run = async (args) => {
    if (args[0] === "bootstrap") {
      expect(fixtureHost.state.time).toBe(1000)
      expect(fixtureHost.state.alive).toBe(false)
      expect(await pointer(home, "current")).toBe(second)
      server.value = Bun.serve({
        hostname: "127.0.0.1",
        port,
        fetch: () => Response.json({ version: `0.0.0-custom.${second}` }),
      })
    }
    return run(args)
  }
  try {
    await activate(home, second, { skipBackup: true }, service)
  } finally {
    await server.value?.stop(true)
  }
  expect(fixtureHost.state.bootstraps).toBe(1)
})

test("launchd retries explicit in-progress responses but reconciles a registered job", async () => {
  const fixtureHost = launchHost("/fixture")
  fixtureHost.state.registered = false
  fixtureHost.state.transient = 1
  const service = launchd("/fixture", fixtureHost.host)
  await service.start()
  expect(fixtureHost.state.bootstraps).toBe(2)
  await service.start()
  expect(fixtureHost.state.bootstraps).toBe(2)
})

test.each(["permanent", "transient"])("launchd bounds %s bootstrap failure", async (kind) => {
  const fixtureHost = launchHost("/fixture")
  fixtureHost.state.registered = false
  fixtureHost.state.permanent = kind === "permanent"
  fixtureHost.state.transient = 10
  await expect(launchd("/fixture", fixtureHost.host).start()).rejects.toThrow("bootstrap failed")
  expect(fixtureHost.state.bootstraps).toBe(kind === "permanent" ? 1 : 3)
})

test("bootstrap error with an owned registration reconciles without another bootstrap", async () => {
  const fixtureHost = launchHost("/fixture")
  fixtureHost.state.registered = false
  const run = fixtureHost.host.run
  fixtureHost.host.run = async (args) => {
    const result = await run(args)
    if (args[0] === "bootstrap") return { code: 5, stdout: "", stderr: "Input/output error" }
    return result
  }
  await launchd("/fixture", fixtureHost.host).start()
  expect(fixtureHost.state.bootstraps).toBe(1)
})

test("ownership change during teardown aborts without unloading the new owner", async () => {
  const fixtureHost = launchHost("/fixture")
  const run = fixtureHost.host.run
  fixtureHost.host.run = async (args) => {
    const result = await run(args)
    if (args[0] === "bootout") fixtureHost.state.owner = "/other"
    return result
  }
  await expect(launchd("/fixture", fixtureHost.host).stop()).rejects.toThrow("another runtime")
  expect(fixtureHost.state.bootouts).toBe(1)
  expect(fixtureHost.state.bootstraps).toBe(0)
})

test("launchd teardown timeout and unknown ownership prevent pointer switch", async () => {
  const home = await fixture()
  const fixtureHost = launchHost(home)
  fixtureHost.state.stuck = true
  const socket = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port: socket.port }))
  socket.stop(true)
  await expect(activate(home, second, { skipBackup: true }, launchd(home, fixtureHost.host))).rejects.toThrow(
    "timed out",
  )
  expect(fixtureHost.state.time).toBe(65_000)
  expect(await pointer(home, "current")).toBe(first)
  fixtureHost.state.owner = "/other"
  await expect(launchd(home, fixtureHost.host).stop()).rejects.toThrow("another runtime")
  await expect(launchd(home, fixtureHost.host).start()).rejects.toThrow("another runtime")
  expect(fixtureHost.state.bootouts).toBe(1)
  expect(fixtureHost.state.bootstraps).toBe(0)
  fixtureHost.state.queryError = true
  await expect(launchd(home, fixtureHost.host).stop()).rejects.toThrow("Permission denied")
})

test("shared server config includes the native Safari DevTools MCP server", () => {
  expect(serverConfig("/release/plugin")).toEqual({
    update: "disable",
    plugins: ["/release/plugin"],
    mcp: {
      servers: {
        "safari-devtools": {
          type: "local",
          command: ["/usr/bin/safaridriver", "--mcp"],
        },
      },
    },
  })
})

afterEach(async () => {
  await Promise.all(
    homes.splice(0).map(async (home) => {
      await command(["chmod", "-R", "u+w", home])
      await rm(home, { recursive: true, force: true })
    }),
  )
})

async function fixture() {
  await mkdir(path.join(os.tmpdir(), "opencode"), { recursive: true })
  const home = await realpath(await mkdtemp(path.join(os.tmpdir(), "opencode", "manual-' &-")))
  homes.push(home)
  for (const commit of [first, second]) {
    const directory = path.join(home, "releases", commit)
    for (const file of artifacts) await Bun.write(`${directory}/${file}`, "fixture")
    await Bun.write(
      `${directory}/manual-release.json`,
      JSON.stringify({
        format: 2,
        hashes: Object.fromEntries(
          await Promise.all(artifacts.map(async (file) => [file, await digest(`${directory}/${file}`)])),
        ),
        commit,
        version: `0.0.0-custom.${commit}`,
        platform: process.platform,
        arch: process.arch,
      }),
    )
  }
  await Bun.write(`${home}/password`, "fixture-secret\n")
  await mkdir(`${home}/data/opencode`, { recursive: true })
  const db = new Database(`${home}/data/opencode/custom.db`)
  db.exec("CREATE TABLE facts (value TEXT); INSERT INTO facts VALUES ('preserved')")
  db.close()
  await point(home, "current", first)
  await point(home, "prepared", second)
  return home
}

test("atomic release pointers and manifest reject non-release targets", async () => {
  const home = await fixture()
  await point(home, "current", second)
  expect(await pointer(home, "current")).toBe(second)
  expect((await manifest(home, second)).version).toBe(`0.0.0-custom.${second}`)
  await expect(point(home, "current", "../../elsewhere")).rejects.toThrow("full commit SHA")
  await Bun.write(`${home}/releases/${second}/manual-release.json`, "{}")
  await expect(manifest(home, second)).rejects.toThrow("Invalid or incompatible")
})

test("hash verification rejects an edited artifact before any lifecycle operation", async () => {
  const home = await fixture()
  await Bun.write(`${home}/releases/${second}/plugin/index.js`, "tampered")
  await expect(manifest(home, second)).rejects.toThrow("integrity check failed")
  await expect(activate(home, second, { dryRun: true })).rejects.toThrow("integrity check failed")
})

test("publication renames writable staging before making the entire release read-only", async () => {
  const home = await fixture()
  await mkdir(`${home}/builds`)
  const staging = `${home}/builds/release`
  await rename(`${home}/releases/${second}`, staging)
  await seal(staging, second)
  expect((await stat(staging)).mode & 0o200).toBe(0o200)
  await publish(home, second, staging)
  const release = await manifest(home, second)
  for (const name of ["", "bin", "plugin", "manual-release.json", ...artifacts])
    expect((await stat(path.join(release.directory, name))).mode & 0o222).toBe(0)
  expect(await pointer(home, "prepared")).toBe(second)
  expect(await Bun.file(`${staging}/manual-release.json`).exists()).toBe(false)
})

test("publication recovers writable releases without resealing modified artifacts", async () => {
  const home = await fixture()
  await point(home, "prepared", first)
  const directory = `${home}/releases/${second}`
  const original = await Bun.file(`${directory}/manual-release.json`).text()
  expect((await stat(directory)).mode & 0o200).toBe(0o200)
  await Bun.write(`${directory}/plugin/index.js`, "tampered")
  await expect(publish(home, second)).rejects.toThrow("integrity check failed")
  expect(await pointer(home, "prepared")).toBe(first)
  expect(await Bun.file(`${directory}/manual-release.json`).text()).toBe(original)
  expect((await stat(directory)).mode & 0o200).toBe(0o200)
  await Bun.write(`${directory}/plugin/index.js`, "fixture")
  await publish(home, second)
  await publish(home, second)
  expect((await stat(directory)).mode & 0o222).toBe(0)
  expect((await manifest(home, second)).commit).toBe(second)
  expect(await Bun.file(`${directory}/manual-release.json`).text()).toBe(original)
  expect(await pointer(home, "prepared")).toBe(second)
})

test("manual pruning protects pointers and dry-run leaves all artifacts intact", async () => {
  const home = await fixture()
  const commit = "c".repeat(40)
  const directory = `${home}/releases/${commit}`
  for (const file of artifacts) await Bun.write(`${directory}/${file}`, "fixture")
  await Bun.write(
    `${directory}/manual-release.json`,
    JSON.stringify({
      format: 2,
      commit,
      version: `0.0.0-custom.${commit}`,
      platform: process.platform,
      arch: process.arch,
      hashes: Object.fromEntries(
        await Promise.all(artifacts.map(async (file) => [file, await digest(`${directory}/${file}`)])),
      ),
    }),
  )
  const socket = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port: socket.port }))
  socket.stop(true)
  await prune(home, 0, true)
  expect(await Bun.file(`${directory}/manual-release.json`).exists()).toBe(true)
  await prune(home, 0, false)
  expect(await Bun.file(`${directory}/manual-release.json`).exists()).toBe(false)
  expect((await manifest(home, first)).commit).toBe(first)
  expect((await manifest(home, second)).commit).toBe(second)
})

test("migration dry-run, preservation and retries use only validated fixture lifecycle", async () => {
  const home = await fixture()
  const user = `${home}/user`
  const calls: string[] = []
  const state = { beta: true }
  await rm(`${home}/password`)
  await Bun.write(
    `${home}/environment.sh`,
    `export OPENCODE_DB='${home.replaceAll("'", "'\\''")}/data/opencode/custom.db'\nexport OPENCODE_CONFIG_DIR='${home.replaceAll("'", "'\\''")}/existing-config'\n`,
  )
  await Bun.write(
    `${home}/config/opencode/service-custom.json`,
    JSON.stringify({ port: 4178, password: "fixture-secret" }),
  )
  await Bun.write(`${user}/Library/LaunchAgents/local.opencode.custom-service.plist`, "known fixture")
  await Bun.write(`${user}/.opencode/bin/opencode2`, "old binary")
  const host = {
    async validateOld(file: string, launcher: string) {
      expect(await Bun.file(file).text()).toBe("known fixture")
      expect(launcher).toBe(`${home}/bin/serve.sh`)
    },
    async stopOld() {
      calls.push("old-stop")
    },
    async beta() {
      return state.beta ? 1234 : undefined
    },
    async stopBeta(pid: number) {
      expect(pid).toBe(1234)
      calls.push("beta-stop")
      state.beta = false
    },
    async activate(commit: string) {
      calls.push("activate")
      await point(home, "current", commit)
    },
  }
  await migrate(home, user, { dryRun: true }, host)
  expect(calls).toEqual([])
  expect(await Bun.file(`${home}/password`).exists()).toBe(false)
  await expect(migrate(home, user, { replaceLauncher: true }, host)).rejects.toThrow("--stop-beta")
  await expect(
    migrate(
      home,
      user,
      { replaceLauncher: true, stopBeta: true },
      {
        ...host,
        async stopBeta() {
          throw new Error("fixture beta shutdown failed")
        },
      },
    ),
  ).rejects.toThrow("fixture beta shutdown failed")
  expect(calls).toEqual([])
  expect(await Bun.file(`${user}/Library/LaunchAgents/local.opencode.custom-service.plist`).text()).toBe(
    "known fixture",
  )
  expect(await pointer(home, "current")).toBe(first)
  await migrate(home, user, { replaceLauncher: true, stopBeta: true }, host)
  await migrate(home, user, { replaceLauncher: true, stopBeta: true }, host)
  expect(calls).toEqual(["beta-stop", "old-stop", "activate", "activate"])
  expect(await Bun.file(`${home}/password`).text()).toBe("fixture-secret")
  expect((await stat(`${home}/password`)).mode & 0o777).toBe(0o600)
  expect((await stat(`${home}/manual.json`)).mode & 0o777).toBe(0o600)
  expect(await readlink(`${user}/.opencode/bin/opencode2`)).toBe(`${home}/bin/opencode2`)
  expect(Array.from(new Bun.Glob("opencode2.pre-custom-*").scanSync(`${user}/.opencode/bin`))).toHaveLength(1)
  const unknown = {
    ...host,
    async validateOld() {
      throw new Error("unknown label")
    },
  }
  await Bun.write(`${user}/Library/LaunchAgents/local.opencode.custom-service.plist`, "unknown")
  await expect(migrate(home, user, { dryRun: true }, unknown)).rejects.toThrow("unknown label")
})

test("SQLite backup includes committed WAL content and leaves source intact", async () => {
  const home = await fixture()
  const config = await settings(home)
  const db = new Database(config.database)
  try {
    db.exec("PRAGMA journal_mode=WAL; INSERT INTO facts VALUES ('in WAL')")
    await backup(config.database, `${home}/backup.sqlite`)
    const saved = new Database(`${home}/backup.sqlite`, { readonly: true })
    try {
      expect(saved.query("SELECT value FROM facts ORDER BY rowid").all()).toEqual([
        { value: "preserved" },
        { value: "in WAL" },
      ])
      expect(db.query("SELECT count(*) AS count FROM facts").get()).toEqual({ count: 2 })
    } finally {
      saved.close()
    }
  } finally {
    db.close()
  }
})

test("activation dry-run and rollback refusal never invoke lifecycle or change current", async () => {
  const home = await fixture()
  const service = {
    async start() {
      throw new Error("must not start")
    },
    async stop() {
      throw new Error("must not stop")
    },
  }
  await activate(home, second, { dryRun: true }, service)
  await expect(activate(home, second, { rollback: true }, service)).rejects.toThrow("--database-compatible")
  expect(await pointer(home, "current")).toBe(first)
  expect(await Bun.file(`${home}/bin/serve`).exists()).toBe(false)
})

test.each([false, true])(
  "authenticated activation (skipBackup=%s) and rollback retain data and password",
  async (skipBackup) => {
    const home = await fixture()
    const state = { version: `0.0.0-custom.${first}`, authorization: "", starts: 0, stops: 0 }
    const serve = (port: number) =>
      Bun.serve({
        hostname: "127.0.0.1",
        port,
        fetch(request) {
          state.authorization = request.headers.get("authorization") ?? ""
          if (state.authorization !== `Basic ${Buffer.from("opencode:fixture-secret").toString("base64")}`)
            return new Response(null, { status: 401 })
          const endpoint = state.version === `0.0.0-custom.${first}` ? "/api/health" : "/api/info"
          if (new URL(request.url).pathname !== endpoint) return new Response(null, { status: 404 })
          return Response.json({ healthy: true, version: state.version })
        },
      })
    const stateServer = { value: serve(0) }
    const port = stateServer.value.port!
    await Bun.write(`${home}/manual.json`, JSON.stringify({ port }))
    const service = {
      async stop() {
        state.stops++
        await stateServer.value.stop(true)
      },
      async start() {
        state.starts++
        state.version = `0.0.0-custom.${await pointer(home, "current")}`
        stateServer.value = serve(port)
      },
    }
    try {
      await activate(home, second, { skipBackup }, service)
      expect(Array.from(new Bun.Glob("backups/*/database.sqlite").scanSync(home))).toHaveLength(skipBackup ? 0 : 1)
      expect(await pointer(home, "current")).toBe(second)
      expect(await pointer(home, "previous")).toBe(first)
      await activate(home, first, { rollback: true, compatible: true }, service)
      expect(Array.from(new Bun.Glob("backups/*/database.sqlite").scanSync(home))).toHaveLength(skipBackup ? 1 : 2)
      expect(await pointer(home, "current")).toBe(first)
      expect(state.starts).toBe(2)
      expect(state.stops).toBe(2)
      expect((await health(home, port)).ready).toBe(true)
      expect(await Bun.file(`${home}/password`).text()).toBe("fixture-secret\n")
      const db = new Database((await settings(home)).database, { readonly: true })
      expect(db.query("SELECT value FROM facts").all()).toEqual([{ value: "preserved" }])
      db.close()
    } finally {
      await stateServer.value.stop(true)
    }
  },
)

test.each([false, true])(
  "failed startup (skipBackup=%s) stops attempted release without silently downgrading the database",
  async (skipBackup) => {
    const home = await fixture()
    const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
    await Bun.write(`${home}/manual.json`, JSON.stringify({ port: listener.port }))
    listener.stop(true)
    const calls: string[] = []
    await expect(
      activate(
        home,
        second,
        { skipBackup },
        {
          async stop() {
            calls.push("stop")
          },
          async start() {
            calls.push("start")
            throw new Error("fixture boot failure")
          },
        },
      ),
    ).rejects.toThrow(skipBackup ? "No database backup was created." : "Backup:")
    expect(calls).toEqual(["stop", "start", "stop"])
    expect(await pointer(home, "current")).toBe(second)
    expect(await pointer(home, "previous")).toBe(first)
    expect(Array.from(new Bun.Glob("backups/*/database.sqlite").scanSync(home))).toHaveLength(skipBackup ? 0 : 1)
  },
)

test.each(["waiting-port", "healthcheck"])("reporter failure at %s does not interrupt activation", async (phase) => {
  const home = await fixture()
  const socket = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  const port = socket.port
  socket.stop(true)
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port }))
  const state = {
    stops: 0,
    starts: 0,
    reports: [] as string[],
    server: undefined as ReturnType<typeof Bun.serve> | undefined,
  }
  try {
    await activate(
      home,
      second,
      {
        skipBackup: true,
        async report(value) {
          state.reports.push(value)
          if (value === phase) {
            expect(state.stops).toBe(1)
            expect(state.starts).toBe(phase === "healthcheck" ? 1 : 0)
            throw new Error("fixture journal IO failure")
          }
        },
      },
      {
        async stop() {
          state.stops++
        },
        async start() {
          state.starts++
          state.server = Bun.serve({
            hostname: "127.0.0.1",
            port,
            fetch(request) {
              if (
                request.headers.get("authorization") !==
                `Basic ${Buffer.from("opencode:fixture-secret").toString("base64")}`
              )
                return new Response(null, { status: 401 })
              return Response.json({ version: `0.0.0-custom.${second}` })
            },
          })
        },
      },
    )
    expect(state.reports).toContain(phase)
    expect(state.stops).toBe(1)
    expect(state.starts).toBe(1)
    expect(await health(home, port)).toMatchObject({ ready: true, version: `0.0.0-custom.${second}` })
    expect(await pointer(home, "current")).toBe(second)
  } finally {
    await state.server?.stop(true)
  }
})

test("cleanup failure retains the original startup cause", async () => {
  const home = await fixture()
  const socket = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port: socket.port }))
  socket.stop(true)
  const original = new Error("fixture original bootstrap failure")
  const state = { stops: 0 }
  const error = await activate(
    home,
    second,
    { skipBackup: true },
    {
      async stop() {
        state.stops++
        if (state.stops === 2) throw new Error("fixture cleanup failure")
      },
      async start() {
        throw original
      },
    },
  ).then(
    () => undefined,
    (failure: unknown) => failure,
  )
  expect(error).toBeInstanceOf(Error)
  if (!(error instanceof Error)) throw new Error("Expected activation failure")
  expect(error.cause).toBe(original)
  expect(error.message).toContain("fixture original bootstrap failure")
  expect(error.message).toContain("cleanup failed: Error: fixture cleanup failure")
  expect(state.stops).toBe(2)
  expect(await pointer(home, "current")).toBe(second)
})

test("another service on the configured port is never stopped, including a non-JSON 401", async () => {
  const home = await fixture()
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response(null, { status: 401 }) })
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port: server.port }))
  const calls: string[] = []
  try {
    expect((await health(home, server.port!)).status).toBe(401)
    await expect(
      activate(
        home,
        second,
        {},
        {
          async stop() {
            calls.push("stop")
          },
          async start() {
            calls.push("start")
          },
        },
      ),
    ).rejects.toThrow("another release/service")
    expect(calls).toEqual([])
    expect(await pointer(home, "current")).toBe(first)
  } finally {
    await server.stop(true)
  }
})

test("launcher pins release and explicit server, preserves cwd, and rejects managed lifecycle", async () => {
  const home = await fixture()
  const config = await settings(home)
  const output = scripts(home, config)
  await Bun.write(`${home}/launcher`, output.tui)
  await Bun.write(
    `${home}/releases/${first}/bin/opencode`,
    '#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" "$OPENCODE_DISABLE_AUTOUPDATE"\n',
  )
  await chmod(`${home}/releases/${first}/bin/opencode`, 0o755)
  const result = await command(["sh", `${home}/launcher`, "a directory"], home)
  expect(result.split("\n")).toEqual([home, "a directory", "--server", "http://127.0.0.1:4178", "1"])
  const blocked = Bun.spawn(["sh", `${home}/launcher`, "service", "restart"], { stdout: "ignore", stderr: "ignore" })
  expect(await blocked.exited).toBe(2)
  expect(output.server).toContain('exec "$release/bin/opencode" serve --hostname 127.0.0.1 --port 4178')
  expect(plist(home)).toContain("&amp;")
  expect(plist(home)).not.toContain("fixture-secret")
})
