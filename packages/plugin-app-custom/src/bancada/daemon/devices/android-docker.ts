import { emulatorScript } from "../../catalog/android-docker.js"
import { satisfies } from "../capabilities.js"
import type { Docker } from "../launcher/docker.js"
import type { Driver } from "./pool.js"

/**
 * Emulators in containers on host-6 (`docs/bancada.md`, "Android on host-6"): one container per emulator
 * (`<prefix>emu-<n>`, its AVD in the volume `<prefix>emu-<n>-avd`), in the mould of AbacatoV3's `up.sh`: KVM, the
 * emulators' network, no capabilities, limits, labels. Ready: booted, the radio service stopped, error dialogs hidden,
 * home screen; a new volume boots twice (the first boot's adb connection drops under load). Given back clean: the
 * third-party packages uninstalled and the container removed; the volume stays, so the next boot reuses the AVD.
 */
export function androidDocker(input: {
  readonly docker: Docker
  readonly adb: string
  readonly prefix: string
  readonly machineID: string
  readonly labels: ReadonlyArray<string>
  readonly image: string
  readonly network: string
  readonly cpus: number
  readonly memMb: number
  /** The address the device reaches the attempt's execution at, on the emulators' network. */
  readonly host: (key: { job: string; group: string }) => Promise<string | undefined>
  readonly machine: () => string
  readonly log: (line: string) => void
  readonly sleep?: (ms: number) => Promise<void>
}): Driver {
  const docker = input.docker
  const sleep = input.sleep ?? Bun.sleep
  const api = Number(/api-?(\d+)/i.exec(input.image)?.[1] ?? 0)
  const adb = (name: string, ...args: string[]) =>
    Bun.spawn([input.adb, "-H", name, "-P", "5037", "-s", "emulator-5554", ...args], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "ignore",
      timeout: 30_000,
    })
  const shell = async (name: string, ...args: string[]) => {
    const child = adb(name, ...args)
    const [out, code] = await Promise.all([new Response(child.stdout).text(), child.exited])
    return { code, out: out.replace(/\r/g, "") }
  }
  const kvm = { gid: undefined as string | undefined }
  const group = async () => {
    if (kvm.gid) return kvm.gid
    const found = await docker.run([
      "run",
      "--rm",
      "--device",
      "/dev/kvm",
      "--entrypoint",
      "stat",
      input.image,
      "-c",
      "%g",
      "/dev/kvm",
    ])
    if (found.code !== 0) throw new Error(`/dev/kvm não está disponível para os emuladores: ${found.stderr.trim()}`)
    kvm.gid = found.stdout.trim()
    return kvm.gid
  }
  const start = async (name: string) => {
    const volume = `${name}-avd`
    await docker.run(["rm", "-f", name])
    // A container that died with the emulator open leaves its locks in the volume.
    await docker.run([
      "run",
      "--rm",
      "--user",
      "1000:1000",
      "-v",
      `${volume}:/home/android/.android`,
      "--entrypoint",
      "bash",
      input.image,
      "-c",
      'find /home/android/.android -name "*.lock" -exec rm -rf {} + 2>/dev/null; true',
    ])
    const started = await docker.run(
      emulatorArgv({
        name,
        volume,
        image: input.image,
        network: input.network,
        gid: await group(),
        cpus: input.cpus,
        memMb: input.memMb,
        labels: [`bancada.device=${name}`, `bancada.machine=${input.machineID}`, ...input.labels],
      }),
    )
    if (started.code !== 0) throw new Error(`o contêiner de ${name} não partiu: ${started.stderr.trim()}`)
  }
  /** Booted, the radio stopped, dialogs hidden, and its network (Wi-Fi: the only one here) up to `host`. */
  const ready = async (name: string, host: string | undefined) => {
    const deadline = Date.now() + 8 * 60_000
    while (Date.now() < deadline) {
      if ((await shell(name, "shell", "getprop", "sys.boot_completed")).out.trim() === "1") break
      await sleep(3_000)
    }
    if ((await shell(name, "shell", "getprop", "sys.boot_completed")).out.trim() !== "1")
      throw new Error(`${name} não terminou de ligar`)
    await shell(name, "root")
    await sleep(3_000)
    await shell(name, "wait-for-device")
    await shell(
      name,
      "shell",
      "setprop ctl.stop vendor.radio-ranchu; settings put global hide_error_dialogs 1; am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null; input keyevent HOME",
    )
    // Wi-Fi stays on: in its container the emulator has no other network, and it comes up a while after the boot.
    const routed = Date.now() + 3 * 60_000
    while (Date.now() < routed) {
      if ((await shell(name, "shell", "ip", "route", "get", host ?? "10.0.2.2")).out.includes(" dev ")) return
      await sleep(3_000)
    }
    throw new Error(`${name} ligou sem rede`)
  }
  /** Third-party packages uninstalled, forwards and reverses gone: what a test left. */
  const clean = async (name: string) => {
    const listed = await shell(name, "shell", "pm", "list", "packages", "-3")
    for (const line of listed.out.split("\n").filter((item) => item.startsWith("package:")))
      await shell(name, "uninstall", line.slice("package:".length).trim())
    await shell(name, "forward", "--remove-all")
    await shell(name, "reverse", "--remove-all")
  }

  return {
    kind: "android-docker",
    choose: async (spec, profile) => {
      if (spec.api && !satisfies(String(api), spec.api)) return `a imagem ${input.image} não serve (${spec.api})`
      if (spec.googlePlay) return `a imagem ${input.image} não tem Google Play`
      return {
        key: `docker:${input.image}:${profile}`,
        spec: { image: input.image, api },
        name: (n) => `${input.prefix}emu-${n}`,
      }
    },
    ready: async (device, slot, key) => {
      const started = Date.now()
      const volume = `${device.id}-avd`
      const host = await input.host(key)
      const fresh = (await docker.run(["volume", "inspect", volume])).code !== 0
      if (fresh)
        await docker.run([
          "volume",
          "create",
          "--label",
          `bancada.machine=${input.machineID}`,
          ...input.labels.flatMap((label) => ["--label", label]),
          volume,
        ])
      await start(device.id)
      await ready(device.id, host)
      if (fresh) {
        await sleep(90_000)
        await shell(device.id, "emu", "kill")
        await sleep(10_000)
        await start(device.id)
        await ready(device.id, host)
      }
      await clean(device.id)
      input.log(`${device.id} ready in ${Math.round((Date.now() - started) / 1000)} s${fresh ? " (new volume)" : ""}`)
      return {
        run: { serial: "emulator-5554", container: device.id },
        view: {
          id: device.id,
          tipo: "android-emulador",
          plataforma: "android",
          serial: "emulator-5554",
          udid: null,
          adb: { host: device.id, porta: 5037 },
          abi: "x86_64",
          api,
          perfil: device.profile,
          portas: { inicio: slot.start, fim: slot.end },
          host: host ?? null,
          maquina: input.machine(),
        },
      }
    },
    health: async (device) => {
      const state = await docker.state(device.id)
      if (state === "unknown") return "mudo"
      if (state === "absent" || !state.running) return "morto"
      return (await shell(device.id, "shell", "getprop", "sys.boot_completed")).out.trim() === "1" ? "ok" : "mudo"
    },
    giveBack: async (device) => {
      const state = await docker.state(device.id)
      if (state !== "absent" && state !== "unknown" && state.running) await clean(device.id)
      await docker.run(["rm", "-f", device.id])
    },
  }
}

