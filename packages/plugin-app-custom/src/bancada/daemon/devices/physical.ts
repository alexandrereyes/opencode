import type { Phone } from "../../machine-config.js"

/**
 * The phones of this machine's catalog as they are connected now (`docs/bancada.md`, "Phones"): an Android phone by USB
 * is its own serial; one by Wi-Fi is found by its `ro.serialno` behind whatever `ip:porta` (or mDNS name) adb has for
 * it, and reconnected through its mDNS announcement when asked; an iPhone by its UDID in `devicectl`. Read only: the
 * Bancada never clears, uninstalls, restarts or sends anything on a phone.
 */

export type Run = (
  argv: ReadonlyArray<string>,
  timeoutMs: number,
) => Promise<{ readonly code: number; readonly stdout: string } | undefined>

export function makePhones(input: {
  readonly phones: () => ReadonlyArray<Phone>
  /** The SDK's adb, by absolute path (discovery); without it no Android phone is seen. */
  readonly adb: () => string | undefined
  /** On a Mac: `xcrun devicectl` lists the iPhones. */
  readonly ios: boolean
  readonly run: Run
}) {
  /** The current serials of each phone, by alias; empty when it is not connected. */
  const current = new Map<string, ReadonlyArray<string>>()
  /** `ro.serialno` behind each `ip:porta` seen, so a Wi-Fi phone is asked once per address. */
  const behind = new Map<string, string>()

  const adbOut = async (args: string[], timeoutMs = 10_000) => {
    const adb = input.adb()
    if (!adb) return undefined
    const done = await input.run([adb, ...args], timeoutMs)
    return done?.code === 0 ? done.stdout : undefined
  }
  const listed = async () =>
    ((await adbOut(["devices"])) ?? "")
      .split("\n")
      .slice(1)
      .filter((line) => line.endsWith("\tdevice"))
      .map((line) => line.split("\t")[0]!)

  /** A Wi-Fi phone's serials now: the `ip:porta` first (a name with a space breaks Appium), mDNS names after. */
  const wifi = async (phone: Phone, serials: ReadonlyArray<string>) => {
    const found: string[] = []
    for (const serial of serials) {
      if (serial.toLowerCase().includes(phone.id.toLowerCase())) {
        found.push(serial)
        continue
      }
      const at = serial.lastIndexOf(":")
      if (at < 0 || !/^\d+$/.test(serial.slice(at + 1)) || !/^[\d.]+$/.test(serial.slice(0, at))) continue
      if (!behind.has(serial))
        behind.set(serial, ((await adbOut(["-s", serial, "shell", "getprop", "ro.serialno"], 5_000)) ?? "").trim())
      if (behind.get(serial)?.toLowerCase() === phone.id.toLowerCase()) found.push(serial)
    }
    return found.toSorted(
      (a, b) =>
        Number(a.includes(" ") || a.includes("._adb")) - Number(b.includes(" ") || b.includes("._adb")) ||
        a.localeCompare(b),
    )
  }

  /** `adb connect` to the phone's `_adb-tls-connect` announcement (its port changes when it restarts). */
  const reconnect = async (phone: Phone) => {
    const services = (await adbOut(["mdns", "services"])) ?? ""
    for (const line of services.split("\n")) {
      const parts = line.split("\t")
      if (
        parts.length >= 3 &&
        parts[1]!.includes("_adb-tls-connect") &&
        parts[0]!.toLowerCase().includes(phone.id.toLowerCase())
      )
        await adbOut(["connect", parts[2]!.trim()], 15_000)
    }
  }

  const refresh = async (options: { readonly reconnect?: ReadonlyArray<string> } = {}) => {
    const phones = input.phones().filter((phone) => phone.policy !== "negar")
    const android = phones.filter((phone) => phone.platform === "android")
    const ios = phones.filter((phone) => phone.platform === "ios")
    if (android.length) {
      // The addresses of phones gone (another `ip:porta` now) are forgotten.
      const serials = await listed()
      ;[...behind.keys()].filter((serial) => !serials.includes(serial)).forEach((serial) => behind.delete(serial))
      for (const phone of android) {
        if (phone.transport === "usb") {
          current.set(phone.alias, serials.includes(phone.id) ? [phone.id] : [])
          continue
        }
        const found = await wifi(phone, serials)
        if ((found.length === 0 || found[0]!.includes(" ")) && options.reconnect?.includes(phone.alias)) {
          await reconnect(phone)
          current.set(phone.alias, await wifi(phone, await listed()))
          continue
        }
        current.set(phone.alias, found)
      }
    }
    if (ios.length && input.ios) {
      const devices = (await input.run(["/usr/bin/xcrun", "devicectl", "list", "devices"], 30_000))?.stdout ?? ""
      for (const phone of ios) {
        const line = devices.split("\n").find((item) => item.split(/\s+/).includes(phone.id))
        current.set(phone.alias, line && /\b(connected|available)\b/.test(line) ? [phone.id] : [])
      }
    }
  }

  return {
    refresh,
    /** The serial to use now (`adb -s`, or the UDID), when connected. */
    serial: (alias: string) => current.get(alias)?.[0],
    /** Every serial a phone has now: what a command may cite it by. */
    serials: (alias: string) => current.get(alias) ?? [],
    connected: (alias: string) => (current.get(alias)?.length ?? 0) > 0,
  }
}

export type Phones = ReturnType<typeof makePhones>
