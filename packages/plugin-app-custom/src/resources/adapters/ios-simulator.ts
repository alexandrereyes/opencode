import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { run, size, text } from "./process.js"
import {
  acquire,
  makeTranslator,
  recover,
  rotation,
  typeable,
  withHelper,
  type Config,
  type Helper,
} from "./serve-sim.js"
import type { Adapter, Entry, Probe, StreamSink } from "./types.js"

/**
 * iOS Simulator. Liveness through `simctl list` and snapshots through `simctl io screenshot`; the live stream and
 * input go through serve-sim (`serve-sim.ts`): IOSurface MJPEG and SimulatorKit HID. All of them work headless,
 * with the Mac locked and no Simulator window. See `docs/resources-ios-simulator.md`.
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
  async stream(entry, sink, signal) {
    const udid = udidOf(entry)
    const lease = await acquire(udid)
    const stop = lease.helper.onConfig((config) => sink.meta(orientationMeta(config)))
    // Video keeps flowing while serve-sim's input socket reconnects; say so instead of failing touches silently.
    const stopInput = lease.helper.onInput((available) =>
      sink.notice?.(
        available ? "Controle do simulador restabelecido." : "Controle do simulador indisponível; reconectando…",
      ),
    )
    return relay(lease.helper, sink, signal).finally(() => {
      stop()
      stopInput()
      // Nobody watches any more: lift a finger whose end will never come.
      if (lease.helper.inputAvailable())
        translator(udid, lease.helper)
          .lift()
          .forEach(([tag, body]) => lease.helper.send(tag, body))
      lease.release()
    })
  },
  async input(entry, event) {
    const udid = udidOf(entry)
    // Input arrives while the viewer streams, so this reuses the stream's helper.
    await withHelper(udid, async (helper) => {
      if (event.type === "text" && !typeable(event.text)) return helper.paste(event.text)
      translator(udid, helper)
        .translate(event, helper.config())
        .forEach(([tag, body]) => helper.send(tag, body))
    })
  },
  recover: () => recover(),
}

const translators = new Map<string, { generation: number; translator: ReturnType<typeof makeTranslator> }>()

/** The simulator's gesture state, fresh whenever serve-sim's input socket was readmitted (it lifted every finger). */
function translator(udid: string, helper: Helper) {
  const current = translators.get(udid)
  if (current && current.generation === helper.inputGeneration()) return current.translator
  const fresh = { generation: helper.inputGeneration(), translator: makeTranslator() }
  translators.set(udid, fresh)
  return fresh.translator
}

function udidOf(entry: Entry) {
  if (entry.meta.kind !== "ios-simulator") throw new Error("Not an iOS simulator")
  return entry.meta.udid
}

/** `rotation`: clockwise degrees the viewer turns frames; touch coordinates stay in the unrotated frame. */
function orientationMeta(config: Config) {
  return { orientation: config.orientation, rotation: rotation(config) }
}

/**
 * Forwards JPEG frames, announcing their size again when it changes (an `economy` profile shrinks them). serve-sim repeats the last frame at 5 fps while
 * the screen is still; repeats are dropped, so a still screen costs nothing between viewers and the hub (it caches the
 * last frame for viewers that join, and its own heartbeat keeps them alive).
 */
export async function relay(helper: Helper, sink: StreamSink, signal: AbortSignal) {
  const announced = { width: 0, height: 0 }
  const config = helper.config()
  if (config) sink.meta(orientationMeta(config))
  let last: Buffer | undefined
  for await (const part of helper.frames(signal)) {
    // serve-sim repeats frames at 5 fps even when still, so a profile change applies within 200 ms.
    void helper.profile(sink.profile?.() ?? "standard")
    const jpeg = Buffer.from(part.jpeg.buffer, part.jpeg.byteOffset, part.jpeg.byteLength)
    if (last?.equals(jpeg)) continue
    last = jpeg
    const dimensions = size(part.jpeg)
    if (dimensions && (dimensions.width !== announced.width || dimensions.height !== announced.height)) {
      Object.assign(announced, dimensions)
      sink.hello({ format: "jpeg", width: dimensions.width, height: dimensions.height })
      const current = helper.config()
      if (current) sink.meta(orientationMeta(current))
    }
    sink.frame(part.jpeg, { capturedAt: part.receivedAt })
  }
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
