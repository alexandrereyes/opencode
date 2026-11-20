// Default costs (`docs/bancada.md`, "Budget"): what a device, a build or a test's extra take before this machine has
// measured them (fewer than 3 samples). Memory in MB, CPU in thousandths of a core. The devices' are AbacatoV3's
// measurements (`.agents/skills/e2e/references/measurements.md` and `linux.md`, 11/2026): an emulator on the Mac has
// 2 cores and takes 6.5 to 7.8 GB; one in a container on host-6 (API 36, SwiftShader), 4 GB and 2.7 cores (6 took
// 24 GB and ~16 cores); a simulator 14.4 GB in stock and 3.3 GB trimmed.

export const deviceCosts = {
  "android-emulador": { memMb: 7_987, cpuMilli: 2_000 },
  "android-docker": { memMb: 4_096, cpuMilli: 2_700 },
  "ios-simulador:enxuto": { memMb: 3_379, cpuMilli: 2_000 },
  "ios-simulador:estoque": { memMb: 14_746, cpuMilli: 2_500 },
} as const

/** A project's build, until its own builds were measured. */
export const buildCost = { memMb: 8_192, cpuMilli: 6_000 } as const

/** What a test that needs Docker takes beside each device (its containers), until measured. */
export const dockerExtraPerDevice = { memMb: 2_048, cpuMilli: 1_000 } as const

/**
 * How many devices of a kind are worth running at once on a machine, by default (the machine file's `max_android` and
 * `max_ios` say otherwise): on a 16-core Mac, 6 emulators or 6 trimmed simulators (the suite stops getting shorter
 * past 6, and the CPU is full); in containers on host-6, 4 (with 6, accessibility timeouts failed a scenario).
 */
export const worthRunning = { android: 6, androidDocker: 4, ios: 6 } as const
