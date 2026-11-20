import type { Part } from "../commands.js"
import type { BancadaProtocol } from "../protocol.js"
import type { HoldRow, MirrorRow, Target } from "./holds.js"

/**
 * The hook's decision (`docs/bancada.md`, "Hook", steps 2 to 6), on what the plugin read of a shell command: phones of
 * the catalog need the family's hold; a device of a test or of another family's slot is refused; the family's own is
 * renewed; a start without a slot asks for one on the spot. Decided here, without the network: a device of another
 * machine by what this server's sessions hold there (`grant_mirror`).
 */

export type Phone = typeof BancadaProtocol.CatalogPhone.Type & { readonly machineID: string }

export type Asker = {
  readonly sessionID: string
  readonly rootSessionID: string
  readonly sessionTitle?: string
  readonly rootTitle?: string
}

export type Decision =
  | { readonly allow: true }
  | { readonly allow: false; readonly message: string }
  /** Slots asked of another machine, not answered yet: the caller waits for them a little (`answer`). */
  | { readonly pending: ReadonlyArray<string> }

export function makeGate(input: {
  readonly machineID: string
  /** This machine's device prefix: a device named so is a test's. */
  readonly prefix: string
  readonly phones: () => ReadonlyArray<Phone>
  readonly family: (rootSessionID: string) => ReadonlyArray<MirrorRow>
  readonly granted: () => ReadonlyArray<MirrorRow>
  /** The holds this machine decides in force, whoever asked. */
  readonly here: () => ReadonlyArray<HoldRow>
  /** The emulator ports of the tests running here. */
  readonly ports: () => ReadonlyArray<{ readonly start: number; readonly end: number }>
  /** The machine behind the `mac` bridge: its id, or `mac` while unknown. */
  readonly bridge: () => string
  readonly hold: (
    request: Asker & { readonly hold: string; readonly machine?: string; readonly target: Target },
  ) => MirrorRow | undefined
  readonly touch: (hold: string) => void
  readonly find: (hold: string) => MirrorRow | undefined
  readonly id: () => string
}) {
  const answer = (holds: ReadonlyArray<string>): Decision => {
    const rows = holds.map((hold) => input.find(hold))
    if (rows.some((row) => row?.state === "pedida")) return { pending: holds }
    const missing = rows.find((row) => row?.state !== "concedida")
    if (!missing) return { allow: true }
    if (missing.state === "esperando")
      return {
        allow: false,
        message: `Sem vaga agora (${missing.reason ?? "sem folga"}; ${missing.position ?? 1}º na fila). Você será avisado quando sair.`,
      }
    return { allow: false, message: `Sem vaga agora (${missing.reason ?? "recusada"}).` }
  }

  return {
    decide: (asker: Asker, parts: ReadonlyArray<Part>): Decision => {
      const family = input.family(asker.rootSessionID)
      const renew = new Set<string>()
      const asks: { machine: string | undefined; start: Part["starts"][number] }[] = []
      for (const part of parts) {
        const machine = part.where === "here" ? input.machineID : input.bridge()
        const local = machine === input.machineID
        // 2. Phones of the catalog: never one not to be reserved; otherwise only with the family's hold.
        for (const phone of input.phones().filter((item) => cites(part.command, item.id))) {
          if (phone.policy === "negar")
            return {
              allow: false,
              message: `O celular ${phone.alias} não pode ser usado por agentes (politica = "negar" no arquivo da máquina).`,
            }
          const mine = family.find((row) => row.state === "concedida" && phoneOf(row) === phone.alias)
          if (!mine)
            return { allow: false, message: `Reserve antes com \`bancada_hold({ aparelho: "${phone.alias}" })\`.` }
          renew.add(mine.hold)
        }
        const names = [
          ...part.emulators.flatMap((item) => (item.avd ? [{ platform: "android" as const, name: item.avd }] : [])),
          ...part.simulators.flatMap((item) => {
            const name = item.name ?? item.udid
            return name ? [{ platform: "ios" as const, name }] : []
          }),
          ...part.starts,
        ]
        for (const device of names) {
          // 3. A test's device, or another family's slot.
          if (local && device.name.startsWith(input.prefix)) return { allow: false, message: testDevice(device.name) }
          const mine = family.find((row) => row.state === "concedida" && slotOf(row) === key(device))
          if (mine) {
            // 4. The family's own: renewed.
            renew.add(mine.hold)
            continue
          }
          const other = local
            ? input
                .here()
                .find(
                  (row) =>
                    row.root_session_id !== asker.rootSessionID && slotKey(JSON.parse(row.target)) === key(device),
                )
            : undefined
          if (other) return { allow: false, message: taken(device.name, JSON.parse(other.origin)) }
          // Another machine's: only what this server's other families hold there is known.
          const mirrored = local
            ? undefined
            : input
                .granted()
                .find(
                  (row) =>
                    row.root_session_id !== asker.rootSessionID &&
                    row.machine_id !== input.machineID &&
                    slotOf(row) === key(device),
                )
          if (mirrored)
            return { allow: false, message: `${device.name} está reservado para outra sessão deste servidor.` }
        }
        if (local)
          for (const item of part.emulators) {
            const port = Number(/^emulator-(\d+)$/.exec(item.serial ?? "")?.[1])
            if (input.ports().some((range) => port >= range.start && port <= range.end))
              return { allow: false, message: testDevice(item.serial!) }
          }
        // 5. A start without the family's slot asks for one (after every other check passed).
        part.starts
          .filter((start) => !family.some((row) => row.state === "concedida" && slotOf(row) === key(start)))
          .forEach((start) => asks.push({ machine: local ? undefined : machine, start }))
      }
      renew.forEach((hold) => input.touch(hold))
      if (asks.length === 0) return { allow: true }
      const holds = asks.flatMap(({ machine, start }) => {
        const row = input.hold({
          ...asker,
          hold: input.id(),
          ...(machine === undefined ? {} : { machine }),
          target: { kind: "vaga", platform: start.platform, name: start.name },
        })
        return row ? [row.hold] : []
      })
      return answer(holds)
    },
    /** Where the slots a decision asked stand now. */
    answer,
  }
}

function cites(command: string, id: string) {
  const escaped = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  return new RegExp(`(^|[\\s'"=@/])${escaped}($|[\\s'"/;&|)])`).test(command)
}

const key = (device: { readonly platform: "android" | "ios"; readonly name: string }) =>
  `${device.platform}:${device.name}`

function slotKey(target: Target) {
  return target.kind === "vaga" ? `${target.platform}:${target.name}` : undefined
}

function slotOf(row: MirrorRow) {
  return slotKey(JSON.parse(row.target))
}

function phoneOf(row: MirrorRow) {
  const target: Target = JSON.parse(row.target)
  return target.kind === "fisico" ? target.device : undefined
}

function testDevice(name: string) {
  return `${name} é um aparelho de um teste da Bancada em andamento; não use. Para rodar testes, use bancada_run.`
}

function taken(name: string, origin: BancadaProtocol.Origin) {
  const who = origin.rootTitle ?? origin.sessionTitle ?? "outra sessão"
  return `${name} está reservado para ${who} (em ${origin.name}); não use aparelho de outra sessão.`
}
