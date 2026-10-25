import { createHmac, timingSafeEqual } from "node:crypto"
import type { Resources } from "../rpc.js"

export interface Claims {
  /** Resource ID. */
  readonly r: string
  readonly c: Resources.Capability
  /** Expiry, epoch milliseconds. */
  readonly e: number
  /** Control tickets carry the lock token they were issued for. */
  readonly l?: string
}

/** `<base64url JSON claims>.<base64url HMAC-SHA256>`, signed with the hub secret. */
export function sign(secret: string, claims: Claims) {
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url")
  return `${payload}.${mac(secret, payload)}`
}

export function verify(secret: string, ticket: string, id: string, now: number): Claims | undefined {
  const [payload, signature, extra] = ticket.split(".")
  if (!payload || !signature || extra !== undefined) return undefined
  const expected = Buffer.from(mac(secret, payload))
  const given = Buffer.from(signature)
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return undefined
  const claims: unknown = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"))
  if (typeof claims !== "object" || claims === null) return undefined
  const value = claims as Record<string, unknown>
  if (value.r !== id || typeof value.e !== "number" || value.e < now) return undefined
  if (value.c !== "view" && value.c !== "control") return undefined
  return { r: value.r, c: value.c, e: value.e, ...(typeof value.l === "string" ? { l: value.l } : {}) }
}

function mac(secret: string, payload: string) {
  return createHmac("sha256", secret).update(payload).digest("base64url")
}
