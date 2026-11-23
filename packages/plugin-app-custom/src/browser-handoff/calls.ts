/**
 * What an agent's browse calls tell (browse 0.1.5, `docs/browse-handoff-remoto.md`, "Sessions and tabs"). OpenCode gets
 * browse's plain tools (`browse_navigate`, `browse_click`… and `tools.browse.<name>` in Code Mode), each naming the
 * `tab` it acts on: browse's integer, or since 0.1.2 a chosen id like `work-mail` (`tabs new` with an `id`);
 * `navigate` without `tab` and `tabs new` open one and answer with its integer.
 */
import { createHash } from "node:crypto"
import { Option, Schema } from "effect"
import { tabNumber, type TabRef } from "../resources/adapters/browse-relay.js"

/**
 * The ID of an OpenCode session's browse resource (`chrome:browse:<owner>`): `mcp-` and the first 8 hex digits of the
 * SHA-256 of the trimmed session ID, the owner browse 0.1.0 gave the session's tabs. browse 0.1.1 dropped owners (the
 * relay ignores the header and every agent sees every tab); resources keep the ID, which the apps treat as opaque.
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
const Fields = Schema.Record(Schema.String, Schema.Unknown)
const decodeFields = Schema.decodeUnknownOption(Fields)

/** Tools whose result names browse's integer for the tab the call used. */
const answering = new Set(["navigate", "handoff", "demonstrate"])

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

/** A `tab` argument: browse's integer, or a chosen id (never a number: it starts with a letter). */
export function tabRef(value: unknown): TabRef | undefined {
  if (typeof value === "number") return Number.isInteger(value) ? value : undefined
  if (typeof value !== "string" || value.trim() === "") return undefined
  return tabNumber(value) ?? value.trim()
}

/**
 * The tab a browse call works in, which its session's resource follows: the `tab` it names (as browse's integer when
 * the result says it), else the one it opened (`navigate` without `tab`, `tabs` with `action: "new"`), as its result
 * says. `tabs` naming tabs closes them: no tab to follow.
 */
export function callTab(name: string, input: unknown, output?: unknown) {
  const fields = fieldsOf(input)
  const answered = Option.getOrUndefined(decodeTabbed(resultJson(output)))?.tab
  if (name === "tabs") return fields.action === "new" ? answered : undefined
  const named = tabRef(fields.tab)
  if (typeof named === "number" || !answering.has(name)) return named
  return answered ?? named
}

/**
 * Every tab a browse call names, which a lock may refuse: its `tab`, the `tabs` it closes, and the chosen `id` a `tabs
 * new` would answer with when that tab exists.
 */
export function namedTabs(name: string, input: unknown) {
  const fields = fieldsOf(input)
  const closing = Array.isArray(fields.tabs) ? fields.tabs : []
  const chosen = name === "tabs" && fields.action === "new" ? [fields.id] : []
  return [fields.tab, ...closing, ...chosen].flatMap((value) => {
    const ref = tabRef(value)
    return ref === undefined ? [] : [ref]
  })
}

/** The group a `tabs close` closes whole, if any. */
export function closedGroup(name: string, input: unknown) {
  const fields = fieldsOf(input)
  return name === "tabs" && fields.action === "close" && typeof fields.group === "string"
    ? fields.group.trim()
    : undefined
}

const fieldsOf = (input: unknown) => Option.getOrElse(decodeFields(input), (): Record<string, unknown> => ({}))
