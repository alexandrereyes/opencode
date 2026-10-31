#!/usr/bin/env bun

import { chmod, copyFile, mkdir, mkdtemp, readdir, readlink, realpath, rename, rm, symlink } from "node:fs/promises"
import { Database } from "bun:sqlite"
import { randomUUID } from "node:crypto"
import os from "node:os"
import path from "node:path"
import { serverConfig } from "./custom-config"
import { installMacController } from "./custom-mac-controller"
import { bundleRelease } from "./custom-signing"
import { verifyParser } from "./custom-parser-smoke"

const repository = path.resolve(import.meta.dirname, "../../..")
export const label = "local.opencode.custom-manual"
// The managed-service config of the custom channel, read by `serve --service` from OPENCODE_CONFIG_DIR.
export const serviceConfigName = "service-custom.json"
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
      `Prepare ${commit}: git archive, frozen install, package typechecks, plugin and CLI build (embedded upstream web app); publish ${home}/releases/${commit}`,
    )
    return commit
  }
  if (await Bun.file(path.join(home, "releases", commit, "manual-release.json")).exists()) {
    await publish(home, commit)
    return commit
  }
  // The build scripts enforce the root packageManager's Bun, and the release embeds the Bun that runs this script.
  const bun = (await Bun.file(path.join(repository, "package.json")).json()).packageManager.split("@")[1]
  if (!Bun.semver.satisfies(Bun.version, `^${bun}`))
    throw new Error(`Preparing this commit requires Bun ${bun} (root packageManager); this is Bun ${Bun.version}`)
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
  for (const pkg of ["cli", "app", "plugin-app-custom"])
    await command([`${work}/bin/bun`, "typecheck"], path.join(source, "packages", pkg), env, false)
  await command([`${work}/bin/bun`, "run", "build"], path.join(source, "packages/plugin-app-custom"), env, false)
  await command(
    [`${work}/bin/bun`, "run", "script/build.ts", "--single", "--skip-install"],
    path.join(source, "packages/cli"),
    env,
    false,
  )
  const staging = path.join(work, "release")
  await mkdir(`${staging}/plugin`, { recursive: true })
  const cli = path.join(source, `packages/cli/dist/cli-${process.platform}-${process.arch}/bin/opencode`)
  if (process.platform === "darwin") await bundleRelease(home, staging, cli)
  else await plainRelease(staging, cli)
  const reported = await command([`${staging}/bin/opencode`, "--version"], work, env)
  if (reported !== `opencode v${env.OPENCODE_VERSION}`) throw new Error(`Unexpected CLI version: ${reported}`)
  await command([`${staging}/bin/opencode`, "--help"], work, env)
  await verifyParser(`${staging}/bin/opencode`, env.OPENCODE_VERSION)
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
  await bundleServeSim(source, staging)
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

/** Linux has no TCC grants to keep across releases: the release holds the plain executable, unsigned. */
export async function plainRelease(staging: string, binary: string) {
  await mkdir(path.join(staging, "bin"), { recursive: true })
  await copyFile(binary, path.join(staging, "bin/opencode"))
  await chmod(path.join(staging, "bin/opencode"), 0o755)
}

/**
 * Copies Expo's serve-sim (Apache-2.0, prebuilt for Apple silicon) beside the plugin: the resources hub runs it with
 * the release binary (`BUN_BE_BUN`) to stream and drive iOS simulators. Its only runtime dependency is `ws`. A
 * linux-arm64 release carries the same files only to publish them with the Mac's hub (`publishResourcesHub`).
 */
export async function bundleServeSim(source: string, staging: string, platform: string = process.platform) {
  if (process.arch !== "arm64" || (platform !== "darwin" && platform !== "linux")) return
  const pkg = await realpath(path.join(source, "packages/plugin-app-custom/node_modules/@expo/serve-sim"))
  const ws = path.dirname(Bun.resolveSync("ws/package.json", pkg))
  const modules = path.join(staging, "serve-sim/node_modules")
  await mkdir(path.join(modules, "@expo"), { recursive: true })
  await command(["cp", "-R", pkg, path.join(modules, "@expo/serve-sim")])
  await command(["cp", "-R", ws, path.join(modules, "ws")])
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
          pid:
            typeof body === "object" &&
            body !== null &&
            "pid" in body &&
            typeof body.pid === "number" &&
            Number.isSafeInteger(body.pid) &&
            body.pid > 0
              ? body.pid
              : undefined,
        }
      })
      .catch(() => ({ ready: false, status: 0, version: undefined, pid: undefined }))
  )
}

/**
 * `serve --service` ignores OPENCODE_PASSWORD and answers with the password of its managed-service config, generating
 * one when it is missing. Seed that config from the runtime password, which the launchers, the 4096 proxy and the
 * healthcheck use, and refuse to activate a server that would answer with another credential.
 */
