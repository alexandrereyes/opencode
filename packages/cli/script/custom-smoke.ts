// Explicit integration check: only a fresh temporary database and an ephemeral
// loopback port. Never discovers, registers, or controls an installed service.
import { chmod, copyFile, mkdir, mkdtemp, rm } from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { artifacts, command, manifest, seal } from "./custom-release"

const binary = process.argv[2]
if (!binary || !path.isAbsolute(binary))
  throw new Error("Usage: bun script/custom-smoke.ts /absolute/compiled/custom/opencode")
await mkdir(path.join(os.tmpdir(), "opencode"), { recursive: true })
const work = await mkdtemp(path.join(os.tmpdir(), "opencode", "compact-smoke-"))
const env = {
  HOME: `${work}/home`,
  PATH: "/opt/homebrew/bin:/usr/bin:/bin",
  TMPDIR: os.tmpdir(),
  XDG_CONFIG_HOME: `${work}/config`,
  XDG_DATA_HOME: `${work}/data`,
  XDG_STATE_HOME: `${work}/state`,
  XDG_CACHE_HOME: `${work}/cache`,
  OPENCODE_CONFIG_DIR: `${work}/config/opencode`,
  OPENCODE_DB: `${work}/database.sqlite`,
  OPENCODE_CONFIG_PROJECT_DISABLE: "1",
  OPENCODE_DISABLE_MODELS_FETCH: "1",
  OPENCODE_DISABLE_AUTOUPDATE: "1",
  OPENCODE_PASSWORD: "isolated-fixture",
}
const version = (await command([binary, "--version"], work, env)).replace("opencode v", "")
const commit = version.replace("0.0.0-custom.", "")
if (!/^[a-f0-9]{40}$/.test(commit))
  throw new Error(`Expected a commit-versioned custom binary; received ${JSON.stringify(version)}`)
const release = `${work}/releases/${commit}`
await mkdir(`${release}/bin`, { recursive: true })
await mkdir(`${release}/plugin`)
await mkdir(`${work}/home/project`, { recursive: true })
await copyFile(binary, `${release}/bin/opencode`)
await chmod(`${release}/bin/opencode`, 0o755)
await command(
  [
    process.execPath,
    "build",
    "script/custom-plugin.ts",
    "--target=bun",
    "--minify",
    `--outfile=${release}/plugin/index.js`,
  ],
  path.resolve(import.meta.dirname, ".."),
  env,
  false,
)
await Bun.write(`${release}/server-config.json`, JSON.stringify({ update: "disable", plugins: [`${release}/plugin`] }))
await seal(release, commit)
await manifest(work, commit)
const listener = Bun.listen({ hostname: "127.0.0.1", port: 0, socket: { data() {} } })
const port = listener.port
listener.stop(true)
const log = Bun.file(`${work}/server.log`)
const child = Bun.spawn([`${release}/bin/opencode`, "serve", "--hostname", "127.0.0.1", "--port", String(port)], {
  cwd: `${work}/home/project`,
  env: { ...env, OPENCODE_CONFIG_CONTENT: await Bun.file(`${release}/server-config.json`).text() },
  stdin: "ignore",
  stdout: log,
  stderr: log,
})
const headers = {
  authorization: `Basic ${Buffer.from("opencode:isolated-fixture").toString("base64")}`,
  "content-type": "application/json",
}
try {
  for (let attempt = 0; ; attempt++) {
    if (child.exitCode !== null || attempt === 120) throw new Error(`Fixture startup failed: ${work}/server.log`)
    const response = await fetch(`http://127.0.0.1:${port}/api/health`, {
      headers,
      signal: AbortSignal.timeout(2000),
    }).catch(() => undefined)
    if (response?.ok) {
      const body = await response.json()
      if (body.version !== version) throw new Error("Server/CLI version mismatch")
      break
    }
    await Bun.sleep(500)
  }
  const call = async (method: string, input: unknown) => {
    const response = await fetch(`http://127.0.0.1:${port}/api/rpc/custom.snippets/${method}`, {
      method: "POST",
      headers,
      body: JSON.stringify({ input }),
      signal: AbortSignal.timeout(10000),
    })
    if (!response.ok) throw new Error(`Bundled RPC ${method} failed: ${response.status}; ${work}/server.log`)
    return response.json()
  }
  await call("save", { id: "fixture", name: "fixture", description: "", aliases: [], content: "compact bundle" })
  const listed = await call("list", {})
  if (listed.output.items[0]?.content !== "compact bundle") throw new Error("Bundled RPC did not preserve data")
  const invalid = await fetch(`http://127.0.0.1:${port}/api/rpc/custom.snippets/save`, {
    method: "POST",
    headers,
    body: JSON.stringify({ input: { id: "invalid" } }),
  })
  if (invalid.ok) throw new Error("Bundled input validation was bypassed")
  const web = await fetch(`http://127.0.0.1:${port}/`, { headers })
  if (!web.ok || !(await web.text()).includes("/_assets/")) throw new Error("Embedded custom web failed")
  const files = Array.from(new Bun.Glob("**/*").scanSync({ cwd: release, onlyFiles: true })).sort()
  if (JSON.stringify(files) !== JSON.stringify([...artifacts, "manual-release.json"].sort()))
    throw new Error("Unexpected compact release payload")
  console.log(
    JSON.stringify(
      {
        work,
        version,
        files,
        bytes: files.reduce((sum, file) => sum + Bun.file(`${release}/${file}`).size, 0),
        rpc: "save/list/invalid-input passed",
        web: 200,
        health: 200,
      },
      null,
      2,
    ),
  )
} finally {
  child.kill("SIGTERM")
  await child.exited
}
// Keep the measured compact release and logs, remove only the disposable database.
await rm(`${work}/database.sqlite`, { force: true })
