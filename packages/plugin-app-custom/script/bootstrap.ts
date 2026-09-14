import { parseArgs } from "node:util"
import { randomBytes } from "node:crypto"
import { chmod, copyFile, mkdir, realpath } from "node:fs/promises"
import path from "node:path"
import { Schema } from "effect"
import { Deployment } from "../src/updates/prepare.js"
import { defaultValidation, UpstreamDeployment } from "../src/updates/upstream-sync.js"
import { pointRelease, readRelease } from "../src/updates/release.js"
import { Flock } from "@opencode/util/flock"

const args = parseArgs({
  options: {
    home: { type: "string" },
    repository: { type: "string" },
    branch: { type: "string", default: "custom" },
    upstream: { type: "string", default: "https://github.com/anomalyco/opencode.git" },
    "upstream-branch": { type: "string", default: "v2" },
    "worktree-root": { type: "string" },
    "worktree-name": { type: "string", default: "opencode2" },
    bun: { type: "string" },
    database: { type: "string" },
    "data-home": { type: "string" },
    port: { type: "string", default: "4178" },
    activate: { type: "string" },
  },
}).values
if (!args.home || !path.isAbsolute(args.home))
  throw new Error("Provide --home with a new absolute distribution directory")
const home = path.resolve(args.home)
if (args.activate) {
  await Flock.withLock(
    "activation",
    async () => {
      if (await readRelease(home, "current"))
        throw new Error("Initial activation only; use the UI to update an existing installation")
      const release = await readRelease(home, "prepared", true)
      if (!release || release.commit !== args.activate)
        throw new Error("Confirm the exact prepared commit with --activate <commit>")
      await pointRelease(home, "current", release.commit)
      console.log(`Initial release selected: ${release.version}. No service was started.`)
    },
    { dir: path.join(home, "locks") },
  )
  process.exit(0)
}
const preparation = Schema.decodeUnknownSync(Deployment)({
  repository: args.repository,
  branch: args.branch,
  bun: await realpath(args.bun ?? process.execPath),
})
const config = Schema.decodeUnknownSync(UpstreamDeployment)({
  ...preparation,
  upstream: args.upstream,
  upstreamBranch: args["upstream-branch"],
  worktreeRoot: args["worktree-root"] ?? path.join(process.env.HOME ?? path.dirname(home), "Worktrees"),
  worktreeName: args["worktree-name"],
  validation: defaultValidation(preparation.bun),
})
if (process.platform !== "darwin") throw new Error("This distribution bootstrap targets macOS")
const port = Number(args.port)
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid --port")
if (args.database && !path.isAbsolute(args.database)) throw new Error("--database must be an absolute path")
if (args["data-home"] && !path.isAbsolute(args["data-home"])) throw new Error("--data-home must be an absolute path")
// Refuse to overwrite installed state, including the retired deployment directory.
await mkdir(home, { mode: 0o700 })
await Promise.all(
  ["bin", "logs", "config/opencode", "data", "state", "cache", "plists"].map((name) =>
    mkdir(path.join(home, name), { recursive: true }),
  ),
)
await Bun.write(path.join(home, "deployment.json"), JSON.stringify(config, null, 2))
const environment = {
  OPENCODE_DISTRIBUTION_HOME: home,
  OPENCODE_BUILD_BUN: config.bun,
  OPENCODE_CONFIG_DIR: path.join(home, "config/opencode"),
  OPENCODE_DB: args.database ?? path.join(home, "data/opencode/custom.db"),
  XDG_DATA_HOME: args["data-home"] ?? path.join(home, "data"),
  XDG_STATE_HOME: path.join(home, "state"),
  XDG_CACHE_HOME: path.join(home, "cache"),
  OPENCODE_DISABLE_AUTOUPDATE: "1",
  PATH: process.env.PATH ?? "/usr/bin:/bin:/usr/sbin:/sbin",
}
await Bun.write(
  path.join(home, "environment.sh"),
  Object.entries(environment)
    .map(([key, value]) => `export ${key}='${value.replaceAll("'", "'\\''")}'`)
    .join("\n") + "\n",
)
await Bun.write(
  path.join(home, "config/opencode/service-custom.json"),
  JSON.stringify(
    {
      hostname: "127.0.0.1",
      port,
      password: randomBytes(32).toString("base64url"),
    },
    null,
    2,
  ),
)
await chmod(path.join(home, "config/opencode/service-custom.json"), 0o600)
const deployment = path.resolve(import.meta.dirname, "../deployment")
await Promise.all(
  ["serve.sh", "prepare.sh", "tui.sh"].map((name) =>
    copyFile(path.join(deployment, name), path.join(home, "bin", name)),
  ),
)
const escaped = home.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;")
await Promise.all(
  ["serve", "prepare"].map(async (name) =>
    Bun.write(
      path.join(home, "plists", `${name}.plist`),
      (await Bun.file(path.join(deployment, `${name}.plist`)).text()).replaceAll("@HOME@", escaped),
    ),
  ),
)
const bundle = await Bun.build({
  entrypoints: [path.resolve(import.meta.dirname, "prepare.ts")],
  target: "bun",
  outdir: path.join(home, "bin"),
  naming: "prepare.js",
})
if (!bundle.success) throw new Error(bundle.logs.join("\n"))
console.log(
  `Bootstrap files written to ${home}. Run bin/prepare.sh, then explicitly select its commit with --activate. No launchd jobs were installed.`,
)
