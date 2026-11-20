import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import type { MachineConfig, Phone } from "../machine-config.js"
import type { BancadaProtocol } from "../protocol.js"

/**
 * What this machine has (`docs/bancada.md`, "Discovery"), found without starting anything: the Android SDK and its
 * images, Xcode's runtimes and models, the phones of the catalog that answer, .NET and its workloads, Docker, versions.
 * Nothing by `PATH`: the server's environment is not a terminal's (on the Mac it has neither `ANDROID_HOME` nor
 * `JAVA_HOME`, `emulator` is not on the `PATH`, and Homebrew's `avdmanager` does not find the SDK), so every tool is
 * resolved to an absolute path once, and the Bancada uses only those.
 */

/** How discovery looks at the machine; tests give recorded outputs. */
export type Probe = {
  readonly platform: NodeJS.Platform
  readonly arch: string
  readonly home: string
  readonly env: Readonly<Record<string, string | undefined>>
  /** A command's exit code and output (standard output and error together), or `undefined` when it cannot start. */
  readonly run: (argv: ReadonlyArray<string>) => Promise<{ readonly code: number; readonly output: string } | undefined>
  readonly exists: (file: string) => Promise<boolean>
  /** The names in a folder; none when it does not exist. */
  readonly list: (folder: string) => Promise<ReadonlyArray<string>>
}

/** The Android tools the Bancada uses, by absolute path. */
export type AndroidTools = {
  readonly sdk: string
  readonly adb: string
  readonly emulator?: string
  readonly avdmanager?: string
  readonly javaHome?: string
  /** Why no AVD can be created here, when one cannot. */
  readonly cannotCreate?: string
}

export type Discovery = {
  /** By capability name, with its details (`docs/bancada.md`, "Discovery"). */
  readonly found: Record<string, unknown>
  readonly android?: AndroidTools
  /** `simslim`, by absolute path, where there is one. */
  readonly simslim?: string
}

export async function discover(
  probe: Probe,
  config: MachineConfig,
  /** Whether a phone is connected now, from what the Bancada keeps of them (`devices/physical.ts`). */
  connected?: (alias: string) => boolean,
): Promise<Discovery> {
  const docker = config.execution.mode === "docker"
  const android = await androidTools(probe, config)
  const [emulators, ios, phones, dotnet, others] = await Promise.all([
    docker ? dockerAndroid(probe, config) : androidCapability(probe, android),
    probe.platform === "darwin" ? iosCapability(probe) : undefined,
    phonesCapability(probe, config.phones, android, connected),
    dotnetCapabilities(probe),
    versions(probe, android, docker),
  ])
  return {
    found: {
      ...(emulators ? { android: emulators } : {}),
      ...(ios ? { ios: ios.capability } : {}),
      ...phones,
      ...dotnet,
      ...others,
    },
    ...(android ? { android } : {}),
    ...(ios?.path ? { simslim: ios.path } : {}),
  }
}

/**
 * The SDK: `[android] sdk`, else `ANDROID_HOME`, `ANDROID_SDK_ROOT`, else the usual folder of the system; the first
 * with `platform-tools/adb`. `avdmanager`: the SDK's own `cmdline-tools/latest`, else its highest version; never
 * Homebrew's. Java (only to create AVDs): `[android] java_home`, `JAVA_HOME`, `/usr/libexec/java_home`, Android
 * Studio's, Homebrew's `openjdk`; the first whose `bin/java -version` runs.
 */
