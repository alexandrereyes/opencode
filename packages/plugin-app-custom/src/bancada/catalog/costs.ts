// Default costs (`docs/bancada.md`, "Budget"): what a device, a build or a test's extra take before this machine has
// measured them (fewer than 3 samples). Memory in MB, CPU in thousandths of a core.

export const deviceCosts = {
  "android-emulador": { memMb: 8_192, cpuMilli: 1_000 },
  "android-docker": { memMb: 8_192, cpuMilli: 3_000 },
  "ios-simulador:enxuto": { memMb: 3_584, cpuMilli: 2_000 },
  "ios-simulador:estoque": { memMb: 12_288, cpuMilli: 2_500 },
} as const

/** A project's build, until its own builds were measured. */
export const buildCost = { memMb: 8_192, cpuMilli: 6_000 } as const

/** What a test that needs Docker takes beside each device (its containers), until measured. */
export const dockerExtraPerDevice = { memMb: 2_048, cpuMilli: 1_000 } as const
