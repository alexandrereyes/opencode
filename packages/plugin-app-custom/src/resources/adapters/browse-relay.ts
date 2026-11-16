import { randomUUID } from "node:crypto"
import os from "node:os"
import path from "node:path"
import { Option, Schema } from "effect"

/**
 * A client of browse's relay (browse 0.1.0, `docs/browse-handoff-remoto.md`): its tools over `POST /tools/call`, as
 * the agent's own browse MCP server calls them, for one owner. browse gives clients no CDP and no sessions any more:
 * an agent's tabs are the ones its calls opened under its owner id (`browseOwner`), and every call names its `tab`.
 *
 * The relay token is read per call, goes only into the `authorization` header and never into a message or a log.
 */

/** browse's default relay port; a relay that finds it taken moves to 19990–19997 and says so in `relay.json`. */
export const defaultPort = 19988

export type Env = Record<string, string | undefined>

/** browse's `Paths`: `OPENCODE_BROWSER_HOME` replaces every root, else the XDG ones (absolute only), else `~/.…`. */
function root(env: Env, variable: string, fallback: string) {
  if (env.OPENCODE_BROWSER_HOME) return env.OPENCODE_BROWSER_HOME
  const configured = env[variable] && path.isAbsolute(env[variable]) ? env[variable] : undefined
  return path.join(configured ?? path.join(os.homedir(), fallback), "browse")
}

/**
 * The relay token, as browse itself finds it (`OPENCODE_BROWSER_HOME`, else `$XDG_DATA_HOME/browse`, else
 * `~/.local/share/browse`; `OPENCODE_BROWSE_RELAY_TOKEN_FILE` names the file directly, for sandboxes whose XDG
 * directories are their own).
 */
export function relayTokenFile(env: Env = process.env) {
  return env.OPENCODE_BROWSE_RELAY_TOKEN_FILE || path.join(root(env, "XDG_DATA_HOME", ".local/share"), "relay-token")
}

const RelayState = Schema.Struct({ port: Schema.Int, pid: Schema.Int })
const decodeState = Schema.decodeUnknownOption(RelayState)

/**
 * The relay's port as browse's own clients resolve it (`resolve_port`): `OPENCODE_BROWSER_PORT` pins it; else the
 * port a live relay recorded in `<state>/relays/19988/relay.json`; else 19988.
 */
export async function relayPort(env: Env = process.env) {
  const pinned = Number(env.OPENCODE_BROWSER_PORT?.trim())
  if (Number.isInteger(pinned) && pinned > 0 && pinned < 65_536) return pinned
  const file = path.join(root(env, "XDG_STATE_HOME", ".local/state"), "relays", String(defaultPort), "relay.json")
  const state = Option.getOrUndefined(
    decodeState(
      await Bun.file(file)
        .json()
        .catch(() => undefined),
    ),
  )
  return state && state.port > 0 && alive(state.pid) ? state.port : defaultPort
}

/** The relay's HTTP endpoint (`meta.cdp` of a browse resource, which `machine.ts` checks). */
export async function relayEndpoint(env: Env = process.env) {
  return `http://127.0.0.1:${await relayPort(env)}`
}

/**
 * Why a call failed: `down` (no relay answers, or it is still starting), `refused` (the token or the request was
 * refused), `tool` (the tool ran and failed: its own text, which never holds the token), `cancelled` (our signal).
 */
export class RelayError extends Error {
  constructor(
    readonly reason: "down" | "refused" | "tool" | "cancelled",
    message: string,
  ) {
    super(message)
  }
}

const Content = Schema.Union([
  Schema.Struct({ type: Schema.Literal("text"), text: Schema.String }),
  Schema.Struct({ type: Schema.Literal("image"), data: Schema.String, mimeType: Schema.String }),
])
const Output = Schema.Struct({ content: Schema.Array(Content), isError: Schema.optional(Schema.Boolean) })
export type Output = typeof Output.Type
const decodeOutput = Schema.decodeUnknownOption(Output)

/**
 * Calls browse tool `name` for `owner` (`OpenCode-Browser-Owner`: the call sees that owner's tabs, the ones Alexandre
 * lent and the ones nobody claims; without it, every tab). The call has its own key: when `signal` aborts or
 * `timeoutMs` passes the relay is told to stop it (`POST /tools/cancel`), which also takes down a card it shows.
 */
