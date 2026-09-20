#!/usr/bin/env bun

import { chmod, copyFile, mkdir, mkdtemp, readdir, readlink, realpath, rename, rm, symlink } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import os from "node:os"
import path from "node:path"
import { serverConfig } from "./custom-config"

const repository = path.resolve(import.meta.dirname, "../../..")
export const label = "local.opencode.custom-manual"
const sha = /^[a-f0-9]{40}$/

export function quote(value: string) {
  return `'${value.replaceAll("'", "'\\''")}'`
}

export async function command(args: string[], cwd = repository, env = process.env, capture = true) {
  const child = Bun.spawn(args, { cwd, env, stdin: "ignore", stdout: capture ? "pipe" : "inherit", stderr: "inherit" })
  const output = capture ? await new Response(child.stdout).text() : ""
  if ((await child.exited) !== 0) throw new Error(`Command failed: ${args[0]} ${args.slice(1).join(" ")}`)
  return output.trim()
}

export async function point(home: string, name: string, commit: string) {
  if (!sha.test(commit)) throw new Error("Expected a full commit SHA")
  const temporary = path.join(home, `.${name}-${randomUUID()}`)
  await symlink(`releases/${commit}`, temporary)
  await rename(temporary, path.join(home, name)).finally(() => rm(temporary, { force: true }))
}

export async function pointer(home: string, name: string) {
  const value = await readlink(path.join(home, name)).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return undefined
    throw error
  })
  if (!value) return
  const commit = path.basename(value)
  if (!sha.test(commit)) throw new Error(`Invalid ${name} pointer: ${value}`)
  return commit
}

export async function manifest(home: string, commit: string) {
  if (!sha.test(commit)) throw new Error("Expected a full commit SHA")
  const directory = path.join(home, "releases", commit)
  const input: unknown = await Bun.file(path.join(directory, "manual-release.json")).json()
  if (
    typeof input !== "object" ||
    input === null ||
    !("format" in input) ||
    input.format !== 2 ||
    !("commit" in input) ||
    input.commit !== commit ||
    !("version" in input) ||
    input.version !== `0.0.0-custom.${commit}` ||
    !("platform" in input) ||
    input.platform !== process.platform ||
    !("arch" in input) ||
    input.arch !== process.arch
  )
    throw new Error(`Invalid or incompatible manual release: ${commit}`)
  if ((await realpath(directory)) !== path.join(await realpath(home), "releases", commit))
    throw new Error("Release directory must not be a symlink")
  if (!("hashes" in input) || typeof input.hashes !== "object" || input.hashes === null)
    throw new Error("Missing artifact hashes")
  for (const file of artifacts) {
    if (Object.entries(input.hashes).find(([key]) => key === file)?.[1] !== (await digest(path.join(directory, file))))
      throw new Error(`Release integrity check failed: ${file}`)
  }
  return { commit, version: input.version, directory }
}

export const artifacts = ["bin/opencode", "plugin/index.js", "server-config.json"] as const

export async function digest(file: string) {
  return new Bun.CryptoHasher("sha256").update(await Bun.file(file).arrayBuffer()).digest("hex")
}

export async function seal(directory: string, commit: string) {
  if (!sha.test(commit)) throw new Error("Expected a full commit SHA")
  await Bun.write(
    `${directory}/manual-release.json`,
    JSON.stringify(
      {
        format: 2,
        commit,
        version: `0.0.0-custom.${commit}`,
        platform: process.platform,
        arch: process.arch,
        hashes: Object.fromEntries(
          await Promise.all(artifacts.map(async (file) => [file, await digest(`${directory}/${file}`)])),
        ),
      },
      null,
      2,
    ),
  )
}

