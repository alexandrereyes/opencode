/**
 * Secrets the server sealed out of `process.env` (`@opencode/util/private-env`): `bin/serve` fetches them from
 * MyCredentials and lists them in `OPENCODE_PRIVATE_ENV`, so agent shells and other children never inherit them.
 * The host keeps them in a `Map` under this registry symbol, shared with this separately built plugin.
 */
export function privateEnv(name: string) {
  const store = (globalThis as { [key: symbol]: unknown })[Symbol.for("opencode.private-env")]
  return store instanceof Map ? (store.get(name) as string | undefined) : undefined
}