export async function androidTools(probe: Probe, config: MachineConfig): Promise<AndroidTools | undefined> {
  const candidates = [
    config.android.sdk,
    probe.env.ANDROID_HOME,
    probe.env.ANDROID_SDK_ROOT,
    ...(probe.platform === "darwin"
      ? [path.join(probe.home, "Library/Android/sdk")]
      : ["/opt/android-sdk", path.join(probe.home, "Android/Sdk")]),
  ].filter((item): item is string => Boolean(item))
  const sdk = await first(candidates, (folder) => probe.exists(path.join(folder, "platform-tools/adb")))
  if (!sdk) return undefined
  const emulator = path.join(sdk, "emulator/emulator")
  const latest = path.join(sdk, "cmdline-tools/latest/bin/avdmanager")
  const versioned = (await probe.list(path.join(sdk, "cmdline-tools")))
    .filter((name) => name !== "latest")
    .toSorted((a, b) => compare(b, a))
    .map((name) => path.join(sdk, "cmdline-tools", name, "bin/avdmanager"))
  const avdmanager = await first([latest, ...versioned], probe.exists)
  const javaHome = await java(probe, config)
  const cannotCreate = !avdmanager
    ? `o SDK em ${sdk} não tem cmdline-tools com avdmanager`
    : !javaHome
      ? "nenhum Java encontrado ([android] java_home, JAVA_HOME, /usr/libexec/java_home, Android Studio, Homebrew)"
      : undefined
  return {
    sdk,
    adb: path.join(sdk, "platform-tools/adb"),
    ...((await probe.exists(emulator)) ? { emulator } : {}),
    ...(avdmanager ? { avdmanager } : {}),
    ...(javaHome ? { javaHome } : {}),
    ...(cannotCreate ? { cannotCreate } : {}),
  }
}

async function java(probe: Probe, config: MachineConfig) {
  const found = probe.platform === "darwin" ? await probe.run(["/usr/libexec/java_home"]) : undefined
  const libexec = found?.code === 0 ? found.output.trim() : undefined
  const candidates = [
    config.android.javaHome,
    probe.env.JAVA_HOME,
    libexec,
    ...(probe.platform === "darwin"
      ? [
          "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
          "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
          "/usr/local/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
        ]
      : ["/usr/lib/jvm/default-java"]),
  ].filter((item): item is string => Boolean(item))
  return first(candidates, async (home) => (await probe.run([path.join(home, "bin/java"), "-version"]))?.code === 0)
}

/** `android` with the images installed (read from folders, no JVM), the host's ABI and acceleration. */
async function androidCapability(probe: Probe, tools: AndroidTools | undefined) {
  if (!tools?.emulator) return undefined
  const root = path.join(tools.sdk, "system-images")
  const images = (
    await Promise.all(
      (await probe.list(root)).map(async (platform) =>
        (
          await Promise.all(
            (await probe.list(path.join(root, platform))).map(async (tag) =>
              (await probe.list(path.join(root, platform, tag))).map((abi) => ({ api: api(platform), tag, abi })),
            ),
          )
        ).flat(),
      ),
    )
  ).flat()
  const abi = probe.arch === "arm64" ? "arm64-v8a" : "x86_64"
  const acceleration =
    probe.platform === "darwin"
      ? (await probe.run(["/usr/sbin/sysctl", "-n", "kern.hv_support"]))?.output.trim() === "1"
      : await probe.exists("/dev/kvm")
  if (!acceleration) return undefined
  return {
    imagens: images.filter((image) => image.abi === abi),
    abi,
    aceleracao: true,
    criaAvd: tools.cannotCreate === undefined,
    ...(tools.cannotCreate ? { motivo: tools.cannotCreate } : {}),
  }
}

/** In the Docker mode: the machine file's emulator image exists; its API from its name (`…api36…`). */
async function dockerAndroid(probe: Probe, config: MachineConfig) {
  const image = config.android.docker?.image
  if (!image) return undefined
  const docker = await which(probe, "docker")
  const inspected = docker ? await probe.run([docker, "image", "inspect", "--format", "{{.Id}}", image]) : undefined
  if (inspected?.code !== 0) return undefined
  const found = /api-?(\d+)/i.exec(image)?.[1]
  return {
    imagens: found ? [{ api: Number(found), tag: "docker", abi: "x86_64" }] : [],
    abi: "x86_64",
    aceleracao: true,
    criaAvd: true,
    docker: image,
  }
}

