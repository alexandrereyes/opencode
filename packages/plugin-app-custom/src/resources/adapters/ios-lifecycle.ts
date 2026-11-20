import type { Shell } from "./android-lifecycle.js"

/**
 * The life of an iOS simulator the Bancada owns (`docs/bancada.md`, "iOS"): created with `simctl`, started trimmed by
 * `simslim` (or as it comes), checked, and given back shut down and erased, only after proving the UDID is the
 * simulator of that name.
 */

const xcrun = "/usr/bin/xcrun"

type Listed = { readonly udid: string; readonly name: string; readonly state: string }

/** `<prefix><model>-<n>`: `bancada-iphone-17-pro-2`. */
export function simulatorName(prefix: string, model: string, n: number) {
  return `${prefix}${model
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")}-${n}`
}

export function makeIosLifecycle(shell: Shell, tools: { readonly simslim?: string }) {
  const simctl = (...args: string[]) => [xcrun, "simctl", ...args]
  const json = async (argv: ReadonlyArray<string>) => {
    const done = await shell.run(argv, { timeoutMs: 60_000 })
    if (done.code !== 0) throw new Error(`simctl falhou: ${done.stderr.trim()}`)
    return JSON.parse(done.stdout) as Record<string, unknown>
  }
  const devices = async () =>
    Object.values((await json(simctl("list", "devices", "-j"))).devices as Record<string, Listed[]>).flat()

  return {
    /** The runtime identifier of the newest available iOS that satisfies `wanted`, and the device type of `model`. */
    choose: async (wanted: (version: string) => boolean, model: string) => {
      const runtimes = (
        (await json(simctl("list", "runtimes", "-j"))).runtimes as {
          identifier: string
          version: string
          isAvailable?: boolean
          platform?: string
          name?: string
        }[]
      )
        .filter((item) => item.isAvailable !== false && (item.platform ?? item.name ?? "iOS").startsWith("iOS"))
        .filter((item) => wanted(item.version))
        .toSorted((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))
      const types = (await json(simctl("list", "devicetypes", "-j"))).devicetypes as {
        identifier: string
        name: string
      }[]
      const type = types.find((item) => item.name === model)
      if (!runtimes[0] || !type) return undefined
      return { runtime: runtimes[0].identifier, type: type.identifier }
    },
    /** The simulator of that name, if it exists. */
    find: async (name: string) => (await devices()).find((item) => item.name === name),
    create: async (name: string, type: string, runtime: string) => {
      const made = await shell.run(simctl("create", name, type, runtime), { timeoutMs: 120_000 })
      if (made.code !== 0) throw new Error(`simctl não criou ${name}: ${made.stderr.trim()}`)
      return made.stdout.trim()
    },
    /** Boots it trimmed (`simslim on`, which boots it) or as it comes, and waits until it finished booting. */
    boot: async (udid: string, profile: "enxuto" | "estoque", file: string) => {
      const started =
        profile === "enxuto" && tools.simslim
          ? await shell.run([tools.simslim, "on", udid, "--profile", file], { timeoutMs: 15 * 60_000 })
          : await shell.run(simctl("boot", udid), { timeoutMs: 120_000 })
      if (started.code !== 0 && !`${started.stderr}`.includes("current state: Booted"))
        throw new Error(
          `o simulador ${udid} não ligou: ${(started.stderr || started.stdout).trim().split("\n").at(-1)}`,
        )
      const done = await shell.run(simctl("bootstatus", udid, "-b"), { timeoutMs: 10 * 60_000 })
      if (done.code !== 0) throw new Error(`o simulador ${udid} não terminou de ligar`)
    },
    /** `ok` (booted and its launchd answers), `morto` (not booted any more) or `mudo`. */
    health: async (udid: string) => {
      const listed = (await devices().catch(() => undefined))?.find((item) => item.udid === udid)
      if (listed && listed.state !== "Booted") return "morto" as const
      const answers = await shell.run(simctl("spawn", udid, "launchctl", "print", "system"), { timeoutMs: 10_000 })
      return answers.code === 0 ? ("ok" as const) : ("mudo" as const)
    },
    /**
     * Shut down and erased, only after proving the UDID is the simulator named `name`. The WebDriverAgent an Appium
     * left building for it (`xcodebuild … id=<udid>`) ignores TERM and boots it again once shut down: killed first.
     */
    giveBack: async (udid: string, name: string) => {
      const listed = (await devices()).find((item) => item.udid === udid)
      if (!listed) return
      if (listed.name !== name) throw new Error(`${udid} é ${listed.name}, não ${name}: não desligo`)
      await shell.run(["/usr/bin/pkill", "-KILL", "-f", `xcodebuild.*${udid}`], { timeoutMs: 10_000 })
      if (listed.state !== "Shutdown") await shell.run(simctl("shutdown", udid), { timeoutMs: 120_000 })
      const erased = await shell.run(simctl("erase", udid), { timeoutMs: 120_000 })
      if (erased.code !== 0) throw new Error(`o simulador ${name} não foi apagado: ${erased.stderr.trim()}`)
    },
    destroy: async (udid: string, name: string) => {
      const listed = (await devices()).find((item) => item.udid === udid)
      if (!listed) return
      if (listed.name !== name) throw new Error(`${udid} é ${listed.name}, não ${name}: não apago`)
      await shell.run(simctl("shutdown", udid), { timeoutMs: 120_000 })
      await shell.run(simctl("delete", udid), { timeoutMs: 120_000 })
    },
  }
}

export type IosLifecycle = ReturnType<typeof makeIosLifecycle>
