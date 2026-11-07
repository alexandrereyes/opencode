import { createHash } from "node:crypto"

/**
 * The machine identity of `browse-handoff-remoto.md` ("Abrir no Chrome"): a domain-separated SHA-256 of the Mac's
 * `IOPlatformUUID`, lowercase hex. The Mac app computes the same from its own `IOPlatformUUID`; the raw hardware UUID
 * never leaves the machine.
 */
export const machinePrefix = "opencode-browse-machine/v1\u0000"

export function machineID(platformUUID: string) {
  return createHash("sha256")
    .update(machinePrefix + platformUUID.trim().toUpperCase())
    .digest("hex")
}