export async function serviceCredential(home: string, config: Awaited<ReturnType<typeof settings>>) {
  const password = (await Bun.file(`${home}/password`).text()).trim()
  const file = path.join(config.config, serviceConfigName)
  const existing: unknown = (await Bun.file(file).exists()) ? await Bun.file(file).json() : {}
  if (typeof existing !== "object" || existing === null || Array.isArray(existing))
    throw new Error(`Invalid managed-service config: ${file}`)
  if ("password" in existing && existing.password !== undefined) {
    if (existing.password === password) return
    throw new Error(
      `${file} holds a different password than ${home}/password. The server would reject every client; make them equal before activating. Nothing was stopped.`,
    )
  }
  await mkdir(config.config, { recursive: true })
  await Bun.write(file, JSON.stringify({ ...existing, password }, null, 2) + "\n", { mode: 0o600 })
  await chmod(file, 0o600)
}

/**
 * Only `serve --service` resumes, at boot, the Sessions and background jobs a restart interrupted. Plain `serve` never
 * did, so its interrupted executions and background jobs (one entry per restart since the migration) were never
 * reconciled. Discard them before the first managed-service start; otherwise that boot would resume weeks-old Sessions
 * and subagents and wake their parents. Runs while the old server is still up, so a failure stops nothing.
 */
export function discardPlainServeRecovery(database: string) {
  const db = new Database(database)
  try {
    db.run("PRAGMA busy_timeout = 10000")
    db.transaction(() => {
      db.run("DELETE FROM kv WHERE key LIKE 'job.background/%'")
      db.run("UPDATE session_v2 SET time_suspended = NULL WHERE time_suspended IS NOT NULL")
    })()
  } finally {
    db.close()
  }
}

