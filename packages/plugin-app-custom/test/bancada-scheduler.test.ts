import { describe, expect, test } from "bun:test"
import { schedule, type MachineView, type QueuedPart } from "../src/bancada/daemon/scheduler"
import type { BancadaProtocol } from "../src/bancada/protocol"

const spec = (
  platform: BancadaProtocol.Platform,
  devices = { min: 1, max: 1 },
  more: Partial<BancadaProtocol.PartSpec> = {},
): BancadaProtocol.PartSpec => ({
  part: platform,
  label: platform,
  platform,
  needs: platform === "none" ? [] : [platform],
  device: {},
  devices,
  exclusive: [],
  unsafe: false,
  args: [],
  ...more,
})
let created = 0
const part = (job: string, partSpec: BancadaProtocol.PartSpec, more: Partial<QueuedPart> = {}): QueuedPart => ({
  job,
  part: partSpec.part,
  spec: partSpec,
  createdAt: ++created,
  index: 0,
  reserved: false,
  ...more,
})
const machine = (
  machineID: string,
  free: Partial<BancadaProtocol.Vector>,
  capabilities: string[],
  more: Partial<MachineView> = {},
): MachineView => ({
  machineID,
  name: machineID,
  state: "ok",
  braked: false,
  pulse: 10,
  free: { memMb: 64_000, cpuMilli: 16_000, builds: 2, android: 0, ios: 0, ...free },
  capabilities: Object.fromEntries(capabilities.map((name) => [name, {}])),
  ...more,
})
const run = (
  parts: QueuedPart[],
  machines: MachineView[],
  options: { locks?: string[]; durations?: Record<string, number>; waits?: Record<string, number> } = {},
) =>
  schedule({
    parts,
    machines,
    locks: new Set(options.locks ?? []),
    duration: (item, at) => options.durations?.[`${item.job}@${at.machineID}`] ?? 60_000,
    wait: (item, at) => options.waits?.[`${item.job}@${at.machineID}`] ?? 0,
  })
const offered = (decision: ReturnType<typeof run>) => decision.offers.map((offer) => `${offer.job}→${offer.machineID}`)

