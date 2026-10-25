import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { run, size } from "./process.js"
import type { Adapter, Probe } from "./types.js"

/**
 * Android Emulator. Foundation stub: liveness from the emulator's `avd/running/pid_*.ini` files (console and gRPC
 * ports, AVD name) and snapshots through `adb exec-out screencap`. The live stream and input (serve-emu H.264 or
 * gRPC `streamScreenshot` + `sendTouch`/`sendKey`) belong to the `resources-android` work.
 */
export const adapter: Adapter = {
  kind: "android-emulator",
  async probe(entries) {
    const running = await emulators()
    return new Map(
      await Promise.all(
        entries.flatMap((entry) => {
          if (entry.meta.kind !== "android-emulator") return []
          const meta = entry.meta
          const found = running.find(
            (item) => (meta.serial && item.serial === meta.serial) || (meta.avd && item.avd === meta.avd),
          )
          if (found)
            return [
              Promise.resolve<[string, Probe]>([
                entry.id,
                {
                  status: "running",
                  meta: {
                    ...meta,
                    serial: found.serial,
                    consolePort: found.consolePort,
                    ...(found.avd ? { avd: found.avd } : {}),
                    ...(found.grpcPort ? { grpcPort: found.grpcPort } : {}),
                    ...(found.device ? { device: found.device } : {}),
                  },
                },
              ]),
            ]
          return [
            avdExists(meta.avd).then((exists): [string, Probe] => [entry.id, { status: exists ? "stopped" : "gone" }]),
          ]
        }),
      ),
    )
  },
  async snapshot(entry) {
    if (entry.meta.kind !== "android-emulator" || !entry.meta.serial) throw new Error("Emulator is not attached to adb")
    const data = await run([adb(), "-s", entry.meta.serial, "exec-out", "screencap", "-p"])
    return { mime: "image/png", data, ...size(data) }
  },
}

export type RunningEmulator = {
  readonly pid: number
  readonly serial: string
  readonly consolePort: number
  readonly grpcPort?: number
  readonly avd?: string
  readonly device?: string
}

export function adb() {
  const sdk = process.env.ANDROID_HOME ?? process.env.ANDROID_SDK_ROOT ?? path.join(os.homedir(), "Library/Android/sdk")
  return Bun.which("adb") ?? path.join(sdk, "platform-tools/adb")
}

/** Emulators whose process is alive, from the files each one writes while running. */
export async function emulators(): Promise<RunningEmulator[]> {
  const directories = [
    path.join(os.homedir(), ".android/avd/running"),
    path.join(os.homedir(), "Library/Caches/TemporaryItems/avd/running"),
    path.join(os.tmpdir(), "avd/running"),
  ]
  const files = (
    await Promise.all(
      directories.map((directory) =>
        fs
          .readdir(directory)
          .then((names) =>
            names.filter((name) => /^pid_\d+\.ini$/.test(name)).map((name) => path.join(directory, name)),
          )
          .catch(() => []),
      ),
    )
  ).flat()
  const parsed = await Promise.all(files.map((file) => fs.readFile(file, "utf8").then(parseRunning, () => undefined)))
  const alive = parsed.filter((item): item is RunningEmulator => item !== undefined && isAlive(item.pid))
  return Promise.all(
    alive.map(async (item) => ({ ...item, device: item.avd ? await deviceName(item.avd) : undefined })),
  )
}

export function parseRunning(content: string): RunningEmulator | undefined {
  const values = new Map(
    content.split("\n").flatMap((line) => {
      const index = line.indexOf("=")
      return index > 0 ? [[line.slice(0, index).trim(), line.slice(index + 1).trim()] as const] : []
    }),
  )
  const pid = Number(values.get("pid") ?? Number.NaN)
  const consolePort = Number(values.get("port.serial") ?? Number.NaN)
  if (!Number.isInteger(consolePort)) return undefined
  const grpcPort = Number(values.get("grpc.port") ?? Number.NaN)
  return {
    pid: Number.isInteger(pid) ? pid : 0,
    serial: `emulator-${consolePort}`,
    consolePort,
    ...(Number.isInteger(grpcPort) ? { grpcPort } : {}),
    ...(values.get("avd.name") ? { avd: values.get("avd.name") } : {}),
  }
}

function isAlive(pid: number) {
  if (pid <= 0) return true
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

async function avdExists(avd: string | undefined) {
  if (!avd) return false
  return fs.stat(path.join(os.homedir(), ".android/avd", `${avd}.avd`)).then(
    () => true,
    () => false,
  )
}

async function deviceName(avd: string) {
  const config = await fs
    .readFile(path.join(os.homedir(), ".android/avd", `${avd}.avd`, "config.ini"), "utf8")
    .catch(() => "")
  const name = /^hw\.device\.name\s*=\s*(.+)$/m.exec(config)?.[1]?.trim()
  return name ? name.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase()) : undefined
}