export function scripts(home: string, config: Awaited<ReturnType<typeof settings>>) {
  const environment = Object.entries({
    OPENCODE_RESOURCES_HUB_PORT: String(resourcesHubPort),
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
    server: `#!/bin/sh
set -eu
${environment}
release=$(cd ${quote(`${home}/current`)} && pwd -P)
export OPENCODE_CONFIG_CONTENT="$(cat "$release/server-config.json")"
cd ${quote(home)}
exec "$release/bin/opencode" serve --service --hostname 127.0.0.1 --port ${config.port}
`,
    tui: launcher(home, config.port, environment),
  }
}

function launcher(home: string, port: number, environment: string) {
  // Keep routing local to the custom distribution. Commands without ServerParams
  // may start another service; only audited filesystem-only handlers pass through.
  return `#!/bin/sh
set -eu

fail() {
  printf '%s\\n' "$1" >&2
  exit 2
}

help=
options=1
for arg do
  case "$arg" in
    --standalone*|--server*|--password*)
      fail 'This launcher always connects to the custom server; server overrides are not supported.' ;;
    --wizard*|--no-wizard*)
      # The native wizard can generate and run a new command without this launcher.
      fail 'Use explicit commands with the custom launcher instead of --wizard.' ;;
  esac
  if [ -n "$options" ]; then
    case "$arg" in
      --) options= ;;
      --help|-h) help=1 ;;
    esac
  fi
done

mode=remote
insert=0
route=
display=
classify() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|--help=*|-h|--no-help) help=1 ;;
      --version|--version=*|-v|--no-version|--completions|--completions=*) display=1 ;;
    esac
    case "$1" in
      --print-logs|--help|-h|--version|-v|--no-print-logs|--no-help|--no-version)
        shift
        insert=$((insert + 1))
        case "\${1-}" in
          true|false|yes|no|on|off|1|0) shift; insert=$((insert + 1)) ;;
        esac
        continue ;;
      --print-logs=*|--help=*|--version=*|--log-level=*|--completions=*)
        shift; insert=$((insert + 1)); continue ;;
      --log-level|--completions)
        [ "$#" -ge 2 ] || fail "Missing value for $1"
        shift 2; insert=$((insert + 2)); continue ;;
    esac

    case "$route" in
      '')
        case "$1" in
          serve|upgrade|update|uninstall)
            fail 'Use custom:* for lifecycle and release updates.' ;;
          acp)
            fail 'acp starts a private server and is unavailable through this launcher. Use opencode api for the custom server API.' ;;
          pair)
            if [ -n "$help" ]; then mode=local; return; fi
            fail 'pair uses native service discovery. Use opencode api server.pair, then open /auth/connect/<code> on the custom server.' ;;
          run|mini|api|models|stats|reload)
            insert=$((insert + 1)); return ;;
          auth|session|service|mcp|plugin|debug)
            route=$1; shift; insert=$((insert + 1)); continue ;;
          --prompt|--session|-s)
            [ "$#" -ge 2 ] || fail "Missing value for $1"
            shift 2; insert=$((insert + 2)); continue ;;
          --prompt=*|--session=*|-s?*)
            shift; insert=$((insert + 1)); continue ;;
          --continue|-c|--auto|--yolo|--dangerously-skip-permissions|--no-continue|--no-auto|--no-yolo|--no-dangerously-skip-permissions)
            shift
            insert=$((insert + 1))
            case "\${1-}" in
              true|false|yes|no|on|off|1|0) shift; insert=$((insert + 1)) ;;
            esac
            continue ;;
          --continue=*|--auto=*|--yolo=*|--dangerously-skip-permissions=*)
            shift; insert=$((insert + 1)); continue ;;
          --) return ;;
          -*) fail "Unsupported option before the command: $1. Use opencode --help." ;;
          *) return ;;
        esac ;;
      service)
        case "$1" in
          start|stop|restart|set|unset) fail 'Use custom:* for service lifecycle and configuration.' ;;
          status|get) route="$route $1"; mode=service; shift; continue ;;
          *) fail 'Use service status or service get password|port|hostname with this launcher.' ;;
        esac ;;
      'service get')
        case "$1" in
          password|port|hostname) route="$route $1"; shift; continue ;;
          *) fail 'Use service get password|port|hostname with this launcher.' ;;
        esac ;;
      'service '*) fail "Unexpected argument for $route: $1" ;;
    esac

    # Help is an exception only for audited API commands, never for lifecycle.
    if [ -n "$help" ]; then
      case "$route:$1" in
        mcp:list|mcp:auth|mcp:logout|plugin:list|plugin:check|plugin:update|debug:agents|debug:config)
          mode=local; return ;;
      esac
    fi
    case "$route:$1" in
      auth:list|auth:login|auth:logout|auth:switch|session:list|session:delete|session:export|session:import)
        insert=$((insert + 1)); return ;;
      mcp:add|plugin:add|plugin:remove|debug:paths)
        mode=local; return ;;
      mcp:auth|mcp:logout)
        fail 'MCP authentication uses native service discovery. Use /mcps in the custom TUI, or opencode auth login|logout.' ;;
      mcp:list)
        fail 'Use opencode api mcp.list --param "location[directory]=$PWD" to query the custom server.' ;;
      plugin:list)
        fail 'Use opencode api plugin.list --param "location[directory]=$PWD" to list custom server plugins.' ;;
      plugin:check)
        fail 'Use opencode api plugin.check --param "location[directory]=$PWD" --data "{}" for server plugin updates.' ;;
      plugin:update)
        fail ${quote(`Use opencode api plugin.update --param "location[directory]=$PWD" --data '{"targets":["<package>"]}' for server plugins.`)} ;;
      debug:agents)
        fail 'Use opencode api agent.list --param "location[directory]=$PWD" to query the custom server.' ;;
      debug:config)
        fail 'Use opencode api config.get --param "location[directory]=$PWD" to query the custom server configuration.' ;;
      *) fail "Unsupported custom launcher command: $route $1. Use opencode $route --help." ;;
    esac
  done
  # Bare command groups only display native help, never a server handler.
  [ -z "$route" ] || mode=local
  case "$route" in service*) mode=service ;; esac
  # Version/completion actions short-circuit the native handler. Never return a
  # service credential in place of an informational action.
  if [ -n "$display" ] && [ -z "$help" ]; then mode=local; fi
}
classify "$@"

server=${quote(`http://127.0.0.1:${port}`)}
password_file=${quote(`${home}/password`)}
if [ "$mode" = service ]; then
  if [ -n "$help" ]; then
    printf '%s\\n' 'Usage: opencode service status | get password|port|hostname'
    exit 0
  fi
  case "$route" in
    'service get')
      printf '%s\\n' ${quote(JSON.stringify({ hostname: "127.0.0.1", port }, null, 2))}
      exit 0 ;;
    'service status')
      if password=$(cat "$password_file" 2>/dev/null) && [ -n "$password" ]; then
        authorization=$(printf 'opencode:%s' "$password" | base64 | tr -d '\\n')
        for endpoint in /api/info /api/health; do
          # Read credentials from stdin, not the process arguments or curlrc.
          status=$(printf 'Authorization: Basic %s\\n' "$authorization" |
            curl -q --silent --noproxy '*' --max-time 2 --header @- --output /dev/null --write-out '%{http_code}' "$server$endpoint") || status=000
          case "$status" in
            200) printf '%s\\n' "$server"; exit 0 ;;
            404) continue ;;
            *) break ;;
          esac
        done
      fi
      printf '%s\\n' stopped
      exit 0 ;;
    'service get password')
      password=$(cat "$password_file")
      [ -n "$password" ] || fail 'Runtime password is empty.'
      printf '%s\\n' "$password"; exit 0 ;;
    'service get port') printf '%s\\n' ${quote(String(port))}; exit 0 ;;
    'service get hostname') printf '%s\\n' 127.0.0.1; exit 0 ;;
    *) fail 'Use service status or service get password|port|hostname with this launcher.' ;;
  esac
fi

release=$(cd ${quote(`${home}/current`)} && pwd -P)
export OPENCODE_DISABLE_AUTOUPDATE=1
if [ "$mode" = local ]; then
${environment}
  exec "$release/bin/opencode" "$@"
fi

export OPENCODE_PASSWORD="$(cat "$password_file")"
# Rotate the original arguments once, inserting after the command path and
# before its operands (including --). No eval or word splitting is involved.
remaining=$#
while [ "$remaining" -gt 0 ]; do
  if [ "$insert" -eq 0 ]; then set -- "$@" --server "$server"; fi
  arg=$1
  shift
  set -- "$@" "$arg"
  insert=$((insert - 1))
  remaining=$((remaining - 1))
done
if [ "$insert" -eq 0 ]; then set -- "$@" --server "$server"; fi
exec "$release/bin/opencode" "$@"
`
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
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>${xml(`${home}/logs/server.log`)}</string>
<key>StandardErrorPath</key><string>${xml(`${home}/logs/server.log`)}</string>
</dict></plist>\n`
}

