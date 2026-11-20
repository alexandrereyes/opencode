import { simulatorName, type IosLifecycle } from "../../../resources/adapters/ios-lifecycle.js"
import { satisfies } from "../capabilities.js"
import type { Driver } from "./pool.js"

/**
 * Simulators on the Mac (`docs/bancada.md`, "iOS"): one per model and runtime, created once with `simctl`; booted
 * trimmed by `simslim` (the catalog's profile) or as they come; given back shut down and erased.
 */
export function iosSimulators(input: {
  readonly lifecycle: IosLifecycle
  readonly prefix: string
  /** The `simslim` profile file (`catalog/slim.ts`). */
  readonly profile: string
  readonly machine: () => string
  readonly log: (line: string) => void
}): Driver {
  const lifecycle = input.lifecycle
  return {
    kind: "ios-simulador",
    choose: async (spec, profile) => {
      const model = spec.model ?? "iPhone 17 Pro"
      const found = await lifecycle.choose((version) => !spec.ios || satisfies(version, spec.ios), model)
      if (!found) return `nenhum runtime iOS ${spec.ios ?? ""} com o modelo ${model} nesta máquina`.replace("  ", " ")
      return {
        key: `ios:${found.runtime}:${found.type}:${profile}`,
        spec: { ...found, model },
        name: (n) => simulatorName(input.prefix, model, n),
      }
    },
    ready: async (device, slot) => {
      const spec = device.spec as { runtime: string; type: string; model: string }
      const started = Date.now()
      const udid =
        (await lifecycle.find(device.id))?.udid ?? (await lifecycle.create(device.id, spec.type, spec.runtime))
      await lifecycle.boot(udid, device.profile, input.profile)
      input.log(`${device.id} ready in ${Math.round((Date.now() - started) / 1000)} s`)
      return {
        run: { udid },
        view: {
          id: device.id,
          tipo: "ios-simulador",
          plataforma: "ios",
          serial: null,
          udid,
          adb: null,
          runtime: spec.runtime,
          modelo: spec.model,
          perfil: device.profile,
          portas: { inicio: slot.start, fim: slot.end },
          host: "127.0.0.1",
          maquina: input.machine(),
        },
      }
    },
    health: (_device, run) => lifecycle.health(run.udid!),
    giveBack: async (device, run) => {
      if (run.udid) await lifecycle.giveBack(run.udid, device.id)
    },
  }
}
