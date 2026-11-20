import { describe, expect, test } from "bun:test"
import { discover, satisfies, unmet, type Probe } from "../src/bancada/daemon/capabilities"
import { parseMachineConfig, type MachineConfig } from "../src/bancada/machine-config"
import type { BancadaProtocol } from "../src/bancada/protocol"
import { createWorld } from "./fixture/bancada-sim"

const home = "/Users/ana"
const sdk = `${home}/Library/Android/sdk`
const studio = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"

/** Recorded outputs of a Mac like the owner's (`xcrun simctl … -j` trimmed). */
const runtimes = JSON.stringify({
  runtimes: [
    { version: "26.5", isAvailable: true, platform: "iOS" },
    { version: "27.0", isAvailable: true, platform: "iOS" },
    { version: "26.0", isAvailable: false, platform: "iOS" },
    { version: "11.0", isAvailable: true, platform: "watchOS" },
  ],
})
const devicetypes = JSON.stringify({
  devicetypes: [
    { name: "iPhone 17 Pro", productFamily: "iPhone" },
    { name: "iPad Air 11-inch (M3)", productFamily: "iPad" },
    { name: "Apple Watch Series 11 (46mm)", productFamily: "Apple Watch" },
  ],
})
const workloads = [
  "",
  "Versão da carga de trabalho: 10.0.108",
  "",
  "ID da carga de trabalho instalada      Versão do Manifesto      Origem da Instalação",
  "------------------------------------------------------------------------------------",
  "maui-android                           10.0.108/10.0.100        SDK 10.0.100",
  "wasm-tools                             10.0.108/10.0.100        SDK 10.0.100",
  "",
].join("\n")

/** A machine of files and recorded command outputs; anything else does not exist or does not start. */
function probe(input: {
  platform?: NodeJS.Platform
  env?: Record<string, string>
  files?: string[]
  outputs?: Record<string, { code?: number; output: string }>
}): Probe & { readonly ran: string[] } {
  const files = new Set(input.files ?? [])
  const ran: string[] = []
  return {
    platform: input.platform ?? "darwin",
    arch: input.platform === "linux" ? "x64" : "arm64",
    home,
    env: input.env ?? {},
    ran,
    run: async (argv) => {
      ran.push(argv.join(" "))
      const found = input.outputs?.[argv.join(" ")]
      return found ? { code: found.code ?? 0, output: found.output } : undefined
    },
    exists: async (file) => files.has(file),
    list: async (folder) => [
      ...new Set(
        [...files]
          .filter((file) => file.startsWith(`${folder}/`))
          .map((file) => file.slice(folder.length + 1).split("/")[0]!),
      ),
    ],
  }
}

const config = (text = ""): MachineConfig => {
  const parsed = parseMachineConfig(`versao = 1\n[execucao]\nmodo = "processo"\n${text}`, {
    memMb: 131_072,
    cores: 16,
    inDocker: false,
    platform: "darwin",
  })
  if (!parsed.ok) throw new Error(parsed.problems.join("\n"))
  return parsed.config
}

/** The owner's Mac as the server sees it: no `ANDROID_HOME`, no `JAVA_HOME`, a short `PATH`. */
const mac = (more: { files?: string[]; outputs?: Record<string, { code?: number; output: string }> } = {}) =>
  probe({
    env: { PATH: "/usr/bin:/bin" },
    files: [
      `${sdk}/platform-tools/adb`,
      `${sdk}/emulator/emulator`,
      `${sdk}/system-images/android-36/google_apis_playstore/arm64-v8a/system.img`,
      `${sdk}/system-images/android-37.0/google_apis/arm64-v8a/system.img`,
      `${sdk}/system-images/android-33/google_apis/x86_64/system.img`,
      "/opt/homebrew/bin/avdmanager",
      "/opt/homebrew/bin/node",
      "/usr/local/share/dotnet/dotnet",
      `${home}/.local/bin/simslim`,
      ...(more.files ?? []),
    ],
    outputs: {
      "/usr/sbin/sysctl -n kern.hv_support": { output: "1\n" },
      "/usr/libexec/java_home": { code: 1, output: "Unable to locate a Java Runtime.\n" },
      [`${studio}/bin/java -version`]: { output: 'openjdk version "21.0.8" 2025-07-15\n' },
      "/usr/bin/xcodebuild -version": { output: "Xcode 27.2\nBuild version 27C5\n" },
      "/usr/bin/xcrun simctl list runtimes -j": { output: runtimes },
      "/usr/bin/xcrun simctl list devicetypes -j": { output: devicetypes },
      "/usr/local/share/dotnet/dotnet --list-sdks": {
        output: "9.0.200 [/usr/local/share/dotnet/sdk]\n10.0.302 [/usr/local/share/dotnet/sdk]\n",
      },
      "/usr/local/share/dotnet/dotnet workload list": { output: workloads },
      "/opt/homebrew/bin/node --version": { output: "v26.13.1\n" },
      ...more.outputs,
    },
  })