export type Service = {
  stop: () => Promise<void>
  start: () => Promise<void>
  pid: () => Promise<number | undefined>
  /** Installs the repository's 4096 proxy after a successful activation; absent for fixture services. */
  proxy?: () => Promise<string>
  /** Publishes the release's resources hub to the Mac after a successful Linux activation (`publishResourcesHub`). */
  hub?: (release: { commit: string; directory: string }) => Promise<string>
  /** Installs the Mac's signed `bin/mac-controller` after a successful Linux activation (`installMacController`). */
  controller?: () => Promise<string>
  /** Writes the service definition before start; without it, activation writes the launchd plist into the runtime. */
  install?: () => Promise<void>
}

export const unitName = `${label}.service`

/**
 * systemd user unit of the Linux runtime. The server starts with the login environment (/etc/profile and
 * /etc/profile.d: PATH, SDKs), like a terminal; a unit has no shell of its own. Requires lingering
 * (`loginctl enable-linger`) to run without a login session.
 */
export function unit(home: string) {
  // systemd expands % specifiers everywhere and $ in command lines; arguments are double-quoted.
  const value = (text: string) => text.replaceAll("%", "%%")
  const argument = (text: string) =>
    `"${value(text).replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("$", "$$$$")}"`
  return `# Runtime ${home}
[Unit]
Description=OpenCode custom

[Service]
ExecStart=/bin/sh -c ". /etc/profile >/dev/null 2>&1; exec \\"$$0\\"" ${argument(`${home}/bin/serve`)}
Restart=always
RestartSec=2
# Like launchd on the Mac: stop signals only the server. Agents' commands live in this cgroup too (custom:update
# itself, tmux, nohup, mac clients whose death ends their Mac process) and must outlive a restart.
KillMode=process
TimeoutStopSec=60
StandardOutput=append:${value(`${home}/logs/server.log`)}
StandardError=append:${value(`${home}/logs/server.log`)}

[Install]
WantedBy=default.target
`
}

