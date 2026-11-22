import type { Database } from "bun:sqlite"
import { BancadaProtocol } from "../protocol.js"
import type { Alerts } from "./alerts.js"
import { join } from "../results.js"
import { duration, defaults as estimates, perScenario, wait, type Sample } from "./estimate.js"
import { needs, reserveAfter, schedule as choose, seat, type MachineView, type QueuedPart } from "./scheduler.js"

type PartRow = {
  readonly job_id: string
  readonly part: string
  readonly idx: number
  readonly spec: string
  readonly state: BancadaProtocol.PartState
  readonly attempt_n: number
  readonly machine_id: string | null
  readonly offer_seq: number | null
  readonly devices_granted: number | null
  readonly devices: string | null
  /** Where it waits now, as the queue shows it: the reason, the place and the estimate (`queue`). */
  readonly waiting: string | null
  readonly refused_by: string | null
  readonly refused_pulse: number | null
  readonly held_state: BancadaProtocol.PartState | null
  readonly since: number
  readonly outcome: string | null
  readonly reserved: number
  readonly bypassed: number
  readonly retry_used: number
  readonly only_scenarios: string | null
  readonly previous: string | null
  readonly missing: number
  readonly told: string | null
  readonly reason_at: number | null
  readonly est_ms: number | null
  readonly offered_at: number | null
  readonly acked_at: number | null
  readonly started_at: number | null
  readonly built_at: number | null
  readonly adopt_until: number | null
  /** Its last attempt could not get the origin's bundle: offered again only with the origin `ok`. */
  readonly needs_code: number
  /** `BancadaProtocol.Evidence[]`: what its attempts keep for the notice. */
  readonly evidence: string
}
type MachineRow = {
  readonly machine_id: string
  readonly name: string
  readonly instance_id: string
  readonly platform: string | null
  readonly phones: string
  readonly hardware: string | null
  readonly capabilities: string
  readonly speed: string
  readonly free: string | null
  readonly brake: number
  readonly state: string
  readonly pulse_stream: string | null
  readonly pulse_seq: number | null
  readonly running: string
  readonly last_sync_at: number
  readonly state_since: number
}
type JobRow = {
  readonly id: string
  readonly origin_machine: string
  readonly origin: string
  readonly code: string
  readonly state: string
  readonly created_at: number
  readonly cancelled_at: number | null
  readonly closed_at: number | null
}

/** How far a part has gone; a report never moves a part back. */
const rank: Record<BancadaProtocol.PartState, number> = {
  na_fila: 0,
  oferecido: 1,
  aceito: 2,
  compilando: 3,
  rodando: 4,
  incerto: 4,
  concluido: 5,
  perdido: 5,
  cancelado: 5,
  invalido: 5,
}
const live = ["aceito", "compilando", "rodando"] as const
/** A machine another server called with this recently stays that server's. */
const takenMs = 60_000

/** The times of the queue (`docs/bancada.md`, "State machine"); the hub's own `[tempos]`. */
export type QueueTimes = {
  /** A machine that has not called for this long is silent. */
  readonly silentMs: number
  /** Silent for this long, a machine is away (`fora`): parts only it can run wait for it by name. */
  readonly uncertainMs: number
  /** A part uncertain for this long is lost; it runs again elsewhere only when that is safe. */
  readonly lostMs: number
  /** A machine still reconciling after this long is treated as silent for what it runs. */
  readonly reconcilingMs: number
  /** An offer the machine received and has not answered after this long is withdrawn. */
  readonly replyMs: number
  /** How long a delivered request's tombstone stays (its id would not run again). */
  readonly tombstoneMs: number
  /** A part waiting this long for a machine that nobody offers raises an alert. */
  readonly noMachineMs: number
  /** A transfer lives this long (`docs/bancada.md`, "Blobs"). */
  readonly transferMs: number
}

/**
 * The queue of every machine (`docs/bancada.md`, "Queue"), where the hub runs. It offers parts to machines that can
 * take them, follows what each machine's executor reports and tells the origin; executors decide, it mirrors. Every
 * handler runs inside the transaction that applies the message it answers, and what it sends shares it.
 */
