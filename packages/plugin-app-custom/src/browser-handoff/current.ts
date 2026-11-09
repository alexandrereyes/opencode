/**
 * Which browse session a browse call that names none acts on (`docs/browse-handoff-remoto.md`, "Sessão do browse").
 *
 * Since browse 0.0.16 its MCP server keeps a current session per caller, keyed by the `_meta["ai.opencode/sessionID"]`
 * OpenCode sends with every call: `mcp-` and the first 8 hex digits of the OpenCode session ID's SHA-256 until the
 * agent makes another one current (`session_new`, `session_use`, `session_reset`, `session_adopt` or `execute` with a
 * `session`, `session_delete` of the current one). browse reports it nowhere outside the MCP process, so this follows
 * the agent's browse calls for what may be current, and the relay (`pick`) says which of those the call touched.
 */
import { createHash } from "node:crypto"

/** browse's current session for an OpenCode session that never chose one (`callerSessionId` in browse's MCP). */
export function callerSession(sessionID: string) {
  return `mcp-${createHash("sha256").update(sessionID).digest("hex").slice(0, 8)}`
}

/** What a finished tool call tells (the hooks' `execute.after`). */
export type Observed = {
  readonly tool: string
  readonly sessionID: string
  readonly input: unknown
  readonly status: "completed" | "error"
  readonly result?: { readonly output?: unknown }
}

const browseTool = /^browse[._](.+)$/

/** A browse tool's own name (`execute`, `session_new`…) from its effective name (`browse_execute`), or undefined. */
export const browseName = (tool: string) => browseTool.exec(tool)?.[1]

/** The session a result names: `execute`'s `session` is its id, the others' a summary with one. */
export const named = (output: unknown) => {
  const session = typeof output === "object" && output !== null ? (output as { session?: unknown }).session : undefined
  return typeof session === "string" && session.length > 0 ? session : text(session, "id")
}

/**
 * The browse session a call names: `id` (or `session`) for `session_reset`, `session_delete` and `session_use`,
 * `session` for the others.
 */
export function explicitSession(name: string, input: unknown) {
  if (["session_reset", "session_delete", "session_use"].includes(name))
    return text(input, "id") ?? text(input, "session")
  return name === "session_new" ? undefined : text(input, "session")
}

const text = (value: unknown, key: string) => {
  if (typeof value !== "object" || value === null || !(key in value)) return undefined
  const found = (value as Record<string, unknown>)[key]
  return typeof found === "string" && found.length > 0 ? found : undefined
}

/**
 * The browse sessions that may be each OpenCode session's current one, as its browse calls left them: a call that
 * certainly set one leaves only it; a failed call that may have set one adds it. The caller's default is always a
 * candidate too (`candidates`), since browse forgets everything else when its MCP server restarts.
 */
export function makeCurrentSessions(limit = 1024) {
  const known = new Map<string, ReadonlySet<string>>()
  const set = (sessionID: string, ids: Iterable<string>) => {
    known.delete(sessionID)
    if (known.size >= limit) known.delete(known.keys().next().value!)
    known.set(sessionID, new Set(ids))
  }
  const now = (sessionID: string) => known.get(sessionID) ?? new Set([callerSession(sessionID)])

  const observe = (event: Observed) => {
    const name = browseTool.exec(event.tool)?.[1]
    if (!name) return
    const output = event.status === "completed" ? event.result?.output : undefined
    const session = text(event.input, "session")
    const sure = (id: string | undefined) => {
      if (id) set(event.sessionID, [id])
    }
    const maybe = (id: string | undefined) => {
      if (id) set(event.sessionID, [...now(event.sessionID), id])
    }
    switch (name) {
      case "execute":
      case "session_adopt": {
        // Both make the session they ran in current; the result says which.
        if (event.status === "completed") return sure(named(output) ?? session)
        return maybe(session)
      }
      case "session_new":
        if (event.status === "completed") return sure(named(output) ?? text(event.input, "id"))
        return
      case "session_use":
        if (event.status === "completed") return sure(text(output, "currentSession") ?? text(event.input, "id"))
        return
      case "session_reset": {
        const id = text(event.input, "id") ?? session
        if (event.status === "completed") return sure(id)
        return maybe(id)
      }
      case "session_delete": {
        if (event.status !== "completed") return
        const current = text(output, "currentSession")
        if (current) return sure(current)
        // Deleting the current one leaves a random id nobody outside browse knows: only the default is left.
        const id = text(event.input, "id") ?? session
        if (id && now(event.sessionID).has(id))
          set(
            event.sessionID,
            [...now(event.sessionID)].filter((item) => item !== id),
          )
        return
      }
    }
  }

  /** The browse sessions a call of `sessionID` that names none may act on. */
  const candidates = (sessionID: string): readonly string[] => [
    ...new Set([callerSession(sessionID), ...now(sessionID)]),
  ]

  return { observe, candidates }
}

/**
 * The one candidate the relay saw change since the call began (`updatedAt`: browse stamps a session as an `execute`
 * starts in it), or `undefined` when none or several did: the resource would risk another session's tab.
 */
export function pick(
  candidates: readonly string[],
  sessions: readonly { readonly id: string; readonly updatedAt: number }[],
  since: number,
) {
  const touched = sessions.filter((session) => candidates.includes(session.id) && session.updatedAt >= since)
  return touched.length === 1 ? touched[0]!.id : undefined
}

let shared: ReturnType<typeof makeCurrentSessions> | undefined
/** One tracker for the whole server: the handoffs observe the agents' browse calls, the resources read it. */
export const sharedCurrentSessions = () => (shared ??= makeCurrentSessions())
