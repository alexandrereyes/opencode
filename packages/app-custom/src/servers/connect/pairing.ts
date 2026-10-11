import { Option, Schema } from "effect"
import { isUnauthorizedError, OpenCode } from "@opencode/client/promise"
import { checkServerHealth } from "@/runtime/server/health"
import { normalizeServerUrl } from "@/runtime/server/registry"

const pairing = Schema.fromJsonString(
  Schema.Struct({
    urls: Schema.optional(Schema.Array(Schema.String)),
    username: Schema.Literal("opencode"),
    password: Schema.String,
  }),
)

export function serverAddress(value: string) {
  if (value.includes("://") && !/^https?:\/\//.test(value.trim())) return
  const normalized = normalizeServerUrl(value)
  if (!normalized || !URL.canParse(normalized)) return
  const url = new URL(normalized)
  if (url.protocol !== "http:" && url.protocol !== "https:") return
  if (url.username || url.password || url.search || url.hash) return
  return normalized
}

export function decodePairingCode(value: string, origin?: string) {
  const result = Schema.decodeUnknownOption(pairing)(value)
  if (Option.isNone(result)) return
  const urls = [
    ...new Set((result.value.urls ?? (origin ? [origin] : [])).map(serverAddress).filter((url) => url !== undefined)),
  ]
  if (!urls.length) return
  return { urls, password: result.value.password }
}

// Scanned codes are either raw pairing JSON or a full /connect URL.
export function decodePairingScan(value: string) {
  const url = URL.parse(value.trim())
  if (!url || (url.protocol !== "http:" && url.protocol !== "https:")) return decodePairingCode(value)
  return decodePairingUrl(url.search, url.origin) ?? decodePairingUrl(url.hash, url.origin)
}

export function decodePairingUrl(value: string, origin?: string) {
  if (value.startsWith("?")) {
    const data = new URLSearchParams(value).get("data")
    return data === null ? undefined : decodePairingCode(data, origin)
  }
  const encoded = value.startsWith("#") ? value.slice(1) : value
  if (!encoded) return
  const legacy = new URLSearchParams(`value=${encoded}`).get("value") ?? ""
  if (legacy.startsWith("{")) return decodePairingCode(legacy)
  if (!/^[A-Za-z0-9_-]+$/.test(encoded) || encoded.length % 4 === 1) return
  const binary = atob(
    encoded
      .replaceAll("-", "+")
      .replaceAll("_", "/")
      .padEnd(Math.ceil(encoded.length / 4) * 4, "="),
  )
  return decodePairingCode(new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0))), origin)
}

const CODE = /^[A-Za-z0-9_-]+$/

const decodeLinkPayload = Schema.decodeUnknownOption(
  Schema.fromJsonString(Schema.Struct({ code: Schema.String, urls: Schema.Array(Schema.String) })),
)

// `opencode pair` prints links carrying a single-use code that the server exchanges for a session token.
// Its QR code carries the same code with every reachable server address as {"code","urls"} JSON.
export function pairingLink(value: string) {
  const trimmed = value.trim()
  if (trimmed.startsWith("{")) {
    const payload = Option.getOrUndefined(decodeLinkPayload(trimmed))
    if (!payload || !CODE.test(payload.code)) return
    const urls = [...new Set(payload.urls)].map(serverAddress)
    if (urls.length === 0 || urls.some((url) => url === undefined)) return
    return { urls: urls.filter((url) => url !== undefined), code: payload.code }
  }
  const url = URL.parse(trimmed)
  if (!url || (url.protocol !== "http:" && url.protocol !== "https:")) return
  const code = /^\/auth\/connect\/([^/]+)$/.exec(url.pathname)?.[1]
  const address = serverAddress(url.origin)
  if (!code || !CODE.test(code) || !address) return
  return { urls: [address], code }
}

export type PairingLink = NonNullable<ReturnType<typeof pairingLink>>

// The custom result shape, shared with the credential decoders: the server addresses and the password or token.
export type Pairing = { readonly urls: string[]; readonly password: string }

export type Redeemed =
  | { readonly type: "paired"; readonly pairing: Pairing }
  | { readonly type: "expired" }
  | { readonly type: "unreachable" }

// Every address may reach the same server, but the code is single-use, so at most one attempt succeeds.
export function redeemPairingLink(link: PairingLink, fetch = globalThis.fetch): Promise<Redeemed> {
  const attempts = link.urls.map((url) =>
    OpenCode.make({ baseUrl: url, fetch })
      .server.connect({ code: link.code }, { signal: AbortSignal.timeout(5_000) })
      .then((session) => ({ url, password: session.token })),
  )
  // Whether the first address answered at all: a 401 there means another address spent the code first.
  const first = attempts[0]?.then(
    () => true,
    (error) => isUnauthorizedError(error),
  )
  return Promise.any(attempts)
    .then((pairing) => preferFirst(link.urls, pairing, first, fetch))
    .then(
      (pairing): Redeemed => ({ type: "paired", pairing: { urls: [pairing.url], password: pairing.password } }),
      // Only a server's answer proves the code is spent; addresses that could not be reached leave it valid.
      (error): Redeemed =>
        error instanceof AggregateError && error.errors.some(isUnauthorizedError)
          ? { type: "expired" }
          : { type: "unreachable" },
    )
}

// The token works on every address of the server, so keep the first one the pairing code lists when it answers, even if
// a nearer address answered sooner: a local network address stops working away from that network. An address that has
// not answered within a second, such as a local one seen from elsewhere, is not waited for.
async function preferFirst(
  urls: ReadonlyArray<string>,
  pairing: { url: string; password: string },
  answered: Promise<boolean> | undefined,
  fetch: typeof globalThis.fetch,
) {
  const first = urls[0]
  if (!first || first === pairing.url || !answered) return pairing
  const reachable = await Promise.race([
    answered,
    new Promise<false>((resolve) => setTimeout(() => resolve(false), 1_000)),
  ])
  if (!reachable) return pairing
  const http = { url: first, password: pairing.password }
  const health = await checkServerHealth(http, fetch, { signal: AbortSignal.timeout(5_000), retryCount: 0 })
  return health.healthy ? http : pairing
}
