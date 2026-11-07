import { createHash } from "node:crypto"
import net from "node:net"
import os from "node:os"
import { text } from "./adapters/process.js"

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

/** `IOPlatformUUID` from `ioreg -rd1 -c IOPlatformExpertDevice` output. */
export function parsePlatformUUID(output: string) {
  return /"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]{36})"/.exec(output)?.[1]
}

/** The addresses other machines could reach this one on: every non-internal interface, minus IPv6 link-local. */
export function externalAddresses(interfaces = os.networkInterfaces()) {
  return Object.values(interfaces)
    .flatMap((list) => list ?? [])
    .filter((item) => !item.internal && !(item.family === "IPv6" && item.address.toLowerCase().startsWith("fe80")))
    .map((item) => item.address)
}

/** Whether something accepts TCP connections on `address:port` within `timeout`. */
export function accepts(address: string, port: number, timeout = 400) {
  return new Promise<boolean>((resolve) => {
    const socket = net.connect({ host: address, port })
    const done = (value: boolean) => {
      socket.destroy()
      resolve(value)
    }
    socket.setTimeout(timeout, () => done(false))
    socket.once("connect", () => done(true))
    socket.once("error", () => done(false))
  })
}

const loopbackHosts = new Set(["127.0.0.1", "localhost", "[::1]", "::1"])

/**
 * `handoff.machine` for a browse relay at `cdp`, or `undefined` when the hub cannot vouch that the tab's Chrome runs
 * on this Mac: the relay is not on loopback, it also accepts connections on an address other machines reach (browse's
 * `set hostname 0.0.0.0`), or this is no Mac. Read once per hub; the relay check runs per handoff.
 */
export function makeMachine(
  options: {
    readonly platformUUID?: () => Promise<string | undefined>
    readonly addresses?: () => readonly string[]
    readonly accepts?: (address: string, port: number) => Promise<boolean>
  } = {},
) {
  let uuid: Promise<string | undefined> | undefined
  const read =
    options.platformUUID ??
    (async () =>
      process.platform === "darwin"
        ? parsePlatformUUID(
            await text(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], { timeout: 3_000 }).catch(() => ""),
          )
        : undefined)
  return async (cdp: string | undefined) => {
    const url = cdp ? URL.parse(cdp) : null
    const port = Number(url?.port)
    if (!url || !loopbackHosts.has(url.hostname) || !Number.isInteger(port) || port <= 0) return undefined
    uuid ??= read().catch(() => undefined)
    const platform = await uuid
    if (!platform) return undefined
    const reachable = await Promise.all(
      (options.addresses ?? externalAddresses)().map((address) => (options.accepts ?? accepts)(address, port)),
    )
    return reachable.includes(true) ? undefined : machineID(platform)
  }
}
