import path from "node:path"
import { androidSlim } from "../../catalog/slim.js"
import { avdName, serialOf, type AndroidLifecycle, type Image } from "../../../resources/adapters/android-lifecycle.js"
import { satisfies } from "../capabilities.js"
import type { Driver, Running } from "./pool.js"

/**
 * Emulators on the Mac (`docs/bancada.md`, "Android on the Mac"): an AVD per image and profile, created once with the
 * SDK's `avdmanager`; every boot from the clean snapshot (made on the first boot, after trimming), Wi-Fi off, the host
 * reachable at `10.0.2.2`; given back stopped, so the next boot is clean again.
 */
export function androidLocal(input: {
  readonly lifecycle: AndroidLifecycle
  readonly prefix: string
  /** The images installed for this machine's ABI (discovery). */
  readonly images: () => ReadonlyArray<Image>
  /** A free pair of console and adb ports, held for this device from now on (`pool.ts`). */
  readonly port: (device: string) => Promise<number>
  /** Where each emulator's output goes. */
  readonly logs: string
  readonly machine: () => string
  readonly log: (line: string) => void
}): Driver {
  const lifecycle = input.lifecycle
  return {
    kind: "android-emulador",
    choose: async (spec, profile) => {
      const fits = input
        .images()
        .filter(
          (image) =>
            (!spec.api || satisfies(String(image.api), spec.api)) &&
            (spec.googlePlay === undefined || image.tag.includes("playstore") === spec.googlePlay),
        )
      // Without Play services when the test does not ask for them (lighter), the newest API of those.
      const image = fits.toSorted(
        (a, b) =>
          Number(a.tag.includes("playstore")) - Number(b.tag.includes("playstore")) ||
          String(b.api).localeCompare(String(a.api), undefined, { numeric: true }),
      )[0]
      if (!image) return `nenhuma imagem Android instalada serve (${spec.api ?? "qualquer API"})`
      return {
        key: `android:${image.api}:${image.tag}:${image.abi}:${profile}`,
        spec: { ...image },
        name: (n) => avdName(input.prefix, image, profile, n),
      }
    },
    ready: async (device, slot) => {
      const image = device.spec as unknown as Image
      if (!(await lifecycle.exists(device.id))) await lifecycle.create(device.id, image)
      const console = await input.port(device.id)
      const serial = serialOf(console)
      const log = path.join(input.logs, `${device.id}.log`)
      const started = Date.now()
      const process = await lifecycle.boot(device.id, console, log)
      const run: Running = {
        serial,
        console,
        pid: process.pid,
        ...(process.started ? { started: process.started } : {}),
      }
      const stop = () => lifecycle.stop(device.id, serial, process.pid, process.started).catch(() => false)
      const snapshot = await lifecycle.fromSnapshot(log, 15_000)
      const loaded = Date.now()
      if (!(await lifecycle.booted(serial, snapshot ? 3 * 60_000 : 6 * 60_000))) {
        await stop()
        throw new Error(`${device.id} não terminou de ligar`)
      }
      // What booted on the port must be this AVD: one that lost the port to another emulator is ended by its pid.
      const runs = await lifecycle.name(serial)
      if (runs !== device.id) {
        await lifecycle.end(process.pid, process.started)
        throw new Error(`${serial} roda ${runs ?? "outro emulador"}, não ${device.id}: a porta não ficou com ele`)
      }
      // The first boot (or a snapshot that did not load): trimmed, then the clean snapshot every later boot starts from.
      if (!snapshot) {
        if (device.profile === "enxuto") {
          const missing = await lifecycle.slim(serial, androidSlim)
          if (missing.length) input.log(`${device.id}: not on this image, or not turned off: ${missing.join(" ")}`)
        }
        if (!(await lifecycle.save(serial)))
          input.log(`${device.id} did not keep its snapshot; it boots in full next time`)
      }
      const answered = Date.now()
      if (!(await lifecycle.deliver(serial))) {
        await stop()
        throw new Error(`${device.id} não alcança a máquina em 10.0.2.2`)
      }
      // Each stage apart: started (and the snapshot loaded), Android answered through adb, delivered.
      const seconds = (from: number, to: number) => Math.round((to - from) / 1000)
      input.log(
        `${device.id} ready in ${seconds(started, Date.now())} s (${snapshot ? "snapshot" : "first boot"}: ` +
          `${seconds(started, loaded)} s to start, ${seconds(loaded, answered)} s until adb answered, ` +
          `${seconds(answered, Date.now())} s to deliver)`,
      )
      return {
        run,
        view: {
          id: device.id,
          tipo: "android-emulador",
          plataforma: "android",
          serial,
          udid: null,
          adb: { host: "127.0.0.1", porta: 5037 },
          abi: image.abi,
          api: image.api,
          perfil: device.profile,
          portas: { inicio: slot.start, fim: slot.end },
          host: "10.0.2.2",
          maquina: input.machine(),
        },
      }
    },
    health: (_device, run) => lifecycle.health(run.serial!, run.pid!, run.started),
    giveBack: async (device, run) => {
      if (!run.serial || !run.pid) return
      const stopped = await lifecycle.stop(device.id, run.serial, run.pid, run.started).catch((error: unknown) => {
        // Its port answers another AVD: its own process, proven by pid and start time, is ended without the console.
        input.log(`${device.id}: ${error instanceof Error ? error.message : String(error)}; ending its own process`)
        return lifecycle.end(run.pid!, run.started)
      })
      if (!stopped) throw new Error(`${device.id} não desligou`)
    },
  }
}
