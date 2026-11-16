/**
 * What an agent's browse calls tell (browse 0.1.0, `docs/browse-handoff-remoto.md`, "Owner and tabs"). OpenCode gets
 * browse's plain tools (`browse_navigate`, `browse_click`… and `tools.browse.<name>` in Code Mode), each naming the
 * integer `tab` it acts on; `navigate` without `tab` and `tabs new` open one and answer with it.
 */
import { createHash } from "node:crypto"
import { Option, Schema } from "effect"

/**
 * browse's owner of an OpenCode session's tabs (`session_owner` in browse's MCP server: `mcp-` and the first 8 hex
 * digits of the SHA-256 of the `_meta["ai.opencode/sessionID"]` OpenCode sends with every call). The relay shows a call
 * made for that owner only its tabs, the ones Alexandre lent and the ones nobody claims.
 */
export function browseOwner(sessionID: string) {
  return `mcp-${createHash("sha256").update(sessionID.trim()).digest("hex").slice(0, 8)}`
}

const browseTool = /^browse[._](.+)$/

/** A browse tool's own name (`navigate`, `handoff`…) from its effective name (`browse_navigate`), or undefined. */
export const browseName = (tool: string) => browseTool.exec(tool)?.[1]

const Tabbed = Schema.Struct({ tab: Schema.Int })
const decodeTabbed = Schema.decodeUnknownOption(Tabbed)
const decodeJson = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Unknown))

/**
 * A browse result as JSON. OpenCode parses a JSON text result itself, unless browse appended a warning or a note to it
 * (`\nWarning: …`): then the text holds the JSON first, which is all that is read.
 */
export function resultJson(output: unknown): unknown {
  if (typeof output !== "string") return output
  const whole = decodeJson(output)
  if (Option.isSome(whole)) return whole.value
  const ends = [...output.matchAll(/}\s*\n/g)].map((match) => match.index + 1)
  for (const end of ends) {
    const found = decodeJson(output.slice(0, end))
    if (Option.isSome(found)) return found.value
  }
  return undefined
}

/**
 * The tab a browse call acted on: the `tab` it names, else the one it opened (`navigate` without `tab`, `tabs` with
 * `action: "new"`), as its result says. `tabs` naming tabs closes them: no tab to follow.
 */
export function callTab(name: string, input: unknown, output?: unknown) {
  const action = typeof input === "object" && input !== null && "action" in input ? input.action : undefined
  if (name === "tabs") return action === "new" ? Option.getOrUndefined(decodeTabbed(resultJson(output)))?.tab : undefined
  const named = Option.getOrUndefined(decodeTabbed(input))?.tab
  if (named !== undefined || name !== "navigate") return named
  return Option.getOrUndefined(decodeTabbed(resultJson(output)))?.tab
}
