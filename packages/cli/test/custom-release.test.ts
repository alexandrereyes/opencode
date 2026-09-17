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

test("authenticated fixture activation and rollback retain data and password", async () => {
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
    await activate(home, second, {}, service)
    expect(await pointer(home, "current")).toBe(second)
    expect(await pointer(home, "previous")).toBe(first)
    await activate(home, first, { rollback: true, compatible: true }, service)
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
})

test("failed startup stops attempted release without silently downgrading the database", async () => {
  const home = await fixture()
  const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
  await Bun.write(`${home}/manual.json`, JSON.stringify({ port: listener.port }))
  listener.stop(true)
  const calls: string[] = []
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
          throw new Error("fixture boot failure")
        },
      },
    ),
  ).rejects.toThrow("Database may have migrated")
  expect(calls).toEqual(["stop", "start", "stop"])
  expect(await pointer(home, "current")).toBe(second)
  expect(await pointer(home, "previous")).toBe(first)
  expect(Array.from(new Bun.Glob("backups/*/database.sqlite").scanSync(home))).toHaveLength(1)
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
