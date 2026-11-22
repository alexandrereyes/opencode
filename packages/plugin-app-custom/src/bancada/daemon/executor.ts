import type { Database } from "bun:sqlite"
import { buildCost, dockerExtraPerDevice } from "../catalog/costs.js"
import type { BrakeConfig, Range } from "../machine-config.js"
import { BancadaProtocol } from "../protocol.js"
import { evidence, judge, type Ending } from "../results.js"
import { open, step, type Brake, type Reading } from "./brake.js"
import { unmet } from "./capabilities.js"
import { phoneTags, seat } from "./scheduler.js"
import { add, free as budgetFree, largestFit, measured, room, samples, times, zero, type Cost } from "./budget.js"
import { deviceFor } from "./devices/types.js"
import { block } from "./devices/ports.js"

/** The key of an attempt: a part of a job, and its number. */
export type AttemptKey = { readonly job: string; readonly part: string; readonly attempt: number }

/**
 * An attempt where it runs: its group, the parts of one request this machine accepted together, which share a
 * working folder, build once and run side by side (`docs/bancada.md`, "Requests with several parts").
 */
export type Placed = AttemptKey & { readonly group: string }

/** What the launcher needs to start a group (the real one writes the group's folder, `docs/bancada.md`). */
export type Launch = {
  readonly job: string
  readonly group: string
  readonly code: BancadaProtocol.Code
  readonly parts: ReadonlyArray<{
    readonly part: string
    readonly attempt: number
    readonly spec: BancadaProtocol.PartSpec
    readonly devices: number
    readonly only?: ReadonlyArray<string>
  }>
  /** The session's repository, when the request came from this machine: the code is fetched from it, nothing travels. */
  readonly repository?: string
  /** The origin's bundle, received through the hub and checked: the code is fetched from it. */
  readonly bundle?: string
}

/**
 * A start that found no way to bring the commit (not here, not in the session's repository nor a remote): the executor
 * asks the origin for it through the hub and starts again with the bundle (`docs/bancada.md`, "Frozen code").
 */
export class CodeMissing extends Error {
  constructor(
    message: string,
    /** A bundle came and did not apply here: asked again, whole (`transfers.ts`). */
    readonly spoiled = false,
  ) {
    super(message)
  }
}

/** How the code of a request asked through the hub stands on this machine (`transfers.ts`). */
export type CodeState = { readonly state: string; readonly file: string | null; readonly reason: string | null }

/**
 * What an execution reports, read from its folder: still building or running, or ended (how, with the project's files,
 * judged by `results.ts`). `gone`: it never started, or the launcher has no trace of it. `unstarted`: this process
 * never started it and no runner took it (the process restarted in between): start it again.
 */
export type Status =
  | { readonly state: "compilando" | "rodando" | "unstarted" }
  | { readonly state: "done"; readonly ending: Ending }
  | { readonly state: "gone"; readonly reason: string }

/**
 * Starts executions away from the server and reads how they go; every method is idempotent per attempt. `start` and
 * `cleanup` may take minutes (a fetch, a big folder): the executor runs them off its round. `status` and `reap` read
 * only what is local and never wait for long work.
 */
export interface Launcher {
  readonly start: (launch: Launch) => Promise<void>
  /** Rejects when it cannot tell (no answer about the runner yet): nothing changes for that attempt this round. */
  readonly status: (key: Placed) => Promise<Status>
  /** Asks one part to stop; it ends with `cancelado`. */
  readonly cancel: (key: Placed) => Promise<void>
  /** Ends a group's runner that did not answer a cancel, with proof it is that runner; its orphans go by `reap`. */
  readonly stop: (key: Placed) => Promise<void>
  /**
   * What groups without a live attempt still hold (their working folder) goes back once nothing they started runs:
   * the launcher ends what they left with proof it is theirs, on its own time.
   */
  readonly reap: (live: ReadonlyArray<Placed>) => Promise<void>
  /** Whether an attempt's group still holds anything here (its folder, or the giving back still runs). */
  readonly held: (key: Placed) => boolean
  /** After delivery: nothing of the group stays (its folder, the commit's ref); rejects while it still holds any. */
  readonly cleanup: (key: Placed) => Promise<void>
}

/** What this machine offers and how much of it (`docs/bancada.md`, "Budget"), from its machine file. */
export type Limits = {
  readonly capacity: BancadaProtocol.Vector
  /** What this machine offers now (discovery runs again every 10 min). */
  readonly capabilities: () => Readonly<Record<string, unknown>>
  /** MyCredentials policies resolved here: a part with `segredos` is accepted only when its policy is listed. */
  readonly secrets: ReadonlyArray<string>
  readonly presence: { readonly idleMs: number; readonly factor: number }
  readonly brake: BrakeConfig
  /** The machine's `portas.projeto`: each granted device gets a block of it. */
  readonly ports: Range
  /** Executions in containers: an Android device is an emulator in a container. */
  readonly docker: boolean
  /** How many scenarios are worth one device without history (`cenarios_por_aparelho`). */
  readonly scenariosPerDevice: number
}

/** The scenario the machine file's `cenarios_por_aparelho` counts: with history, a device takes that many times it. */
export const referenceScenarioMs = 30_000

type AttemptRow = {
  readonly job_id: string
  readonly part: string
  readonly n: number
  readonly origin: string
  readonly code: string
  readonly spec: string
  readonly devices: number
  /** How many scenarios are worth one of its devices (`devices/pool.ts`); null when accepted before r27. */
  readonly per_device: number | null
  readonly only_scenarios: string | null
  readonly state: string
  readonly lease_id: string
  readonly phone_hold: string | null
  readonly group_id: string | null
  readonly cancel_at: number | null
  readonly cancel_reason: string | null
  readonly started_at: number | null
  readonly outcome: string | null
  /** What it keeps for the notice: `{ index, path, size, sha256, file }[]`. */
  readonly evidence: string | null
}