export async function publish(home: string, commit: string, staging?: string) {
  // macOS requires the staging directory to remain writable during rename.
  if (staging) await rename(staging, path.join(home, "releases", commit))
  const release = await manifest(home, commit)
  // Also completes publication after a crash between rename and chmod. Never
  // regenerate hashes here: a modified release must fail before normalization.
  await command(["chmod", "-R", "a-w", release.directory])
  await manifest(home, commit)
  await point(home, "prepared", commit)
}

export async function prepare(home: string, dryRun = false) {
  if ((await command(["git", "branch", "--show-current"])) !== "custom")
    throw new Error("Prepare requires branch custom")
  if (await command(["git", "status", "--porcelain"]))
    throw new Error("Commit or stash changes before preparing a release")
  const commit = await command(["git", "rev-parse", "HEAD"])
  if (dryRun) {
    console.log(
      `Prepare ${commit}: git archive, frozen install, package typechecks, custom web/plugin/CLI build; publish ${home}/releases/${commit}`,
    )
    return commit
  }
  if (await Bun.file(path.join(home, "releases", commit, "manual-release.json")).exists()) {
    await publish(home, commit)
    return commit
  }
  await mkdir(path.join(home, "releases"), { recursive: true })
  await mkdir(path.join(home, "builds"), { recursive: true })
  const work = await mkdtemp(path.join(home, "builds", "prepare-"))
  const source = path.join(work, "source")
  await mkdir(source)
  await mkdir(path.join(work, "bin"))
  await copyFile(process.execPath, path.join(work, "bin/bun"))
  await chmod(path.join(work, "bin/bun"), 0o755)
  const env = {
    ...process.env,
    HUSKY: "0",
    OPENCODE_CHANNEL: "custom",
    OPENCODE_VERSION: `0.0.0-custom.${commit}`,
    OPENCODE_DISABLE_AUTOUPDATE: "1",
    PATH: `${work}/bin:${process.env.PATH ?? "/usr/bin:/bin"}`,
    XDG_CONFIG_HOME: `${work}/checks/config`,
    XDG_DATA_HOME: `${work}/checks/data`,
    XDG_STATE_HOME: `${work}/checks/state`,
    XDG_CACHE_HOME: `${work}/checks/cache`,
    OPENCODE_CONFIG_DIR: `${work}/checks/config/opencode`,
    OPENCODE_CUSTOM_HOME: `${work}/checks/runtime`,
  }
  // Build only archived files. Ignored output and mutable checkout dependencies never enter a release.
  await command(["git", "archive", "--format=tar", `--output=${work}/source.tar`, commit])
  await command(["tar", "-xf", `${work}/source.tar`, "-C", source])
  await command([`${work}/bin/bun`, "install", "--frozen-lockfile", "--backend=copyfile"], source, env, false)
  for (const pkg of ["cli", "app-custom", "plugin-app-custom"])
    await command([`${work}/bin/bun`, "typecheck"], path.join(source, "packages", pkg), env, false)
  await command([`${work}/bin/bun`, "run", "build"], path.join(source, "packages/plugin-app-custom"), env, false)
  await command(
    [`${work}/bin/bun`, "run", "script/build.ts", "--single", "--skip-install", "--custom"],
    path.join(source, "packages/cli"),
    env,
    false,
  )
  const staging = path.join(work, "release")
  await mkdir(`${staging}/bin`, { recursive: true })
  await mkdir(`${staging}/plugin`)
  await copyFile(
    path.join(source, `packages/cli/dist/cli-${process.platform}-${process.arch}/bin/opencode`),
    `${staging}/bin/opencode`,
  )
  await chmod(`${staging}/bin/opencode`, 0o755)
  const reported = await command([`${staging}/bin/opencode`, "--version"], work, env)
  if (reported !== `opencode v${env.OPENCODE_VERSION}`) throw new Error(`Unexpected CLI version: ${reported}`)
  await command([`${staging}/bin/opencode`, "--help"], work, env)
  await command(
    [
      `${work}/bin/bun`,
      "build",
      "packages/cli/script/custom-plugin.ts",
      "--target=bun",
      "--minify",
      `--outfile=${staging}/plugin/index.js`,
    ],
    source,
    env,
    false,
  )
  await Bun.write(
    `${staging}/server-config.json`,
    JSON.stringify(serverConfig(path.join(home, "releases", commit, "plugin"))),
  )
  await seal(staging, commit)
  await publish(home, commit, staging)
  await rm(work, { recursive: true, force: true })
  console.log(`Prepared ${commit}`)
  return commit
}

