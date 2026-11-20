import type { Database } from "bun:sqlite"
import { BancadaProtocol } from "../protocol.js"
import { join } from "../results.js"
import { duration, defaults as estimates, wait, type Sample } from "./estimate.js"
import { reserveAfter, schedule as choose, type MachineView, type QueuedPart } from "./scheduler.js"

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
  readonly est_ms: number | null
  readonly offered_at: number | null
  readonly acked_at: number | null
  readonly started_at: number | null
  readonly built_at: number | null
}
type MachineRow = {
  readonly machine_id: string
  readonly name: string
  readonly capabilities: string
  readonly speed: string
  readonly free: string | null
  readonly brake: number
  readonly state: string
  readonly pulse_stream: string | null
  readonly pulse_seq: number | null
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
  const history = db.query<{ cancelled: number; state: string }, [string, string, number]>(
    "SELECT cancelled, state FROM hub_attempt WHERE job_id = ? AND part = ? AND n = ?",
  )
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
      "INSERT INTO hub_attempt (job_id, part, n, machine_id, state, outcome, at) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (job_id, part, n) DO UPDATE SET state = excluded.state, outcome = COALESCE(excluded.outcome, outcome), at = excluded.at",
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
    if (history.get(key.job, key.part, key.attempt)?.cancelled) return
    db.run("UPDATE hub_attempt SET cancelled = 1 WHERE job_id = ? AND part = ? AND n = ?", [
      key.job,
      key.part,
      key.attempt,
    ])
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
      ...(at ? { machine: { machineID: at.machine_id, name: at.name } } : {}),
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
    input.send(owner.origin_machine, {
      type: "result",
      job: jobID,
      parts: all.map((row) => {
        const at = row.machine_id ? machine.get(row.machine_id) : undefined
        return {
          part: row.part,
          state: row.state,
          attempts: row.attempt_n,
          ...(at ? { machine: { machineID: at.machine_id, name: at.name } } : {}),
          ...(row.outcome ? { outcome: JSON.parse(row.outcome) } : {}),
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

  const handlers = {
    hello: (from: string, message: typeof BancadaProtocol.Hello.Type) =>
      db.run("UPDATE hub_machine SET platform = ?, capabilities = ?, speed = ? WHERE machine_id = ?", [
        message.platform,
        JSON.stringify(message.capabilities),
        message.speed,
        from,
      ]),
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
      const superseded = supersede(from, message)
      db.run(
        "INSERT INTO hub_job (id, origin_machine, origin, code, state, created_at) VALUES (?, ?, ?, ?, 'aberto', ?)",
        [message.job, from, JSON.stringify(message.origin), JSON.stringify(message.code), input.now()],
      )
      message.parts.forEach((spec, idx) =>
        db.run(
          "INSERT INTO hub_part (job_id, part, idx, spec, state, attempt_n, since) VALUES (?, ?, ?, ?, 'na_fila', 0, ?)",
          [message.job, spec.part, idx, JSON.stringify(spec), input.now()],
        ),
      )
      input.send(from, {
        type: "submit.ack",
        job: message.job,
        parts: message.parts.map((spec) => ({
          part: spec.part,
          state: "na_fila",
          attempt: 0,
          reason: { code: "fila", text: "na fila" },
        })),
        superseded,
      })
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
      record(message, { machine: from, state: message.accepted ? "aceito" : "recusado" })
      // An unsafe part whose machine went silent with the offer unanswered waits as `incerto` for this reply.
      const pending = row?.state === "oferecido" || (row?.state === "incerto" && row.held_state === "oferecido")
      if (!row || !pending || row.attempt_n !== message.attempt || row.machine_id !== from) return
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
        })
        return tell(row)
      }
      const outcome = message.outcome ?? lostOutcome("a execução terminou sem resultado")
      if (message.state === "concluido") sample(row, outcome)
      ended(row, outcome, true)
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

  /** A concluded attempt's times feed the estimates of that project's test on that machine (the last 10). */
  const sample = (row: PartRow, outcome: BancadaProtocol.Outcome) => {
    const owner = job.get(row.job_id)
    if (!owner || !row.machine_id || row.started_at === null) return
    const project = (JSON.parse(owner.code) as BancadaProtocol.Code).project
    const built = row.built_at ?? row.started_at
    const next: Sample = {
      buildMs: Math.max(0, built - row.started_at),
      runMs: Math.max(0, input.now() - built),
      devices: row.devices_granted ?? 0,
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
  }

  /**
   * Records who called and, only from a pulse newer than the last applied, everything the pulse says: the machine's
   * state, when it last called, its free vector, its brake and what it runs (`docs/bancada.md`, "State machine"). A
   * repeated or late call never makes a machine "come back". An uncertain part it still runs returns to where it was;
   * one it accepted and has not listed in two pulses in a row, without a final report, is lost.
   */
  const seen = (sync: BancadaProtocol.SyncInput) => {
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
    db.run(
      "UPDATE hub_machine SET state = ?, state_since = CASE WHEN state = ? THEN state_since ELSE ? END, last_sync_at = ?, free = ?, brake = ?, pulse_stream = ?, pulse_seq = ? WHERE machine_id = ?",
      [
        sync.pulse.state,
        sync.pulse.state,
        input.now(),
        input.now(),
        JSON.stringify(sync.pulse.free),
        sync.pulse.brake ? 1 : 0,
        stream,
        sync.pulse.seq,
        sync.machineID,
      ],
    )
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
    for (const row of inState.all("oferecido")) {
      if (!row.machine_id) continue
      const received = (row.offer_seq ?? 0) <= input.acknowledged(row.machine_id)
      if (received && row.acked_at === null) update(row, { acked_at: now })
      if (!received || row.acked_at === null || now - row.acked_at < times.replyMs) continue
      withdraw(row)
    }
    db.run("DELETE FROM hub_job WHERE state = 'entregue' AND closed_at < ?", [now - times.tombstoneMs])
  }

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
    const queued = inState.all("na_fila")
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
                    ...(spec.platform === "none"
                      ? {}
                      : { [spec.platform]: vector[spec.platform] - (offer.devices_granted ?? 0) }),
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
    const estimateOf = (item: QueuedPart, at: MachineView) => {
      const found = byPart.get(`${item.job}/${item.part}`)!
      const project = (JSON.parse(found.owner.code) as BancadaProtocol.Code).project
      const samples = durations.all(project, item.part)
      const previous: BancadaProtocol.Outcome | undefined = found.row.previous
        ? JSON.parse(found.row.previous)
        : undefined
      const planned = found.row.only_scenarios
        ? (JSON.parse(found.row.only_scenarios) as string[]).length
        : previous?.planned.length
      return duration({
        here: samples
          .filter((row) => row.machine_id === at.machineID)
          .flatMap((row) => JSON.parse(row.samples) as Sample[]),
        elsewhere: samples
          .filter((row) => row.machine_id !== at.machineID)
          .flatMap((row) => JSON.parse(row.samples) as Sample[]),
        slow: all.find((row) => row.machine_id === at.machineID)?.speed === "lento",
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
          spec.platform !== "none" && spec.platform === item.spec.platform ? devices : 0
        return wait({
          now,
          free: {
            builds: line.free.builds,
            devices: item.spec.platform === "none" ? 0 : line.free[item.spec.platform],
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
      const told = JSON.stringify([waiting.reason.code, waiting.reason.detail ?? null, waiting.position ?? null])
      if (item.row.told === told) continue
      update(item.row, { told })
      tell(item.row, {
        reason: waiting.reason,
        ...(waiting.position === undefined ? {} : { position: waiting.position }),
        ...(waiting.etaMs === undefined ? {} : { etaMs: waiting.etaMs }),
      })
    }
  }

  return { apply, seen, schedule, watch }
}

export type Coordinator = ReturnType<typeof makeCoordinator>