/** How long an execution may take to answer a cancel before its runner is ended (`docs/bancada.md`, "Cancel"). */
export const cancelGraceMs = 15_000

/**
 * This machine's authority over what it runs (`docs/bancada.md`, "Executor"): it accepts or refuses each offer
 * against its own reservations, records the attempt and its reservation in one transaction before anything starts,
 * starts it, follows it and reports every change to the hub. Its database is the truth about this machine; the hub
 * only mirrors it.
 */
export function makeExecutor(input: {
  readonly db: Database
  readonly now: () => number
  readonly random: () => string
  readonly machineID: string
  readonly limits: Limits
  readonly launcher: Launcher
  readonly send: (body: BancadaProtocol.FromMachine) => void
  /** The session's repository of a request this machine's origin holds (the same machine: nothing travels). */
  readonly repository: (job: string) => string | undefined
  /** Asks for a round: a task of an attempt ended. */
  readonly wake: () => void
  /** An ended attempt no `cleanup` reached in this long is cleaned up here. */
  readonly keepMs: number
  /** An offer was refused for a capability this machine published: discovery runs again. */
  readonly missed?: () => void
  /** A phone for a test's attempt, and giving it back on a refused offer (`holds.ts`). */
  readonly phone?: {
    readonly take: (want: {
      readonly platform: "android" | "ios"
      readonly tags: ReadonlyArray<string>
      readonly origin: BancadaProtocol.Origin
      readonly attempt: string
      readonly hold: string
    }) => unknown
    readonly drop: (hold: string) => void
  }
  /** Light slots waiting for room, per kind (`holds.ts`). */
  readonly slots?: () => { readonly android: number; readonly ios: number }
  /** The code through the hub; without it, a start without code loses its attempt. */
  readonly code?: {
    readonly ask: (job: string, project: string) => void
    /** The bundle that came did not apply: asked again, whole, while tries are left. */
    readonly spoiled: (job: string, reason: string) => void
    readonly state: (job: string) => CodeState | undefined
    readonly forget: (job: string) => void
  }
}) {
  const db = input.db
  const limits = input.limits
  const used = db.query<BancadaProtocol.Vector, []>(
    "SELECT COALESCE(SUM(mem_mb), 0) AS memMb, COALESCE(SUM(cpu_milli), 0) AS cpuMilli, COALESCE(SUM(builds), 0) AS builds, COALESCE(SUM(android), 0) AS android, COALESCE(SUM(ios), 0) AS ios FROM lease WHERE state = 'active'",
  )
  const samplesOf = db.query<Cost, [string, number]>(
    "SELECT mem_mb AS memMb, cpu_milli AS cpuMilli FROM cost_sample WHERE subject = ? ORDER BY at DESC LIMIT ?",
  )
  const portsTaken = db.query<Range, []>(
    "SELECT d.port_start AS start, d.port_end AS end FROM lease_device d JOIN lease l ON l.id = d.lease_id WHERE l.state = 'active'",
  )
  /** The brake and the owner's presence, from the process's readings (`observe`); in memory, read again on restart. */
  const watch: { brake: Brake; present: boolean } = { brake: open, present: false }
  const live = db.query<AttemptRow, []>(
    "SELECT * FROM attempt WHERE state IN ('aceito', 'compilando', 'rodando') ORDER BY accepted_at",
  )
  const ended = db.query<AttemptRow, []>(
    "SELECT * FROM attempt WHERE state IN ('concluido', 'perdido', 'cancelado') ORDER BY ended_at",
  )
  const delivered = db.query<AttemptRow, []>(
    "SELECT a.* FROM attempt a JOIN lease l ON l.id = a.lease_id WHERE a.state = 'limpar' AND l.state <> 'active'",
  )
  /** Ended attempts whose reservation still counts: it goes back with their folder (and devices), in the giving back. */
  const usedDevices = db.query<{ id: string; kind: string; running: string | null }, [string]>(
    "SELECT d.id, d.kind, d.running FROM lease_device l JOIN device d ON d.id = l.device_id WHERE l.lease_id = ? ORDER BY l.rowid",
  )
  const holding = db.query<AttemptRow, []>(
    "SELECT a.* FROM attempt a JOIN lease l ON l.id = a.lease_id WHERE a.state NOT IN ('aceito', 'compilando', 'rodando') AND l.state = 'active'",
  )
  /**
   * Back after a restart with attempts it had started: until one round has read each of them again, this executor
   * takes no new offer (`docs/bancada.md`, "Reconciliation"), and its pulse says `reconciling`.
   */
  const reconciling = { value: live.all().length > 0 }
  const findAttempt = db.query<AttemptRow, [string, string, number]>(
    "SELECT * FROM attempt WHERE job_id = ? AND part = ? AND n = ?",
  )
  /**
   * Work of an attempt that may take long (its start, its removal): it runs on its own and a later round collects how
   * it ended (`docs/bancada.md`, "Process"). Per process: after a restart the launcher says what to start again.
   */
  const tasks = new Map<string, { done: boolean; failure?: string; missing?: boolean; spoiled?: boolean }>()
  const run = (id: string, work: () => Promise<void>) => {
    const task: { done: boolean; failure?: string; missing?: boolean; spoiled?: boolean } = { done: false }
    tasks.set(id, task)
    void work()
      .catch((error: unknown) => {
        task.failure = error instanceof Error ? error.message : String(error)
        task.missing = error instanceof CodeMissing
        task.spoiled = error instanceof CodeMissing && error.spoiled
      })
      .finally(() => {
        task.done = true
        input.wake()
      })
  }
  const inGroup = db.query<AttemptRow, [string, string]>(
    "SELECT * FROM attempt WHERE job_id = ? AND group_id = ? AND state IN ('aceito', 'compilando', 'rodando') ORDER BY part",
  )
  const placed = (row: AttemptRow): Placed => ({
    job: row.job_id,
    part: row.part,
    attempt: row.n,
    group: row.group_id ?? `${row.part}-${row.n}`,
  })
  const keyOf = (row: AttemptRow): AttemptKey => ({ job: row.job_id, part: row.part, attempt: row.n })
  /** The lease that holds the build of a request's group not started yet, if any. */
  const carrier = db.query<{ id: string }, [string]>(
    "SELECT l.id FROM attempt a JOIN lease l ON l.id = a.lease_id WHERE a.job_id = ? AND a.state = 'aceito' AND a.group_id IS NULL AND a.cancel_at IS NULL AND l.builds > 0 AND l.state = 'active'",
  )
  /** A sibling that would build but holds no build: the one the build passes to when its carrier leaves first. */
  const heir = db.query<AttemptRow & { lease: string }, [string]>(
    "SELECT a.*, l.id AS lease FROM attempt a JOIN lease l ON l.id = a.lease_id WHERE a.job_id = ? AND a.state = 'aceito' AND a.group_id IS NULL AND a.cancel_at IS NULL AND l.builds = 0 AND l.state = 'active' ORDER BY a.part",
  )
  const startOf = (job: string, group: string) => `start:${job}/${group}`
  /** A request of another machine's session whose bundle has not arrived yet: its group does not form. */
  const waitingCode = (job: string) => {
    const code = input.code?.state(job)
    return code !== undefined && code.state !== "pronto" && code.state !== "falhou"
  }
  /** Code that may come through the hub: the request is another machine's, and no bundle came for it yet. */
  const throughHub = (row: AttemptRow) =>
    (JSON.parse(row.origin) as BancadaProtocol.Origin).machineID !== input.machineID &&
    input.code?.state(row.job_id)?.state !== "pronto"
  /**
   * Starts a group (`docs/bancada.md`, "Requests with several parts"): the attempts of one request accepted together,
   * one working folder, one build, the runs side by side; or a group again after a restart.
   */
  const begin = (rows: ReadonlyArray<AttemptRow>, group: string) => {
    const first = rows[0]!
    rows.forEach((row) =>
      db.run("UPDATE attempt SET group_id = ? WHERE job_id = ? AND part = ? AND n = ?", [
        group,
        row.job_id,
        row.part,
        row.n,
      ]),
    )
    const origin: BancadaProtocol.Origin = JSON.parse(first.origin)
    const repository = origin.machineID === input.machineID ? input.repository(first.job_id) : undefined
    const code = input.code?.state(first.job_id)
    const bundle = code?.state === "pronto" && code.file ? code.file : undefined
    run(startOf(first.job_id, group), () =>
      input.launcher.start({
        job: first.job_id,
        group,
        code: JSON.parse(first.code),
        parts: rows.map((row) => ({
          part: row.part,
          attempt: row.n,
          spec: JSON.parse(row.spec),
          devices: row.devices,
          ...(row.only_scenarios ? { only: JSON.parse(row.only_scenarios) } : {}),
        })),
        ...(repository ? { repository } : {}),
        ...(bundle ? { bundle } : {}),
      }),
    )
  }

  /** What this machine measured of a subject (the last samples), or its default cost before it has enough. */
  const costOf = (subject: string, fallback: Cost) => measured(samplesOf.all(subject, samples.kept), fallback)
  const simslim = () => {
    const ios = limits.capabilities().ios
    return typeof ios === "object" && ios !== null && "simslim" in ios && ios.simslim === true
  }
  const device = (platform: BancadaProtocol.Platform, spec: BancadaProtocol.DeviceSpec) => {
    const found = deviceFor(platform, spec, { docker: limits.docker, simslim: simslim() })
    return found ? costOf(found.subject, found.cost) : zero
  }
  /** What new admissions may use now: a share of memory and CPU while the owner uses the Mac. */
  const current = () => {
    const base = room(limits.capacity, used.get()!, watch.present ? limits.presence.factor : 1)
    // The light slots waiting for room take the next room (`docs/bancada.md`, "Holds"): tests wait behind them.
    const waiting = input.slots?.() ?? { android: 0, ios: 0 }
    const held = add(times(device("android", slim), waiting.android), times(device("ios", slim), waiting.ios))
    return {
      ...base,
      memMb: base.memMb - held.memMb,
      cpuMilli: base.cpuMilli - held.cpuMilli,
      android: base.android - waiting.android,
      ios: base.ios - waiting.ios,
    }
  }
  const slim = { slim: "aceita" } as const

  /**
   * A light slot of `platform` reserved now, when one device of its kind fits (`docs/bancada.md`, "Holds"): its
   * lease's id. A slot holds no build and no ports: the session starts the device itself.
   */
  const reserveSlot = (platform: "android" | "ios") => {
    const cost = device(platform, slim)
    // The slot asking is one of those waiting, whose room `current()` set aside: that share is its own.
    const own = (input.slots?.()[platform] ?? 0) > 0
    const now = current()
    const fits = largestFit({
      room: own
        ? {
            ...now,
            memMb: now.memMb + cost.memMb,
            cpuMilli: now.cpuMilli + cost.cpuMilli,
            [platform]: now[platform] + 1,
          }
        : now,
      builds: 0,
      platform,
      min: 1,
      proposed: 1,
      build: zero,
      device: cost,
      extra: () => zero,
    })
    if (fits === undefined) return undefined
    const lease = input.random()
    db.run(
      "INSERT INTO lease (id, kind, owner, android, ios, mem_mb, cpu_milli, builds, build_mem_mb, build_cpu_milli, state, created_at) VALUES (?, 'hold', ?, ?, ?, ?, ?, 0, 0, 0, 'active', ?)",
      [
        lease,
        `vaga:${platform}`,
        platform === "android" ? 1 : 0,
        platform === "ios" ? 1 : 0,
        cost.memMb,
        cost.cpuMilli,
        input.now(),
      ],
    )
    return lease
  }
  const releaseLease = (lease: string) =>
    db.run("UPDATE lease SET state = 'released', released_at = ? WHERE id = ? AND state = 'active'", [
      input.now(),
      lease,
    ])

  /** The pulse's free vector: the hub never offers beyond it (a default build, default devices). */
  const free = (): BancadaProtocol.Vector =>
    budgetFree(current(), buildCost, {
      android: device("android", { slim: "aceita" }),
      ios: device("ios", { slim: "aceita" }),
    })

  /** What a test takes beside its `n` devices (its containers): measured, else the default for one that needs Docker. */
  const extraOf = (project: string, spec: BancadaProtocol.PartSpec) => {
    const measuredExtra = samplesOf.all(`extra:${project}/${spec.part}`, samples.kept)
    return (n: number) =>
      measuredExtra.length >= samples.trusted
        ? measured(measuredExtra, zero)
        : spec.needs.includes("docker")
          ? times(dockerExtraPerDevice, n)
          : zero
  }

  /**
   * An attempt's peak at admission (`docs/bancada.md`, "Budget"): its project's build, its devices and what the test
   * takes beside them, with as many devices between the offer's minimum and proposal as fit now. A test with a plan
   * reserves only its minimum: it grows after its plan says how many it can use (`grow`).
   */
  const admit = (message: typeof BancadaProtocol.Offer.Type) => {
    const spec = message.spec
    // One build per group: a sibling accepted and not started yet already holds it (`docs/bancada.md`, "Groups").
    const building = spec.build && !carrier.get(message.job)
    const build = building ? costOf(`build:${message.code.project}`, buildCost) : zero
    const platform = seat(spec)
    const unit = device(platform, spec.device)
    const extra = extraOf(message.code.project, spec)
    const devices = largestFit({
      room: current(),
      builds: building ? 1 : 0,
      platform,
      min: message.devices.min,
      proposed: spec.plan
        ? Math.min(message.devices.proposed, Math.max(1, message.devices.min))
        : message.devices.proposed,
      build,
      device: unit,
      extra,
    })
    return devices === undefined
      ? undefined
      : { devices, build, builds: building ? 1 : 0, peak: add(build, times(unit, devices), extra(devices)) }
  }

  /** A block of the project's ports for each granted device, none shared with a live reservation. */
  const portsFor = (devices: number) =>
    Array.from({ length: devices }).reduce<Range[] | undefined>((blocks) => {
      if (!blocks) return undefined
      const next = block(limits.ports, [...portsTaken.all(), ...blocks])
      return next ? [...blocks, next] : undefined
    }, [])

  /**
   * Called inside the transaction that applies the hub's message (`docs/bancada.md`, "Accept or refuse"): this
   * machine's answer is the truth, the hub only mirrors it. Refused while reconciling, with the brake closed, when a
   * capability is gone or the part's policy is not resolved here, when not even its minimum fits.
   */
  const offer = (message: typeof BancadaProtocol.Offer.Type) => {
    const known = findAttempt.get(message.job, message.part, message.attempt)
    if (known) return answerAgain(known)
    const refuse = (reason: BancadaProtocol.Reason) =>
      input.send({
        type: "offer.reply",
        job: message.job,
        part: message.part,
        attempt: message.attempt,
        accepted: false,
        reason,
      })
    if (reconciling.value) return refuse({ code: "reconciliando", text: "reconciliando" })
    if (watch.brake.closed) return refuse({ code: "freio", text: `freio fechado: ${watch.brake.reasons.join("; ")}` })
    const missing = message.spec.needs.filter((need) => !(need in limits.capabilities()))
    const short = missing.length > 0 ? missing.join(", ") : unmet(message.spec, limits.capabilities())
    if (short) {
      // What it had may have changed since discovery last ran: it looks again.
      input.missed?.()
      return refuse({ code: "sem_maquina", text: `esta máquina não oferece mais ${short}` })
    }
    const secrets = message.spec.secrets
    if (secrets && !limits.secrets.includes(secrets))
      return refuse({ code: "sem_maquina", text: `a policy ${secrets} não está na lista segredos desta máquina` })
    // A phone first (`docs/bancada.md`, "Phones"): the part's other devices only once it has one.
    const tags = phoneTags(message.spec)
    const physical = tags !== undefined
    const phoneHold = physical ? `p-${input.random()}` : undefined
    if (
      phoneHold &&
      !input.phone?.take({
        platform: message.spec.platform as "android" | "ios",
        tags: tags ?? [],
        origin: message.origin,
        attempt: `${message.job}/${message.part}/${message.attempt}`,
        hold: phoneHold,
      })
    )
      return refuse({ code: "aparelho_ocupado", text: "nenhum celular livre com o que o teste pede" })
    const admission = admit(message)
    const blocks = admission ? portsFor(admission.devices + (physical ? 1 : 0)) : undefined
    if (!admission || !blocks) {
      if (phoneHold) input.phone?.drop(phoneHold)
      return refuse(
        admission
          ? { code: "orcamento", text: "sem portas livres para os aparelhos" }
          : { code: "orcamento", text: "aguardando folga" },
      )
    }
    const kind = message.spec.platform
    const devices = admission.devices
    const lease = input.random()
    db.run(
      "INSERT INTO lease (id, kind, owner, android, ios, mem_mb, cpu_milli, builds, build_mem_mb, build_cpu_milli, state, created_at) VALUES (?, 'job', ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)",
      [
        lease,
        `${message.job}/${message.part}/${message.attempt}`,
        kind === "android" ? devices : 0,
        kind === "ios" ? devices : 0,
        admission.peak.memMb,
        admission.peak.cpuMilli,
        admission.builds,
        admission.build.memMb,
        admission.build.cpuMilli,
        input.now(),
      ],
    )
    blocks.forEach((ports) =>
      db.run("INSERT INTO lease_device (lease_id, device_id, port_start, port_end) VALUES (?, NULL, ?, ?)", [
        lease,
        ports.start,
        ports.end,
      ]),
    )
    db.run(
      "INSERT INTO attempt (job_id, part, n, origin, code, spec, devices, per_device, only_scenarios, state, lease_id, phone_hold, accepted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'aceito', ?, ?, ?)",
      [
        message.job,
        message.part,
        message.attempt,
        JSON.stringify(message.origin),
        JSON.stringify(message.code),
        JSON.stringify(message.spec),
        devices,
        // Without history, the machine file's; with it, as many as take that many reference scenarios here.
        message.scenarioMs
          ? Math.max(1, Math.round((limits.scenariosPerDevice * referenceScenarioMs) / message.scenarioMs))
          : limits.scenariosPerDevice,
        message.only ? JSON.stringify(message.only) : null,
        lease,
        phoneHold ?? null,
        input.now(),
      ],
    )
    input.send({
      type: "offer.reply",
      job: message.job,
      part: message.part,
      attempt: message.attempt,
      accepted: true,
      devices,
    })
  }

  /**
   * An offer of an attempt this executor already has: a hub that forgot (another database) offers again what it had
   * offered (`docs/bancada.md`, "When a side forgot"). The answer is said again (the acceptance and, past that, the
   * last report, with the result when it ended); nothing runs twice.
   */
  const answerAgain = (row: AttemptRow) => {
    if (row.state === "limpar") return
    input.send({
      type: "offer.reply",
      job: row.job_id,
      part: row.part,
      attempt: row.n,
      accepted: true,
      devices: row.devices,
    })
    if (row.state === "aceito") return
    input.send({
      type: "attempt",
      job: row.job_id,
      part: row.part,
      attempt: row.n,
      state: row.state as BancadaProtocol.AttemptState,
      ...(row.outcome ? { outcome: JSON.parse(row.outcome) } : {}),
      ...(row.only_scenarios ? { partial: true } : {}),
      ...(row.evidence
        ? {
            evidence: (JSON.parse(row.evidence) as (BancadaProtocol.File & { file: string })[]).map(
              ({ file: _, ...declared }) => declared,
            ),
          }
        : {}),
    })
  }

  /**
   * The hub gave an attempt up (withdrawn, lost, replaced, cancelled): called inside the transaction that applies the
   * message. One not started yet never starts; one that runs is asked to stop, and its runner is ended if it does not
   * answer within `cancelGraceMs` (`docs/bancada.md`, "Cancel").
   */
  const cancel = (message: typeof BancadaProtocol.AttemptCancel.Type) =>
    db.run(
      "UPDATE attempt SET cancel_at = ?, cancel_reason = ? WHERE job_id = ? AND part = ? AND n = ? AND state IN ('aceito', 'compilando', 'rodando') AND cancel_at IS NULL",
      [input.now(), message.reason, message.job, message.part, message.attempt],
    )

  /**
   * After delivery nothing of the job stays (D9): its attempts are cleaned once ended (the next round removes their
   * folders, then their rows); one still running stops, the request is over.
   */
  const cleanup = (message: typeof BancadaProtocol.Cleanup.Type) => {
    input.code?.forget(message.job)
    db.run("UPDATE attempt SET delivered = 1 WHERE job_id = ?", [message.job])
    db.run(
      "UPDATE attempt SET cancel_at = ?, cancel_reason = 'o pedido já foi entregue' WHERE job_id = ? AND state IN ('aceito', 'compilando', 'rodando') AND cancel_at IS NULL",
      [input.now(), message.job],
    )
  }

  /**
   * Starts what was accepted and follows what runs; one report per change. The round only reads what is local and
   * never waits for a task: an attempt whose start runs stays `aceito` and counts as not read yet. Every transition is
   * conditional on the state read before the `await`s, and reports only when the row changed. One attempt never holds
   * the others: a start that fails loses that attempt, a status that cannot be read leaves it as it was.
   */
  const tick = async () => {
    const unread = { count: 0 }
    // Ended long ago and never cleaned up: the origin delivered it, or never will, and the hub that would say so is
    // gone (`docs/bancada.md`, "When a side forgot").
    db.run(
      "UPDATE attempt SET delivered = 1 WHERE delivered = 0 AND state IN ('concluido', 'perdido', 'cancelado') AND ended_at < ?",
      [input.now() - input.keepMs],
    )
    db.run("UPDATE attempt SET state = 'limpar' WHERE delivered = 1 AND state IN ('concluido', 'perdido', 'cancelado')")
    // Groups whose start ended: started, or lost with the reason.
    for (const [id, task] of tasks) {
      if (!id.startsWith("start:") || !task.done) continue
      tasks.delete(id)
      const slash = id.indexOf("/")
      const rows = inGroup.all(id.slice("start:".length, slash), id.slice(slash + 1))
      const first = rows[0]
      // The code is not here, or its bundle did not apply (infrastructure, never the code's fault): asked from the
      // origin through the hub, whole after a bundle that failed; the group forms again when it arrives.
      if (task.missing && first && input.code && (throughHub(first) || task.spoiled)) {
        rows.forEach((row) =>
          db.run("UPDATE attempt SET group_id = NULL WHERE job_id = ? AND part = ? AND n = ?", [
            row.job_id,
            row.part,
            row.n,
          ]),
        )
        if (task.spoiled) input.code.spoiled(first.job_id, task.failure ?? "o pacote não se aplicou")
        else input.code.ask(first.job_id, (JSON.parse(first.code) as BancadaProtocol.Code).project)
        continue
      }
      if (task.failure !== undefined) {
        rows.forEach((row) => finish(row, { state: "gone", reason: `a partida falhou: ${task.failure}` }))
        continue
      }
      rows.forEach((row) =>
        db.run("UPDATE attempt SET started_at = ? WHERE job_id = ? AND part = ? AND n = ? AND started_at IS NULL", [
          input.now(),
          row.job_id,
          row.part,
          row.n,
        ]),
      )
    }
    // A cancelled attempt that never started ends first: its build may pass to a sibling of the group about to form.
    for (const row of live.all())
      if (row.started_at === null && row.group_id === null && row.cancel_at !== null)
        finish(row, { state: "done", ending: { stage: "build", cause: "cancelado" } })
    // Code asked through the hub that never came: the request's attempts here are lost with the reason.
    for (const row of live.all()) {
      const code = row.group_id === null && row.cancel_at === null ? input.code?.state(row.job_id) : undefined
      if (code?.state === "falhou") finish(row, { state: "gone", reason: code.reason ?? "o código não chegou" })
    }
    // New groups: what one request has here not started yet, and whose code is here (or not asked for).
    const fresh = live
      .all()
      .filter((row) => row.group_id === null && row.cancel_at === null && !waitingCode(row.job_id))
    new Set(fresh.map((row) => row.job_id)).forEach((job) => {
      const rows = fresh.filter((row) => row.job_id === job).toSorted((a, b) => a.part.localeCompare(b.part))
      begin(rows, rows.map((row) => `${row.part}-${row.n}`).join("+"))
    })
    for (const row of live.all()) {
      const key = placed(row)
      const starting = row.group_id !== null && tasks.has(startOf(row.job_id, row.group_id))
      if (row.started_at === null && row.cancel_at !== null && !starting) {
        finish(row, { state: "done", ending: { stage: "build", cause: "cancelado" } })
        continue
      }
      if (row.started_at === null) {
        // Waiting for its code is a known state, not one still to read again.
        if (!waitingCode(row.job_id)) unread.count++
        continue
      }
      if (row.cancel_at !== null) stopping(row, key)
      const status = await input.launcher.status(key).catch(() => undefined)
      if (!status || status.state === "unstarted") {
        if (status && !starting) begin(inGroup.all(row.job_id, key.group), key.group)
        unread.count++
        continue
      }
      if (status.state === "done" || status.state === "gone") {
        finish(row, status)
        continue
      }
      const next = status.state
      if (next === row.state) continue
      db.transaction(() => {
        const changed = db.run("UPDATE attempt SET state = ? WHERE job_id = ? AND part = ? AND n = ? AND state = ?", [
          next,
          row.job_id,
          row.part,
          row.n,
          row.state,
        ]).changes
        if (!changed) return
        // The build ended: its share of the reservation goes back (`docs/bancada.md`, "Budget").
        if (next === "rodando")
          db.run(
            "UPDATE lease SET mem_mb = mem_mb - build_mem_mb, cpu_milli = cpu_milli - build_cpu_milli, builds = 0, build_mem_mb = 0, build_cpu_milli = 0 WHERE id = ?",
            [row.lease_id],
          )
        // Running: its devices are ready, and the apps show them (`docs/bancada.md`, "App surface").
        const devices = next === "rodando" ? usedDevices.all(row.lease_id).map(usedDevice) : []
        input.send({ type: "attempt", ...keyOf(row), state: next, ...(devices.length ? { devices } : {}) })
      })()
    }
    if (unread.count === 0) reconciling.value = false
    await input.launcher.reap(live.all().map(placed)).catch(() => undefined)
    // Until then an orphan of a dead runner may still use the machine: the budget would take another part on top.
    for (const row of holding.all())
      if (!input.launcher.held(placed(row)))
        db.transaction(() => {
          db.run("UPDATE lease SET state = 'released', released_at = ? WHERE id = ? AND state = 'active'", [
            input.now(),
            row.lease_id,
          ])
          db.run("DELETE FROM lease_device WHERE lease_id = ?", [row.lease_id])
          if (row.phone_hold) input.phone?.drop(row.phone_hold)
        })()
    for (const row of delivered.all()) {
      const id = `cleanup:${row.job_id}/${row.part}/${row.n}`
      const task = tasks.get(id)
      if (!task) run(id, () => input.launcher.cleanup(placed(row)))
      if (!task?.done) continue
      // Failed (the folder is still held): asked again on the next round.
      tasks.delete(id)
      if (task.failure !== undefined) continue
      db.transaction(() => {
        db.run("DELETE FROM lease WHERE id = ? AND state <> 'active'", [row.lease_id])
        db.run("DELETE FROM attempt WHERE job_id = ? AND part = ? AND n = ? AND state = 'limpar'", [
          row.job_id,
          row.part,
          row.n,
        ])
      })()
    }
  }

  /** A cancel on its way: the part is asked to stop once; without an end in `cancelGraceMs`, its runner is ended. */
  const stopping = (row: AttemptRow, key: Placed) => {
    const id = `${key.job}/${key.part}/${key.attempt}`
    if (!tasks.has(`cancel:${id}`)) run(`cancel:${id}`, () => input.launcher.cancel(key))
    if (input.now() - row.cancel_at! >= cancelGraceMs && !tasks.has(`stop:${id}`))
      run(`stop:${id}`, () => input.launcher.stop(key))
  }

  /**
   * The execution ended (or never started): the hub hears how it went at once. What it held here (its folder, its
   * reservation of the budget) goes back by `reap`, once nothing it started runs. Infrastructure (a dead runner, a
   * deadline, exit 75) loses the attempt; a cancel cancels it.
   */
  const finish = (row: AttemptRow, status: Extract<Status, { state: "done" | "gone" }>) => {
    const outcome: BancadaProtocol.Outcome =
      status.state === "gone"
        ? { verdict: "infraestrutura", reason: status.reason, planned: [], scenarios: [], lost: [], approved: false }
        : judge(status.ending)
    // Asked to stop, it is cancelled however it ended (its runner may have been ended for not answering).
    const cancelled = row.cancel_at !== null
    const final: BancadaProtocol.Outcome = cancelled
      ? { ...outcome, verdict: "cancelado", reason: row.cancel_reason ?? "cancelado", approved: false }
      : outcome
    const state = cancelled
      ? "cancelado"
      : outcome.verdict === "infraestrutura"
        ? "perdido"
        : outcome.verdict === "cancelado"
          ? "cancelado"
          : "concluido"
    // What it keeps for the notice; the files stay in the attempt's folder until the hub asks for them, or the origin
    // (on this machine) copies them.
    const kept = status.state === "done" && !cancelled ? evidence(final, status.ending) : []
    db.transaction(() => {
      const changed = db.run(
        "UPDATE attempt SET state = ?, ended_at = ?, outcome = ?, evidence = ? WHERE job_id = ? AND part = ? AND n = ? AND state = ?",
        [
          state,
          input.now(),
          JSON.stringify(final),
          kept.length ? JSON.stringify(kept) : null,
          row.job_id,
          row.part,
          row.n,
          row.state,
        ],
      ).changes
      if (!changed) return
      // It held its group's build and leaves before the start: the build passes to a sibling that builds.
      if (row.group_id === null) handOver(row)
      input.send({
        type: "attempt",
        job: row.job_id,
        part: row.part,
        attempt: row.n,
        state,
        outcome: final,
        ...(row.only_scenarios ? { partial: true } : {}),
        ...(kept.length ? { evidence: kept.map(({ file: _, ...declared }) => declared) } : {}),
        // The devices it ran on, for the history (it may have grown after its admission).
        ...((devices) => (devices.length ? { devices } : {}))(usedDevices.all(row.lease_id).map(usedDevice)),
      })
    })()
  }

  /** Moves a not-started attempt's build reservation to a sibling of its request that would build and holds none. */
  function handOver(row: AttemptRow) {
    const lease = db
      .query<
        { builds: number; build_mem_mb: number; build_cpu_milli: number },
        [string]
      >("SELECT builds, build_mem_mb, build_cpu_milli FROM lease WHERE id = ?")
      .get(row.lease_id)
    const next = heir.all(row.job_id).find((item) => (JSON.parse(item.spec) as BancadaProtocol.PartSpec).build)
    if (!lease || lease.builds === 0 || !next) return
    db.run(
      "UPDATE lease SET mem_mb = mem_mb - build_mem_mb, cpu_milli = cpu_milli - build_cpu_milli, builds = 0, build_mem_mb = 0, build_cpu_milli = 0 WHERE id = ?",
      [row.lease_id],
    )
    db.run(
      "UPDATE lease SET mem_mb = mem_mb + ?, cpu_milli = cpu_milli + ?, builds = 1, build_mem_mb = ?, build_cpu_milli = ? WHERE id = ?",
      [lease.build_mem_mb, lease.build_cpu_milli, lease.build_mem_mb, lease.build_cpu_milli, next.lease],
    )
  }

  /**
   * An attempt uses fewer devices than it was granted (its plan, `devices/pool.ts`): the rest of its reservation goes
   * back (their share of memory and CPU and of what the test takes beside them, their count, the ports no device
   * took), for the next part.
   */
  const shrink = (key: { job: string; part: string; attempt: number }, devices: number) =>
    db.transaction(() => {
      const row = findAttempt.get(key.job, key.part, key.attempt)
      if (!row || devices >= row.devices) return
      const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
      const extra = extraOf((JSON.parse(row.code) as BancadaProtocol.Code).project, spec)
      const back = add(
        times(device(seat(spec), spec.device), row.devices - devices),
        extra(row.devices),
        times(extra(devices), -1),
      )
      db.run(
        "UPDATE lease SET android = MAX(0, android - ?), ios = MAX(0, ios - ?), mem_mb = MAX(0, mem_mb - ?), cpu_milli = MAX(0, cpu_milli - ?) WHERE id = ?",
        [
          spec.platform === "android" ? row.devices - devices : 0,
          spec.platform === "ios" ? row.devices - devices : 0,
          back.memMb,
          back.cpuMilli,
          row.lease_id,
        ],
      )
      // Each device (and a phone) takes its block of ports as it starts (`devices/pool.ts`): those left go.
      db.query<{ rowid: number }, [string]>(
        "SELECT rowid FROM lease_device WHERE lease_id = ? AND device_id IS NULL ORDER BY rowid DESC",
      )
        .all(row.lease_id)
        .slice(0, row.devices - devices)
        .forEach((block) => db.run("DELETE FROM lease_device WHERE rowid = ?", [block.rowid]))
      db.run("UPDATE attempt SET devices = ? WHERE job_id = ? AND part = ? AND n = ?", [
        devices,
        key.job,
        key.part,
        key.attempt,
      ])
    })()

  /** What each queue this machine reaches (the hub, its own) said waits for room here, at its last answer. */
  const queued = new Map<string, { readonly android: number; readonly ios: number }>()

  /**
   * An attempt whose scenarios are worth more devices than it was granted (`devices/pool.ts`): as many more as fit in
   * the budget now, up to its test's maximum, each with its share of memory and CPU, of what the test takes beside
   * them, and a block of ports. Its count of devices after; none more with the brake closed, nor while a part of the
   * queue waits for room on this machine for the same kind of device (it goes first).
   */
  const grow = (key: { job: string; part: string; attempt: number }, wanted: number) =>
    db.transaction(() => {
      const row = findAttempt.get(key.job, key.part, key.attempt)
      if (!row) return 0
      const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
      const platform = seat(spec)
      const most = Math.min(wanted, spec.devices.max)
      if (platform === "none" || most <= row.devices || watch.brake.closed) return row.devices
      if ([...queued.values()].some((counts) => counts[platform] > 0)) return row.devices
      if (!["aceito", "compilando", "rodando"].includes(row.state)) return row.devices
      const unit = device(platform, spec.device)
      const extra = extraOf((JSON.parse(row.code) as BancadaProtocol.Code).project, spec)
      const now = current()
      const cost = (more: number) => add(times(unit, more), extra(row.devices + more), times(extra(row.devices), -1))
      const more = Array.from({ length: most - row.devices }, (_, index) => most - row.devices - index).find(
        (count) =>
          count <= now[platform] &&
          cost(count).memMb <= now.memMb &&
          cost(count).cpuMilli <= now.cpuMilli &&
          portsFor(count) !== undefined,
      )
      if (more === undefined) return row.devices
      db.run(
        "UPDATE lease SET android = android + ?, ios = ios + ?, mem_mb = mem_mb + ?, cpu_milli = cpu_milli + ? WHERE id = ?",
        [
          platform === "android" ? more : 0,
          platform === "ios" ? more : 0,
          cost(more).memMb,
          cost(more).cpuMilli,
          row.lease_id,
        ],
      )
      portsFor(more)!.forEach((ports) =>
        db.run("INSERT INTO lease_device (lease_id, device_id, port_start, port_end) VALUES (?, NULL, ?, ?)", [
          row.lease_id,
          ports.start,
          ports.end,
        ]),
      )
      db.run("UPDATE attempt SET devices = ? WHERE job_id = ? AND part = ? AND n = ?", [
        row.devices + more,
        key.job,
        key.part,
        key.attempt,
      ])
      return row.devices + more
    })()

  /** Whether `count` running devices of `platform` nobody uses fit in what is free now (`devices/pool.ts`). */
  const warmFits = (platform: "android" | "ios", count: number) => {
    const now = current()
    const cost = times(device(platform, slim), count)
    return now.memMb >= cost.memMb && now.cpuMilli >= cost.cpuMilli && now[platform] >= count
  }

  return {
    offer,
    cancel,
    cleanup,
    reserveSlot,
    releaseLease,
    shrink,
    grow,
    /** A queue's answer said what waits for room here (absent: a hub of an older release, which says nothing). */
    waiting: (peer: string, counts: { readonly android: number; readonly ios: number } | undefined) =>
      void (counts ? queued.set(peer, counts) : queued.delete(peer)),
    warmFits,
    tick,
    free,
    running: (): BancadaProtocol.Pulse["running"] =>
      live.all().map((row) => ({ job: row.job_id, part: row.part, attempt: row.n })),
    /** Ended attempts still kept (no `cleanup` yet): a hub that forgot adopts them with their final report. */
    kept: (): BancadaProtocol.Pulse["kept"] =>
      ended.all().map((row) => ({ job: row.job_id, part: row.part, attempt: row.n })),
    reconciling: () => reconciling.value,
    /**
     * A reading of the machine (the process takes one every 5 s, off the round): the brake moves, and whether the
     * owner is at the Mac. Says whether the brake changed, for the log.
     */
    observe: (reading: Reading) => {
      const was = watch.brake.closed
      watch.brake = step(watch.brake, reading, limits.brake)
      watch.present = reading.idleMs !== undefined && reading.idleMs < limits.presence.idleMs
      return { changed: was !== watch.brake.closed, closed: watch.brake.closed, reasons: watch.brake.reasons }
    },
    braked: () => watch.brake.closed,
    present: () => watch.present,
  }
}

export type Executor = ReturnType<typeof makeExecutor>

/** A device of an attempt as the apps see it: its id in the resources hub, when the hub lists that kind. */
function usedDevice(row: { id: string; kind: string; running: string | null }): typeof BancadaProtocol.UsedDevice.Type {
  const running: { udid?: string } = row.running ? JSON.parse(row.running) : {}
  const resourceID =
    row.kind === "android-emulador"
      ? `android-emulator:${row.id}`
      : row.kind === "ios-simulador" && running.udid
        ? `ios-simulator:${running.udid}`
        : undefined
  return { kind: row.kind, id: row.id, ...(resourceID ? { resourceID } : {}) }
}