describe("discovery", () => {
  test("the owner's Mac without ANDROID_HOME and JAVA_HOME: the SDK, Android Studio's Java, Xcode, .NET", async () => {
    const found = await discover(
      mac({ files: [`${sdk}/cmdline-tools/latest/bin/avdmanager`, `${studio}/bin/java`] }),
      config(),
    )
    expect(found).toEqual({
      found: {
        android: {
          imagens: [
            { api: 36, tag: "google_apis_playstore", abi: "arm64-v8a" },
            { api: "37.0", tag: "google_apis", abi: "arm64-v8a" },
          ],
          abi: "arm64-v8a",
          aceleracao: true,
          criaAvd: true,
        },
        ios: { runtimes: ["26.5", "27.0"], modelos: ["iPhone 17 Pro", "iPad Air 11-inch (M3)"], simslim: true },
        dotnet: { sdks: ["9.0.200", "10.0.302"] },
        "dotnet-android": {},
        "dotnet-maui": {},
        xcode: { versao: "27.2" },
        node: { versao: "26.13.1" },
        java: { versao: "21.0.8" },
      },
      android: {
        sdk,
        adb: `${sdk}/platform-tools/adb`,
        emulator: `${sdk}/emulator/emulator`,
        avdmanager: `${sdk}/cmdline-tools/latest/bin/avdmanager`,
        javaHome: studio,
      },
      simslim: `${home}/.local/bin/simslim`,
    })
  })

  test("Homebrew's avdmanager is never used; without the SDK's, or without Java, no AVD is created, and why", async () => {
    const withoutTools = await discover(mac({ files: [`${studio}/bin/java`] }), config())
    expect(withoutTools.found.android).toMatchObject({
      criaAvd: false,
      motivo: `o SDK em ${sdk} não tem cmdline-tools com avdmanager`,
    })
    expect(withoutTools.android?.avdmanager).toBeUndefined()
    const withoutJava = await discover(
      mac({
        files: [`${sdk}/cmdline-tools/latest/bin/avdmanager`],
        outputs: { [`${studio}/bin/java -version`]: { code: 127, output: "" } },
      }),
      config(),
    )
    expect(withoutJava.found.android).toMatchObject({
      criaAvd: false,
      motivo:
        "nenhum Java encontrado ([android] java_home, JAVA_HOME, /usr/libexec/java_home, Android Studio, Homebrew)",
    })
    // The machine still offers the emulators it has.
    expect(withoutJava.found.android).toMatchObject({ aceleracao: true, imagens: expect.any(Array) })
  })

  test("the highest cmdline-tools without latest; the machine file's SDK and Java before anything else", async () => {
    const versioned = await discover(
      mac({
        files: [
          `${sdk}/cmdline-tools/9.0/bin/avdmanager`,
          `${sdk}/cmdline-tools/22.0/bin/avdmanager`,
          `${sdk}/cmdline-tools/12.0/bin/avdmanager`,
          `${studio}/bin/java`,
        ],
      }),
      config(),
    )
    expect(versioned.android?.avdmanager).toBe(`${sdk}/cmdline-tools/22.0/bin/avdmanager`)
    const own = "/Volumes/dados/sdk"
    const chosen = await discover(
      mac({
        files: [`${own}/platform-tools/adb`, `${own}/emulator/emulator`],
        outputs: { "/opt/jdk/bin/java -version": { output: 'openjdk version "17"' } },
      }),
      config(`[android]\nsdk = "${own}"\njava_home = "/opt/jdk"\n`),
    )
    expect(chosen.android).toMatchObject({ sdk: own, javaHome: "/opt/jdk" })
  })

  test("a Linux machine never offers ios, whatever it finds; no acceleration, no android", async () => {
    const linux = probe({
      platform: "linux",
      env: { ANDROID_HOME: "/opt/android-sdk", PATH: "/usr/bin" },
      files: ["/opt/android-sdk/platform-tools/adb", "/opt/android-sdk/emulator/emulator", "/usr/bin/docker"],
      outputs: {
        "/usr/bin/xcodebuild -version": { output: "Xcode 27.2" },
        "/usr/bin/xcrun simctl list runtimes -j": { output: runtimes },
        "/usr/bin/docker version --format {{.Server.Version}}": { output: "27.3.1\n" },
      },
    })
    const found = await discover(linux, config())
    expect(Object.keys(found.found).sort()).toEqual(["docker"])
    expect(linux.ran.some((command) => command.includes("xcrun") || command.includes("xcodebuild"))).toBe(false)
    // With /dev/kvm, its emulators.
    const kvm = probe({
      platform: "linux",
      env: { ANDROID_HOME: "/opt/android-sdk" },
      files: [
        "/opt/android-sdk/platform-tools/adb",
        "/opt/android-sdk/emulator/emulator",
        "/opt/android-sdk/system-images/android-35/google_apis/x86_64/system.img",
        "/dev/kvm",
      ],
    })
    expect((await discover(kvm, config())).found.android).toMatchObject({
      imagens: [{ api: 35, tag: "google_apis", abi: "x86_64" }],
      abi: "x86_64",
    })
  })

  test("phones of the catalog by adb and devicectl; one not to be reserved is not offered", async () => {
    const found = await discover(
      mac({
        files: [`${studio}/bin/java`],
        outputs: {
          [`${sdk}/platform-tools/adb devices -l`]: {
            output: "List of devices attached\nIBHUYT85ZTYH5XDM       device usb:1-1 product:poco model:POCO_X7\n",
          },
          "/usr/bin/xcrun devicectl list devices": { output: "Name   Hostname   Identifier   State\n" },
        },
      }),
      config(
        `[[fisico]]\napelido = "poco"\nnome = "POCO X7"\nid = "IBHUYT85ZTYH5XDM"\nplataforma = "android"\ntransporte = "usb"\netiquetas = ["whatsapp"]\n` +
          `[[fisico]]\napelido = "redmi"\nnome = "Redmi"\nid = "d8cf6fc2"\nplataforma = "android"\ntransporte = "wifi"\n` +
          `[[fisico]]\napelido = "pessoal"\nnome = "Pessoal"\nid = "00008110-00065DA13A78401E"\nplataforma = "ios"\ntransporte = "usb"\npolitica = "negar"\n`,
      ),
    )
    expect(found.found["android-fisico"]).toEqual({
      aparelhos: [
        { apelido: "poco", etiquetas: ["whatsapp"], contasReais: false, conectado: true },
        { apelido: "redmi", etiquetas: [], contasReais: false, conectado: false },
      ],
    })
    expect(found.found["ios-fisico"]).toBeUndefined()
  })
})

