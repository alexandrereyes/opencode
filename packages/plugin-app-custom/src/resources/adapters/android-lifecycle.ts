import path from "node:path"

/**
 * The life of an Android emulator the Bancada owns on a Mac (`docs/bancada.md`, "Android on the Mac"): created with the
 * SDK's own `avdmanager`, started detached from its clean snapshot, made ready for a test, checked, and stopped only
 * after proving the serial runs that AVD. Every tool by absolute path (discovery), never the `PATH`.
 */

/** How the lifecycle reaches the machine; tests give a recorded one. */
export type Shell = {
  readonly run: (
    argv: ReadonlyArray<string>,
    options?: { readonly env?: Readonly<Record<string, string>>; readonly timeoutMs?: number; readonly stdin?: string },
  ) => Promise<{ readonly code: number; readonly stdout: string; readonly stderr: string }>
  /** Starts a long-lived process in a session of its own, its output to `log`: its pid and start time. */
  readonly detach: (
    argv: ReadonlyArray<string>,
    options: { readonly env?: Readonly<Record<string, string>>; readonly log: string },
  ) => Promise<{ readonly pid: number; readonly started?: string }>
  /** Whether that process (pid and start time) still runs; `unknown` is never `dead`. */
  readonly alive: (pid: number, started?: string) => Promise<"alive" | "dead" | "unknown">
  readonly signal: (pid: number, signal: "SIGTERM" | "SIGKILL") => void
  readonly read: (file: string) => Promise<string | undefined>
  readonly write: (file: string, text: string) => Promise<void>
  readonly remove: (file: string) => Promise<void>
  readonly sleep: (ms: number) => Promise<void>
  readonly now: () => number
}

export type AndroidPaths = {
  readonly sdk: string
  readonly adb: string
  readonly emulator: string
  readonly avdmanager?: string
  readonly javaHome?: string
  /** Where the AVDs live (`ANDROID_AVD_HOME`, else `~/.android/avd`). */
  readonly avdHome: string
}

export type Image = { readonly api: number | string; readonly tag: string; readonly abi: string }

/** The snapshot every boot starts from; never saved again after it was made. */
export const snapshot = "bancada-limpo"

/** The light profile (`config.ini`), the values of the machine's reference launcher of light emulators. */
export const profile: Readonly<Record<string, string>> = {
  "hw.gpu.enabled": "yes",
  "hw.gpu.mode": "host",
  "hw.cpu.ncore": "2",
  "hw.ramSize": "2048",
  "hw.lcd.width": "720",
  "hw.lcd.height": "1600",
  "hw.lcd.density": "280",
  "hw.lcd.vsync": "30",
}

/** `<prefix>a<api>-<tag>-<abi>-<profile>-<n>`: `bancada-a36-ga-arm64-enxuto-3`. */
export function avdName(prefix: string, image: Image, kind: "enxuto" | "estoque", n: number) {
  const tag = image.tag === "google_apis" ? "ga" : image.tag === "google_apis_playstore" ? "gp" : image.tag.slice(0, 6)
  const abi = image.abi === "arm64-v8a" ? "arm64" : image.abi === "x86_64" ? "x64" : image.abi
  return `${prefix}a${String(image.api).replace(/\W/g, "")}-${tag}-${abi}-${kind}-${n}`
}

/** `emulator-<adb port - 1>`: the console port names the serial. */
export function serialOf(console: number) {
  return `emulator-${console}`
}

