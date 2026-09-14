import { Flock } from "@opencode/util/flock"
import { Schema } from "effect"
import { chmod, copyFile, lstat, mkdir, mkdtemp, realpath, rename, rm } from "node:fs/promises"
import path from "node:path"
import { artifacts, Manifest, pointRelease, readManifest, readRelease, sha256 } from "./release.js"

const absolute = Schema.String.check(Schema.isPattern(/^\//))
export const Deployment = Schema.Struct({
  repository: Schema.NonEmptyString,
  branch: Schema.String.check(Schema.isPattern(/^[a-zA-Z0-9][a-zA-Z0-9._/-]*$/)),
  bun: absolute,
})

/** Finite launchd job. It never changes current, starts a server, or opens a database. */
export async function prepare(home: string) {
  const config = Schema.decodeUnknownSync(Schema.fromJsonString(Deployment))(
    await Bun.file(path.join(home, "deployment.json")).text(),
  )
  await using lock = await Flock.acquire("prepare", { dir: path.join(home, "locks"), timeoutMs: 1_000 })
  const repository = path.join(home, "repository")
  if (!(await Bun.file(path.join(repository, "HEAD")).exists()))
    await command(["git", "clone", "--bare", "--no-hardlinks", config.repository, repository], home)
  await command(["git", "fetch", "origin", config.branch], repository)
  const commit = (await command(["git", "rev-parse", "FETCH_HEAD^{commit}"], repository, undefined, true)).trim()
  const active = await readRelease(home, "current")
  if (active?.commit === commit) return active
  const existing = path.join(home, "releases", commit)
  if (
    await lstat(existing).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") return undefined
      throw error
    })
  ) {
    const manifest = await readManifest(existing, true)
    if (
      manifest.commit !== commit ||
      (await realpath(existing)) !== path.join(await realpath(home), "releases", commit)
    )
      throw new Error("Cached release does not match the fetched commit directory")
    await pointRelease(home, "prepared", commit)
    return manifest
  }
  await mkdir(path.join(home, "builds"), { recursive: true })
  const work = await mkdtemp(path.join(home, "builds", "prepare-"))
  return await build({ home, repository, commit, work, bun: config.bun }).finally(() =>
    rm(work, { recursive: true, force: true }),
  )
}

async function build(input: { home: string; repository: string; commit: string; work: string; bun: string }) {
  const source = path.join(input.work, "source")
  await mkdir(source)
  const archive = path.join(input.work, "source.tar")
  await command(["git", "archive", "--format=tar", `--output=${archive}`, input.commit], input.repository)
  await command(["tar", "-xf", archive, "-C", source], input.work)
  const version = `0.0.0-custom-${Date.now()}.0`
  const env = {
    ...process.env,
    OPENCODE_VERSION: version,
    OPENCODE_CHANNEL: "custom",
    VITE_OPENCODE_CUSTOM_UPDATES: "1",
    VITE_OPENCODE_DEV_BUILD: version,
    VITE_OPENCODE_DISABLE_SERVICE_WORKER: "1",
    PATH: `${path.dirname(input.bun)}:${process.env.PATH ?? "/usr/bin:/bin"}`,
  }
  await command([input.bun, "install", "--frozen-lockfile"], source, env)
  // The native build owns the backend binary AND its embedded app archive.
  await command([input.bun, "run", "packages/cli/script/build.ts", "--single"], source, env)
  return stageRelease({
    home: input.home,
    source,
    commit: input.commit,
    version,
    bun: input.bun,
    directory: path.join(input.work, "release"),
    binary: path.join(source, `packages/cli/dist/cli-darwin-${process.arch}/bin/opencode`),
  })
}