export async function settings(home: string) {
  const file = Bun.file(path.join(home, "manual.json"))
  const input: unknown = (await file.exists()) ? await file.json() : {}
  if (typeof input !== "object" || input === null) throw new Error("Invalid manual.json")
  const port = "port" in input ? input.port : 4178
  const database = "database" in input ? input.database : `${home}/data/opencode/custom.db`
  const config = "config" in input ? input.config : `${home}/config/opencode`
  const environment = "environment" in input ? input.environment : {}
  if (
    typeof port !== "number" ||
    !Number.isInteger(port) ||
    port < 1024 ||
    port > 65535 ||
    typeof database !== "string" ||
    !path.isAbsolute(database) ||
    typeof config !== "string" ||
    !path.isAbsolute(config) ||
    typeof environment !== "object" ||
    environment === null ||
    Array.isArray(environment)
  )
    throw new Error("Invalid manual.json settings")
  const entries = Object.entries(environment)
  if (entries.some(([key, value]) => !/^[A-Z_][A-Z0-9_]*$/.test(key) || typeof value !== "string"))
    throw new Error("manual.json environment must contain shell environment names and string values")
  return {
    port,
    database,
    config,
    environment: Object.fromEntries(entries.map(([key, value]) => [key, String(value)])),
  }
}

export async function health(home: string, port: number) {
  const file = Bun.file(`${home}/password`)
  const legacy: unknown = (await file.exists())
    ? undefined
    : await Bun.file(`${home}/config/opencode/service-custom.json`)
        .json()
        .catch(() => undefined)
  const password = (await file.exists())
    ? (await file.text()).trim()
    : typeof legacy === "object" && legacy !== null && "password" in legacy && typeof legacy.password === "string"
      ? legacy.password
      : ""
  if (!password) throw new Error("Runtime password is empty")
  const options = {
    headers: { authorization: `Basic ${Buffer.from(`opencode:${password}`).toString("base64")}` },
    signal: AbortSignal.timeout(2000),
    redirect: "error" as const,
  }
  return (
    fetch(`http://127.0.0.1:${port}/api/info`, options)
      // Releases before 2.0.6 expose only /api/health; rollback and activation inspect both versions.
      .then((response) => (response.status === 404 ? fetch(`http://127.0.0.1:${port}/api/health`, options) : response))
      .then(async (response) => {
        const body: unknown = await response.json().catch(() => null)
        return {
          ready: response.ok,
          status: response.status,
          version:
            typeof body === "object" && body !== null && "version" in body && typeof body.version === "string"
              ? body.version
              : undefined,
        }
      })
      .catch(() => ({ ready: false, status: 0, version: undefined }))
  )
}