export async function systemctl(args: string[]) {
  const child = Bun.spawn(["systemctl", "--user", ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C" },
    timeout: 90_000,
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  return { stdout, stderr, code }
}

export function systemd(
  home: string,
  host = {
    run: systemctl,
    directory: path.join(os.homedir(), ".config/systemd/user"),
    async alive(pid: number) {
      return Bun.file(`/proc/${pid}/stat`).exists()
    },
    now: Date.now,
    sleep: (ms: number) => Bun.sleep(ms),
  },
  hub: Service["hub"] = (release) => publishResourcesHub(release),
  proxy: Service["proxy"] = () => installMacProxy(),
  controller: Service["controller"] = () => installMacController(),
): Service {
  const file = path.join(host.directory, unitName)
  const owned = async () => {
    const content = await Bun.file(file)
      .text()
      .catch(() => undefined)
    if (content === undefined) return false
    if (content.split("\n")[0] !== `# Runtime ${home}`)
      throw new Error(`${unitName} belongs to another runtime; refusing lifecycle operation`)
    return true
  }
  const query = async () => {
    if (!(await owned())) return
    const result = await host.run(["show", unitName, "--property=ActiveState,MainPID"])
    if (result.code !== 0) throw new Error(`systemctl show failed (${result.code}): ${result.stderr.trim()}`)
    const state = result.stdout.match(/^ActiveState=(.*)$/m)?.[1]
    if (state === "inactive" || state === "failed") return
    return { pid: Number(result.stdout.match(/^MainPID=(\d+)$/m)?.[1]) || undefined }
  }
  const install = async () => {
    await mkdir(host.directory, { recursive: true })
    await Bun.write(file, unit(home))
    const reload = await host.run(["daemon-reload"])
    if (reload.code !== 0) throw new Error(`systemctl daemon-reload failed (${reload.code}): ${reload.stderr.trim()}`)
  }
  return {
    hub,
    proxy,
    controller,
    install,
    async pid() {
      return (await query())?.pid
    },
    async stop() {
      const running = await query()
      if (!running) return
      // An older unit (KillMode=mixed) would kill this very custom:update when an agent runs it; the reloaded
      // definition applies to the running unit's stop.
      if ((await Bun.file(file).text()) !== unit(home)) await install()
      const result = await host.run(["stop", unitName])
      if (result.code !== 0) throw new Error(`systemctl stop failed (${result.code}): ${result.stderr.trim()}`)
      const deadline = host.now() + 65_000
      while (running.pid && (await host.alive(running.pid))) {
        if (host.now() >= deadline) throw new Error(`systemd stop timed out: previous process ${running.pid} alive`)
        await host.sleep(250)
      }
    },
    async start() {
      if (!(await owned())) throw new Error(`${file} is missing; activate installs it`)
      for (const args of [
        ["enable", unitName],
        ["start", unitName],
      ]) {
        const result = await host.run(args)
        if (result.code !== 0) throw new Error(`systemctl ${args[0]} failed (${result.code}): ${result.stderr.trim()}`)
      }
    },
  }
}

/** Lifecycle backend of this host: launchd on macOS, a systemd user unit on Linux. */
export function hostService(home: string): Service {
  return process.platform === "linux" ? systemd(home) : launchd(home)
}

export const proxyLabel = "com.alexandrem.opencode2-ui"
/** Loopback port of the session resources hub; the 4096 proxy (`custom-proxy.mjs`) forwards `/resources/*` to it. */
export const resourcesHubPort = 4179

/**
 * Replaces `<runtime>/bin/proxy.mjs` with `custom-proxy.mjs` and restarts the proxy job, only when the installed
 * job runs this runtime's proxy and the content changed. Other runtimes (sandboxes, tests) are skipped.
 */
export async function installProxy(home: string, agents = path.join(os.homedir(), "Library/LaunchAgents")) {
  const target = `${home}/bin/proxy.mjs`
  const definition = Bun.spawn(["/usr/bin/plutil", "-convert", "json", "-o", "-", `${agents}/${proxyLabel}.plist`], {
    stdout: "pipe",
    stderr: "ignore",
  })
  const parsed: unknown = await new Response(definition.stdout).json().catch(() => undefined)
  return replaceProxy(target, parsed, () => launchctl(["kickstart", "-k", `gui/${process.getuid!()}/${proxyLabel}`]))
}

/**
 * `installProxy` for a Linux server: bytes travel through stdin and every Mac file operation runs on the Mac.
 */
export async function installMacProxy(host = { home: `/Users/${os.userInfo().username}`, mac: onMac }) {
  const source = await Bun.file(path.join(import.meta.dirname, "custom-proxy.mjs")).bytes()
  const result = await macPublish(host, "proxy", [], source)
  if (result !== "proxy installed") return result
  const uid = (await host.mac(["id", "-u"])).stdout.trim()
  if (!/^\d+$/.test(uid)) throw new Error("Cannot read the Mac user ID")
  const restart = await host.mac(["launchctl", "kickstart", "-k", `gui/${uid}/${proxyLabel}`])
  if (restart.code !== 0)
    throw new Error(`Proxy installed but restart failed (${restart.code}): ${restart.stderr.trim()}`)
  return "proxy updated and restarted"
}

async function macPublish(
  host: { home: string; mac: typeof onMac },
  operation: "proxy" | "hub",
  args: string[],
  input: Uint8Array,
) {
  const script = await Bun.file(path.join(import.meta.dirname, "custom-mac-host.py")).text()
  const result = await host.mac(["python3", "-c", script, operation, host.home, ...args], input)
  if (result.code !== 0) throw new Error(`Mac publication failed (${result.code}): ${result.stderr.trim()}`)
  return result.stdout.trim()
}

async function replaceProxy(
  target: string,
  definition: unknown,
  restart: () => Promise<{ code: number; stderr: string }>,
) {
  const program =
    typeof definition === "object" && definition !== null && "ProgramArguments" in definition
      ? definition.ProgramArguments
      : []
  if (!Array.isArray(program) || !program.includes(target)) return "proxy skipped (job not installed for this runtime)"
  const source = await Bun.file(path.join(import.meta.dirname, "custom-proxy.mjs")).text()
  const installed = await Bun.file(target)
    .text()
    .catch(() => "")
  if (installed === source) return "proxy unchanged"
  await Bun.write(`${target}.tmp`, source)
  await chmod(`${target}.tmp`, 0o644)
  await rename(`${target}.tmp`, target)
  const result = await restart()
  if (result.code !== 0) throw new Error(`Proxy installed but restart failed (${result.code}): ${result.stderr.trim()}`)
  return "proxy updated and restarted"
}

export const resourcesHubLabel = "local.opencode.resources-hub"

/**
 * The Mac's standalone resources hub (LaunchAgent `local.opencode.resources-hub`), which serves a server running on
 * the Linux machine. Paths are under the Mac home `/Users/<user>`, which the Linux machine mounts at the same path.
 */
export function resourcesHubPaths(macHome: string) {
  const root = path.join(macHome, ".local/share/opencode-resources-hub")
  return {
    root,
    current: path.join(root, "current"),
    state: path.join(root, "state"),
    info: path.join(root, "state/hub.json"),
    playwright: path.join(root, "state/playwright-cli.json"),
    log: path.join(root, "hub.log"),
    plist: path.join(macHome, "Library/LaunchAgents", `${resourcesHubLabel}.plist`),
  }
}

/**
 * The hub's LaunchAgent: the Mac's Bun runs `current/plugin/index.js --opencode-resources-hub` with no parent (it
 * never exits on its own), the fixed loopback port the 4096 proxy forwards to and `current/serve-sim`.
 */
export function resourcesHubPlist(
  macHome: string,
  bun = path.join(macHome, ".local/share/opencode-custom-v2/bin/bun"),
) {
  const xml = (value: string) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
  const paths = resourcesHubPaths(macHome)
  const environment = {
    OPENCODE_RESOURCES_HUB_STATE: paths.state,
    OPENCODE_RESOURCES_HUB_PORT: String(resourcesHubPort),
    OPENCODE_SERVE_SIM: path.join(paths.current, "serve-sim/node_modules/@expo/serve-sim/dist/serve-sim.js"),
    PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${resourcesHubLabel}</string>
<key>ProgramArguments</key><array>${[bun, path.join(paths.current, "plugin/index.js"), "--opencode-resources-hub"].map((value) => `<string>${xml(value)}</string>`).join("")}</array>
<key>EnvironmentVariables</key><dict>
${Object.entries(environment)
  .map(([key, value]) => `<key>${key}</key><string>${xml(value)}</string>`)
  .join("\n")}
</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>${xml(paths.log)}</string>
<key>StandardErrorPath</key><string>${xml(paths.log)}</string>
</dict></plist>\n`
}

/** Runs a command on the Mac from the OrbStack Linux machine (`mac`, with the Mac's login environment). */
export async function onMac(args: string[], input?: Uint8Array) {
  // Host paths must not be probed or rewritten as Linux files by the bridge.
  const literal = args.map((value) =>
    value.startsWith("/") && !value.startsWith("/mnt/") ? `/mnt/mac${value}` : value,
  )
  const child = Bun.spawn([Bun.which("mac") ?? "/opt/orbstack-guest/bin/mac", ...literal], {
    cwd: os.homedir(),
    stdout: "pipe",
    stderr: "pipe",
    stdin: input ?? "ignore",
    timeout: 30_000,
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  return { stdout, stderr, code }
}

/**
 * Publishes a Linux release's hub to the Mac, only when the hub's LaunchAgent is installed there: copies `plugin/` and
 * `serve-sim/` through stdin to the native Mac publisher, points `current` at it atomically, restarts
 * the job with `launchctl kickstart -k` and keeps the three newest hub releases besides `current`.
 */
export async function publishResourcesHub(
  release: { commit: string; directory: string },
  host = { home: `/Users/${os.userInfo().username}`, mac: onMac },
) {
  const parts = []
  for (const part of ["plugin", "serve-sim"])
    if ((await readdir(path.join(release.directory, part)).catch(() => undefined)) !== undefined) parts.push(part)
  const archive = Bun.spawn(["tar", "-C", release.directory, "-cf", "-", ...parts], {
    env: { ...process.env, COPYFILE_DISABLE: "1" },
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  const [data, error, code] = await Promise.all([
    new Response(archive.stdout).arrayBuffer(),
    new Response(archive.stderr).text(),
    archive.exited,
  ])
  if (code !== 0) throw new Error(`Cannot archive the hub: ${error.trim()}`)
  const publication = await macPublish(host, "hub", [release.commit], new Uint8Array(data))
  if (publication !== "resources hub installed") return publication
  const uid = (await host.mac(["id", "-u"])).stdout.trim()
  if (!/^\d+$/.test(uid)) throw new Error(`Cannot read the Mac user ID through mac: ${JSON.stringify(uid)}`)
  const result = await host.mac(["launchctl", "kickstart", "-k", `gui/${uid}/${resourcesHubLabel}`])
  if (result.code !== 0)
    throw new Error(
      `Hub ${release.commit} copied and current, but restart failed (${result.code}): ${result.stderr.trim()}`,
    )
  return `resources hub ${release.commit} published and restarted`
}

export function portFree(port: number) {
  try {
    const listener = Bun.listen({ hostname: "127.0.0.1", port, socket: { data() {} } })
    listener.stop(true)
    return true
  } catch {
    return false
  }
}

export async function launchctl(args: string[]) {
  const child = Bun.spawn(["/bin/launchctl", ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C" },
    timeout: 10_000,
  })
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ])
  return { stdout, stderr, code }
}

export function launchd(
  home: string,
  host = {
    run: launchctl,
    async alive(pid: number) {
      const child = Bun.spawn(["/bin/ps", "-p", String(pid), "-o", "pid="], {
        stdout: "pipe",
        stderr: "pipe",
        timeout: 10_000,
      })
      const [output, error, code] = await Promise.all([
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
        child.exited,
      ])
      if (code === 0) return output.trim() === String(pid)
      if (code === 1 && !output.trim() && !error.trim()) return false
      throw new Error(`Cannot inspect previous process ${pid}: ${error}`)
    },
    now: Date.now,
    sleep: (ms: number) => Bun.sleep(ms),
  },
): Service {
  const domain = `gui/${process.getuid!()}`
  const target = `${domain}/${label}`
  const query = async () => {
    const result = await host.run(["print", target])
    if (result.code !== 0) {
      // Missing domains and permission errors do not prove that the job is gone.
      if (result.code === 113 && result.stderr.includes(`Could not find service "${label}" in domain`)) return
      throw new Error(`launchctl print failed (${result.code}): ${result.stderr.trim()}`)
    }
    if (result.stdout.match(/^\s*program = (.+)$/m)?.[1] !== `${home}/bin/serve`)
      throw new Error(`${label} belongs to another runtime; refusing lifecycle operation`)
    return { pid: Number(result.stdout.match(/^\s*pid = (\d+)$/m)?.[1]) || undefined }
  }
  return {
    proxy: () => installProxy(home),
    async pid() {
      return (await query())?.pid
    },
    async stop() {
      const loaded = await query()
      if (!loaded) return
      const pids = new Set(loaded.pid ? [loaded.pid] : [])
      const result = await host.run(["bootout", target])
      if (result.code !== 0) throw new Error(`launchctl bootout failed (${result.code}): ${result.stderr.trim()}`)
      const deadline = host.now() + 65_000
      while (true) {
        const registered = await query()
        if (registered?.pid) pids.add(registered.pid)
        const alive = (await Promise.all([...pids].map((pid) => host.alive(pid)))).some(Boolean)
        if (!registered && !alive) return
        if (host.now() >= deadline)
          throw new Error(`launchd stop timed out: registered=${!!registered}, previousProcessAlive=${alive}`)
        await host.sleep(250)
      }
    },
    async start() {
      for (let attempt = 1; attempt <= 3; attempt++) {
        if (await query()) return // Activation still requires exact authenticated health.
        const result = await host.run(["bootstrap", domain, `${home}/${label}.plist`])
        if (result.code === 0) return
        const error = new Error(
          `launchctl bootstrap failed (${result.code}), attempt ${attempt}: ${result.stderr.trim()}`,
        )
        console.error(`${new Date().toISOString()} ${error.message}`)
        if (
          await query().catch((failure: unknown) => {
            throw new Error(`${error.message}; reconciliation failed: ${String(failure)}`, { cause: error })
          })
        )
          return
        // Generic EIO (5) alone is permanent; require an explicit in-progress response.
        if (attempt === 3 || !/Operation (?:already |now )?in progress/i.test(result.stderr)) throw error
        await host.sleep(250 * attempt)
      }
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
  options: {
    dryRun?: boolean
    rollback?: boolean
    compatible?: boolean
    skipBackup?: boolean
    report?: (phase: string) => Promise<void>
  },
  service = hostService(home),
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
      `Verify the service password in ${path.join(config.config, serviceConfigName)}; when switching from plain serve, discard its unreconciled restart-recovery markers; stop ${label}; ${options.skipBackup ? "skip database backup" : `back up ${config.database}`}; current ${previous ?? "none"} -> ${commit}; install ${home}/bin/opencode2; start serve --service; authenticated healthcheck; then install bin/proxy.mjs and restart ${proxyLabel} only if it changed${service.hub ? `; publish the resources hub to the Mac and restart ${resourcesHubLabel} if its LaunchAgent is installed` : ""}. Failed boot stays stopped: no automatic database downgrade.`,
    )
    return
  }
  if (!(await Bun.file(`${home}/password`).text()).trim()) throw new Error("Runtime password is empty")
  if (!(await Bun.file(config.database).exists()))
    throw new Error(`Database does not exist: ${config.database}; initialize a new runtime separately`)
  if (!options.skipBackup && !Bun.which("sqlite3")) throw new Error("sqlite3 is required for a consistent backup")
  const before = await health(home, config.port)
  if (previous === commit && before.ready && before.version === release.version) {
    await verifyProcess(service, before.pid, config.port).catch((cause: unknown) => {
      throw new Error(
        `Already-active check failed; no service, launcher or release pointer was changed. ${String(cause)}`,
        { cause },
      )
    })
    console.log(`Already active ${commit}`)
    return
  }
  if (!portFree(config.port) && (!previous || before.version !== `0.0.0-custom.${previous}`))
    throw new Error("Port is occupied by another release/service. Complete the documented one-time migration first.")
  await serviceCredential(home, config)
  const launcher = Bun.file(`${home}/bin/serve`)
  if (!(await launcher.exists()) || !(await launcher.text()).includes(" serve --service "))
    discardPlainServeRecovery(config.database)
  const save = options.skipBackup
    ? undefined
    : path.join(home, "backups", `${new Date().toISOString().replaceAll(":", "-")}-${randomUUID()}`)
  if (save) {
    await mkdir(save, { recursive: true, mode: 0o700 })
    await Bun.write(`${save}/activation.json`, JSON.stringify({ previous, target: commit, database: config.database }))
  }
  await reportProgress(options.report, "stopping")
  await service.stop()
  await reportProgress(options.report, "waiting-port")
  // launchd removal and previous process exit are confirmed by stop; the port is a separate condition.
  for (let attempt = 0; attempt < 65; attempt++) {
    if (portFree(config.port)) break
    if (attempt === 64) throw new Error("Server did not stop; current is unchanged")
    await Bun.sleep(1000)
  }
  if (save) {
    await reportProgress(options.report, "backup")
    await backup(config.database, `${save}/database.sqlite`)
    console.log(`Consistent database backup: ${save}/database.sqlite`)
  }
  await reportProgress(options.report, "switching")
  await mkdir(`${home}/bin`, { recursive: true })
  await mkdir(`${home}/logs`, { recursive: true })
  const wrappers = scripts(home, config)
  await Bun.write(`${home}/bin/serve`, wrappers.server, { mode: 0o700 })
  await Bun.write(`${home}/bin/opencode2`, wrappers.tui)
  await chmod(`${home}/bin/serve`, 0o700)
  await chmod(`${home}/bin/opencode2`, 0o700)
  if (service.install) await service.install()
  else await Bun.write(`${home}/${label}.plist`, plist(home))
  if (previous && previous !== commit) await point(home, "previous", previous)
  await point(home, "current", commit)
  try {
    await reportProgress(options.report, "starting")
    await service.start()
    await reportProgress(options.report, "healthcheck")
    for (let attempt = 0; attempt < 90; attempt++) {
      const result = await health(home, config.port)
      if (result.ready && result.version === release.version) {
        await verifyProcess(service, result.pid, config.port)
        console.log(`Active ${commit}; launcher ${home}/bin/opencode2`)
        // The server is already healthy; a proxy failure is reported without undoing the activation.
        if (service.proxy)
          await service.proxy().then(console.log, (error: unknown) => console.error(`Proxy: ${String(error)}`))
        if (service.hub)
          await service
            .hub({ commit, directory: release.directory })
            .then(console.log, (error: unknown) => console.error(`Resources hub: ${String(error)}`))
        if (service.controller)
          await service
            .controller()
            .then(console.log, (error: unknown) => console.error(`Mac controller: ${String(error)}`))
        return
      }
      await Bun.sleep(1000)
    }
    throw new Error("Healthcheck timed out")
  } catch (error) {
    const cleanup = await service.stop().then(
      () => "stopped",
      (failure: unknown) => `cleanup failed: ${String(failure)}`,
    )
    throw new Error(
      `Release failed to start (${cleanup}). Original error: ${String(error)}. current remains ${commit}; previous=${previous ?? "none"}. Database may have migrated. ${save ? `Backup: ${save}/database.sqlite.` : "No database backup was created."} Review logs and migrations before custom:rollback --database-compatible.`,
      { cause: error },
    )
  }
}

async function verifyProcess(service: Service, responding: number | undefined, port: number) {
  const owned = await service.pid()
  if (responding !== undefined && responding === owned) return
  throw new Error(
    `Healthcheck PID ${responding ?? "missing"} does not match ${label} PID ${owned ?? "missing"}. ` +
      `Inspect with lsof -nP -iTCP:${port} -sTCP:LISTEN and ${process.platform === "linux" ? `systemctl --user status ${unitName}` : `launchctl print gui/${process.getuid!()}/${label}`} before retrying.`,
  )
}

async function reportProgress(report: ((phase: string) => Promise<void>) | undefined, phase: string) {
  // Observability failures must never interrupt activation or trigger service cleanup.
  try {
    await report?.(phase)
  } catch (error) {
    console.error(`${new Date().toISOString()} Could not report operation phase ${phase}:`, error)
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
  if (action === "hub-plist") {
    // Printed for the Mac's installer (core-infra/opencode-mac); runs on either machine: /Users/<user> is the same path.
    process.stdout.write(resourcesHubPlist(`/Users/${os.userInfo().username}`))
    return
  }
  if (!["prepare", "activate", "update", "rollback", "migrate", "prune"].includes(action))
    throw new Error(
      "Usage: custom:{prepare,activate,update,rollback,status,migrate,prune,hub-plist} [full-sha] [--dry-run]\nRollback: --database-compatible\nMigrate: --replace-launcher [--stop-beta]\nPrune: --keep=<count> (default 3)",
    )
  if (process.platform !== "darwin" && (process.platform !== "linux" || action === "migrate"))
    throw new Error("Manual custom deployment supports macOS, and Linux (systemd user unit) except migrate")
  if (!dryRun) {
    await mkdir(home, { recursive: true })
    await mkdir(`${home}/.manual-lock`).catch(() => {
      throw new Error(
        `Another operation is active, or a stale lock exists: ${home}/.manual-lock. Remove it only after verifying no custom:* command is running.`,
      )
    })
  }
  const journal = dryRun
    ? undefined
    : `${home}/logs/operations/${new Date().toISOString().replaceAll(":", "-")}-${randomUUID()}.json`
  const record = {
    action,
    target: "",
    started: new Date().toISOString(),
    phase: "preflight",
    outcome: "running",
    error: "",
    events: [] as { phase: string; at: string }[],
  }
  const report = async (phase: string) => {
    record.phase = phase
    record.events.push({ phase, at: new Date().toISOString() })
    console.log(`${new Date().toISOString()} custom:${action} ${phase}`)
    if (!journal) return
    await mkdir(path.dirname(journal), { recursive: true, mode: 0o700 })
    await Bun.write(`${journal}.tmp`, JSON.stringify(record, null, 2), { mode: 0o600 })
    await chmod(`${journal}.tmp`, 0o600)
    await rename(`${journal}.tmp`, journal)
  }
  try {
    await reportProgress(report, action === "prepare" || action === "update" ? "preparing" : "preflight")
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
    if (!commit) throw new Error("No prepared/previous release; provide its full SHA")
    record.target = commit
    if (action === "prepare") return
    if (dryRun && action === "update") {
      console.log(`Then activate ${commit} without database backup and with authenticated healthcheck`)
      return
    }
    await activate(home, commit, {
      dryRun,
      rollback: action === "rollback",
      compatible,
      skipBackup: action === "update",
      report,
    })
  } catch (error) {
    record.outcome = "failed"
    record.error = String(error)
    throw error
  } finally {
    if (record.outcome === "running") record.outcome = "succeeded"
    await reportProgress(report, record.phase)
    if (journal) console.log(`Operation result: ${journal}`)
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