/** Package and verify an already-built native CLI with its matching sidecar. */
export async function stageRelease(input: {
  home: string
  source: string
  commit: string
  version: string
  bun: string
  directory: string
  binary: string
}) {
  const directory = input.directory
  const source = input.source
  const env = {
    ...process.env,
    XDG_DATA_HOME: path.join(input.home, "data"),
    XDG_STATE_HOME: path.join(input.home, "state"),
    XDG_CONFIG_HOME: path.join(input.home, "config"),
    XDG_CACHE_HOME: path.join(input.home, "cache"),
  }
  await mkdir(path.join(directory, "bin"), { recursive: true })
  await mkdir(path.join(directory, "plugin"))
  await copyFile(input.binary, path.join(directory, "bin/opencode"))
  await chmod(path.join(directory, "bin/opencode"), 0o755)
  await command(
    [
      input.bun,
      "build",
      "./packages/plugin-app-custom/src/updates/sidecar.ts",
      "--target=bun",
      "--external=@opencode/plugin-app-custom/updates/runtime",
      `--outfile=${directory}/plugin/index.js`,
    ],
    source,
    env,
  )
  const runtime = path.join(directory, "plugin/node_modules/@opencode/plugin-app-custom")
  await mkdir(runtime, { recursive: true })
  await Bun.write(
    path.join(runtime, "package.json"),
    JSON.stringify({
      name: "@opencode/plugin-app-custom",
      type: "module",
      exports: { "./updates/runtime": "./runtime.js" },
    }),
  )
  await command(
    [
      input.bun,
      "build",
      "./packages/plugin-app-custom/src/updates/runtime.ts",
      "--target=bun",
      `--outfile=${runtime}/runtime.js`,
    ],
    source,
    env,
  )
  await command(
    [
      input.bun,
      "build",
      "./packages/plugin-app-custom/src/updates/tui.ts",
      "--target=bun",
      `--outfile=${directory}/plugin/tui.js`,
    ],
    source,
    env,
  )
  await command(
    [
      input.bun,
      "build",
      "./packages/plugin-app-custom/script/prepare.ts",
      "--target=bun",
      `--outfile=${directory}/plugin/prepare.js`,
    ],
    source,
    env,
  )
  await command(
    [
      input.bun,
      "build",
      "./packages/plugin-app-custom/script/handoff.ts",
      "--target=bun",
      `--outfile=${directory}/plugin/handoff.js`,
    ],
    source,
    env,
  )
  const destination = path.join(input.home, "releases", input.commit)
  await Bun.write(
    path.join(directory, "server-config.json"),
    JSON.stringify({
      update: "disable",
      plugins: [path.join(destination, "plugin")],
    }),
  )
  const manifest = Schema.decodeUnknownSync(Manifest)({
    format: 1,
    commit: input.commit,
    version: input.version,
    platform: process.platform,
    arch: process.arch,
    files: Object.fromEntries(
      await Promise.all(artifacts.map(async (file) => [file, await sha256(path.join(directory, file))])),
    ),
  })
  const reported = (await command([path.join(directory, "bin/opencode"), "--version"], directory, env, true)).trim()
  if (reported !== `opencode v${input.version}`)
    throw new Error(`Built executable reports ${reported}, expected ${input.version}`)
  await Bun.write(path.join(directory, "manifest.json"), JSON.stringify(manifest, null, 2))
  await readManifest(directory, true)
  await mkdir(path.join(input.home, "releases"), { recursive: true })
  await rename(directory, destination)
  await pointRelease(input.home, "prepared", manifest.commit)
  return manifest
}

async function command(args: string[], cwd: string, env = process.env, capture = false) {
  const child = Bun.spawn(args, {
    cwd,
    env: { ...env, GIT_TERMINAL_PROMPT: "0" },
    stdin: "ignore",
    stdout: capture ? "pipe" : "inherit",
    stderr: "inherit",
    timeout: 30 * 60_000,
  })
  const output = capture ? await new Response(child.stdout).text() : ""
  if ((await child.exited) !== 0) throw new Error(`Command failed: ${args[0]} ${args.slice(1).join(" ")}`)
  return output
}
