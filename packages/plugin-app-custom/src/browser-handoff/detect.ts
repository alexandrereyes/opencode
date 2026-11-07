/**
 * Which tool calls may be waiting on Alexandre in the browser (`docs/browser-handoff.md`). browse's `execute` blocks
 * while its code's `handoff()` (or `demonstrate()`, which hands off too) waits for the in-page Continue, and browse
 * reports nothing over MCP meanwhile, so the code is the only signal: a call that runs such code and is still running
 * after `limits.graceMs` is taken as waiting.
 */

/** The effective names of browse's `execute`: Code Mode's inner call (`browse_execute`) and its dotted path. */
export const tools: ReadonlySet<string> = new Set(["browse_execute", "browse.execute"])

export const messages = {
  handoff: "Conclua a etapa no navegador e clique em Continue",
  demonstrate: "Demonstre o fluxo no navegador e clique em Continue",
}

/** At most this many characters of the handoff message reach the apps (the Live Activity's text limit). */
export const maxMessage = 120

const call = /\b(handoff|demonstrate)\s*\(\s*(?:(["'`])((?:\\[\s\S]|(?!\2)[^\\])*)\2)?/

/** Comments may mention `handoff(` without calling it. */
const comments = /\/\*[\s\S]*?\*\/|(^|[^:\\])\/\/[^\n]*/g

/**
 * The message of the first `handoff(...)` or `demonstrate(...)` call in browse code, or `undefined` when it calls
 * neither. A string literal argument is the message (a template's `${…}` reads as `…`); any other argument, or none,
 * gives browse's default wording in pt-BR.
 */
export function handoffMessage(code: string): string | undefined {
  const match = code.replace(comments, (_, prefix: string | undefined) => prefix ?? "").match(call)
  if (!match) return undefined
  const kind = match[1] === "demonstrate" ? "demonstrate" : "handoff"
  const raw = match[3]
  const text = raw
    ?.replace(/\$\{[^}]*\}/g, "…")
    .replace(/\\([\s\S])/g, (_, char: string) => (char === "n" ? " " : char))
    .replace(/\s+/g, " ")
    .trim()
  const message = text || messages[kind]
  const chars = Array.from(message)
  return chars.length <= maxMessage ? message : `${chars.slice(0, maxMessage - 1).join("")}…`
}

/** The handoff message of a browse `execute` call's input, or `undefined` when the call cannot hand off. */
export function detect(tool: string, input: unknown): string | undefined {
  if (!tools.has(tool) || typeof input !== "object" || input === null) return undefined
  const code = (input as { readonly code?: unknown }).code
  return typeof code === "string" ? handoffMessage(code) : undefined
}
