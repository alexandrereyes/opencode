import { closeSync, existsSync, openSync } from "node:fs"
import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Option, Schema } from "effect"
import { BancadaDaemon } from "./daemon/main.js"
import type { Bancada } from "./rpc.js"

const Info = Schema.Struct({
  protocol: Schema.Number,
  pid: Schema.Number,
  port: Schema.Number,
  secret: Schema.String,
  machineID: Schema.String,
})
type Info = typeof Info.Type
const decodeInfo = Schema.decodeUnknownOption(Info)
const Taken = Schema.Struct({ owner: Schema.Struct({ instanceID: Schema.String, name: Schema.String }) })
const decodeTaken = Schema.decodeUnknownOption(Taken)

export class BancadaError extends Error {
  constructor(
    readonly reason: "process" | "owner" | "invalid" | "not_hub" | "protocol_mismatch" | "machine_taken",
    message: string,
    readonly owner?: Bancada.Owner,
    readonly problems?: ReadonlyArray<string>,
    readonly data?: Readonly<Record<string, unknown>>,
  ) {
    super(message)
  }
}
const Problems = Schema.Struct({ type: Schema.Literal("invalid"), problems: Schema.Array(Schema.String) })
const decodeProblems = Schema.decodeUnknownOption(Problems)
/** A refusal of the process between servers (`BancadaDaemon`, status 422). */
const Refused = Schema.Struct({
  type: Schema.Literals(["not_hub", "protocol_mismatch", "machine_taken", "invalid"]),
  message: Schema.String,
  data: Schema.optional(Schema.Record(Schema.String, Schema.Unknown)),
})
const decodeRefused = Schema.decodeUnknownOption(Refused)

export const limits = {
  /** Deadline of an ordinary admin request; the process answers on loopback in milliseconds. */
  requestMs: 3_000,
  /** How long a start waits for the process to listen. */
  startMs: 5_000,
}

/**
 * The machine's folder: one process per folder (`bancada.db` is its lock). A literal path, never XDG: the Mac's
 * production server and the sandboxes change `XDG_STATE_HOME` (D2).
 */
export function stateDirectory(env: Readonly<Record<string, string | undefined>> = process.env) {
  return env.OPENCODE_BANCADA_STATE || path.join(os.homedir(), ".local/state/opencode-bancada")
}

/** Command that starts the process: its `bin` beside this module in source/dist, or the release bundle itself. */
export function bancadaCommand(module = fileURLToPath(import.meta.url), exec = process.execPath) {
  const bin = path.join(path.dirname(module), "daemon", module.endsWith(".ts") ? "bin.ts" : "bin.js")
  return existsSync(bin) ? [exec, bin] : [exec, module, BancadaDaemon.flag]
}

/**
 * A plugin instance's view of this machine's process (`docs/bancada.md`, "Process"). Every Location's instance has
 * one; they share the process through `bancada.json`. The first call starts the process when none answers: in a
 * session of its own, with this server as its parent, so it leaves when the server is gone. A process reporting
 * another admin protocol is asked to shut down and replaced. Before its first call a client configures the process
 * with `owner()`; a process that already serves another server refuses with its name.
 */
