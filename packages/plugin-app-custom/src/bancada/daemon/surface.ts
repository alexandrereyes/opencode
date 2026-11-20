import type { Database } from "bun:sqlite"
import { initials } from "../../live-activity/unified.js"
import type { BancadaProtocol } from "../protocol.js"
import type { MirrorRow } from "./holds.js"

/**
 * What the apps read (`docs/bancada.md`, "App surface"): a session family's devices and waits (`session`), and the
 * queue (`queue`, the whole one on the hub, this machine's own elsewhere). Ordered here; the apps show lists as they
 * come.
 */

export type Server = { readonly instanceID: string; readonly name: string; readonly short: string }
export type HubState = "ok" | "unavailable" | "incompatible" | "none"
type Reason = typeof BancadaProtocol.Reason.Type
type PartState = typeof BancadaProtocol.PartState.Type
type UsedDevice = typeof BancadaProtocol.UsedDevice.Type
type Origin = typeof BancadaProtocol.Origin.Type
type Spec = typeof BancadaProtocol.PartSpec.Type

type View = {
  readonly state: PartState
  readonly machine?: { readonly machineID: string; readonly name: string; readonly instanceID?: string }
  readonly position?: number
  readonly etaMs?: number
  readonly reason?: Reason
  readonly devices?: ReadonlyArray<UsedDevice>
  readonly since?: number
}
type JobRow = {
  readonly id: string
  readonly session_id: string
  readonly root_session_id: string
  readonly origin: string
  readonly parts: string
  readonly view: string
  readonly state: string
  readonly created_at: number
}

export type By = { sessionID: string; title?: string; root: boolean; agent?: string }
type Kind = "android-emulator" | "ios-simulator" | "android-device" | "ios-device" | "none"

const running = new Set<PartState>(["oferecido", "aceito", "compilando", "rodando", "incerto"])
const queued = new Set<PartState>(["na_fila"])

export function server(instanceID: string, name: string): Server {
  return { instanceID, name, short: initials(name) }
}

/** `2 emuladores Android`, `1 a 6 emuladores Android`, `1 simulador iOS`; a test without devices, its label. */
function what(spec: Spec) {
  const kind: Kind = spec.platform === "none" ? "none" : spec.platform === "ios" ? "ios-simulator" : "android-emulator"
  const count = { min: spec.devices.min, max: spec.devices.max }
  if (kind === "none") return { kind, count, label: spec.label }
  const noun = (n: number) =>
    kind === "ios-simulator"
      ? n === 1
        ? "simulador iOS"
        : "simuladores iOS"
      : n === 1
        ? "emulador Android"
        : "emuladores Android"
  const label =
    count.min === count.max ? `${count.min} ${noun(count.min)}` : `${count.min} a ${count.max} ${noun(count.max)}`
  return { kind, count, label }
}

const kindOf = (device: UsedDevice, platform: Spec["platform"]): Exclude<Kind, "none"> =>
  device.kind.startsWith("ios") ? "ios-simulator" : platform === "ios" ? "ios-simulator" : "android-emulator"
const kindLabel = (kind: Exclude<Kind, "none">) =>
  kind === "android-emulator" ? "Emulador Android" : kind === "ios-simulator" ? "Simulador iOS" : "Celular físico"
const useState = (state: PartState) => (state === "compilando" || state === "rodando" ? state : ("preparando" as const))