describe("queue", () => {
  test("each part goes to the machine where it ends soonest; the soonest to end goes first", () => {
    const mac = machine("mac", { android: 2 }, ["android"])
    const linux = machine("linux", { android: 1 }, ["android"])
    const decision = run([part("j-a", spec("android")), part("j-b", spec("android"))], [mac, linux], {
      durations: { "j-a@mac": 50_000, "j-a@linux": 90_000, "j-b@mac": 30_000, "j-b@linux": 40_000 },
    })
    expect(offered(decision)).toEqual(["j-b→mac", "j-a→mac"])
  })

  test("a part that does not fit where it would end soonest waits for it, with why and when", () => {
    const mac = machine("mac", { android: 0 }, ["android"])
    const ios = machine("mac2", { ios: 0 }, ["ios"])
    const decision = run([part("j-a", spec("android")), part("j-b", spec("ios"))], [mac, ios], {
      waits: { "j-a@mac": 120_000, "j-b@mac2": 30_000 },
    })
    expect(decision.offers).toEqual([])
    expect(decision.waiting).toEqual([
      { job: "j-b", part: "ios", reason: { code: "orcamento", text: "aguardando um Mac" }, position: 1, etaMs: 30_000 },
      {
        job: "j-a",
        part: "android",
        reason: { code: "orcamento", text: "aguardando folga" },
        position: 2,
        etaMs: 120_000,
      },
    ])
  })

  test("braked, away, nobody offers it: each reason with its text, and no position under a lock", () => {
    const braked = machine("mac", { android: 2 }, ["android"], { braked: true })
    const away = machine("velho", {}, ["ios"], { state: "silenciosa" })
    const decision = run(
      [
        part("j-a", spec("android")),
        part("j-b", spec("ios")),
        part("j-c", spec("none", { min: 0, max: 0 }, { needs: ["xcode"] })),
        part("j-d", spec("none", { min: 0, max: 0 }, { needs: [], exclusive: ["abacato:servidor-dev"] })),
      ],
      [braked, away],
      { locks: ["abacato:servidor-dev"] },
    )
    expect(decision.waiting.map((wait) => [wait.job, wait.reason, wait.position])).toEqual([
      ["j-a", { code: "freio", text: "máquina no limite" }, 1],
      ["j-d", { code: "trava", detail: "abacato:servidor-dev", text: "aguardando trava servidor-dev" }, undefined],
      ["j-b", { code: "maquina_fora", detail: "velho", text: "aguardando velho voltar" }, 2],
      ["j-c", { code: "sem_maquina", text: "nenhuma máquina oferece xcode" }, 3],
    ])
  })

  test("an exclusive lock goes to one part at a time", () => {
    const linux = machine("linux", { builds: 3 }, [])
    const locked = (job: string) => part(job, spec("none", { min: 0, max: 0 }, { exclusive: ["abacato:servidor-dev"] }))
    const decision = run([locked("j-a"), locked("j-b"), part("j-c", spec("none", { min: 0, max: 0 }))], [linux])
    expect(offered(decision)).toEqual(["j-a→linux", "j-c→linux"])
    expect(decision.waiting).toMatchObject([{ job: "j-b", reason: { code: "trava" } }])
  })

  test("elastic: a part takes up to its maximum alone, a fair share when others wait for the same devices", () => {
    const mac = machine("mac", { android: 4, builds: 1 }, ["android"])
    expect(run([part("j-a", spec("android", { min: 1, max: 6 }))], [mac]).offers).toMatchObject([{ proposed: 4 }])
    // One build at a time: j-a goes now, j-b and j-c wait for the same emulators, so j-a gets a third of four.
    const decision = run(
      [
        part("j-a", spec("android", { min: 1, max: 6 })),
        part("j-b", spec("android", { min: 1, max: 6 })),
        part("j-c", spec("android", { min: 1, max: 6 })),
      ],
      [mac],
    )
    expect(decision.offers).toEqual([{ job: "j-a", part: "android", machineID: "mac", proposed: 1 }])
  })

  test("a part bypassed on a machine it could use counts it; reserved, no newer part of its kind goes there", () => {
    const mac = machine("mac", { android: 1, ios: 2 }, ["android", "ios"])
    const old = part("j-old", spec("android", { min: 2, max: 2 }))
    const newer = part("j-new", spec("android"))
    expect(run([old, newer], [mac])).toMatchObject({
      offers: [{ job: "j-new" }],
      bypassed: [{ job: "j-old", part: "android", times: 1 }],
    })
    // Reserved: the newer Android part waits; an iOS part still goes (iOS never holds Android, nor this the reverse).
    const ios = part("j-ios", spec("ios"))
    const decision = run([{ ...old, reserved: true }, newer, ios], [mac])
    expect(offered(decision)).toEqual(["j-ios→mac"])
    expect(decision.waiting).toMatchObject([
      { job: "j-old", reason: { code: "orcamento" }, position: 1 },
      { job: "j-new", reason: { code: "fila", text: "na fila" }, position: 2 },
    ])
  })

  test("a machine that refused a part is a candidate again only from a newer pulse", () => {
    const mac = machine("mac", { android: 1 }, ["android"], { pulse: 7 })
    const refused = part("j-a", spec("android"), { refused: { machineID: "mac", pulse: 7 } })
    expect(run([refused], [mac]).offers).toEqual([])
    expect(run([refused], [{ ...mac, pulse: 8 }]).offers).toMatchObject([{ machineID: "mac" }])
  })

  test("a part with secrets only where the policy is resolved", () => {
    const plain = machine("linux", { builds: 1 }, [])
    const mac = machine("mac", { builds: 1 }, ["segredos:opencode-skills"])
    const secret = part("j-a", spec("none", { min: 0, max: 0 }, { secrets: "opencode-skills" }))
    expect(offered(run([secret], [plain, mac]))).toEqual(["j-a→mac"])
    expect(run([secret], [plain]).waiting).toMatchObject([
      { reason: { code: "sem_maquina", text: "nenhuma máquina oferece segredos:opencode-skills" } },
    ])
  })
})