export function makeBancadaClient(options: {
  readonly state: string
  readonly owner: () => Promise<BancadaDaemon.Owner>
  readonly command?: readonly string[]
  /** The machine file the process reads (`OPENCODE_BANCADA_CONFIG`); by default the owner's `~/.config/opencode/bancada.toml`. */
  readonly config?: string
}) {
  const file = path.join(options.state, "bancada.json")
  const origin = (info: Info) => `http://127.0.0.1:${info.port}`
  let cached: Info | undefined
  let starting: Promise<Info | undefined> | undefined
  /** The process this client configured, and as which server. */
  let configured: { readonly pid: number; readonly instanceID: string } | undefined

  const read = async () =>
    Option.getOrUndefined(
      decodeInfo(
        await Bun.file(file)
          .json()
          .catch(() => undefined),
      ),
    )

  const healthy = (info: Info) =>
    fetch(`${origin(info)}/admin/health`, {
      headers: { authorization: `Bearer ${info.secret}` },
      signal: AbortSignal.timeout(1_500),
    })
      .then(async (response) => {
        if (!response.ok) return "down" as const
        const body: unknown = await response.json()
        return typeof body === "object" &&
          body !== null &&
          "protocol" in body &&
          body.protocol === BancadaDaemon.adminProtocol
          ? ("ok" as const)
          : ("stale" as const)
      })
      .catch(() => "down" as const)

  const post = (
    info: Info,
    route: string,
    body: unknown,
    headers: Record<string, string> = {},
    timeout = limits.requestMs,
  ) =>
    fetch(`${origin(info)}${route}`, {
      method: "POST",
      headers: { ...headers, authorization: `Bearer ${info.secret}`, "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeout),
    }).catch(() => undefined)

  const start = async (): Promise<Info | undefined> => {
    const current = await read()
    const health = current ? await healthy(current) : "down"
    if (current && health === "ok") return current
    if (current && health === "stale") await post(current, "/admin/shutdown", {})
    await fs.mkdir(options.state, { recursive: true, mode: 0o700 })
    // Appended, never truncated: a process that loses the start race must not erase the winner's log.
    const log = openSync(path.join(options.state, "bancada.log"), "a", 0o600)
    const child = Bun.spawn([...(options.command ?? bancadaCommand())], {
      detached: true,
      env: {
        ...process.env,
        BUN_BE_BUN: "1",
        OPENCODE_BANCADA_STATE: options.state,
        OPENCODE_BANCADA_PARENT: String(process.pid),
        ...(options.config ? { OPENCODE_BANCADA_CONFIG: options.config } : {}),
      },
      stdin: "ignore",
      stdout: log,
      stderr: log,
    })
    closeSync(log)
    child.unref()
    const deadline = Date.now() + limits.startMs
    while (Date.now() < deadline) {
      await Bun.sleep(100)
      const next = await read()
      if (next && next.pid !== current?.pid && (await healthy(next)) === "ok") return next
    }
    // Another plugin instance, or another server of this machine, may have won the start; use whoever answers now.
    const winner = await read()
    return winner && (await healthy(winner)) === "ok" ? winner : undefined
  }

  const ensure = async () => {
    if (cached) return cached
    starting ??= start().finally(() => (starting = undefined))
    cached = await starting
    return cached
  }

  const configure = async (info: Info) => {
    const owner = await options.owner()
    const response = await post(info, "/admin/configure", owner)
    if (response?.status === 409) throw taken(await response.json().catch(() => undefined))
    if (!response?.ok) return undefined
    configured = { pid: info.pid, instanceID: owner.instanceID }
    return configured
  }

  const call = async <T>(method: string, input: unknown, timeout = limits.requestMs): Promise<T> => {
    const attempt = async (retry: boolean): Promise<T> => {
      const info = await ensure()
      if (!info) throw unavailable()
      const as = configured?.pid === info.pid ? configured : await configure(info)
      const response = as
        ? await post(info, `/admin/rpc/${method}`, input, { [BancadaDaemon.instanceHeader]: as.instanceID }, timeout)
        : undefined
      if (response?.ok) return (await response.json()) as T
      if (response?.status === 409) throw taken(await response.json().catch(() => undefined))
      const refused = response?.status === 422 ? decodeRefused(await response.json().catch(() => undefined)) : undefined
      if (refused && Option.isSome(refused))
        throw new BancadaError(refused.value.type, refused.value.message, undefined, undefined, refused.value.data)
      const invalid =
        response?.status === 400 ? decodeProblems(await response.json().catch(() => undefined)) : undefined
      if (invalid && Option.isSome(invalid))
        throw new BancadaError("invalid", invalid.value.problems.join("\n"), undefined, invalid.value.problems)
      if (response && response.status !== 401 && response.status !== 412) throw unavailable()
      // Gone, restarted (a new secret, or a process this client never configured): look again once.
      cached = undefined
      configured = undefined
      if (retry) return attempt(false)
      throw unavailable()
    }
    return attempt(true)
  }

  return {
    /** The process's `custom.bancada` method; throws `BancadaError`. */
    call,
    /** The running process (`bancada.json`), starting it when none answers; undefined when it cannot start. */
    ensure,
  }
}

export type BancadaClient = ReturnType<typeof makeBancadaClient>

function unavailable() {
  return new BancadaError("process", "O processo da Bancada desta máquina não está respondendo.")
}

function taken(body: unknown) {
  const owner = Option.getOrUndefined(decodeTaken(body))?.owner
  return new BancadaError(
    "owner",
    owner ? `A Bancada desta máquina pertence a ${owner.name}.` : "A Bancada desta máquina pertence a outro servidor.",
    owner,
  )
}