export function scripts(home: string, config: Awaited<ReturnType<typeof settings>>) {
  const environment = Object.entries({
    ...config.environment,
    OPENCODE_DB: config.database,
    OPENCODE_CONFIG_DIR: config.config,
    OPENCODE_DISABLE_AUTOUPDATE: "1",
    XDG_DATA_HOME: config.environment.XDG_DATA_HOME ?? `${home}/data`,
    XDG_STATE_HOME: config.environment.XDG_STATE_HOME ?? `${home}/state`,
    XDG_CONFIG_HOME: config.environment.XDG_CONFIG_HOME ?? `${home}/config`,
    XDG_CACHE_HOME: config.environment.XDG_CACHE_HOME ?? `${home}/cache`,
  })
    .map(([key, value]) => `export ${key}=${quote(value)}`)
    .join("\n")
  return {
    server: `#!/bin/sh\nset -eu\n${environment}\nrelease=$(cd ${quote(`${home}/current`)} && pwd -P)\nexport OPENCODE_PASSWORD="$(cat ${quote(`${home}/password`)})"\nexport OPENCODE_CONFIG_CONTENT="$(cat "$release/server-config.json")"\ncd ${quote(home)}\nexec "$release/bin/opencode" serve --hostname 127.0.0.1 --port ${config.port}\n`,
    tui: `#!/bin/sh\nset -eu\nfor arg in "$@"; do\n  case "$arg" in service|serve|upgrade|update|uninstall|--|--standalone|--standalone=*|--server|--server=*|--password|--password=*) echo 'Use custom:* for lifecycle; this launcher always connects to the custom server.' >&2; exit 2;; esac\ndone\nrelease=$(cd ${quote(`${home}/current`)} && pwd -P)\nexport OPENCODE_DISABLE_AUTOUPDATE=1\nexport OPENCODE_PASSWORD="$(cat ${quote(`${home}/password`)})"\nexec "$release/bin/opencode" "$@" --server ${quote(`http://127.0.0.1:${config.port}`)}\n`,
  }
}