export function makeCoordinator(input: {
  readonly db: Database
  readonly now: () => number
  readonly times: QueueTimes
  /** When this hub's process started: a machine's silence counts only from then (it could not call a hub that was out). */
  readonly startedAt: number
  readonly send: (machineID: string, body: BancadaProtocol.FromHub) => number
  /** The last sequence number `machineID` acknowledged of the hub's stream to it. */
  readonly acknowledged: (machineID: string) => number
  readonly log: (line: string) => void
  readonly alerts: Alerts
  /** A fresh random id (128 bits): the hub names each transfer. */
  readonly random: () => string
  /** The hub tells every machine the catalog; a machine's own queue does not. */
  readonly hub?: boolean
}) {
  const db = input.db
  const times = input.times
  const job = db.query<JobRow, [string]>("SELECT * FROM hub_job WHERE id = ?")
  const part = db.query<PartRow, [string, string]>("SELECT * FROM hub_part WHERE job_id = ? AND part = ?")
  const parts = db.query<PartRow, [string]>("SELECT * FROM hub_part WHERE job_id = ? ORDER BY idx")
  const inState = db.query<PartRow, [string]>("SELECT * FROM hub_part WHERE state = ?")
  const onMachine = db.query<PartRow, [string]>("SELECT * FROM hub_part WHERE machine_id = ?")
  const machines = db.query<MachineRow, []>("SELECT * FROM hub_machine ORDER BY machine_id")
  const machine = db.query<MachineRow, [string]>("SELECT * FROM hub_machine WHERE machine_id = ?")
  const history = db.query<{ cancelled: number; state: string }, [string, string, number, string]>(
    "SELECT cancelled, state FROM hub_attempt WHERE job_id = ? AND part = ? AND n = ? AND machine_id = ?",
  )
  const blob = db.query<
    {
      transfer: string
      job_id: string
      kind: string
      uploader: string
      downloader: string
      received: string
      state: string
      created_at: number
    },
    [string]
  >("SELECT * FROM hub_blob WHERE transfer = ?")
  const holdRoute = db.query<{ origin_machine: string; target_machine: string }, [string]>(
    "SELECT origin_machine, target_machine FROM hub_hold WHERE hold = ?",
  )
  const scenarios = db.query<{ last: string }, [string, string, string]>(
    "SELECT last FROM hub_scenario WHERE project = ? AND test = ? AND scenario_id = ?",
  )
  /** Parts waiting for room on each machine, by the kind of device they take: as the last `schedule` found them. */
  const waitingOn = new Map<string, { android: number; ios: number }>()
  const durations = db.query<{ machine_id: string; samples: string }, [string, string]>(
    "SELECT machine_id, samples FROM hub_duration WHERE project = ? AND test = ?",
  )

  const update = (row: PartRow, fields: Partial<Record<keyof PartRow, unknown>>) => {
    const names = Object.keys(fields)
    db.run(`UPDATE hub_part SET ${names.map((name) => `${name} = ?`).join(", ")} WHERE job_id = ? AND part = ?`, [
      ...names.map((name) => fields[name as keyof typeof fields] as string | number | null),
      row.job_id,
      row.part,
    ])
  }
  const record = (
    key: { job: string; part: string; attempt: number },
    fields: { machine?: string; state: string; outcome?: unknown },
  ) =>
    db.run(
      "INSERT INTO hub_attempt (job_id, part, n, machine_id, state, outcome, at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (job_id, part, n, machine_id) DO UPDATE SET state = excluded.state, outcome = COALESCE(excluded.outcome, outcome), at = excluded.at",
      [
        key.job,
        key.part,
        key.attempt,
        fields.machine ?? "",
        fields.state,
        fields.outcome === undefined ? null : JSON.stringify(fields.outcome),
        input.now(),
      ],
    )
  /** An attempt the hub gave up (withdrawn, lost, replaced): the machine hears it when it calls, and stops it. */
  const cancelAttempt = (machineID: string, key: { job: string; part: string; attempt: number }, reason: string) => {
    if (history.get(key.job, key.part, key.attempt, machineID)?.cancelled) return
    db.run(
      "INSERT INTO hub_attempt (job_id, part, n, machine_id, state, cancelled, at) VALUES (?, ?, ?, ?, 'cancelado', 1, ?) ON CONFLICT (job_id, part, n, machine_id) DO UPDATE SET cancelled = 1",
      [key.job, key.part, key.attempt, machineID, input.now()],
    )
    input.send(machineID, { type: "attempt.cancel", job: key.job, part: key.part, attempt: key.attempt, reason })
  }
  const releaseLocks = (row: PartRow) =>
    db.run("DELETE FROM hub_lock WHERE job_id = ? AND part = ?", [row.job_id, row.part])
  /** Tells the origin where a part stands. */
  const tell = (row: PartRow, extra: Partial<typeof BancadaProtocol.JobUpdate.Type> = {}) => {
    const owner = job.get(row.job_id)
    const current = part.get(row.job_id, row.part)
    if (!owner || !current) return
    const at = current.machine_id ? machine.get(current.machine_id) : undefined
    input.send(owner.origin_machine, {
      type: "job.update",
      job: row.job_id,
      part: row.part,
      state: current.state,
      attempt: current.attempt_n,
      ...(at ? { machine: { machineID: at.machine_id, name: at.name, instanceID: at.instance_id } } : {}),
      ...(current.devices && current.state === "rodando" ? { devices: JSON.parse(current.devices) } : {}),
      ...extra,
    })
  }
  const lostOutcome = (reason: string): BancadaProtocol.Outcome => ({
    verdict: "infraestrutura",
    reason,
    planned: [],
    scenarios: [],
    lost: [],
    approved: false,
  })

  /** A part of a cancelled request closes `cancelado` now; what it runs hears `attempt.cancel` when its machine calls. */
  const cancelNow = (row: PartRow) => {
    if (row.machine_id && row.state !== "na_fila")
      cancelAttempt(row.machine_id, { job: row.job_id, part: row.part, attempt: row.attempt_n }, "cancelado")
    releaseLocks(row)
    update(row, {
      state: "cancelado",
      held_state: null,
      outcome: JSON.stringify({ ...lostOutcome("cancelado"), verdict: "cancelado" }),
      since: input.now(),
    })
    tell(row)
  }
  const cancelled = (jobID: string) => job.get(jobID)?.cancelled_at != null

  /** When every part is final the job closes, once, and its result goes to the origin. */
  const close = (jobID: string) => {
    const owner = job.get(jobID)
    if (!owner || owner.state !== "aberto") return
    const all = parts.all(jobID)
    if (!all.every((row) => BancadaProtocol.finalStates.has(row.state))) return
    db.run("UPDATE hub_job SET state = 'fechado', closed_at = ? WHERE id = ?", [input.now(), jobID])
    const project = (JSON.parse(owner.code) as BancadaProtocol.Code).project
    input.send(owner.origin_machine, {
      type: "result",
      job: jobID,
      parts: all.map((row) => {
        const at = row.machine_id ? machine.get(row.machine_id) : undefined
        const outcome: BancadaProtocol.Outcome | undefined = row.outcome ? JSON.parse(row.outcome) : undefined
        const evidence: BancadaProtocol.Evidence[] = JSON.parse(row.evidence)
        const history = Object.fromEntries(
          (outcome?.scenarios ?? [])
            .filter((scenario) => scenario.result === "falhou")
            .flatMap((scenario) => {
              const last = scenarios.get(project, row.part, scenario.id)
              if (!last) return []
              const results: string[] = JSON.parse(last.last)
              return [[scenario.id, { failed: results.filter((item) => item === "falhou").length, of: results.length }]]
            }),
        )
        return {
          part: row.part,
          state: row.state,
          attempts: row.attempt_n,
          ...(at ? { machine: { machineID: at.machine_id, name: at.name } } : {}),
          ...(outcome ? { outcome } : {}),
          ...(row.started_at !== null ? { ms: Math.max(0, row.since - row.started_at) } : {}),
          ...(Object.keys(history).length ? { history } : {}),
          ...(evidence.length ? { evidence } : {}),
        }
      }),
    })
  }

  /**
   * The end of an attempt (`docs/bancada.md`, "State machine"): its outcome joins the earlier attempt's, if any. A part
   * with scenarios left without result (a device that fell, a deadline, exit 75, an incomplete run, a lost machine)
   * runs once more with only those, when that is safe: a part on a phone, with real accounts, an exclusive lock or
   * secrets only after an end its machine confirmed. A failed assertion never runs again.
   */
  const ended = (row: PartRow, outcome: BancadaProtocol.Outcome, confirmed: boolean) => {
    const previous: BancadaProtocol.Outcome | undefined = row.previous ? JSON.parse(row.previous) : undefined
    const result = previous ? join(previous, outcome) : outcome
    // A cancelled request never runs again: whatever the attempt said, the part closes cancelled.
    const joined: BancadaProtocol.Outcome = cancelled(row.job_id)
      ? { ...result, verdict: "cancelado", reason: "cancelado", approved: false }
      : result
    const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
    // Only when something is left to run: scenarios without result, or no plan at all (it never wrote planned.json),
    // when it runs whole. An infrastructure failure with every scenario answered closes with what it gave.
    const leftover = joined.lost.length > 0 || (joined.verdict === "infraestrutura" && joined.planned.length === 0)
    const retry =
      row.retry_used === 0 &&
      leftover &&
      (confirmed || !spec.unsafe) &&
      (joined.verdict === "infraestrutura" || joined.verdict === "incompleto")
    releaseLocks(row)
    if (retry) {
      update(row, {
        state: "na_fila",
        machine_id: null,
        offer_seq: null,
        held_state: null,
        missing: 0,
        retry_used: 1,
        previous: JSON.stringify(joined),
        only_scenarios: joined.lost.length > 0 ? JSON.stringify(joined.lost) : null,
        refused_by: null,
        refused_pulse: null,
        told: null,
        since: input.now(),
      })
      return tell(row)
    }
    const state =
      joined.verdict === "infraestrutura" ? "perdido" : joined.verdict === "cancelado" ? "cancelado" : "concluido"
    update(row, { state, held_state: null, outcome: JSON.stringify(joined), since: input.now() })
    remember(row, joined)
    tell(row)
    close(row.job_id)
  }

  /** A part goes back to the queue: its offer was refused or withdrawn. The next offer has the next attempt number. */
  const requeue = (row: PartRow, extra: Partial<Record<keyof PartRow, unknown>> = {}) => {
    if (cancelled(row.job_id)) return cancelNow(row)
    releaseLocks(row)
    update(row, {
      state: "na_fila",
      machine_id: null,
      offer_seq: null,
      held_state: null,
      offered_at: null,
      acked_at: null,
      told: null,
      since: input.now(),
      ...extra,
    })
  }

  /**
   * A machine lists an attempt of a part this hub forgot and was told again (`again`): the hub adopts it, offering that
   * attempt, with its number, to that machine, which answers with what it has (`docs/bancada.md`, "When a side forgot").
   */
  const adopt = (machineID: string, ref: typeof BancadaProtocol.AttemptRef.Type) => {
    const row = part.get(ref.job, ref.part)
    const owner = job.get(ref.job)
    if (!row || !owner || row.state !== "na_fila" || row.adopt_until === null) return
    const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
    const seq = input.send(machineID, {
      type: "offer",
      job: ref.job,
      part: ref.part,
      attempt: ref.attempt,
      spec,
      origin: JSON.parse(owner.origin),
      code: JSON.parse(owner.code),
      devices: { min: spec.devices.min, proposed: spec.devices.max },
    })
    spec.exclusive.forEach((name) =>
      db.run("INSERT OR REPLACE INTO hub_lock (name, job_id, part, since) VALUES (?, ?, ?, ?)", [
        name,
        ref.job,
        ref.part,
        input.now(),
      ]),
    )
    record(ref, { machine: machineID, state: "oferecido" })
    update(row, {
      state: "oferecido",
      attempt_n: ref.attempt,
      machine_id: machineID,
      offer_seq: seq,
      devices_granted: spec.devices.max,
      offered_at: input.now(),
      acked_at: null,
      adopt_until: null,
      told: null,
      since: input.now(),
    })
    input.log(`adopted attempt ${ref.attempt} of ${ref.job}/${ref.part}, which ${machineID} still runs`)
    tell(row)
  }

  /** Requests over whose cleanup a machine running something of them already heard (this process's life). */
  const cleaned = new Set<string>()
  /**
   * An attempt a machine lists that is no longer its part's (the part ran again elsewhere, or closed while the machine
   * was cut off): it stops there; a request already delivered is cleaned up there. A request this hub never knew is the
   * machine's own, run while the hub was out: only recorded (`local.job`).
   */
  const stray = (machineID: string, ref: typeof BancadaProtocol.AttemptRef.Type) => {
    const owner = job.get(ref.job)
    if (!owner) return
    if (owner.state === "entregue") {
      if (cleaned.has(`${machineID}/${ref.job}`)) return
      cleaned.add(`${machineID}/${ref.job}`)
      input.send(machineID, { type: "cleanup", job: ref.job })
      return
    }
    const row = part.get(ref.job, ref.part)
    if (!row || (row.state === "na_fila" && row.adopt_until !== null)) return
    const over = BancadaProtocol.finalStates.has(row.state)
    if (!over && row.machine_id === machineID && row.attempt_n === ref.attempt) return
    cancelAttempt(machineID, ref, over ? "o pedido já terminou" : "substituída por uma nova tentativa")
  }

  const handlers = {
    hello: (from: string, message: typeof BancadaProtocol.Hello.Type) => {
      db.run(
        "UPDATE hub_machine SET platform = ?, capabilities = ?, speed = ?, phones = ?, hardware = ? WHERE machine_id = ?",
        [
          message.platform,
          JSON.stringify(message.capabilities),
          message.speed,
          JSON.stringify(message.phones ?? []),
          message.hardware ?? null,
          from,
        ],
      )
      if (!input.hub) return
      const all = machines.all()
      const catalog: BancadaProtocol.FromHub = {
        type: "catalog",
        machines: all.map((row) => ({
          machineID: row.machine_id,
          name: row.name,
          ...(row.platform ? { platform: row.platform } : {}),
          ...(row.hardware ? { hardware: row.hardware } : {}),
          instanceID: row.instance_id,
        })),
        phones: all.flatMap((row) =>
          (JSON.parse(row.phones) as (typeof BancadaProtocol.CatalogPhone.Type)[]).map((phone) => ({
            ...phone,
            machineID: row.machine_id,
          })),
        ),
      }
      all.forEach((row) => input.send(row.machine_id, catalog))
    },
    submit: (from: string, message: typeof BancadaProtocol.Submit.Type) => {
      const known = job.get(message.job)
      // A request seen before (its tombstone too) never runs again; an open one hears where it stands.
      if (known) {
        if (known.state === "aberto")
          input.send(from, {
            type: "submit.ack",
            job: message.job,
            parts: parts.all(message.job).map((row) => ({ part: row.part, state: row.state, attempt: row.attempt_n })),
            superseded: [],
          })
        return
      }
      const superseded = message.again ? [] : supersede(from, message)
      db.run(
        "INSERT INTO hub_job (id, origin_machine, origin, code, state, created_at) VALUES (?, ?, ?, ?, 'aberto', ?)",
        [message.job, from, JSON.stringify(message.origin), JSON.stringify(message.code), input.now()],
      )
      // Sent again to this hub, which forgot it: a machine may run it. Nothing is offered until they all called.
      const adoptUntil = message.again ? input.now() + times.silentMs : null
      message.parts.forEach((spec, idx) =>
        db.run(
          "INSERT INTO hub_part (job_id, part, idx, spec, state, attempt_n, since, adopt_until) VALUES (?, ?, ?, ?, 'na_fila', 0, ?, ?)",
          [message.job, spec.part, idx, JSON.stringify(spec), input.now(), adoptUntil],
        ),
      )
      input.send(from, {
        type: "submit.ack",
        job: message.job,
        parts: message.parts.map((spec) => ({
          part: spec.part,
          state: "na_fila",
          attempt: 0,
          reason: message.again ? { code: "reconciliando", text: "reconciliando" } : { code: "fila", text: "na fila" },
        })),
        superseded,
      })
      if (message.again)
        machines
          .all()
          .forEach((row) =>
            (JSON.parse(row.running) as BancadaProtocol.Pulse["running"])
              .filter((ref) => ref.job === message.job)
              .forEach((ref) => adopt(row.machine_id, ref)),
          )
    },
    /**
     * A cancelled request never comes back (`docs/bancada.md`, "State machine"): it is marked, nothing of it is offered
     * or tried again; what waits, what was offered and what is uncertain closes `cancelado` now, what runs on a machine
     * that answers closes when its final report comes.
     */
    cancel: (from: string, message: typeof BancadaProtocol.Cancel.Type) => {
      const owner = job.get(message.job)
      if (!owner || owner.origin_machine !== from || owner.state !== "aberto" || owner.cancelled_at !== null) return
      db.run("UPDATE hub_job SET cancelled_at = ? WHERE id = ?", [input.now(), message.job])
      for (const row of parts.all(message.job)) {
        if (BancadaProtocol.finalStates.has(row.state)) continue
        if (row.machine_id && (live as ReadonlyArray<string>).includes(row.state)) {
          cancelAttempt(row.machine_id, { job: row.job_id, part: row.part, attempt: row.attempt_n }, "cancelado")
          continue
        }
        cancelNow(row)
      }
      close(message.job)
    },
    "offer.reply": (
      from: string,
      message: typeof BancadaProtocol.OfferAccepted.Type | typeof BancadaProtocol.OfferRefused.Type,
    ) => {
      const row = part.get(message.job, message.part)
      if (!row) return
      record(message, { machine: from, state: message.accepted ? "aceito" : "recusado" })
      // An unsafe part whose machine went silent with the offer unanswered waits as `incerto` for this reply.
      const pending = row?.state === "oferecido" || (row?.state === "incerto" && row.held_state === "oferecido")
      if (!pending || row.attempt_n !== message.attempt || row.machine_id !== from) return
      if (message.accepted) {
        update(row, {
          state: "aceito",
          held_state: null,
          devices_granted: message.devices,
          started_at: input.now(),
          since: input.now(),
        })
        return tell(row)
      }
      requeue(row, { refused_by: from, refused_pulse: machine.get(from)?.pulse_seq ?? 0 })
      tell(row, { reason: message.reason })
    },
    attempt: (from: string, message: typeof BancadaProtocol.AttemptReport.Type) => {
      const row = part.get(message.job, message.part)
      if (!row) return
      record(message, { machine: from, state: message.state, ...(message.outcome ? { outcome: message.outcome } : {}) })
      // A late report of an older attempt stays in its history; if it still runs, it stops.
      if (message.attempt < row.attempt_n || row.machine_id !== from) {
        if (!BancadaProtocol.finalStates.has(message.state))
          cancelAttempt(from, message, "substituída por uma nova tentativa")
        return
      }
      if (message.attempt !== row.attempt_n || BancadaProtocol.finalStates.has(row.state)) return
      // An uncertain part hears its real state again, whatever it was before the silence.
      const from_ = row.state === "incerto" ? (row.held_state ?? "aceito") : row.state
      if (rank[message.state] < rank[from_] || (rank[message.state] === rank[from_] && row.state !== "incerto")) return
      if (!BancadaProtocol.finalStates.has(message.state)) {
        update(row, {
          state: message.state,
          held_state: null,
          missing: 0,
          since: input.now(),
          ...(message.state === "rodando" ? { built_at: input.now() } : {}),
          ...(message.devices ? { devices: JSON.stringify(message.devices) } : {}),
        })
        return tell(row)
      }
      const outcome = message.outcome ?? lostOutcome("a execução terminou sem resultado")
      keep(row, from, message)
      // A failed build says nothing about how long the test takes.
      if (message.state === "concluido" && outcome.verdict !== "compilacao")
        sample(row, outcome, message.devices?.length || undefined)
      // A new attempt that ran only some scenarios, adopted by a hub that lost the earlier one's result: it never
      // approves the part alone, nor runs again (`docs/bancada.md`, "When a side forgot").
      const forgotten =
        message.partial === true &&
        row.previous === null &&
        (outcome.verdict === "aprovado" || outcome.verdict === "incompleto")
      if (forgotten)
        return ended(
          { ...row, retry_used: 1 },
          {
            ...outcome,
            verdict: "incompleto",
            reason: "o hub perdeu o resultado da primeira tentativa",
            approved: false,
          },
          true,
        )
      ended(row, outcome, true)
    },
    /**
     * A request a machine served alone while the hub was out (`docs/bancada.md`, "Hub out"): only a fact, for the
     * panel and the history; it never enters the queue. Its id stays known for `tombstoneMs`, like a delivered one.
     */
    "local.job": (from: string, message: typeof BancadaProtocol.LocalJob.Type) =>
      db.run(
        "INSERT OR IGNORE INTO hub_job (id, origin_machine, origin, code, state, created_at, closed_at) VALUES (?, ?, ?, ?, 'local', ?, ?)",
        [message.job, from, JSON.stringify(message.origin), JSON.stringify(message.code), input.now(), input.now()],
      ),
    /**
     * An executor could not bring a request's code (`docs/bancada.md`, "Frozen code"): the hub names a transfer from
     * the origin to it and asks the origin for a bundle; its parts there wait for the code. Asked again, the earlier
     * transfer is dropped.
     */
    "code.have": (from: string, message: typeof BancadaProtocol.CodeHave.Type) => {
      const owner = job.get(message.job)
      if (!owner || owner.state !== "aberto") return
      const waiting = parts
        .all(message.job)
        .filter((row) => row.machine_id === from && (live as ReadonlyArray<string>).includes(row.state))
      // Nothing of the request waits there any more: a late ask.
      if (waiting.length === 0) return
      db.run(
        "UPDATE hub_blob SET state = 'apagar' WHERE job_id = ? AND downloader = ? AND state IN ('aberta', 'pronta')",
        [message.job, from],
      )
      // The origin cannot send now: the part waits for it in the queue, not the machine with its reservation.
      if (machine.get(owner.origin_machine)?.state !== "ok") return waiting.forEach(needCode)
      const transfer = input.random()
      db.run(
        "INSERT INTO hub_blob (transfer, job_id, kind, uploader, downloader, state, expires_at, created_at) VALUES (?, ?, 'codigo', ?, ?, 'aberta', ?, ?)",
        [transfer, message.job, owner.origin_machine, from, input.now() + times.transferMs, input.now()],
      )
      input.send(owner.origin_machine, { type: "code.request", job: message.job, have: message.have, transfer })
      waiting.forEach((row) => tell(row, { reason: { code: "aguardando_codigo", text: "aguardando o código" } }))
    },
    /** The origin sent the whole bundle: once the hub has every file it declared, the executor hears where it is. */
    "blob.ready": (from: string, message: typeof BancadaProtocol.BlobReady.Type) => {
      const row = blob.get(message.transfer.id)
      if (!row || row.uploader !== from || row.state !== "aberta") return
      const received: Record<string, string> = JSON.parse(row.received)
      if (!message.transfer.files.every((file) => received[file.index] === file.sha256)) {
        input.log(`transfer ${row.transfer} of ${row.job_id} said ready without every file`)
        return
      }
      db.run("UPDATE hub_blob SET state = 'pronta', files = ? WHERE transfer = ?", [
        JSON.stringify(message.transfer.files),
        row.transfer,
      ])
      // Evidence: the origin reads it when the request closes (`result`); code: the executor hears where it is.
      if (row.kind !== "codigo") return
      input.send(row.downloader, {
        type: "code.source",
        job: row.job_id,
        source: { transfer: message.transfer },
      })
    },
    /**
     * A session asks for a device of another machine (`docs/bancada.md`, "Holds"): the hub finds that machine (the
     * one named; `mac`, the Mac; for a phone, the machine whose catalog has it) and relays; that machine decides.
     */
    "hold.request": (from: string, message: typeof BancadaProtocol.HoldRequest.Type) => {
      const all = machines.all()
      const target =
        message.machineID === "mac"
          ? all.find((row) => row.platform === "darwin" && row.machine_id !== from)
          : message.machineID === "" && message.target.kind === "fisico"
            ? all.find((row) =>
                (JSON.parse(row.phones) as { alias: string }[]).some(
                  (phone) => phone.alias === (message.target as { device: string }).device,
                ),
              )
            : machine.get(message.machineID)
      if (!target || target.state !== "ok") {
        const reason: BancadaProtocol.Reason = target
          ? { code: "maquina_fora", detail: target.name, text: `aguardando ${target.name} voltar` }
          : { code: "sem_maquina", text: "nenhuma máquina tem esse aparelho" }
        return input.send(from, { type: "hold.deny", hold: message.hold, reason })
      }
      db.run(
        "INSERT OR REPLACE INTO hub_hold (hold, origin_machine, target_machine, state, at) VALUES (?, ?, ?, 'pedida', ?)",
        [message.hold, from, target.machine_id, input.now()],
      )
      input.send(target.machine_id, {
        type: "hold.ask",
        hold: message.hold,
        origin: message.origin,
        target: message.target,
      })
    },
    "hold.touch": (from: string, message: typeof BancadaProtocol.HoldTouch.Type) => {
      const row = holdRoute.get(message.hold)
      if (row && row.origin_machine === from)
        input.send(row.target_machine, { type: "hold.renew", hold: message.hold, at: message.at })
    },
    "hold.release": (from: string, message: typeof BancadaProtocol.HoldRelease.Type) => {
      const row = holdRoute.get(message.hold)
      if (row && row.origin_machine === from) input.send(row.target_machine, { type: "hold.drop", hold: message.hold })
    },
    /** The machine that decides a hold says where it stands: relayed to the session's machine. */
    "hold.state": (from: string, message: typeof BancadaProtocol.HoldState.Type) => {
      const row = holdRoute.get(message.hold)
      if (!row || row.target_machine !== from) return
      db.run("UPDATE hub_hold SET state = ?, at = ? WHERE hold = ?", [message.state, input.now(), message.hold])
      const name = machine.get(from)?.name ?? from
      if (message.state === "concedida")
        return input.send(row.origin_machine, {
          type: "hold.grant",
          hold: message.hold,
          device: { ...message.device, maquina: name },
          expiresAt: message.expiresAt ?? input.now(),
        })
      if (message.state === "esperando" || message.state === "negada")
        return input.send(row.origin_machine, {
          type: "hold.deny",
          hold: message.hold,
          reason: message.reason ?? { code: "orcamento", text: "sem folga agora" },
          machine: name,
          ...(message.state === "esperando" && message.position !== undefined ? { position: message.position } : {}),
          ...(message.state === "esperando" && message.expiresAt !== undefined ? { expiresAt: message.expiresAt } : {}),
        })
      input.send(row.origin_machine, {
        type: "hold.expire",
        hold: message.hold,
        ...(message.state === "vencida" && message.reason ? { reason: message.reason.text } : {}),
      })
    },
    delivered: (from: string, message: typeof BancadaProtocol.Delivered.Type) => {
      const owner = job.get(message.job)
      if (!owner || owner.origin_machine !== from || owner.state !== "fechado") return
      // Every machine that had an attempt of it, earlier ones included (a part that ran again elsewhere).
      const machines = db
        .query<{ machine_id: string }, [string]>(
          "SELECT DISTINCT machine_id FROM hub_attempt WHERE job_id = ? AND machine_id <> ''",
        )
        .all(message.job)
        .map((row) => row.machine_id)
      new Set([
        ...machines,
        ...parts.all(message.job).flatMap((row) => (row.machine_id ? [row.machine_id] : [])),
      ]).forEach((machineID) => input.send(machineID, { type: "cleanup", job: message.job }))
      tombstone(message.job)
    },
  }

  /**
   * After delivery only the request's id and state stay, for `tombstoneMs`, so a resend of the same id never runs it
   * again (`docs/bancada.md`, "State"); its parts and their history go at once.
   */
  const tombstone = (jobID: string) => {
    db.run("UPDATE hub_job SET state = 'entregue', origin = '{}', code = '{}', closed_at = ? WHERE id = ?", [
      input.now(),
      jobID,
    ])
    db.run("DELETE FROM hub_part WHERE job_id = ?", [jobID])
    db.run("DELETE FROM hub_attempt WHERE job_id = ?", [jobID])
    db.run("DELETE FROM hub_lock WHERE job_id = ?", [jobID])
    db.run("UPDATE hub_blob SET state = 'apagar' WHERE job_id = ?", [jobID])
  }

  /**
   * Substitution (`docs/bancada.md`, "Queue"): a request replaces its session's parts of the same project and test
   * still waiting. They are cancelled ("substituída por …"); a request left with every part replaced closes without
   * a notice (the origin hears it in `superseded`). Returns those requests.
   */
  const supersede = (from: string, message: typeof BancadaProtocol.Submit.Type) => {
    const replaced = new Set(message.parts.map((spec) => spec.part))
    const waiting = db
      .query<PartRow & { origin: string; code: string }, [string]>(
        "SELECT p.*, j.origin, j.code FROM hub_part p JOIN hub_job j ON j.id = p.job_id WHERE j.origin_machine = ? AND j.state = 'aberto' AND p.state = 'na_fila'",
      )
      .all(from)
      .filter(
        (row) =>
          replaced.has(row.part) &&
          (JSON.parse(row.origin) as BancadaProtocol.Origin).sessionID === message.origin.sessionID &&
          (JSON.parse(row.code) as BancadaProtocol.Code).project === message.code.project,
      )
    const outcome = { ...lostOutcome(`substituída por ${message.job}`), verdict: "cancelado" as const }
    waiting.forEach((row) => update(row, { state: "cancelado", outcome: JSON.stringify(outcome), since: input.now() }))
    const touched = [...new Set(waiting.map((row) => row.job_id))]
    const whole = touched.filter((jobID) =>
      parts
        .all(jobID)
        .every((row) => row.state === "cancelado" && row.outcome?.includes(`substituída por ${message.job}`)),
    )
    whole.forEach(tombstone)
    touched
      .filter((jobID) => !whole.includes(jobID))
      .forEach((jobID) => {
        waiting.filter((row) => row.job_id === jobID).forEach((row) => tell(row))
        close(jobID)
      })
    return whole
  }

  /** A part's final scenario results join each scenario's last 20 (passed or failed; ignored ones say nothing). */
  const remember = (row: PartRow, outcome: BancadaProtocol.Outcome) => {
    const owner = job.get(row.job_id)
    if (!owner) return
    const project = (JSON.parse(owner.code) as BancadaProtocol.Code).project
    outcome.scenarios
      .filter((scenario) => scenario.result !== "ignorado")
      .forEach((scenario) => {
        const known = scenarios.get(project, row.part, scenario.id)
        const last = [...(known ? (JSON.parse(known.last) as string[]) : []), scenario.result].slice(-20)
        db.run("INSERT OR REPLACE INTO hub_scenario (project, test, scenario_id, last) VALUES (?, ?, ?, ?)", [
          project,
          row.part,
          scenario.id,
          JSON.stringify(last),
        ])
      })
  }

  /**
   * What an attempt keeps for the notice, from its final report: on the origin's own machine it is there already;
   * from another, the hub names a transfer to the origin and asks the executor to send it (`evidence.request`).
   */
  const keep = (row: PartRow, from: string, message: typeof BancadaProtocol.AttemptReport.Type) => {
    const owner = job.get(row.job_id)
    if (!owner || !message.evidence?.length) return
    const transfer = from === owner.origin_machine ? undefined : input.random()
    if (transfer) {
      db.run(
        "INSERT INTO hub_blob (transfer, job_id, kind, uploader, downloader, state, expires_at, created_at) VALUES (?, ?, 'evidencias', ?, ?, 'aberta', ?, ?)",
        [transfer, row.job_id, from, owner.origin_machine, input.now() + times.transferMs, input.now()],
      )
      input.send(from, {
        type: "evidence.request",
        job: row.job_id,
        part: row.part,
        attempt: message.attempt,
        transfer,
      })
    }
    const entry: BancadaProtocol.Evidence = {
      attempt: message.attempt,
      ...(transfer ? { transfer } : {}),
      files: message.evidence,
    }
    update(row, { evidence: JSON.stringify([...(JSON.parse(row.evidence) as BancadaProtocol.Evidence[]), entry]) })
  }

  /**
   * A concluded attempt's times feed the estimates of that project's test on that machine (the last 10), with the
   * devices it ran on (as its end says; what it was granted at admission before).
   */
  const sample = (row: PartRow, outcome: BancadaProtocol.Outcome, devices?: number) => {
    const owner = job.get(row.job_id)
    if (!owner || !row.machine_id || row.started_at === null) return
    const project = (JSON.parse(owner.code) as BancadaProtocol.Code).project
    const built = row.built_at ?? row.started_at
    const next: Sample = {
      buildMs: Math.max(0, built - row.started_at),
      runMs: Math.max(0, input.now() - built),
      devices: devices ?? row.devices_granted ?? 0,
      ...(outcome.planned.length > 0 ? { scenarios: outcome.planned.length } : {}),
    }
    const known = durations.all(project, row.part).find((item) => item.machine_id === row.machine_id)
    const samples = [...(known ? (JSON.parse(known.samples) as Sample[]) : []), next].slice(-estimates.kept)
    db.run("INSERT OR REPLACE INTO hub_duration (project, test, machine_id, samples) VALUES (?, ?, ?, ?)", [
      project,
      row.part,
      row.machine_id,
      JSON.stringify(samples),
    ])
  }

  /** Applies one message from `from`. Messages of later packages (holds, code, blobs) are not handled yet. */
  const apply = (from: string, message: BancadaProtocol.FromMachine) => {
    if (message.type === "hello") return handlers.hello(from, message)
    if (message.type === "submit") return handlers.submit(from, message)
    if (message.type === "cancel") return handlers.cancel(from, message)
    if (message.type === "offer.reply") return handlers["offer.reply"](from, message)
    if (message.type === "attempt") return handlers.attempt(from, message)
    if (message.type === "delivered") return handlers.delivered(from, message)
    if (message.type === "local.job") return handlers["local.job"](from, message)
    if (message.type === "code.have") return handlers["code.have"](from, message)
    if (message.type === "hold.request") return handlers["hold.request"](from, message)
    if (message.type === "hold.touch") return handlers["hold.touch"](from, message)
    if (message.type === "hold.release") return handlers["hold.release"](from, message)
    if (message.type === "hold.state") return handlers["hold.state"](from, message)
    if (message.type === "blob.ready") return handlers["blob.ready"](from, message)
  }

  /**
   * Records who called and, only from a pulse newer than the last applied, everything the pulse says: the machine's
   * state, when it last called, its free vector, its brake and what it runs (`docs/bancada.md`, "State machine"). A
   * repeated or late call never makes a machine "come back". An uncertain part it still runs returns to where it was;
   * one it accepted and has not listed in two pulses in a row, without a final report, is lost.
   */
  const seen = (sync: BancadaProtocol.SyncInputEnvelope) => {
    const known = machine.get(sync.machineID)
    if (!known)
      db.run(
        "INSERT INTO hub_machine (machine_id, instance_id, name, state, protocol, last_sync_at, state_since) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [sync.machineID, sync.instanceID, sync.name, sync.pulse.state, sync.protocol, input.now(), input.now()],
      )
    db.run("UPDATE hub_machine SET instance_id = ?, name = ?, protocol = ? WHERE machine_id = ?", [
      sync.instanceID,
      sync.name,
      sync.protocol,
      sync.machineID,
    ])
    const stream = sync.out.stream
    if (known && known.pulse_stream === stream && (known.pulse_seq ?? -1) >= sync.pulse.seq) return
    // Its process restarts: "reconciliando" until it is back, not "silenciosa" (`docs/bancada.md`, "Process").
    const state = sync.leaving === "restart" ? "reconciling" : sync.pulse.state
    db.run(
      "UPDATE hub_machine SET state = ?, state_since = CASE WHEN state = ? THEN state_since ELSE ? END, last_sync_at = ?, free = ?, brake = ?, pulse_stream = ?, pulse_seq = ?, running = ? WHERE machine_id = ?",
      [
        state,
        state,
        input.now(),
        input.now(),
        JSON.stringify(sync.pulse.free),
        sync.pulse.brake ? 1 : 0,
        stream,
        sync.pulse.seq,
        // What it runs and what it keeps: a request sent again adopts from either.
        JSON.stringify([...sync.pulse.running, ...sync.pulse.kept]),
        sync.machineID,
      ],
    )
    sync.pulse.running.forEach((ref) => {
      adopt(sync.machineID, ref)
      stray(sync.machineID, ref)
    })
    // An ended attempt it keeps: adopted too (it answers with its final report); of a delivered request, cleaned.
    sync.pulse.kept.forEach((ref) => {
      adopt(sync.machineID, ref)
      if (job.get(ref.job)?.state === "entregue") stray(sync.machineID, ref)
    })
    const running = new Set(sync.pulse.running.map((item) => `${item.job}/${item.part}/${item.attempt}`))
    const acknowledged = input.acknowledged(sync.machineID)
    for (const row of onMachine.all(sync.machineID)) {
      const listed = running.has(`${row.job_id}/${row.part}/${row.attempt_n}`)
      // Only a machine that is `ok` vouches for what it lists: a reconciling one lists its database, not what it saw run.
      const vouched = listed && sync.pulse.state === "ok"
      if (row.state === "incerto" && vouched && row.held_state && row.held_state !== "oferecido") {
        update(row, { state: row.held_state, held_state: null, missing: 0 })
        tell(row)
        continue
      }
      const accepted =
        (live as ReadonlyArray<string>).includes(row.state) ||
        (row.state === "incerto" && row.held_state !== "oferecido")
      if (!accepted || (row.offer_seq ?? 0) > acknowledged) continue
      if (listed) {
        if (row.missing > 0) update(row, { missing: 0 })
        continue
      }
      if (row.missing + 1 < 2) {
        update(row, { missing: row.missing + 1 })
        continue
      }
      // Not a confirmed end: an unsafe part does not run again.
      ended(row, lostOutcome("a máquina não conhece mais esta tentativa"), false)
    }
  }

  /**
   * Another server's machine (`docs/bancada.md`, "Several servers"): a `machineID` a different server called with in
   * the last minute is refused; after that, the new one takes it over.
   */
  const taken = (sync: BancadaProtocol.SyncInputEnvelope) => {
    const known = machine.get(sync.machineID)
    if (!known || known.instance_id === sync.instanceID || input.now() - known.last_sync_at >= takenMs) return undefined
    return { instanceID: known.instance_id, name: known.name }
  }

  /**
   * What depends on time, each round: a machine silent for `silentMs` (asleep, or gone) has its offers withdrawn and
   * what it runs turns `incerto`, never approved nor lost by itself; away after `uncertainMs`; an uncertain part lost
   * after `lostMs`. The silence counts only while the hub listens: from the later of the machine's last call and this
   * hub's start (after a deploy every last call is old). An offer received and unanswered for `replyMs` is withdrawn.
   */
  const watch = () => {
    const now = input.now()
    const listening = now - input.startedAt
    for (const row of machines.all()) {
      const quiet = Math.min(now - row.last_sync_at, listening)
      if ((row.state === "ok" || row.state === "reconciling") && quiet >= times.silentMs) {
        db.run("UPDATE hub_machine SET state = 'silenciosa', state_since = ? WHERE machine_id = ?", [
          now,
          row.machine_id,
        ])
        uncertain(row)
      }
      if (row.state === "silenciosa" && quiet >= times.uncertainMs)
        db.run("UPDATE hub_machine SET state = 'fora', state_since = ? WHERE machine_id = ?", [now, row.machine_id])
      // Still reconciling long after it came back: what it runs is as uncertain as a silent machine's.
      if (row.state === "reconciling" && now - row.state_since >= times.reconcilingMs) uncertain(row)
    }
    for (const row of inState.all("incerto")) {
      if (now - row.since < times.lostMs || !row.machine_id) continue
      const away = machine.get(row.machine_id)
      cancelAttempt(
        row.machine_id,
        { job: row.job_id, part: row.part, attempt: row.attempt_n },
        "a máquina não respondeu",
      )
      ended(row, lostOutcome(`a máquina ${away?.name ?? row.machine_id} não respondeu`), false)
    }
    // Nobody listed it while every live machine called: a safe part queues as new, an unsafe one is lost.
    for (const row of inState.all("na_fila")) {
      if (row.adopt_until === null || now < row.adopt_until) continue
      if (!(JSON.parse(row.spec) as BancadaProtocol.PartSpec).unsafe) {
        update(row, { adopt_until: null, told: null })
        continue
      }
      update(row, { adopt_until: null })
      ended(
        row,
        lostOutcome("o hub perdeu o registro deste pedido e esta parte não pode repetir sem confirmação"),
        false,
      )
    }
    for (const row of inState.all("oferecido")) {
      if (!row.machine_id) continue
      const received = (row.offer_seq ?? 0) <= input.acknowledged(row.machine_id)
      if (received && row.acked_at === null) update(row, { acked_at: now })
      if (!received || row.acked_at === null || now - row.acked_at < times.replyMs) continue
      withdraw(row)
    }
    db.run("DELETE FROM hub_job WHERE state IN ('entregue', 'local') AND closed_at < ?", [now - times.tombstoneMs])
    stuckCode(now)
    alertNoMachine(now)
    alertNoCode(now)
  }

  /**
   * An open transfer whose origin stopped being `ok`, or any transfer that expired: what waits for it on its
   * executor is withdrawn (`needCode`), and the transfer goes.
   */
  const stuckCode = (now: number) =>
    db
      .query<
        { transfer: string; job_id: string; uploader: string; downloader: string; state: string; expires_at: number },
        []
      >(
        "SELECT transfer, job_id, uploader, downloader, state, expires_at FROM hub_blob WHERE kind = 'codigo' AND state IN ('aberta', 'pronta')",
      )
      .all()
      .filter((row) => now >= row.expires_at || (row.state === "aberta" && machine.get(row.uploader)?.state !== "ok"))
      .forEach((row) => {
        db.run("UPDATE hub_blob SET state = 'apagar' WHERE transfer = ?", [row.transfer])
        parts
          .all(row.job_id)
          .filter(
            (part) =>
              part.machine_id === row.downloader &&
              (part.state === "aceito" || (part.state === "incerto" && part.held_state === "aceito")),
          )
          .forEach(needCode)
      })

  /** Code an executor waits for that has not arrived in `noMachineMs` (the origin is away, say): an alert, until it does. */
  const alertNoCode = (now: number) => {
    const waiting = db
      .query<
        { job_id: string; uploader: string; downloader: string; created_at: number },
        []
      >("SELECT job_id, uploader, downloader, created_at FROM hub_blob WHERE state = 'aberta'")
      .all()
    const ids = new Set(waiting.map((row) => `codigo:${row.job_id}/${row.downloader}`))
    input.alerts
      .active()
      .filter((alert) => alert.kind === "transferencia" && !ids.has(alert.id))
      .forEach((alert) => input.alerts.clear(alert.id))
    waiting
      .filter((row) => now - row.created_at >= times.noMachineMs)
      .forEach((row) =>
        input.alerts.raise(
          `codigo:${row.job_id}/${row.downloader}`,
          "transferencia",
          `o código do pedido ${row.job_id} não chegou a ${machine.get(row.downloader)?.name ?? row.downloader} há ${Math.round((now - row.created_at) / 60_000)} min: a origem ${machine.get(row.uploader)?.name ?? row.uploader} não o enviou`,
        ),
      )
  }

  /** A part that no machine offers what it needs, for `noMachineMs`: an alert, until it leaves that wait. */
  const alertNoMachine = (now: number) =>
    (["sem_maquina", "aguardando_codigo"] as const).forEach((code) => {
      const waiting = inState
        .all("na_fila")
        .filter((row) => row.told !== null && (JSON.parse(row.told) as unknown[])[0] === code)
      const ids = new Set(waiting.map((row) => `${code}:${row.job_id}/${row.part}`))
      input.alerts
        .active()
        .filter((alert) => alert.kind === code && !ids.has(alert.id))
        .forEach((alert) => input.alerts.clear(alert.id))
      waiting
        .filter((row) => row.reason_at !== null && now - row.reason_at >= times.noMachineMs)
        .forEach((row) => {
          const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
          const minutes = Math.round((now - row.reason_at!) / 60_000)
          const origin = machine.get(job.get(row.job_id)?.origin_machine ?? "")?.name ?? "a origem"
          input.alerts.raise(
            `${code}:${row.job_id}/${row.part}`,
            code,
            code === "sem_maquina"
              ? `a parte ${spec.label} do pedido ${row.job_id} espera há ${minutes} min: nenhuma máquina oferece ${needs(spec).join(", ")}`
              : `a parte ${spec.label} do pedido ${row.job_id} espera há ${minutes} min o código, que só ${origin} tem`,
          )
        })
    })

  /** A silent machine: its offers go back to the queue (an unsafe one waits as `incerto`), what it runs turns `incerto`. */
  const uncertain = (silent: MachineRow) => {
    for (const row of onMachine.all(silent.machine_id)) {
      if (cancelled(row.job_id) && !BancadaProtocol.finalStates.has(row.state)) {
        cancelNow(row)
        close(row.job_id)
        continue
      }
      const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
      if (row.state === "oferecido" && !spec.unsafe) {
        withdraw(row)
        continue
      }
      if (row.state !== "oferecido" && !(live as ReadonlyArray<string>).includes(row.state)) continue
      update(row, { state: "incerto", held_state: row.state, since: input.now() })
      tell(row)
    }
  }

  /**
   * The attempt cannot get its code (`docs/bancada.md`, "Frozen code"): the origin is not `ok`, or the transfer
   * expired. Withdrawn like an offer (the machine lets its reservation go; no new attempt is spent), the part waits in
   * the queue until the origin is `ok`.
   */
  const needCode = (row: PartRow) => {
    if (row.machine_id)
      cancelAttempt(
        row.machine_id,
        { job: row.job_id, part: row.part, attempt: row.attempt_n },
        "aguardando o código da origem",
      )
    requeue(row, { needs_code: 1 })
    tell(row)
  }

  /** Withdraws an offer: the machine hears `attempt.cancel` when it calls, and the part goes back to the queue. */
  const withdraw = (row: PartRow) => {
    if (row.machine_id)
      cancelAttempt(row.machine_id, { job: row.job_id, part: row.part, attempt: row.attempt_n }, "oferta retirada")
    requeue(row)
    tell(row)
  }

  /**
   * Offers what can go now (`scheduler.ts`), with the estimates of `estimate.ts`; tells each waiting part's origin
   * why it waits and where it stands, when that changed (never for the estimate alone).
   */
  const schedule = () => {
    const now = input.now()
    const all = machines.all()
    waitingOn.clear()
    // A part of a request this hub forgot waits for the machines to list what they run (`adopt`); one that needs the
    // origin's bundle, for the origin to be `ok`.
    const originOf = (row: PartRow) => machine.get(job.get(row.job_id)?.origin_machine ?? "")
    const waitingCode = inState
      .all("na_fila")
      .filter((row) => row.adopt_until === null && row.needs_code === 1 && originOf(row)?.state !== "ok")
    waitingCode.forEach((row) => {
      const told = JSON.stringify(["aguardando_codigo", null, null])
      const text = `aguardando ${originOf(row)?.name ?? "a origem"} voltar para enviar o código`
      db.run("UPDATE hub_part SET waiting = ? WHERE job_id = ? AND part = ?", [
        JSON.stringify({ reason: { code: "aguardando_codigo", text } }),
        row.job_id,
        row.part,
      ])
      if (row.told === told) return
      const before: unknown[] | null = row.told ? JSON.parse(row.told) : null
      update(row, { told, ...(before?.[0] === "aguardando_codigo" ? {} : { reason_at: now }) })
      tell(row, {
        reason: {
          code: "aguardando_codigo",
          text: `aguardando ${originOf(row)?.name ?? "a origem"} voltar para enviar o código`,
        },
      })
    })
    const queued = inState
      .all("na_fila")
      .filter(
        (row) =>
          row.adopt_until === null && !waitingCode.some((item) => item.job_id === row.job_id && item.part === row.part),
      )
    if (queued.length === 0) return
    const offered = inState.all("oferecido")
    const busy = (machineID: string) =>
      onMachine.all(machineID).filter((row) => (live as ReadonlyArray<string>).includes(row.state))
    // A machine's room is its last pulse minus the offers it has not received yet (a pulse counts the rest).
    const views: MachineView[] = all.map((row) => {
      const free: BancadaProtocol.Vector | undefined = row.free ? JSON.parse(row.free) : undefined
      const pending = offered.filter(
        (offer) => offer.machine_id === row.machine_id && (offer.offer_seq ?? 0) > input.acknowledged(row.machine_id),
      )
      // A build slot per request's group among the offers it has not received yet.
      const groups = new Set(
        pending
          .filter((offer) => (JSON.parse(offer.spec) as BancadaProtocol.PartSpec).build)
          .map((offer) => offer.job_id),
      )
      return {
        machineID: row.machine_id,
        name: row.name,
        state: row.state,
        braked: row.brake === 1,
        pulse: row.pulse_seq ?? 0,
        capabilities: JSON.parse(row.capabilities),
        ...(free
          ? {
              free: pending.reduce(
                (vector, offer) => {
                  const spec: BancadaProtocol.PartSpec = JSON.parse(offer.spec)
                  return {
                    ...vector,
                    ...((platform) =>
                      platform === "none" ? {} : { [platform]: vector[platform] - (offer.devices_granted ?? 0) })(
                      seat(spec),
                    ),
                  }
                },
                { ...free, builds: free.builds - groups.size },
              ),
            }
          : {}),
      }
    })
    const items = queued.map((row) => {
      const owner = job.get(row.job_id)!
      const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
      return {
        row,
        owner,
        part: {
          job: row.job_id,
          part: row.part,
          spec,
          createdAt: owner.created_at,
          index: row.idx,
          reserved: row.reserved === 1,
          ...(row.refused_by ? { refused: { machineID: row.refused_by, pulse: row.refused_pulse ?? 0 } } : {}),
          siblingsOn: parts
            .all(row.job_id)
            .flatMap((sibling) =>
              sibling.part !== row.part &&
              sibling.machine_id &&
              (sibling.state === "oferecido" || sibling.state === "aceito")
                ? [sibling.machine_id]
                : [],
            ),
        } satisfies QueuedPart,
      }
    })
    const byPart = new Map(items.map((item) => [`${item.part.job}/${item.part.part}`, item]))
    /** The history of a part's test on a machine and on the others. */
    const historyOf = (item: QueuedPart, at: MachineView) => {
      const found = byPart.get(`${item.job}/${item.part}`)!
      const project = (JSON.parse(found.owner.code) as BancadaProtocol.Code).project
      const samples = durations.all(project, item.part)
      return {
        here: samples
          .filter((row) => row.machine_id === at.machineID)
          .flatMap((row) => JSON.parse(row.samples) as Sample[]),
        elsewhere: samples
          .filter((row) => row.machine_id !== at.machineID)
          .flatMap((row) => JSON.parse(row.samples) as Sample[]),
        slow: all.find((row) => row.machine_id === at.machineID)?.speed === "lento",
      }
    }
    const estimateOf = (item: QueuedPart, at: MachineView) => {
      const found = byPart.get(`${item.job}/${item.part}`)!
      const previous: BancadaProtocol.Outcome | undefined = found.row.previous
        ? JSON.parse(found.row.previous)
        : undefined
      const planned = found.row.only_scenarios
        ? (JSON.parse(found.row.only_scenarios) as string[]).length
        : previous?.planned.length
      return duration({
        ...historyOf(item, at),
        devices: Math.max(1, item.spec.devices.min),
        ...(planned ? { planned } : {}),
        // A sibling part of the same request is there already: its build serves this one.
        built: parts.all(item.job).some((row) => row.part !== item.part && row.machine_id === at.machineID),
      })
    }
    const decision = choose({
      parts: items.map((item) => item.part),
      machines: views,
      locks: new Set(
        db
          .query<{ name: string }, []>("SELECT name FROM hub_lock")
          .all()
          .map((row) => row.name),
      ),
      duration: estimateOf,
      wait: (item, at, line) => {
        // Only devices of the part's kind count for it; builds count for every part.
        const kind = (spec: BancadaProtocol.PartSpec, devices: number) =>
          seat(spec) !== "none" && seat(spec) === seat(item.spec) ? devices : 0
        return wait({
          now,
          free: {
            builds: line.free.builds,
            devices: ((platform) => (platform === "none" ? 0 : line.free[platform]))(seat(item.spec)),
          },
          ceiling: Number.POSITIVE_INFINITY,
          min: kind(item.spec, item.spec.devices.min),
          builds: line.builds,
          braked: at.braked,
          running: [
            ...busy(at.machineID).map((row) => ({
              endsAt: (row.started_at ?? row.since) + (row.est_ms ?? estimates.durationMs),
              devices: kind(JSON.parse(row.spec), row.devices_granted ?? 0),
              building: row.state !== "rodando",
            })),
            ...line.offered.map((offer) => ({
              endsAt: now + estimateOf(offer.part, at),
              devices: kind(offer.part.spec, offer.devices),
              building: offer.builds > 0,
            })),
          ],
          ahead: line.waiting.map((ahead) => ({
            devices: kind(ahead.spec, ahead.spec.devices.min),
            builds: ahead.spec.build ? 1 : 0,
            durationMs: estimateOf(ahead, at),
          })),
        })
      },
    })
    for (const offer of decision.offers) {
      const item = byPart.get(`${offer.job}/${offer.part}`)!
      const at = views.find((view) => view.machineID === offer.machineID)!
      const attempt = item.row.attempt_n + 1
      const only: string[] | undefined = item.row.only_scenarios ? JSON.parse(item.row.only_scenarios) : undefined
      const scenarioMs = perScenario(historyOf(item.part, at))
      const seq = input.send(offer.machineID, {
        type: "offer",
        job: offer.job,
        part: offer.part,
        attempt,
        spec: item.part.spec,
        origin: JSON.parse(item.owner.origin),
        code: JSON.parse(item.owner.code),
        devices: { min: item.part.spec.devices.min, proposed: offer.proposed },
        ...(only ? { only } : {}),
        ...(scenarioMs === undefined ? {} : { scenarioMs }),
      })
      item.part.spec.exclusive.forEach((name) =>
        db.run("INSERT OR REPLACE INTO hub_lock (name, job_id, part, since) VALUES (?, ?, ?, ?)", [
          name,
          offer.job,
          offer.part,
          now,
        ]),
      )
      record({ job: offer.job, part: offer.part, attempt }, { machine: offer.machineID, state: "oferecido" })
      // Until the reply, `devices_granted` holds what was proposed: the most the machine may reserve for it.
      update(item.row, {
        state: "oferecido",
        attempt_n: attempt,
        machine_id: offer.machineID,
        offer_seq: seq,
        devices_granted: offer.proposed,
        est_ms: estimateOf(item.part, at),
        offered_at: now,
        acked_at: null,
        missing: 0,
        reserved: 0,
        bypassed: 0,
        needs_code: 0,
        told: null,
        since: now,
      })
      tell(item.row)
    }
    for (const bypass of decision.bypassed) {
      const item = byPart.get(`${bypass.job}/${bypass.part}`)!
      const bypassed = item.row.bypassed + bypass.times
      update(item.row, { bypassed, reserved: bypassed >= reserveAfter ? 1 : item.row.reserved })
    }
    for (const waiting of decision.waiting) {
      const item = byPart.get(`${waiting.job}/${waiting.part}`)!
      const platform = seat(item.part.spec)
      if (waiting.machineID && platform !== "none") {
        const counts = waitingOn.get(waiting.machineID) ?? { android: 0, ios: 0 }
        waitingOn.set(waiting.machineID, { ...counts, [platform]: counts[platform] + 1 })
      }
      db.run("UPDATE hub_part SET waiting = ? WHERE job_id = ? AND part = ?", [
        JSON.stringify({
          reason: waiting.reason,
          ...(waiting.position === undefined ? {} : { position: waiting.position }),
          ...(waiting.etaMs === undefined ? {} : { etaMs: waiting.etaMs }),
        }),
        waiting.job,
        waiting.part,
      ])
      const told = JSON.stringify([waiting.reason.code, waiting.reason.detail ?? null, waiting.position ?? null])
      if (item.row.told === told) continue
      // Since when it waits for this reason (a new place in the queue is the same reason).
      const before: unknown[] | null = item.row.told ? JSON.parse(item.row.told) : null
      update(item.row, { told, ...(before?.[0] === waiting.reason.code ? {} : { reason_at: now }) })
      tell(item.row, {
        reason: waiting.reason,
        ...(waiting.position === undefined ? {} : { position: waiting.position }),
        ...(waiting.etaMs === undefined ? {} : { etaMs: waiting.etaMs }),
      })
    }
  }

  return {
    apply,
    seen,
    schedule,
    watch,
    taken,
    /** Parts of the queue that wait for room on a machine, by the kind of device they take (`schedule`). */
    waitingFor: (machineID: string) => waitingOn.get(machineID) ?? { android: 0, ios: 0 },
  }
}

export type Coordinator = ReturnType<typeof makeCoordinator>