/** `ios` on a Mac with Xcode: the runtimes that are available, the device models, and whether `simslim` is there. */
async function iosCapability(probe: Probe) {
  const xcode = await probe.run(["/usr/bin/xcodebuild", "-version"])
  if (xcode?.code !== 0) return undefined
  const [runtimes, types] = await Promise.all([
    probe.run(["/usr/bin/xcrun", "simctl", "list", "runtimes", "-j"]),
    probe.run(["/usr/bin/xcrun", "simctl", "list", "devicetypes", "-j"]),
  ])
  const parsed = (text: string | undefined) => {
    const json = text?.slice(text.indexOf("{"))
    return json ? (JSON.parse(json) as Record<string, unknown>) : {}
  }
  const available = (
    (parsed(runtimes?.output).runtimes ?? []) as {
      version?: string
      isAvailable?: boolean
      platform?: string
      name?: string
    }[]
  )
    .filter((runtime) => runtime.isAvailable !== false && (runtime.platform ?? runtime.name ?? "iOS").startsWith("iOS"))
    .flatMap((runtime) => (runtime.version ? [runtime.version] : []))
  if (available.length === 0) return undefined
  const models = ((parsed(types?.output).devicetypes ?? []) as { name?: string; productFamily?: string }[])
    .filter(
      (type) => type.productFamily === undefined || type.productFamily === "iPhone" || type.productFamily === "iPad",
    )
    .flatMap((type) => (type.name ? [type.name] : []))
  const simslim = await which(probe, "simslim")
  return { capability: { runtimes: available, modelos: models, simslim: simslim !== undefined }, path: simslim }
}

/**
 * `android-fisico` and `ios-fisico`: the catalog's phones that may be reserved, each said connected when `adb devices`
 * or `devicectl` lists its id now.
 */
async function phonesCapability(
  probe: Probe,
  phones: ReadonlyArray<Phone>,
  tools: AndroidTools | undefined,
  connected?: (alias: string) => boolean,
) {
  const offered = phones.filter((phone) => phone.policy !== "negar")
  if (offered.length === 0) return {}
  if (connected)
    return Object.fromEntries(
      (["android", "ios"] as const)
        .map(
          (platform) =>
            [
              `${platform}-fisico`,
              offered
                .filter((phone) => phone.platform === platform)
                .map((phone) => ({
                  apelido: phone.alias,
                  etiquetas: [...phone.tags],
                  contasReais: phone.realAccounts,
                  conectado: connected(phone.alias),
                })),
            ] as const,
        )
        .filter(([, list]) => list.length > 0)
        .map(([name, list]) => [name, { aparelhos: list }]),
    )
  const [adb, devicectl] = await Promise.all([
    tools && offered.some((phone) => phone.platform === "android")
      ? probe.run([tools.adb, "devices", "-l"])
      : undefined,
    probe.platform === "darwin" && offered.some((phone) => phone.platform === "ios")
      ? probe.run(["/usr/bin/xcrun", "devicectl", "list", "devices"])
      : undefined,
  ])
  const listed = (phone: Phone) => {
    const output = phone.platform === "android" ? adb?.output : devicectl?.output
    return output?.split("\n").some((line) => line.split(/\s+/).includes(phone.id)) === true
  }
  const of = (platform: "android" | "ios") =>
    offered
      .filter((phone) => phone.platform === platform)
      .map((phone) => ({
        apelido: phone.alias,
        etiquetas: [...phone.tags],
        contasReais: phone.realAccounts,
        conectado: listed(phone),
      }))
  return Object.fromEntries(
    (["android", "ios"] as const)
      .map((platform) => [`${platform}-fisico`, of(platform)] as const)
      .filter(([, list]) => list.length > 0)
      .map(([name, list]) => [name, { aparelhos: list }]),
  )
}

/** `dotnet` with its SDKs, and `dotnet-android`, `dotnet-ios`, `dotnet-maui` by the installed workloads. */
/**
 * Every .NET installation found (`DOTNET_ROOT`, `~/.dotnet*` such as the `~/.dotnet11` a project pins in its
 * `global.json`, the system's), with their SDKs and workloads together: a project picks its own.
 */
