import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { run, size, text } from "./process.js"
import type { Adapter, Probe } from "./types.js"

/**
 * iOS Simulator. Foundation stub: liveness through `simctl list` and snapshots through `simctl io screenshot`
 * (both work headless, with the Mac locked and no Simulator window). The live stream and input (serve-sim from
 * Expo Device Hub, IOSurface + HID) belong to the `resources-ios-sim` work.
 */
export const adapter: Adapter = {
  kind: "ios-simulator",
  async probe(entries) {
    const devices = await list()
    return new Map(
      entries.flatMap((entry): [string, Probe][] => {
        if (entry.meta.kind !== "ios-simulator") return []
        const device = devices.get(entry.meta.udid)
        if (!device) return [[entry.id, { status: "gone" }]]
        return [
          [
            entry.id,
            {
              status: device.state === "Booted" ? "running" : "stopped",
              meta: { ...entry.meta, name: device.name, device: device.device, runtime: device.runtime },
            },
          ],
        ]
      }),
    )
  },
  async snapshot(entry) {
    if (entry.meta.kind !== "ios-simulator") throw new Error("Not an iOS simulator")
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), "opencode-simulator-"))
    try {
      const file = path.join(directory, "screen.jpg")
      await run(["xcrun", "simctl", "io", entry.meta.udid, "screenshot", "--type=jpeg", file])
      const data = new Uint8Array(await Bun.file(file).arrayBuffer())
      return { mime: "image/jpeg", data, ...size(data) }
    } finally {
      await fs.rm(directory, { recursive: true, force: true })
    }
  },
}

export type SimulatorDevice = {
  readonly udid: string
  readonly name: string
  readonly state: string
  readonly device?: string
  readonly runtime?: string
}

/** Every simulator known to CoreSimulator, by UDID. */
export async function list(): Promise<ReadonlyMap<string, SimulatorDevice>> {
  const output: unknown = JSON.parse(await text(["xcrun", "simctl", "list", "devices", "-j"]))
  return new Map(parse(output).map((device) => [device.udid, device]))
}

export function parse(output: unknown): SimulatorDevice[] {
  if (typeof output !== "object" || output === null || !("devices" in output)) return []
  const groups = output.devices
  if (typeof groups !== "object" || groups === null) return []
  return Object.entries(groups).flatMap(([runtime, devices]) =>
    Array.isArray(devices)
      ? devices.flatMap((device: unknown): SimulatorDevice[] => {
          if (typeof device !== "object" || device === null) return []
          const record = device as Record<string, unknown>
          if (typeof record.udid !== "string" || typeof record.name !== "string") return []
          return [
            {
              udid: record.udid,
              name: record.name,
              state: typeof record.state === "string" ? record.state : "Unknown",
              device: deviceName(record.deviceTypeIdentifier),
              runtime: runtimeName(runtime),
            },
          ]
        })
      : [],
  )
}

function deviceName(identifier: unknown) {
  if (typeof identifier !== "string") return undefined
  return identifier.replace(/^com\.apple\.CoreSimulator\.SimDeviceType\./, "").replaceAll("-", " ")
}

function runtimeName(identifier: string) {
  const match = /SimRuntime\.([A-Za-z]+)-(\d+)-(\d+)/.exec(identifier)
  return match ? `${match[1]} ${match[2]}.${match[3]}` : undefined
}