describe("choosing by capability", () => {
  const spec = (needs: string[], device: BancadaProtocol.DeviceSpec): BancadaProtocol.PartSpec => ({
    part: "p",
    label: "P",
    platform: needs.some((need) => need.startsWith("ios")) ? "ios" : "android",
    needs,
    device,
    devices: { min: 1, max: 1 },
    exclusive: [],
    unsafe: false,
    build: true,
    args: [],
  })
  const capabilities = {
    android: {
      imagens: [
        { api: 36, tag: "google_apis_playstore", abi: "arm64-v8a" },
        { api: "37.0", tag: "google_apis", abi: "arm64-v8a" },
      ],
    },
    ios: { runtimes: ["26.5", "27.0"], modelos: ["iPhone 17 Pro"], simslim: false },
    "android-fisico": {
      aparelhos: [{ apelido: "poco", etiquetas: ["whatsapp"], contasReais: false, conectado: true }],
    },
  }

  test("versions: at least, or the same major", () => {
    expect([
      satisfies("37.0", ">=36"),
      satisfies("36", ">=36"),
      satisfies("35", ">=36"),
      satisfies("36.1", "36"),
      satisfies("37", "36"),
      satisfies("26.5", ">=27.0"),
      satisfies("27.0", "27.0"),
      satisfies("10", ">=9"),
    ]).toEqual([true, true, false, true, false, false, true, true])
  })

  test("what a machine lacks for a part's device; details not published are not held against it", () => {
    expect(
      [
        spec(["android"], { api: ">=36" }),
        spec(["android"], { api: ">=38" }),
        spec(["android"], { api: ">=37", googlePlay: true }),
        spec(["ios"], { ios: ">=27.0", model: "iPhone 17 Pro" }),
        spec(["ios"], { ios: ">=28.0" }),
        spec(["ios"], { model: "iPhone 18 Pro" }),
        spec(["ios"], { slim: "exige" }),
        spec(["android-fisico"], { tags: ["whatsapp"] }),
        spec(["android-fisico"], { tags: ["nfc"] }),
      ].map((item) => unmet(item, capabilities)),
    ).toEqual([
      undefined,
      "android com api >=38",
      "android com api >=37 e Google Play",
      undefined,
      "ios >=28.0",
      "o modelo iPhone 18 Pro",
      "simslim",
      undefined,
      "um celular Android conectado com nfc",
    ])
    expect(unmet(spec(["android"], { api: ">=40" }), { android: {} })).toBeUndefined()
  })

  test("simulation with different machines: ios only on the Mac, an image only the Mac has, the rest anywhere", async () => {
    const sim = createWorld({ seed: 21 })
    sim.addMachine({
      name: "host-6",
      hub: true,
      platform: "linux",
      capabilities: { android: { imagens: [{ api: 35, tag: "google_apis", abi: "x86_64" }] }, docker: {} },
      capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 1, android: 2, ios: 0 },
    })
    sim.addMachine({
      name: "Mac",
      capabilities: {
        android: { imagens: [{ api: 36, tag: "google_apis", abi: "arm64-v8a" }] },
        ios: { runtimes: ["27.0"], modelos: ["iPhone 17 Pro"], simslim: true },
      },
      capacity: { memMb: 64_000, cpuMilli: 16_000, builds: 2, android: 2, ios: 2 },
    })
    const code = {
      project: "exemplo",
      commit: "3417b7e3c0ffee5d1c2b3a4f5e6d7c8b9a0f1e2d",
      remotes: [],
      inRemote: false,
    }
    const part = (name: string, needs: string[], device: BancadaProtocol.DeviceSpec) => ({
      ...spec(needs, device),
      part: name,
      label: name,
    })
    const jobs = {
      "j-11111111": part("ios", ["ios"], { ios: ">=27.0", model: "iPhone 17 Pro" }),
      "j-22222222": part("android", ["android"], { api: ">=36" }),
      "j-33333333": part("android", ["android"], { api: ">=34" }),
    }
    Object.entries(jobs).forEach(([id, item], index) => {
      sim.script(id, item.part, {
        buildMs: 2_000,
        runMs: 5_000,
        exit: 0,
        planned: ["c1"],
        scenarios: [{ id: "c1", result: "passou" }],
      })
      sim.submit("host-6", { id, sessionID: `ses_${index}`, rootSessionID: `ses_${index}`, code, parts: [item] })
    })
    // The Mac asleep: iOS and the image only it has wait for it, never for host-6.
    sim.sleep("Mac", true)
    await sim.advance(60_000)
    expect(sim.seen("j-11111111", "ios")).not.toContain("oferecido")
    expect(sim.seen("j-22222222", "android")).not.toContain("oferecido")
    expect(sim.facts.delivered.get("j-33333333")?.[0]?.machine?.name).toBe("host-6")
    sim.sleep("Mac", false)
    await sim.advance(2 * 60_000)
    sim.settle()
    expect(sim.facts.delivered.get("j-11111111")?.[0]).toMatchObject({
      machine: { name: "Mac" },
      outcome: { approved: true },
    })
    expect(sim.facts.delivered.get("j-22222222")?.[0]).toMatchObject({
      machine: { name: "Mac" },
      outcome: { approved: true },
    })
  }, 30_000)
})
