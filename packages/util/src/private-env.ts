export * as PrivateEnv from "./private-env.js"

import { execFileSync } from "node:child_process"

/**
 * Secrets the server reads but its children must never inherit. They are not environment variables at all: a
 * launcher names a command in `OPENCODE_PRIVATE_ENV_COMMAND` (a JSON argv), the server runs it once at startup and
 * keeps its output, `NAME\0value\0` pairs, in memory. Nothing reaches `process.env` or the process's initial
 * environment, which Bun hands to every `Bun.spawn` without an explicit `env` and `ps` can read, so shells, PTYs,
 * MCP servers and every other child start without them. `{env:NAME}` in configuration and env-method integrations
 * read them through `get`. The store lives in a registry symbol because plugins are separate builds with their own
 * copy of this module; a plugin reads `globalThis[Symbol.for("opencode.private-env")]`, a `Map<string, string>`.
 */
export const variable = "OPENCODE_PRIVATE_ENV_COMMAND"
const slot = Symbol.for("opencode.private-env")
const name = /^[A-Za-z_][A-Za-z0-9_]*$/

const store = () => {
  const global = globalThis as { [slot]?: Map<string, string> }
  global[slot] ??= new Map()
  return global[slot]
}

export type Result =
  | { readonly status: "none" }
  | { readonly status: "loaded"; readonly names: ReadonlyArray<string> }
  | { readonly status: "failed"; readonly reason: string }

/**
 * Runs the launcher's command and stores its pairs. Reasons name the failure, never the command's output.
 * The command's stderr goes to the server's own stderr; it must not print values there either.
 */
export function load(env: NodeJS.ProcessEnv = process.env): Result {
  const raw = env[variable]
  delete env[variable]
  if (!raw) return { status: "none" }
  const argv = (() => {
    try {
      const parsed: unknown = JSON.parse(raw)
      return Array.isArray(parsed) && parsed.length > 0 && parsed.every((item) => typeof item === "string")
        ? (parsed as string[])
        : undefined
    } catch {
      return undefined
    }
  })()
  if (!argv) return { status: "failed", reason: `${variable} is not a JSON array of strings` }
  const output = (() => {
    try {
      return execFileSync(argv[0]!, argv.slice(1), {
        stdio: ["ignore", "pipe", "inherit"],
        timeout: 120_000,
        maxBuffer: 4 * 1024 * 1024,
      })
    } catch (error) {
      const status = (error as { status?: unknown }).status
      return typeof status === "number" ? `exit ${status}` : "could not run"
    }
  })()
  if (typeof output === "string") return { status: "failed", reason: `the command failed (${output})` }
  const fields = output.toString("utf8").split("\0")
  if (fields.pop() !== "" || fields.length % 2 !== 0) return { status: "failed", reason: "the output is not NAME\\0value\\0 pairs" }
  const pairs: [string, string][] = []
  for (let index = 0; index < fields.length; index += 2) {
    if (!name.test(fields[index]!)) return { status: "failed", reason: "the output names an invalid variable" }
    pairs.push([fields[index]!, fields[index + 1]!])
  }
  for (const [key, value] of pairs) store().set(key, value)
  return { status: "loaded", names: pairs.map(([key]) => key) }
}

export const get = (key: string) => store().get(key)