export function makeAndroidLifecycle(shell: Shell, tools: AndroidPaths) {
  const adb = (serial: string, ...args: string[]) => [tools.adb, "-s", serial, ...args]
  const sdkEnv = {
    ANDROID_SDK_ROOT: tools.sdk,
    ANDROID_HOME: tools.sdk,
    ANDROID_AVD_HOME: tools.avdHome,
    ...(tools.javaHome ? { JAVA_HOME: tools.javaHome } : {}),
  }
  const config = (name: string) => path.join(tools.avdHome, `${name}.avd`, "config.ini")
  const shellOn = (serial: string, script: string, timeoutMs = 20_000) =>
    shell.run(adb(serial, "shell", script), { timeoutMs })

  return {
    /** Whether the AVD exists here (its descriptor). */
    exists: async (name: string) => (await shell.read(path.join(tools.avdHome, `${name}.ini`))) !== undefined,
    /**
     * Creates the AVD with the SDK's `avdmanager` (Java and the SDK passed in the call), then the light profile in
     * its `config.ini`. Throws with the tool's own words when it fails.
     */
    create: async (name: string, image: Image) => {
      if (!tools.avdmanager || !tools.javaHome)
        throw new Error("não consigo criar AVD: falta o avdmanager do SDK ou Java")
      const made = await shell.run(
        [
          tools.avdmanager,
          "create",
          "avd",
          "-n",
          name,
          "-k",
          `system-images;android-${image.api};${image.tag};${image.abi}`,
          "-d",
          "pixel_6",
        ],
        { env: sdkEnv, timeoutMs: 120_000, stdin: "no\n" },
      )
      if (made.code !== 0)
        throw new Error(`avdmanager não criou ${name}: ${(made.stderr || made.stdout).trim().split("\n").at(-1)}`)
      const text = (await shell.read(config(name))) ?? ""
      const kept = text.split("\n").filter((line) => line.trim() && !(line.split("=")[0]!.trim() in profile))
      await shell.write(
        config(name),
        [...kept, ...Object.entries(profile).map(([k, v]) => `${k}=${v}`)].join("\n") + "\n",
      )
    },
    /** Starts it detached on its two ports, from the clean snapshot when there is one, never saving on exit. */
    boot: (name: string, console: number, log: string) =>
      shell.detach(
        [
          tools.emulator,
          "-avd",
          name,
          "-ports",
          `${console},${console + 1}`,
          "-no-window",
          "-no-audio",
          "-no-boot-anim",
          "-no-metrics",
          "-camera-back",
          "none",
          "-camera-front",
          "none",
          "-gpu",
          "host",
          "-cores",
          "2",
          "-memory",
          "2048",
          "-snapshot",
          snapshot,
          "-no-snapshot-save",
        ],
        { env: sdkEnv, log },
      ),
    /** Whether the boot came from the clean snapshot: the emulator says so in its output within `waitMs`. */
    fromSnapshot: async (log: string, waitMs: number) => {
      const deadline = shell.now() + waitMs
      while (shell.now() < deadline) {
        if (((await shell.read(log)) ?? "").includes(`Successfully loaded snapshot '${snapshot}'`)) return true
        await shell.sleep(500)
      }
      return false
    },
    /** Until Android finished booting and its package manager answers, or `timeoutMs`. */
    booted: async (serial: string, timeoutMs: number) => {
      const deadline = shell.now() + timeoutMs
      while (shell.now() < deadline) {
        const done = await shellOn(serial, "getprop sys.boot_completed", 5_000)
        if (done.code === 0 && done.stdout.trim() === "1") {
          const pm = await shellOn(serial, "pm path android", 10_000)
          if (pm.code === 0 && pm.stdout.includes("package:")) return true
        }
        await shell.sleep(2_000)
      }
      return false
    },
    /**
     * The trimmed profile (`catalog/android-enxuto.ts`): each package off for the user, each setting put. What is
     * not on the image is returned, to be taken off the list.
     */
    slim: async (serial: string, lines: ReadonlyArray<readonly [string, string, string]>) => {
      const script = lines
        .map(([what, name, value]) =>
          what === "package"
            ? `pm path ${name} >/dev/null 2>&1 && pm disable-user --user 0 ${name} >/dev/null || echo ${name}`
            : `settings put ${what} ${name} ${value}`,
        )
        .join("\n")
      const done = await shellOn(serial, script, 120_000)
      return done.stdout.split(/\s+/).filter(Boolean)
    },
    /** Saves the clean snapshot; true when the console said `OK`. */
    save: async (serial: string) => {
      const saved = await shell.run(adb(serial, "emu", "avd", "snapshot", "save", snapshot), { timeoutMs: 120_000 })
      return saved.stdout.split(/\r?\n/).some((line) => line.trim() === "OK")
    },
    /**
     * Each delivery: Wi-Fi off, the forwards and reverses of that serial gone, old `nc` ended, and the host reachable
     * at `10.0.2.2` (the adb server's port answers there). False when the host is not reachable.
     */
    deliver: async (serial: string) => {
      await shellOn(serial, "svc wifi disable")
      await shell.run(adb(serial, "forward", "--remove-all"), { timeoutMs: 10_000 })
      await shell.run(adb(serial, "reverse", "--remove-all"), { timeoutMs: 10_000 })
      await shellOn(serial, "pkill -x nc; true")
      // Without Wi-Fi the emulator reaches the Mac by the network that is its alone (eth0), which takes a moment to
      // carry the route (AbacatoV3's `reaches_the_mac`): on Wi-Fi, emulators sometimes share an address.
      const deadline = shell.now() + 60_000
      while (shell.now() < deadline) {
        const route = await shellOn(serial, "ip route get 10.0.2.2", 5_000)
        if (route.stdout.includes("dev eth0")) {
          // The Mac's adb server answers there: a connect alone proves nothing through the emulator's NAT.
          const reach = await shellOn(serial, "printf 000chost:version | toybox nc -q 2 -w 3 10.0.2.2 5037")
          if (reach.stdout.startsWith("OKAY")) return true
        }
        await shell.sleep(2_000)
      }
      return false
    },
    /** The AVD a serial runs now (`emu avd name`), or undefined when it does not answer. */
    identity: async (serial: string) => {
      const named = await shell.run(adb(serial, "emu", "avd", "name"), { timeoutMs: 10_000 })
      return named.code === 0 ? named.stdout.split(/\r?\n/)[0]?.trim() || undefined : undefined
    },
    /**
     * `ok`, `morto` (the emulator's process is gone) or `mudo` (alive, Android does not answer). The process is known
     * by its pid and start time: a reused pid is not ours.
     */
    health: async (serial: string, pid: number, started?: string) => {
      const life = await shell.alive(pid, started)
      if (life === "dead") return "morto" as const
      const done = await shellOn(serial, "getprop sys.boot_completed", 5_000)
      return done.code === 0 && done.stdout.trim() === "1" ? ("ok" as const) : ("mudo" as const)
    },
    /**
     * Stops it, only after proving the serial runs `name` (or that its own process is the one recorded): the console's
     * `kill`, then the process by its pid and start time if it lingers. True once it is gone.
     */
    stop: async (name: string, serial: string, pid: number, started?: string) => {
      const life = await shell.alive(pid, started)
      if (life === "dead") return true
      const runs = await adbIdentity(shell, adb(serial, "emu", "avd", "name"))
      if (runs !== undefined && runs !== name) throw new Error(`${serial} roda ${runs}, não ${name}: não desligo`)
      if (runs === name) await shell.run(adb(serial, "emu", "kill"), { timeoutMs: 10_000 })
      return end(pid, started, false)
    },
    /** The AVD the emulator on `serial` runs, as its console says; undefined when it does not answer. */
    name: (serial: string) => adbIdentity(shell, adb(serial, "emu", "avd", "name")),
    /**
     * Ends the emulator process this lifecycle started (its pid and start time are the proof), whatever its port
     * answers: one that lost its port to another never had a console of its own.
     */
    end: (pid: number, started?: string) => end(pid, started, true),
    /** Deletes the AVD (its files), when the Bancada recreates or retires it. */
    destroy: async (name: string) => {
      await shell.remove(path.join(tools.avdHome, `${name}.avd`))
      await shell.remove(path.join(tools.avdHome, `${name}.ini`))
    },
  }

  /** The recorded process until it is gone (TERM at once when `term`, else after its console's `kill`; then KILL). */
  async function end(pid: number, started: string | undefined, term: boolean) {
    if (term && (await shell.alive(pid, started)) === "alive") shell.signal(pid, "SIGTERM")
    for (const wait of [20_000, 10_000]) {
      const deadline = shell.now() + wait
      while (shell.now() < deadline) {
        if ((await shell.alive(pid, started)) === "dead") return true
        await shell.sleep(1_000)
      }
      // Still there (the console did not answer): the recorded process itself, which is proof enough.
      if ((await shell.alive(pid, started)) === "alive") shell.signal(pid, wait === 20_000 ? "SIGTERM" : "SIGKILL")
    }
    return (await shell.alive(pid, started)) === "dead"
  }
}

export type AndroidLifecycle = ReturnType<typeof makeAndroidLifecycle>

async function adbIdentity(shell: Shell, argv: ReadonlyArray<string>) {
  const named = await shell.run(argv, { timeoutMs: 10_000 })
  return named.code === 0 ? named.stdout.split(/\r?\n/)[0]?.trim() || undefined : undefined
}
