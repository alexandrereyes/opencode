import type { Database } from "bun:sqlite"
import { buildCost, dockerExtraPerDevice } from "../catalog/costs.js"
import type { BrakeConfig, Range } from "../machine-config.js"
import { BancadaProtocol } from "../protocol.js"
import { judge, type Ending } from "../results.js"
import { open, step, type Brake, type Reading } from "./brake.js"
import { add, free as budgetFree, largestFit, measured, room, samples, times, zero, type Cost } from "./budget.js"
import { deviceFor } from "./devices/types.js"
import { block } from "./devices/ports.js"

/** The key of an attempt: a part of a job, and its number. */
export type AttemptKey = { readonly job: string; readonly part: string; readonly attempt: number }

/** What the launcher needs to start an attempt (the real one writes the attempt's folder, `docs/bancada.md`). */
export type Launch = AttemptKey & {
  readonly spec: BancadaProtocol.PartSpec
  readonly code: BancadaProtocol.Code
  readonly devices: number
  readonly only?: ReadonlyArray<string>
  /** The session's repository, when the request came from this machine: the code is fetched from it, nothing travels. */
  readonly repository?: string
}

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
  readonly status: (key: AttemptKey) => Promise<Status>
  /** Asks the execution to stop; it ends with `cancelado`. */
  readonly cancel: (key: AttemptKey) => Promise<void>
  /**
   * What attempts not in `live` still hold (their working folder) goes back once nothing they started runs: the
   * launcher ends what they left with proof it is theirs, on its own time.
   */
  readonly reap: (live: ReadonlyArray<AttemptKey>) => Promise<void>
  /** Whether an attempt still holds anything here (its folder, or the giving back still runs). */
  readonly held: (key: AttemptKey) => boolean
  /** After delivery: nothing of the attempt stays (its folder, the commit's ref); rejects while it still holds any. */
  readonly cleanup: (key: AttemptKey) => Promise<void>
}

/** What this machine offers and how much of it (`docs/bancada.md`, "Budget"), from its machine file. */
export type Limits = {
  readonly capacity: BancadaProtocol.Vector
  readonly capabilities: Readonly<Record<string, unknown>>
  /** MyCredentials policies resolved here: a part with `segredos` is accepted only when its policy is listed. */
  readonly secrets: ReadonlyArray<string>
  readonly presence: { readonly idleMs: number; readonly factor: number }
  readonly brake: BrakeConfig
  /** The machine's `portas.projeto`: each granted device gets a block of it. */
  readonly ports: Range
  /** Executions in containers: an Android device is an emulator in a container. */
  readonly docker: boolean
}

