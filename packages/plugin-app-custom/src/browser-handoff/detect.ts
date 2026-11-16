/**
 * Which tool calls may be waiting on Alexandre in the browser (`docs/browser-handoff.md`). browse's `handoff` and
 * `demonstrate` tools block until he clicks the in-page Continue (or the toolbar button), and report nothing over MCP
 * meanwhile, so such a call that is still running after `limits.graceMs` is taken as waiting.
 */
import { browseName } from "./calls.js"

/** browse's default wording in pt-BR, for a call without a message. */
export const messages = {
  handoff: "Conclua a etapa no navegador e clique em Continue",
  demonstrate: "Demonstre o fluxo no navegador e clique em Continue",
}

/** At most this many characters of the handoff message reach the apps (the Live Activity's text limit). */
export const maxMessage = 120

/**
 * The handoff a browse call asks for: its message (the call's `message`, whitespace collapsed, clipped to
 * `maxMessage`; browse's default wording without one) and its `tab`, or `undefined` for any other call.
 */
export function detect(tool: string, input: unknown): { readonly message: string; readonly tab?: number } | undefined {
  const name = browseName(tool)
  if (name !== "handoff" && name !== "demonstrate") return undefined
  const fields = typeof input === "object" && input !== null ? input : {}
  const given = "message" in fields && typeof fields.message === "string" ? fields.message.replace(/\s+/g, " ").trim() : ""
  const tab = "tab" in fields && Number.isInteger(fields.tab) ? Number(fields.tab) : undefined
  const chars = Array.from(given || messages[name])
  const message = chars.length <= maxMessage ? chars.join("") : `${chars.slice(0, maxMessage - 1).join("")}…`
  return { message, ...(tab === undefined ? {} : { tab }) }
}