export function makeSurface(input: {
  readonly db: Database
  readonly now: () => number
  readonly self: () => { readonly machineID: string; readonly instanceID: string; readonly name: string }
  readonly hubState: () => HubState
  readonly isHub: boolean
  /** The family's holds (`grant_mirror`), and a phone's name and id by its alias. */
  readonly holds: (root: string) => ReadonlyArray<MirrorRow>
  readonly phone: (
    alias: string,
  ) => { readonly name: string; readonly id: string; readonly platform: string } | undefined
  /** A machine's server, by its Bancada id (the hub's catalog). */
  readonly machine: (machineID: string) => Server | undefined
  readonly alerts: () => ReadonlyArray<{ id: string; at: number; kind: string; text: string }>
}) {
  const db = input.db
  const open = db.query<JobRow, [string]>(
    "SELECT id, session_id, root_session_id, origin, parts, view, state, created_at FROM job WHERE root_session_id = ? AND state NOT IN ('entregue') ORDER BY created_at, id",
  )
  const own = db.query<JobRow, []>(
    "SELECT id, session_id, root_session_id, origin, parts, view, state, created_at FROM job WHERE state NOT IN ('entregue', 'concluido', 'recebido') ORDER BY created_at, id",
  )
  const serverOf = (machine: NonNullable<View["machine"]>) =>
    input.machine(machine.machineID) ??
    server(
      machine.instanceID ??
        (machine.machineID === input.self().machineID ? input.self().instanceID : machine.machineID),
      machine.name,
    )
  const byOf = (row: JobRow): By => {
    const origin: Origin = JSON.parse(row.origin)
    const root = row.session_id === row.root_session_id
    const title = root ? origin.rootTitle : origin.sessionTitle
    return { sessionID: row.session_id, ...(title ? { title } : {}), root }
  }
  const away = () => input.hubState() === "unavailable" || input.hubState() === "incompatible"

  const session = (root: string) => {
    const now = input.now()
    const jobs = open.all(root)
    const using: Record<string, unknown>[] = []
    const waiting: Record<string, unknown>[] = []
    for (const row of jobs) {
      const specs: Spec[] = JSON.parse(row.parts)
      const views: Record<string, View> = JSON.parse(row.view)
      const by = byOf(row)
      for (const spec of specs) {
        const view = views[spec.part]
        if (!view) continue
        const forJob = { type: "job", job: row.id, teste: spec.part, partLabel: spec.label }
        if (running.has(view.state) && view.state !== "incerto" && spec.platform !== "none" && view.machine) {
          const machine = serverOf(view.machine)
          const devices = view.devices?.length ? view.devices : [{ kind: spec.platform, id: "" }]
          devices.forEach((device, index) => {
            const kind = kindOf(device, spec.platform)
            using.push({
              key: `${row.id}/${spec.part}/${device.id || index}`,
              kind,
              kindLabel: kindLabel(kind),
              ...(device.resourceID ? { resourceID: device.resourceID } : {}),
              machine,
              ...(device.resourceID
                ? { viewer: { instanceID: machine.instanceID, resourceID: device.resourceID } }
                : {}),
              by,
              use: { ...forJob, state: useState(view.state), since: view.since ?? row.created_at },
            })
          })
        }
        if (queued.has(view.state)) {
          const hubOut = away()
          const reason: Reason = hubOut
            ? { code: "aguardando_hub", text: "aguardando o hub" }
            : (view.reason ?? { code: "aguardando_confirmacao", text: "aguardando confirmação do hub" })
          waiting.push({
            key: `${row.id}/${spec.part}`,
            what: what(spec),
            by,
            for: forJob,
            queue: { job: row.id },
            ...(!hubOut && view.position !== undefined ? { position: view.position } : {}),
            ...(!hubOut && view.etaMs !== undefined ? { etaMs: view.etaMs } : {}),
            reason,
            since: view.since ?? row.created_at,
          })
        }
      }
    }
    for (const hold of input.holds(root)) {
      const target: { kind: string; platform?: string; name?: string; device?: string } = JSON.parse(hold.target)
      const phone = target.kind === "fisico" ? input.phone(target.device!) : undefined
      const kind: Exclude<Kind, "none"> =
        target.kind === "fisico"
          ? phone?.platform === "ios"
            ? "ios-device"
            : "android-device"
          : target.platform === "ios"
            ? "ios-simulator"
            : "android-emulator"
      const name = phone?.name ?? target.name ?? target.device ?? ""
      const resourceID =
        kind === "android-device"
          ? `android-device:${phone?.id ?? target.device}`
          : kind === "ios-device"
            ? `ios-device:${phone?.id ?? target.device}`
            : kind === "android-emulator"
              ? `android-emulator:${target.name}`
              : undefined
      const by: By = { sessionID: hold.session_id, root: hold.session_id === root }
      if (hold.state === "concedida") {
        const machine =
          (hold.machine_id && input.machine(hold.machine_id)) ||
          (hold.machine_id === input.self().machineID
            ? server(input.self().instanceID, input.self().name)
            : server(hold.machine_id, hold.machine_name ?? "outra máquina"))
        using.push({
          key: `hold/${hold.hold}`,
          kind,
          kindLabel: kindLabel(kind),
          name,
          ...(resourceID ? { resourceID } : {}),
          machine,
          by,
          use: {
            type: "hold",
            hold: hold.hold,
            since: hold.requested_at,
            ...(hold.expires_at !== null ? { expiresAt: hold.expires_at } : {}),
          },
        })
        continue
      }
      waiting.push({
        key: `hold/${hold.hold}`,
        what: {
          kind,
          count: { min: 1, max: 1 },
          label:
            target.kind === "fisico" ? name : `1 ${kind === "ios-simulator" ? "simulador iOS" : "emulador Android"}`,
        },
        by,
        for: { type: "hold", hold: hold.hold },
        ...(hold.position !== null ? { position: hold.position } : {}),
        reason: {
          code:
            hold.state === "pedida"
              ? "aguardando_confirmacao"
              : target.kind === "fisico"
                ? "aparelho_ocupado"
                : "orcamento",
          text: hold.reason ?? (hold.state === "pedida" ? "aguardando resposta" : "aguardando"),
        },
        since: hold.requested_at,
      })
    }
    // Tests first, then holds, the most recent use first; waits, the oldest first.
    const useSince = (item: Record<string, unknown>) => (item.use as { since: number }).since
    using.sort(
      (a, b) =>
        Number((a.use as { type: string }).type === "hold") - Number((b.use as { type: string }).type === "hold") ||
        useSince(b) - useSince(a) ||
        String(a.key).localeCompare(String(b.key)),
    )
    waiting.sort((a, b) => (a.since as number) - (b.since as number) || String(a.key).localeCompare(String(b.key)))
    const sessions = [...new Set([...using, ...waiting].map((item) => (item.by as By).sessionID))].toSorted(
      (a, b) => Number(b === root) - Number(a === root) || a.localeCompare(b),
    )
    const members = sessions.map((sessionID) => {
      const mine = waiting.filter((item) => (item.by as By).sessionID === sessionID)
      const best = mine.toSorted(
        (a, b) =>
          ((a.position as number | undefined) ?? Infinity) - ((b.position as number | undefined) ?? Infinity) ||
          (a.since as number) - (b.since as number),
      )[0]
      const by = [...using, ...waiting].find((item) => (item.by as By).sessionID === sessionID)!.by as By
      return {
        sessionID,
        ...(by.title ? { title: by.title } : {}),
        root: sessionID === root,
        using: using.filter((item) => (item.by as By).sessionID === sessionID).length,
        ...(best
          ? {
              waiting: {
                count: mine.length,
                ...(best.position !== undefined ? { position: best.position } : {}),
                ...(best.etaMs !== undefined ? { etaMs: best.etaMs } : {}),
                reason: best.reason,
              },
            }
          : {}),
      }
    })
    return {
      version: 1,
      now,
      hub: input.hubState(),
      counts: { using: using.length, waiting: waiting.length },
      using,
      waiting,
      members,
    }
  }

  /** The whole queue, on the hub (`scope: "all"`). */
  const all = () => {
    const now = input.now()
    const jobs = db
      .query<
        { id: string; origin: string; created_at: number },
        []
      >("SELECT id, origin, created_at FROM hub_job WHERE closed_at IS NULL AND cancelled_at IS NULL ORDER BY created_at, id")
      .all()
    const parts = db.query<
      {
        part: string
        idx: number
        spec: string
        state: PartState
        machine_id: string | null
        devices_granted: number | null
        since: number
        offered_at: number | null
        acked_at: number | null
        waiting: string | null
      },
      [string]
    >(
      "SELECT part, idx, spec, state, machine_id, devices_granted, since, offered_at, acked_at, waiting FROM hub_part WHERE job_id = ? ORDER BY idx",
    )
    const machineRows = db
      .query<
        { machine_id: string; instance_id: string; name: string; state: string },
        []
      >("SELECT machine_id, instance_id, name, state FROM hub_machine ORDER BY name, machine_id")
      .all()
    const machineOf = (id: string) => {
      const row = machineRows.find((item) => item.machine_id === id)
      return row ? server(row.instance_id, row.name) : server(id, id)
    }
    const runningGroups: Group[] = []
    const waitingGroups: Group[] = []
    for (const job of jobs) {
      const origin: Origin = JSON.parse(job.origin)
      const session = sessionOf(origin)
      const rows = parts.all(job.id)
      const accepted = rows.flatMap((row) => row.acked_at ?? row.offered_at ?? [])
      const run = rows
        .filter((row) => running.has(row.state) && row.machine_id)
        .map((row) => {
          const spec: Spec = JSON.parse(row.spec)
          return {
            teste: row.part,
            label: spec.label,
            platform: spec.platform,
            machine: machineOf(row.machine_id!),
            state: row.state === "incerto" ? ("incerto" as const) : useState(row.state),
            devices: row.devices_granted ?? 0,
            since: row.acked_at ?? row.offered_at ?? row.since,
          }
        })
      const wait = rows
        .filter((row) => row.state === "na_fila")
        .map((row) => {
          const spec: Spec = JSON.parse(row.spec)
          const where: { reason?: Reason; position?: number; etaMs?: number } = row.waiting
            ? JSON.parse(row.waiting)
            : {}
          return {
            teste: row.part,
            label: spec.label,
            platform: spec.platform,
            ...(where.position !== undefined ? { position: where.position } : {}),
            ...(where.etaMs !== undefined ? { etaMs: where.etaMs } : {}),
            reason: where.reason ?? { code: "fila", text: "na fila" },
            since: row.since,
          }
        })
      if (run.length) runningGroups.push({ job: job.id, since: Math.min(...accepted), session, parts: run })
      if (wait.length) waitingGroups.push({ job: job.id, since: job.created_at, session, parts: wait })
    }
    return finish(
      now,
      "all",
      runningGroups,
      waitingGroups,
      machineRows.map((row) => ({
        server: server(row.instance_id, row.name),
        state: machineState(row.state),
      })),
    )
  }

  /** What this server knows, on a machine that is not the hub (`scope: "local"`). */
  const local = () => {
    const now = input.now()
    const self = input.self()
    const runningGroups: Group[] = []
    const waitingGroups: Group[] = []
    const hubOut = away()
    for (const row of own.all()) {
      const origin: Origin = JSON.parse(row.origin)
      const specs: Spec[] = JSON.parse(row.parts)
      const views: Record<string, View> = JSON.parse(row.view)
      const run = specs
        .filter((spec) => views[spec.part] && running.has(views[spec.part]!.state) && views[spec.part]!.machine)
        .map((spec) => {
          const view = views[spec.part]!
          return {
            teste: spec.part,
            label: spec.label,
            platform: spec.platform,
            machine: serverOf(view.machine!),
            state: view.state === "incerto" ? ("incerto" as const) : useState(view.state),
            devices: view.devices?.length ?? (spec.platform === "none" ? 0 : spec.devices.min),
            since: view.since ?? row.created_at,
          }
        })
      const wait = specs
        .filter((spec) => views[spec.part] && queued.has(views[spec.part]!.state))
        .map((spec) => {
          const view = views[spec.part]!
          return {
            teste: spec.part,
            label: spec.label,
            platform: spec.platform,
            ...(!hubOut && view.position !== undefined ? { position: view.position } : {}),
            ...(!hubOut && view.etaMs !== undefined ? { etaMs: view.etaMs } : {}),
            reason: hubOut
              ? { code: "aguardando_hub" as const, text: "aguardando o hub" }
              : (view.reason ?? { code: "aguardando_confirmacao" as const, text: "aguardando confirmação do hub" }),
            since: view.since ?? row.created_at,
          }
        })
      const session = sessionOf(origin)
      if (run.length)
        runningGroups.push({ job: row.id, since: Math.min(...run.map((part) => part.since)), session, parts: run })
      if (wait.length) waitingGroups.push({ job: row.id, since: row.created_at, session, parts: wait })
    }
    return finish(now, "local", runningGroups, waitingGroups, [
      { server: server(self.instanceID, self.name), state: "ok" as const },
    ])
  }

  type Group = {
    job: string
    since: number
    session: ReturnType<typeof sessionOf>
    parts: ReadonlyArray<{ since: number; machine?: Server } & Record<string, unknown>>
  }
  const finish = (
    now: number,
    scope: "all" | "local",
    runningGroups: Group[],
    waitingGroups: Group[],
    machines: { server: Server; state: string }[],
  ) => {
    // The request that started running last first; the waiting ones in arrival order. Ties by the id.
    runningGroups.sort((a, b) => b.since - a.since || a.job.localeCompare(b.job))
    waitingGroups.sort((a, b) => a.since - b.since || a.job.localeCompare(b.job))
    const runningParts = runningGroups.flatMap((group) => group.parts)
    return {
      version: 1,
      now,
      scope,
      hub: input.hubState(),
      counts: { running: runningParts.length, waiting: waitingGroups.flatMap((group) => group.parts).length },
      running: runningGroups,
      waiting: waitingGroups,
      machines: machines.map((item) => ({
        ...item,
        running: runningParts.filter((part) => part.machine?.instanceID === item.server.instanceID).length,
      })),
      alerts: input.alerts().map((alert) => ({ id: alert.id, at: alert.at, kind: alert.kind, text: alert.text })),
    }
  }

  return { session, queue: () => (input.isHub ? all() : local()) }
}