type AttemptRow = {
  readonly job_id: string
  readonly part: string
  readonly n: number
  readonly origin: string
  readonly code: string
  readonly spec: string
  readonly devices: number
  readonly only_scenarios: string | null
  readonly state: string
  readonly lease_id: string
  readonly started_at: number | null
}

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
  const delivered = db.query<AttemptRow, []>(
    "SELECT a.* FROM attempt a JOIN lease l ON l.id = a.lease_id WHERE a.state = 'limpar' AND l.state <> 'active'",
  )
  /** Ended attempts whose reservation still counts: it goes back with their folder (and devices), in the giving back. */
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
  const tasks = new Map<string, { done: boolean; failure?: string }>()
  const run = (id: string, work: () => Promise<void>) => {
    const task: { done: boolean; failure?: string } = { done: false }
    tasks.set(id, task)
    void work()
      .catch((error: unknown) => {
        task.failure = error instanceof Error ? error.message : String(error)
      })
      .finally(() => {
        task.done = true
        input.wake()
      })
  }
  const begin = (row: AttemptRow) => {
    const origin: BancadaProtocol.Origin = JSON.parse(row.origin)
    const repository = origin.machineID === input.machineID ? input.repository(row.job_id) : undefined
    run(`start:${row.job_id}/${row.part}/${row.n}`, () =>
      input.launcher.start({
        job: row.job_id,
        part: row.part,
        attempt: row.n,
        spec: JSON.parse(row.spec),
        code: JSON.parse(row.code),
        devices: row.devices,
        ...(row.only_scenarios ? { only: JSON.parse(row.only_scenarios) } : {}),
        ...(repository ? { repository } : {}),
      }),
    )
  }
  const keyOf = (row: AttemptRow): AttemptKey => ({ job: row.job_id, part: row.part, attempt: row.n })

  /** What this machine measured of a subject (the last samples), or its default cost before it has enough. */
  const costOf = (subject: string, fallback: Cost) => measured(samplesOf.all(subject, samples.kept), fallback)
  const simslim = () => {
    const ios = limits.capabilities.ios
    return typeof ios === "object" && ios !== null && "simslim" in ios && ios.simslim === true
  }
  const device = (platform: BancadaProtocol.Platform, spec: BancadaProtocol.DeviceSpec) => {
    const found = deviceFor(platform, spec, { docker: limits.docker, simslim: simslim() })
    return found ? costOf(found.subject, found.cost) : zero
  }
  /** What new admissions may use now: a share of memory and CPU while the owner uses the Mac. */
  const current = () => room(limits.capacity, used.get()!, watch.present ? limits.presence.factor : 1)
  /** The pulse's free vector: the hub never offers beyond it (a default build, default devices). */
  const free = (): BancadaProtocol.Vector =>
    budgetFree(current(), buildCost, {
      android: device("android", { slim: "aceita" }),
      ios: device("ios", { slim: "aceita" }),
    })

  /**
   * An attempt's peak at admission (`docs/bancada.md`, "Budget"): its project's build, its devices and what the test
   * takes beside them, with as many devices between the offer's minimum and proposal as fit now.
   */
  const admit = (message: typeof BancadaProtocol.Offer.Type) => {
    const spec = message.spec
    const build = costOf(`build:${message.code.project}`, buildCost)
    const unit = device(spec.platform, spec.device)
    const measuredExtra = samplesOf.all(`extra:${message.code.project}/${spec.part}`, samples.kept)
    const extra = (n: number) =>
      measuredExtra.length >= samples.trusted
        ? measured(measuredExtra, zero)
        : spec.needs.includes("docker")
          ? times(dockerExtraPerDevice, n)
          : zero
    const devices = largestFit({
      room: current(),
      platform: spec.platform,
      min: message.devices.min,
      proposed: message.devices.proposed,
      build,
      device: unit,
      extra,
    })
    return devices === undefined
      ? undefined
      : { devices, build, peak: add(build, times(unit, devices), extra(devices)) }
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
    if (findAttempt.get(message.job, message.part, message.attempt)) return
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
    const missing = message.spec.needs.filter((need) => !(need in limits.capabilities))
    if (missing.length > 0)
      return refuse({ code: "sem_maquina", text: `esta máquina não oferece mais ${missing.join(", ")}` })
    const secrets = message.spec.secrets
    if (secrets && !limits.secrets.includes(secrets))
      return refuse({ code: "sem_maquina", text: `a policy ${secrets} não está na lista segredos desta máquina` })
    const admission = admit(message)
    if (!admission) return refuse({ code: "orcamento", text: "aguardando folga" })
    const blocks = portsFor(admission.devices)
    if (!blocks) return refuse({ code: "orcamento", text: "sem portas livres para os aparelhos" })
    const kind = message.spec.platform
    const devices = admission.devices
    const lease = input.random()
    db.run(
      "INSERT INTO lease (id, kind, owner, android, ios, mem_mb, cpu_milli, builds, build_mem_mb, build_cpu_milli, state, created_at) VALUES (?, 'job', ?, ?, ?, ?, ?, 1, ?, ?, 'active', ?)",
      [
        lease,
        `${message.job}/${message.part}/${message.attempt}`,
        kind === "android" ? devices : 0,
        kind === "ios" ? devices : 0,
        admission.peak.memMb,
        admission.peak.cpuMilli,
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
      "INSERT INTO attempt (job_id, part, n, origin, code, spec, devices, only_scenarios, state, lease_id, accepted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'aceito', ?, ?)",
      [
        message.job,
        message.part,
        message.attempt,
        JSON.stringify(message.origin),
        JSON.stringify(message.code),
        JSON.stringify(message.spec),
        devices,
        message.only ? JSON.stringify(message.only) : null,
        lease,
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

  /** After delivery nothing of the job stays (D9): the next round removes its folders, then its rows. */
  const cleanup = (message: typeof BancadaProtocol.Cleanup.Type) =>
    db.run("UPDATE attempt SET state = 'limpar' WHERE job_id = ? AND state IN ('concluido', 'perdido', 'cancelado')", [
      message.job,
    ])

  /**
   * Starts what was accepted and follows what runs; one report per change. The round only reads what is local and
   * never waits for a task: an attempt whose start runs stays `aceito` and counts as not read yet. Every transition is
   * conditional on the state read before the `await`s, and reports only when the row changed. One attempt never holds
   * the others: a start that fails loses that attempt, a status that cannot be read leaves it as it was.
   */
  const tick = async () => {
    const unread = { count: 0 }
    for (const row of live.all()) {
      const key = keyOf(row)
      const id = `start:${key.job}/${key.part}/${key.attempt}`
      const task = tasks.get(id)
      if (task && !task.done) {
        unread.count++
        continue
      }
      if (task) tasks.delete(id)
      if (task?.failure !== undefined) {
        finish(row, { state: "gone", reason: `a partida falhou: ${task.failure}` })
        continue
      }
      if (task)
        db.run("UPDATE attempt SET started_at = ? WHERE job_id = ? AND part = ? AND n = ? AND started_at IS NULL", [
          input.now(),
          row.job_id,
          row.part,
          row.n,
        ])
      if (!task && row.started_at === null) {
        begin(row)
        unread.count++
        continue
      }
      const status = await input.launcher.status(key).catch(() => undefined)
      if (!status || status.state === "unstarted") {
        if (status) begin(row)
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
        input.send({ type: "attempt", ...key, state: next })
      })()
    }
    if (unread.count === 0) reconciling.value = false
    await input.launcher.reap(live.all().map(keyOf)).catch(() => undefined)
    // Until then an orphan of a dead runner may still use the machine: the budget would take another part on top.
    for (const row of holding.all())
      if (!input.launcher.held(keyOf(row)))
        db.transaction(() => {
          db.run("UPDATE lease SET state = 'released', released_at = ? WHERE id = ? AND state = 'active'", [
            input.now(),
            row.lease_id,
          ])
          db.run("DELETE FROM lease_device WHERE lease_id = ?", [row.lease_id])
        })()
    for (const row of delivered.all()) {
      const id = `cleanup:${row.job_id}/${row.part}/${row.n}`
      const task = tasks.get(id)
      if (!task) run(id, () => input.launcher.cleanup(keyOf(row)))
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
    const state =
      outcome.verdict === "infraestrutura" ? "perdido" : outcome.verdict === "cancelado" ? "cancelado" : "concluido"
    db.transaction(() => {
      const changed = db.run(
        "UPDATE attempt SET state = ?, ended_at = ?, outcome = ? WHERE job_id = ? AND part = ? AND n = ? AND state = ?",
        [state, input.now(), JSON.stringify(outcome), row.job_id, row.part, row.n, row.state],
      ).changes
      if (!changed) return
      input.send({ type: "attempt", job: row.job_id, part: row.part, attempt: row.n, state, outcome })
    })()
  }

  return {
    offer,
    cleanup,
    tick,
    free,
    running: (): BancadaProtocol.Pulse["running"] =>
      live.all().map((row) => ({ job: row.job_id, part: row.part, attempt: row.n })),
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
