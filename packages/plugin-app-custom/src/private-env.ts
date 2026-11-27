/**
 * Server-only settings and MyCredentials values loaded by `OPENCODE_PRIVATE_ENV_COMMAND` at startup
 * (`@opencode/util/private-env`), outside `process.env` so agent shells and other children never inherit them.
 * The host keeps them in a `Map` under this registry symbol, shared with this separately built plugin.
 */
export function privateEnv(name: string) {
  const store = (globalThis as { [key: symbol]: unknown })[Symbol.for("opencode.private-env")]
  return store instanceof Map ? (store.get(name) as string | undefined) : undefined
}
