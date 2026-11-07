import { Tool } from "@opencode/schema/tool"
import { Effect } from "effect"
import type { Context } from "../context.js"

/**
 * browse must not store credentials on disk (`docs/browse-guard.md`). Its `network` tool writes the captured cookies
 * and tokens to a reusable secret profile when the call carries `secrets`; every other use of browse stays allowed.
 * MCP permission rules see only the tool name, so the input is checked here.
 */

/** browse's `network`: its permission action and Code Mode's inner call, and its dotted path. */
export const tools: ReadonlySet<string> = new Set(["browse_network", "browse.network"])

export const refusal =
  "O browse não pode gravar credenciais em disco nesta máquina: `network` com `secrets` está bloqueado. " +
  "Para guardar a captura, chame `network` de novo sem `secrets`, com `outputPath` (HAR com as credenciais redigidas)."

/** Whether a call of `tool` with `input` would store captured credentials. */
export const storesCredentials = (tool: string, input: unknown) =>
  tools.has(tool) &&
  typeof input === "object" &&
  input !== null &&
  Object.hasOwn(input, "secrets") &&
  (input as { readonly secrets?: unknown }).secrets !== undefined

/** The permission decision: holds on any path that asks for `browse_network`, whatever the configured rules say. */
export const evaluate = (event: {
  readonly action: string
  readonly metadata?: Record<string, unknown>
  effect: string
  message?: string
}) =>
  Effect.sync(() => {
    if (!storesCredentials(event.action, event.metadata?.input)) return
    event.effect = "deny"
    event.message = refusal
  })

/**
 * The refusal the agent reads. A permission denial reaches it only as "Unable to execute browse_network", because the
 * MCP tool wrapper replaces every error that is not a tool failure; rejecting before the call keeps the reason.
 */
export const before = (event: { readonly tool: string; readonly input: unknown }) =>
  storesCredentials(event.tool, event.input) ? Effect.fail(new Tool.Error({ message: refusal })) : Effect.void

export const registerBrowseGuard = Effect.fn("BrowseGuard.register")(function* (ctx: Context) {
  yield* ctx.permission.hook("evaluate", evaluate)
  yield* ctx.tool.hook("execute.before", before)
})
