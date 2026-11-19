import type { Database } from "bun:sqlite"
import { BancadaProtocol } from "../protocol.js"
import { judge, type Ending } from "../results.js"

/** The key of an attempt: a part of a job, and its number. */
export type AttemptKey = { readonly job: string; readonly part: string; readonly attempt: number }

/** What the launcher needs to start an attempt (the real one writes the attempt's folder, `docs/bancada.md`). */
export type Launch = AttemptKey & {
  readonly spec: BancadaProtocol.PartSpec
  readonly code: BancadaProtocol.Code
  readonly devices: number
  readonly only?: ReadonlyArray<string>
}

/**
 * What an execution reports, read from its folder: still building or running, or ended (how, with the project's files,
 * judged by `results.ts`). `gone`: the launcher has no trace of it.
 */
export type Status =
  | { readonly state: "compilando" | "rodando" }
  | { readonly state: "done"; readonly ending: Ending }
  | { readonly state: "gone"; readonly reason: string }

/** Starts executions away from the server and reads how they go; idempotent per attempt. */
export interface Launcher {
  readonly start: (launch: Launch) => Promise<void>
  readonly status: (key: AttemptKey) => Promise<Status>
}

type AttemptRow = {
  readonly job_id: string
  readonly part: string
  readonly n: number
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
  readonly capacity: BancadaProtocol.Vector
  readonly launcher: Launcher
  readonly send: (body: BancadaProtocol.FromMachine) => void
}) {
  const db = input.db
  const used = db.query<{ android: number; ios: number }, []>(
    "SELECT COALESCE(SUM(android), 0) AS android, COALESCE(SUM(ios), 0) AS ios FROM lease WHERE state = 'active'",
  )
  const live = db.query<AttemptRow, []>(
    "SELECT * FROM attempt WHERE state IN ('aceito', 'compilando', 'rodando') ORDER BY accepted_at",
  )
  const findAttempt = db.query<AttemptRow, [string, string, number]>(
    "SELECT * FROM attempt WHERE job_id = ? AND part = ? AND n = ?",
  )

  const free = (): BancadaProtocol.Vector => {
    const taken = used.get()!
    return {
      ...input.capacity,
      android: Math.max(0, input.capacity.android - taken.android),
      ios: Math.max(0, input.capacity.ios - taken.ios),
    }
  }

  /** Called inside the transaction that applies the hub's message. */
  const offer = (message: typeof BancadaProtocol.Offer.Type) => {
    if (findAttempt.get(message.job, message.part, message.attempt)) return
    const kind = message.spec.platform
    const available = kind === "none" ? 0 : free()[kind]
    if (kind !== "none" && available < message.devices.min)
      return input.send({
        type: "offer.reply",
        job: message.job,
        part: message.part,
        attempt: message.attempt,
        accepted: false,
        reason: { code: "orcamento", text: "aguardando folga" },
      })
    const devices = kind === "none" ? 0 : Math.min(message.devices.proposed, available)
    const lease = input.random()
    db.run(
      "INSERT INTO lease (id, kind, owner, android, ios, mem_mb, cpu_milli, builds, state, created_at) VALUES (?, 'job', ?, ?, ?, 0, 0, 0, 'active', ?)",
      [
        lease,
        `${message.job}/${message.part}/${message.attempt}`,
        kind === "android" ? devices : 0,
        kind === "ios" ? devices : 0,
        input.now(),
      ],
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

  /** After delivery nothing of the job stays (D9). */
  const cleanup = (message: typeof BancadaProtocol.Cleanup.Type) => {
    db.run("DELETE FROM lease WHERE id IN (SELECT lease_id FROM attempt WHERE job_id = ?) AND state <> 'active'", [
      message.job,
    ])
    db.run("DELETE FROM attempt WHERE job_id = ? AND state NOT IN ('aceito', 'compilando', 'rodando')", [message.job])
  }

  /**
   * Starts what was accepted and follows what runs; one report per change. Every transition is conditional on the
   * state read before the `await`s, and reports only when the row changed. One attempt never holds the others: a start
   * that fails loses that attempt, a status that cannot be read leaves it as it was until the next round.
   */
  const tick = async () => {
    for (const row of live.all()) {
      const key = { job: row.job_id, part: row.part, attempt: row.n }
      if (row.started_at === null) {
        const failure = await input.launcher
          .start({
            ...key,
            spec: JSON.parse(row.spec),
            code: JSON.parse(row.code),
            devices: row.devices,
            ...(row.only_scenarios ? { only: JSON.parse(row.only_scenarios) } : {}),
          })
          .then(
            () => undefined,
            (error: unknown) => (error instanceof Error ? error.message : String(error)),
          )
        if (failure !== undefined) {
          finish(row, { state: "gone", reason: `a partida falhou: ${failure}` })
          continue
        }
        db.run("UPDATE attempt SET started_at = ? WHERE job_id = ? AND part = ? AND n = ? AND started_at IS NULL", [
          input.now(),
          row.job_id,
          row.part,
          row.n,
        ])
      }
      const status = await input.launcher.status(key).catch(() => undefined)
      if (!status) continue
      if (status.state === "done" || status.state === "gone") {
        finish(row, status)
        continue
      }
      if (status.state === row.state) continue
      db.transaction(() => {
        const changed = db.run("UPDATE attempt SET state = ? WHERE job_id = ? AND part = ? AND n = ? AND state = ?", [
          status.state,
          row.job_id,
          row.part,
          row.n,
          row.state,
        ]).changes
        if (changed) input.send({ type: "attempt", ...key, state: status.state })
      })()
    }
  }

  /** The execution ended (or vanished): its reservation is released and the hub hears how it went, in one step. */
  const finish = (row: AttemptRow, status: Extract<Status, { state: "done" | "gone" }>) => {
    const outcome: BancadaProtocol.Outcome =
      status.state === "gone"
        ? { verdict: "infraestrutura", reason: status.reason, planned: [], scenarios: [], lost: [], approved: false }
        : judge(status.ending)
    const state = status.state === "gone" ? "perdido" : "concluido"
    db.transaction(() => {
      const changed = db.run(
        "UPDATE attempt SET state = ?, ended_at = ?, outcome = ? WHERE job_id = ? AND part = ? AND n = ? AND state = ?",
        [state, input.now(), JSON.stringify(outcome), row.job_id, row.part, row.n, row.state],
      ).changes
      if (!changed) return
      db.run("UPDATE lease SET state = 'released', released_at = ? WHERE id = ?", [input.now(), row.lease_id])
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
  }
}

export type Executor = ReturnType<typeof makeExecutor>