/** The `docker run` of an emulator's container (pure). */
export function emulatorArgv(input: {
  readonly name: string
  readonly volume: string
  readonly image: string
  readonly network: string
  readonly gid: string
  readonly cpus: number
  readonly memMb: number
  readonly labels: ReadonlyArray<string>
}) {
  return [
    "run",
    "-d",
    "--name",
    input.name,
    "--hostname",
    input.name,
    "--network",
    input.network,
    "--network-alias",
    input.name,
    "--device",
    "/dev/kvm",
    "--group-add",
    input.gid,
    "--user",
    "1000:1000",
    "--cap-drop",
    "ALL",
    "--security-opt",
    "no-new-privileges:true",
    "--cpus",
    String(input.cpus),
    "--memory",
    `${input.memMb}m`,
    "--shm-size",
    "1g",
    "--pids-limit",
    "1024",
    "--tmpfs",
    "/tmp:rw,nosuid,nodev,size=2g,mode=1777",
    "-v",
    `${input.volume}:/home/android/.android`,
    "-e",
    `BANCADA_AVD=${input.name}`,
    "-e",
    "ANDROID_EMULATOR_CORES=2",
    "-e",
    "ANDROID_EMULATOR_MEMORY_MB=2048",
    ...input.labels.flatMap((label) => ["--label", label]),
    "--entrypoint",
    "bash",
    input.image,
    "-c",
    emulatorScript,
  ]
}