function sessionOf(origin: Origin) {
  const root = origin.sessionID === origin.rootSessionID
  return {
    server: server(origin.instanceID, origin.name),
    sessionID: origin.sessionID,
    rootSessionID: origin.rootSessionID,
    ...(origin.rootTitle ? { title: origin.rootTitle } : {}),
    ...(!root && origin.sessionTitle ? { by: origin.sessionTitle } : {}),
  }
}

function machineState(state: string) {
  if (state === "ok" || state === "reconciling") return state
  if (state === "silenciosa") return "silent"
  if (state === "incompativel" || state === "incompatible") return "incompatible"
  return "away"
}

/**
 * When the apps should reload (`docs/bancada.md`, "changed"): a family's `session` or the `queue` differs from what was
 * last said, estimates aside, or an alert is new; at most once a second. In memory: a restart says everything once.
 */
export function makeChanges(input: {
  readonly now: () => number
  readonly queue: () => unknown
  readonly session: (root: string) => unknown
  /** The families whose view may be showing now. */
  readonly roots: () => ReadonlyArray<string>
  readonly alerts: () => ReadonlyArray<{ id: string; kind: string; text: string }>
}) {
  const seen = new Map<string, string>()
  const alerted = new Set<string>()
  const last = { at: Number.NEGATIVE_INFINITY }
  const stable = (value: unknown) =>
    JSON.stringify(value, (key, item) => (key === "now" || key === "etaMs" ? undefined : item))
  return () => {
    if (input.now() - last.at < 1_000) return undefined
    const roots = [...new Set([...input.roots(), ...[...seen.keys()].filter((key) => key !== "\u0000queue")])]
    const sessions = roots.filter((root) => {
      const now = stable(input.session(root))
      if (seen.get(root) === now) return false
      seen.set(root, now)
      return true
    })
    const queue = stable(input.queue())
    const queueChanged = seen.get("\u0000queue") !== queue
    seen.set("\u0000queue", queue)
    const alerts = input.alerts().filter((alert) => !alerted.has(alert.id))
    alerts.forEach((alert) => alerted.add(alert.id))
    if (sessions.length === 0 && !queueChanged && alerts.length === 0) return undefined
    last.at = input.now()
    return {
      sessions,
      queue: queueChanged,
      alerts: alerts.map((alert) => ({ id: alert.id, kind: alert.kind, text: alert.text })),
    }
  }
}