async function dotnetCapabilities(probe: Probe) {
  const own = (await probe.list(probe.home)).filter((name) => /^\.dotnet[\w.-]*$/.test(name)).toSorted()
  const candidates = [
    ...(probe.env.DOTNET_ROOT ? [path.join(probe.env.DOTNET_ROOT, "dotnet")] : []),
    ...own.map((name) => path.join(probe.home, name, "dotnet")),
    "/usr/local/share/dotnet/dotnet",
    "/opt/dotnet/dotnet",
    "/opt/homebrew/bin/dotnet",
    "/usr/share/dotnet/dotnet",
    "/usr/lib/dotnet/dotnet",
  ]
  const found = (
    await Promise.all([...new Set(candidates)].map(async (dotnet) => ((await probe.exists(dotnet)) ? [dotnet] : [])))
  ).flat()
  const read = await Promise.all(
    found.map(async (dotnet) => {
      const sdks = await probe.run([dotnet, "--list-sdks"])
      if (sdks?.code !== 0) return undefined
      // `dotnet workload list`, in any language: one installed workload id per line (`maui`, `maui-android`, …).
      const workloads = ((await probe.run([dotnet, "workload", "list"]))?.output ?? "")
        .split("\n")
        .flatMap((line) => /^([a-z][a-z0-9-]*)\s+\d/.exec(line.trim())?.slice(1, 2) ?? [])
      return {
        sdks: sdks.output.split("\n").flatMap((line) => /^(\d+\.\d+\.\d+\S*)/.exec(line.trim())?.slice(1, 2) ?? []),
        workloads,
      }
    }),
  )
  const usable = read.filter((item) => item !== undefined)
  if (usable.length === 0) return {}
  const versions = [...new Set(usable.flatMap((item) => item.sdks))]
  const installed = new Set(usable.flatMap((item) => item.workloads))
  const has = (...ids: string[]) => ids.some((id) => installed.has(id))
  return {
    dotnet: { sdks: versions },
    ...(has("android", "maui", "maui-android", "maui-mobile") ? { "dotnet-android": {} } : {}),
    ...(has("ios", "maui", "maui-ios", "maui-mobile") ? { "dotnet-ios": {} } : {}),
    ...([...installed].some((id) => id === "maui" || id.startsWith("maui-")) ? { "dotnet-maui": {} } : {}),
  }
}