export async function callTool(
  owner: string,
  name: string,
  args: Record<string, unknown>,
  options: { readonly signal?: AbortSignal; readonly timeoutMs?: number; readonly env?: Env } = {},
): Promise<Output> {
  const env = options.env ?? process.env
  const endpoint = await relayEndpoint(env)
  const authorization = await bearer(env)
  const key = randomUUID()
  const signal = AbortSignal.any([
    ...(options.signal ? [options.signal] : []),
    AbortSignal.timeout(options.timeoutMs ?? 15_000),
  ])
  const cancel = () =>
    void fetch(`${endpoint}/tools/cancel`, {
      method: "POST",
      headers: { authorization, "content-type": "application/json" },
      body: JSON.stringify({ call: key }),
      signal: AbortSignal.timeout(2_000),
    }).catch(() => undefined)
  signal.addEventListener("abort", cancel, { once: true })
  const response = await fetch(`${endpoint}/tools/call`, {
    method: "POST",
    headers: {
      authorization,
      "content-type": "application/json",
      "opencode-browser-client": "opencode",
      "opencode-browser-owner": owner,
      "opencode-browser-call": key,
    },
    body: JSON.stringify({ name, arguments: args }),
    signal,
  })
    .catch((error: unknown) => {
      if (signal.aborted) throw new RelayError("cancelled", `browse ${name} was stopped.`)
      throw new RelayError("down", `O browse não responde em ${endpoint} (${message(error)}).`)
    })
    .finally(() => signal.removeEventListener("abort", cancel))
  const body = await response.json().catch(() => undefined)
  if (response.status === 503) throw new RelayError("down", `O relay do browse em ${endpoint} ainda está iniciando.`)
  if (!response.ok) throw new RelayError("refused", `browse ${name}: HTTP ${response.status} ${errorText(body)}`.trim())
  const output = Option.getOrUndefined(decodeOutput(body))
  if (!output) throw new RelayError("refused", `browse ${name}: resposta inesperada do relay.`)
  if (output.isError) throw new RelayError("tool", textOf(output) || `browse ${name} failed`)
  return output
}

/** Whether a browser is connected to the relay (`GET /extension/status`); false when no relay answers. */
export async function extensionConnected(env: Env = process.env) {
  const endpoint = await relayEndpoint(env)
  const status = await fetch(`${endpoint}/extension/status`, {
    headers: { authorization: await bearer(env) },
    signal: AbortSignal.timeout(2_000),
  })
    .then((response) => (response.ok ? response.json() : undefined))
    .catch(() => undefined)
  return typeof status === "object" && status !== null && "connected" in status && status.connected === true
}

/** The text a tool returned, its parts joined (browse appends warnings as parts of their own). */
export function textOf(output: Output) {
  return output.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n")
}

const decodeJson = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Unknown))

/** The JSON a tool answered with: its first text part (warnings follow in parts of their own). */
export function jsonOf<A>(output: Output, schema: Schema.Codec<A, unknown>) {
  const first = output.content.find((part) => part.type === "text")
  const value = first ? Option.getOrUndefined(decodeJson(first.text)) : undefined
  return Option.getOrUndefined(Schema.decodeUnknownOption(schema)(value))
}

/** The image a tool answered with (`screenshot`), copied into a plain `ArrayBuffer`. */
export function imageOf(output: Output) {
  const image = output.content.find((part) => part.type === "image")
  return image?.type === "image" ? new Uint8Array(Buffer.from(image.data, "base64")) : undefined
}

async function bearer(env: Env) {
  const token = (
    await Bun.file(relayTokenFile(env))
      .text()
      .catch(() => "")
  ).trim()
  if (!token) throw new RelayError("refused", "O token do relay do browse não pôde ser lido.")
  return `Bearer ${token}`
}

/** A process that exists, ours or not (`EPERM`). */
function alive(pid: number) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "EPERM"
  }
}

const message = (error: unknown) => (error instanceof Error ? error.message : String(error))

const errorText = (body: unknown) =>
  typeof body === "object" && body !== null && "error" in body && typeof body.error === "string" ? body.error : ""