export function plist(home: string) {
  const xml = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${label}</string>
<key>ProgramArguments</key><array><string>${xml(`${home}/bin/serve`)}</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ExitTimeOut</key><integer>60</integer>
<key>StandardOutPath</key><string>${xml(`${home}/logs/server.log`)}</string>
<key>StandardErrorPath</key><string>${xml(`${home}/logs/server.log`)}</string>
</dict></plist>\n`
}

export type Service = { stop: () => Promise<void>; start: () => Promise<void> }

export function portFree(port: number) {
  try {
    const listener = Bun.listen({ hostname: "127.0.0.1", port, socket: { data() {} } })
    listener.stop(true)
    return true
  } catch {
    return false
  }
}

function launchd(home: string): Service {
  const domain = `gui/${process.getuid!()}`
  return {
    async stop() {
      const loaded = Bun.spawn(["launchctl", "print", `${domain}/${label}`], { stdout: "pipe", stderr: "ignore" })
      const output = await new Response(loaded.stdout).text()
      if ((await loaded.exited) !== 0) return
      if (output.match(/^\s*program = (.+)$/m)?.[1] !== `${home}/bin/serve`)
        throw new Error(`${label} belongs to another runtime; refusing to stop it`)
      await command(["launchctl", "bootout", `${domain}/${label}`])
    },
    async start() {
      await command(["launchctl", "bootstrap", domain, `${home}/${label}.plist`])
    },
  }
}

export async function backup(database: string, destination: string) {
  if (!(await Bun.file(database).exists()))
    throw new Error(`Database does not exist: ${database}; initialize a new runtime separately`)
  await command(["sqlite3", "-readonly", "-cmd", ".timeout 10000", database, `.backup ${JSON.stringify(destination)}`])
  // A backup of a WAL database retains its journal-mode header. Normalize the
  // private copy so it can be opened read-only without creating WAL/SHM files.
  const check = await command(["sqlite3", destination, "PRAGMA journal_mode=DELETE; PRAGMA quick_check;"])
  if (check !== "delete\nok") throw new Error("SQLite backup failed quick_check")
}

export async function activate(
  home: string,
  commit: string,
  options: { dryRun?: boolean; rollback?: boolean; compatible?: boolean; skipBackup?: boolean },
  service = launchd(home),
) {
  const release = await manifest(home, commit)
  const config = await settings(home)
  const previous = await pointer(home, "current")
  if (previous) await manifest(home, previous)
  if (options.rollback && !options.compatible)
    throw new Error(
      "Rollback requires --database-compatible after reviewing migrations, or restoring a compatible backup while stopped. It never restores data automatically.",
    )
  if (options.dryRun) {
    console.log(
      `Stop ${label}; ${options.skipBackup ? "skip database backup" : `back up ${config.database}`}; current ${previous ?? "none"} -> ${commit}; install ${home}/bin/opencode2; start; authenticated healthcheck. Failed boot stays stopped: no automatic database downgrade.`,
    )
    return
  }
  if (!(await Bun.file(`${home}/password`).text()).trim()) throw new Error("Runtime password is empty")
  if (!(await Bun.file(config.database).exists()))
    throw new Error(`Database does not exist: ${config.database}; initialize a new runtime separately`)
  if (!options.skipBackup && !Bun.which("sqlite3")) throw new Error("sqlite3 is required for a consistent backup")
  const before = await health(home, config.port)
  if (previous === commit && before.ready && before.version === release.version) {
    console.log(`Already active ${commit}`)
    return
  }
  if (!portFree(config.port) && (!previous || before.version !== `0.0.0-custom.${previous}`))
    throw new Error("Port is occupied by another release/service. Complete the documented one-time migration first.")
  const save = options.skipBackup
    ? undefined
    : path.join(home, "backups", `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID()}`)
  if (save) {
    await mkdir(save, { recursive: true, mode: 0o700 })
    await Bun.write(`${save}/activation.json`, JSON.stringify({ previous, target: commit, database: config.database }))
  }
  await service.stop()
  // bootout may return before process exit. Never snapshot or start another writer until the port closes.
  for (let attempt = 0; attempt < 65; attempt++) {
    if (portFree(config.port)) break
    if (attempt === 64) throw new Error("Server did not stop; current is unchanged")
    await Bun.sleep(1000)
  }
  if (save) {
    await backup(config.database, `${save}/database.sqlite`)
    console.log(`Consistent database backup: ${save}/database.sqlite`)
  }
  await mkdir(`${home}/bin`, { recursive: true })
  await mkdir(`${home}/logs`, { recursive: true })
  const wrappers = scripts(home, config)
  await Bun.write(`${home}/bin/serve`, wrappers.server, { mode: 0o700 })
  await Bun.write(`${home}/bin/opencode2`, wrappers.tui)
  await chmod(`${home}/bin/serve`, 0o700)
  await chmod(`${home}/bin/opencode2`, 0o700)
  await Bun.write(`${home}/${label}.plist`, plist(home))
  if (previous && previous !== commit) await point(home, "previous", previous)
  await point(home, "current", commit)
  try {
    await service.start()
    for (let attempt = 0; attempt < 90; attempt++) {
      const result = await health(home, config.port)
      if (result.ready && result.version === release.version) {
        console.log(`Active ${commit}; launcher ${home}/bin/opencode2`)
        return
      }
      await Bun.sleep(1000)
    }
    throw new Error("Healthcheck timed out")
  } catch (error) {
    await service.stop()
    throw new Error(
      `Release failed to start and was stopped. current remains ${commit}; previous=${previous ?? "none"}. Database may have migrated. ${save ? `Backup: ${save}/database.sqlite.` : "No database backup was created."} Review logs and migrations before custom:rollback --database-compatible.`,
      { cause: error },
    )
  }
}

async function main() {
  const args = process.argv.slice(2)
  const action = args[0]
  const home = path.resolve(
    process.env.OPENCODE_CUSTOM_HOME ?? path.join(os.homedir(), ".local/share/opencode-custom-v2"),
  )
  const dryRun = args.includes("--dry-run")
  const compatible = args.includes("--database-compatible")
  if (
    args
      .slice(1)
      .some(
        (arg) =>
          !["--dry-run", "--database-compatible", "--replace-launcher", "--stop-beta"].includes(arg) &&
          !/^--keep=\d+$/.test(arg) &&
          !sha.test(arg),
      )
  )
    throw new Error("Unknown argument")
  if (action === "status") {
    const config = await settings(home)
    const result = await health(home, config.port)
    console.log(
      JSON.stringify(
        {
          home,
          prepared: await pointer(home, "prepared"),
          current: await pointer(home, "current"),
          previous: await pointer(home, "previous"),
          running: result.version,
          health: result.ready ? "ready" : `unavailable (${result.status})`,
          url: `http://127.0.0.1:${config.port}`,
        },
        null,
        2,
      ),
    )
    return
  }
  if (!["prepare", "activate", "update", "rollback", "migrate", "prune"].includes(action))
    throw new Error(
      "Usage: custom:{prepare,activate,update,rollback,status,migrate,prune} [full-sha] [--dry-run]\nRollback: --database-compatible\nMigrate: --replace-launcher [--stop-beta]\nPrune: --keep=<count> (default 3)",
    )
  if (process.platform !== "darwin") throw new Error("Manual custom deployment currently supports macOS only")
  if (!dryRun) {
    await mkdir(home, { recursive: true })
    await mkdir(`${home}/.manual-lock`).catch(() => {
      throw new Error(
        `Another operation is active, or a stale lock exists: ${home}/.manual-lock. Remove it only after verifying no custom:* command is running.`,
      )
    })
  }
  try {
    if (action === "migrate") {
      const { migrate } = await import("./custom-migrate")
      return await migrate(home, os.homedir(), {
        dryRun,
        replaceLauncher: args.includes("--replace-launcher"),
        stopBeta: args.includes("--stop-beta"),
      })
    }
    if (action === "prune")
      return await prune(home, Number(args.find((arg) => arg.startsWith("--keep="))?.slice(7) ?? 3), dryRun)
    const commit =
      action === "prepare" || action === "update"
        ? await prepare(home, dryRun)
        : (args.find((arg) => sha.test(arg)) ?? (await pointer(home, action === "rollback" ? "previous" : "prepared")))
    if (action === "prepare") return
    if (!commit) throw new Error("No prepared/previous release; provide its full SHA")
    if (dryRun && action === "update") {
      console.log(`Then activate ${commit} without database backup and with authenticated healthcheck`)
      return
    }
    await activate(home, commit, {
      dryRun,
      rollback: action === "rollback",
      compatible,
      skipBackup: action === "update",
    })
  } finally {
    if (!dryRun)
      await rm(`${home}/.manual-lock`, { recursive: true }).catch((error) =>
        console.error("Could not remove manual lock:", error),
      )
  }
}