/** `docker` (not in the Docker mode: an execution there has no socket), `xcode`, `node` and `java`, by version. */
async function versions(probe: Probe, android: AndroidTools | undefined, docker: boolean) {
  const [dockerPath, nodePath] = await Promise.all([which(probe, "docker"), which(probe, "node")])
  const [engine, xcode, node, jdk] = await Promise.all([
    docker || !dockerPath ? undefined : probe.run([dockerPath, "version", "--format", "{{.Server.Version}}"]),
    probe.platform === "darwin" ? probe.run(["/usr/bin/xcodebuild", "-version"]) : undefined,
    nodePath ? probe.run([nodePath, "--version"]) : undefined,
    android?.javaHome ? probe.run([path.join(android.javaHome, "bin/java"), "-version"]) : undefined,
  ])
  const version = (result: { code: number; output: string } | undefined, pattern: RegExp) =>
    result?.code === 0 ? pattern.exec(result.output)?.[1] : undefined
  const found = {
    docker: version(engine, /^(\d+\.\d+(?:\.\d+)?)/m),
    xcode: version(xcode, /Xcode\s+(\d+(?:\.\d+)*)/),
    node: version(node, /v?(\d+\.\d+\.\d+)/),
    java: version(jdk, /version "?(\d+(?:\.\d+)*)/),
  }
  return Object.fromEntries(
    Object.entries(found).flatMap(([name, value]) => (value ? [[name, { versao: value }]] : [])),
  )
}

/**
 * What of a part's device a machine's capabilities do not satisfy, said in Portuguese, or `undefined` when they do
 * (`docs/bancada.md`, "Choosing by capability"). Details a machine did not publish are not held against it.
 */
export function unmet(spec: BancadaProtocol.PartSpec, capabilities: Readonly<Record<string, unknown>>) {
  const device = spec.device
  if (spec.needs.includes("android")) {
    const android = capabilities.android as { imagens?: { api: number | string; tag: string }[] } | undefined
    const images = android?.imagens
    if (images && (device.api || device.googlePlay !== undefined)) {
      const fits = images.some(
        (image) =>
          (!device.api || satisfies(String(image.api), device.api)) &&
          (device.googlePlay === undefined || image.tag.includes("playstore") === device.googlePlay),
      )
      if (!fits)
        return `android com ${[device.api ? `api ${device.api}` : "", device.googlePlay ? "Google Play" : ""].filter(Boolean).join(" e ")}`
    }
  }
  if (spec.needs.includes("ios")) {
    const ios = capabilities.ios as { runtimes?: string[]; modelos?: string[]; simslim?: boolean } | undefined
    if (device.ios && ios?.runtimes && !ios.runtimes.some((runtime) => satisfies(runtime, device.ios!)))
      return `ios ${device.ios}`
    if (device.model && ios?.modelos && !ios.modelos.includes(device.model)) return `o modelo ${device.model}`
    if (device.slim === "exige" && ios && ios.simslim === false) return "simslim"
  }
  for (const platform of ["android", "ios"] as const) {
    if (!spec.needs.includes(`${platform}-fisico`)) continue
    const phones = (
      capabilities[`${platform}-fisico`] as { aparelhos?: { etiquetas: string[]; conectado?: boolean }[] }
    )?.aparelhos
    const tags = spec.phone?.tags ?? device.tags ?? []
    if (
      phones &&
      !phones.some((phone) => phone.conectado !== false && tags.every((tag) => phone.etiquetas.includes(tag)))
    )
      return `um celular ${platform === "ios" ? "iOS" : "Android"} conectado${tags.length ? ` com ${tags.join(", ")}` : ""}`
  }
  return undefined
}

/** `"36.1"` against `">=36"` or `"36"`; `"26.0"` against `">=26.0"`. */
export function satisfies(version: string, wanted: string) {
  const at = wanted.startsWith(">=")
  const target = wanted.replace(/^>=/, "")
  const order = compare(version, target)
  return at ? order >= 0 : order === 0 || (version.split(".")[0] === target && !target.includes("."))
}

/** Numeric, part by part (`36.1` after `36`, `10` after `9`); text parts compare as text. */
function compare(a: string, b: string) {
  const left = a.split(/[.-]/)
  const right = b.split(/[.-]/)
  return (
    Array.from({ length: Math.max(left.length, right.length) }, (_, index) => {
      const x = left[index] ?? "0"
      const y = right[index] ?? "0"
      return /^\d+$/.test(x) && /^\d+$/.test(y) ? Number(x) - Number(y) : x.localeCompare(y)
    }).find((order) => order !== 0) ?? 0
  )
}

/** `android-36` as 36, `android-36.1` as `"36.1"`, a preview by its name. */
function api(folder: string) {
  const name = folder.replace(/^android-/, "")
  return /^\d+$/.test(name) ? Number(name) : name
}

/** The machine as it is: commands with a time limit, files and folders. */
export function systemProbe(): Probe {
  return {
    platform: process.platform,
    arch: process.arch,
    home: os.homedir(),
    env: process.env,
    run: (argv) =>
      Promise.resolve()
        .then(async () => {
          const child = Bun.spawn([...argv], { stdin: "ignore", stdout: "pipe", stderr: "pipe", timeout: 20_000 })
          const [out, err, code] = await Promise.all([
            new Response(child.stdout).text(),
            new Response(child.stderr).text(),
            child.exited,
          ])
          return { code, output: `${out}${err}` }
        })
        .catch(() => undefined),
    exists: (file) =>
      fs.access(file).then(
        () => true,
        () => false,
      ),
    list: (folder) => fs.readdir(folder).catch(() => []),
  }
}

/**
 * A tool outside the SDKs, by absolute path: the server's `PATH` first, then where Homebrew, the system and OrbStack
 * put it (a server started by `launchd` has a short `PATH`).
 */
function which(probe: Probe, name: string) {
  return first(
    [
      ...(probe.env.PATH ?? "").split(":").filter(Boolean),
      path.join(probe.home, ".local/bin"),
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      path.join(probe.home, ".orbstack/bin"),
    ].map((folder) => path.join(folder, name)),
    probe.exists,
  )
}

async function first<A>(items: ReadonlyArray<A>, test: (item: A) => Promise<boolean>) {
  for (const item of items) if (await test(item)) return item
  return undefined
}