if (import.meta.main) await main()

export async function prune(home: string, keep = 3, dryRun = true) {
  if (!Number.isSafeInteger(keep) || keep < 0) throw new Error("--keep must be a nonnegative integer")
  const protectedCommits = new Set(
    await Promise.all(["current", "previous", "prepared"].map((name) => pointer(home, name))),
  )
  const port = (await settings(home)).port
  const running = (await health(home, port)).version?.replace("0.0.0-custom.", "")
  if (!portFree(port) && (!running || !sha.test(running)))
    throw new Error("Cannot identify the running release; refusing to prune")
  if (running) protectedCommits.add(running)
  const candidates = (
    await Promise.all(
      (await readdir(`${home}/releases`))
        .filter((name) => sha.test(name))
        .map(async (commit) => ({ commit, file: Bun.file(`${home}/releases/${commit}/manual-release.json`) })),
    )
  )
    .filter((entry) => entry.file.size > 0)
    .sort((a, b) => b.file.lastModified - a.file.lastModified)
  candidates.slice(0, keep).forEach((entry) => protectedCommits.add(entry.commit))
  for (const entry of candidates.filter((entry) => !protectedCommits.has(entry.commit))) {
    const release = await manifest(home, entry.commit)
    console.log(`${dryRun ? "Would prune" : "Pruning"} ${entry.commit}`)
    if (dryRun) continue
    await command(["chmod", "-R", "u+w", release.directory])
    await rm(release.directory, { recursive: true })
  }
}
