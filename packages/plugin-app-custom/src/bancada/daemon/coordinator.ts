import type { Database } from "bun:sqlite"
import { BancadaProtocol } from "../protocol.js"

type PartRow = {
  readonly job_id: string
  readonly devices_granted: number | null
  readonly part: string
  readonly idx: number
  readonly spec: string
  readonly state: BancadaProtocol.PartState
  readonly attempt_n: number
  readonly machine_id: string | null
  readonly offer_seq: number | null
  readonly refused_by: string | null
  readonly refused_pulse: number | null
  readonly held_state: BancadaProtocol.PartState | null
  readonly outcome: string | null
}
type MachineRow = {
  readonly machine_id: string
  readonly name: string
  readonly capabilities: string
  readonly free: string | null
  readonly state: string
  readonly pulse_seq: number | null
}
type JobRow = {
  readonly id: string
  readonly origin_machine: string
  readonly origin: string
  readonly code: string
  readonly state: string
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

/**
 * The queue of every machine (`docs/bancada.md`, "Queue"), where the hub runs. It offers parts to machines that can
 * take them, follows what each machine's executor reports and tells the origin; executors decide, it mirrors. Every
 * handler runs inside the transaction that applies the message it answers, and what it sends shares it.
 */
export function makeCoordinator(input: {
  readonly db: Database
  readonly now: () => number
  /** A machine that has not called for this long is silent: what it runs becomes `incerto`. */
  readonly silentMs: number
  /** When this hub's process started: a machine's silence counts only from then (it could not call a hub that was out). */
  readonly startedAt: number
  readonly send: (machineID: string, body: BancadaProtocol.FromHub) => number
  /** The last sequence number `machineID` acknowledged of the hub's stream to it. */
  readonly acknowledged: (machineID: string) => number
}) {
  const db = input.db
  const job = db.query<JobRow, [string]>("SELECT * FROM hub_job WHERE id = ?")
  const part = db.query<PartRow, [string, string]>("SELECT * FROM hub_part WHERE job_id = ? AND part = ?")
  const parts = db.query<PartRow, [string]>("SELECT * FROM hub_part WHERE job_id = ? ORDER BY idx")
  const queued = db.query<PartRow, []>(
    "SELECT p.* FROM hub_part p JOIN hub_job j ON j.id = p.job_id WHERE p.state = 'na_fila' ORDER BY j.created_at, j.id, p.idx",
  )
  const offered = db.query<PartRow, []>("SELECT * FROM hub_part WHERE state = 'oferecido'")
  const machines = db.query<MachineRow, []>("SELECT * FROM hub_machine WHERE state = 'ok' ORDER BY machine_id")
  const machine = db.query<MachineRow, [string]>("SELECT * FROM hub_machine WHERE machine_id = ?")
  const uncertain = db.query<PartRow, [string]>("SELECT * FROM hub_part WHERE state = 'incerto' AND machine_id = ?")
  const silent = db.query<{ machine_id: string }, [number]>(
    "SELECT machine_id FROM hub_machine WHERE state IN ('ok', 'reconciling') AND last_sync_at < ?",
  )
  const runningOn = db.query<PartRow, [string]>(
    "SELECT * FROM hub_part WHERE machine_id = ? AND state IN ('aceito', 'compilando', 'rodando')",
  )

  const update = (row: PartRow, fields: Partial<Record<keyof PartRow | "since", unknown>>) => {
    const names = Object.keys(fields)
    db.run(`UPDATE hub_part SET ${names.map((name) => `${name} = ?`).join(", ")} WHERE job_id = ? AND part = ?`, [
      ...names.map((name) => fields[name as keyof typeof fields] as string | number | null),
      row.job_id,
      row.part,
    ])
  }
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

  const handlers = {
    hello: (from: string, message: typeof BancadaProtocol.Hello.Type) =>
      db.run("UPDATE hub_machine SET platform = ?, capabilities = ?, speed = ? WHERE machine_id = ?", [
        message.platform,
        JSON.stringify(message.capabilities),
        message.speed,
        from,
      ]),
    submit: (from: string, message: typeof BancadaProtocol.Submit.Type) => {
      if (job.get(message.job)) return
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
        parts: message.parts.map((spec) => ({ part: spec.part, reason: { code: "fila", text: "na fila" } })),
        superseded: [],
      })
    },
    "offer.reply": (
      from: string,
      message: typeof BancadaProtocol.OfferAccepted.Type | typeof BancadaProtocol.OfferRefused.Type,
    ) => {
      const row = part.get(message.job, message.part)
      if (!row || row.state !== "oferecido" || row.attempt_n !== message.attempt || row.machine_id !== from) return
      if (message.accepted) {
        update(row, { state: "aceito", devices_granted: message.devices, since: input.now() })
        return tell(row)
      }
      update(row, {
        state: "na_fila",
        machine_id: null,
        offer_seq: null,
        refused_by: from,
        refused_pulse: machine.get(from)?.pulse_seq ?? 0,
      })
      tell(row, { reason: message.reason })
    },
    attempt: (from: string, message: typeof BancadaProtocol.AttemptReport.Type) => {
      const row = part.get(message.job, message.part)
      if (!row || row.attempt_n !== message.attempt || row.machine_id !== from) return
      if (rank[message.state] <= rank[row.state]) return
      update(row, {
        state: message.state,
        since: input.now(),
        ...(message.outcome ? { outcome: JSON.stringify(message.outcome) } : {}),
      })
      tell(row)
      close(row.job_id)
    },
    delivered: (from: string, message: typeof BancadaProtocol.Delivered.Type) => {
      const owner = job.get(message.job)
      if (!owner || owner.origin_machine !== from || owner.state !== "fechado") return
      db.run("UPDATE hub_job SET state = 'entregue' WHERE id = ?", [message.job])
      new Set(parts.all(message.job).flatMap((row) => (row.machine_id ? [row.machine_id] : []))).forEach((machineID) =>
        input.send(machineID, { type: "cleanup", job: message.job }),
      )
    },
  }

  /** Applies one message from `from`. Messages of later packages (holds, code, blobs) are not handled yet. */
  const apply = (from: string, message: BancadaProtocol.FromMachine) => {
    if (message.type === "hello") return handlers.hello(from, message)
    if (message.type === "submit") return handlers.submit(from, message)
    if (message.type === "offer.reply") return handlers["offer.reply"](from, message)
    if (message.type === "attempt") return handlers.attempt(from, message)
    if (message.type === "delivered") return handlers.delivered(from, message)
  }

  /**
   * Records who called and its pulse; a pulse older than the last one applied changes nothing. A machine that was
   * silent is back: each of its `incerto` parts it still runs (its pulse lists it) returns to where it was; one it no
   * longer lists waits for its final report.
   */
  const seen = (sync: BancadaProtocol.SyncInput) => {
    const known = machine.get(sync.machineID)
    if (!known)
      db.run(
        "INSERT INTO hub_machine (machine_id, instance_id, name, state, protocol, last_sync_at) VALUES (?, ?, ?, 'ok', ?, ?)",
        [sync.machineID, sync.instanceID, sync.name, sync.protocol, input.now()],
      )
    db.run(
      "UPDATE hub_machine SET instance_id = ?, name = ?, state = ?, protocol = ?, last_sync_at = ? WHERE machine_id = ?",
      [sync.instanceID, sync.name, sync.pulse.state, sync.protocol, input.now(), sync.machineID],
    )
    const running = new Set(sync.pulse.running.map((item) => `${item.job}/${item.part}/${item.attempt}`))
    for (const row of uncertain.all(sync.machineID))
      if (row.held_state && running.has(`${row.job_id}/${row.part}/${row.attempt_n}`)) {
        update(row, { state: row.held_state, held_state: null })
        tell(row)
      }
    const stream = sync.out.stream
    const current = db
      .query<
        { pulse_stream: string | null; pulse_seq: number | null },
        [string]
      >("SELECT pulse_stream, pulse_seq FROM hub_machine WHERE machine_id = ?")
      .get(sync.machineID)
    if (current?.pulse_stream === stream && (current.pulse_seq ?? -1) >= sync.pulse.seq) return
    db.run("UPDATE hub_machine SET free = ?, brake = ?, pulse_stream = ?, pulse_seq = ? WHERE machine_id = ?", [
      JSON.stringify(sync.pulse.free),
      sync.pulse.brake ? 1 : 0,
      stream,
      sync.pulse.seq,
      sync.machineID,
    ])
  }

  /**
   * Offers each waiting part, oldest first, to the first machine that offers what it needs and has room for its
   * minimum. A machine's room is its last pulse minus the offers it has not received yet (a pulse already counts every
   * offer the machine applied). The order and the choice of machine are minimal here; the full scheduler replaces them.
   */
  const schedule = () => {
    const all = machines.all()
    const room = new Map(
      all.map((row) => [row.machine_id, row.free ? (JSON.parse(row.free) as BancadaProtocol.Vector) : undefined]),
    )
    const take = (machineID: string, platform: BancadaProtocol.Platform, devices: number) => {
      const free = room.get(machineID)
      if (free && platform !== "none") room.set(machineID, { ...free, [platform]: free[platform] - devices })
    }
    for (const row of offered.all())
      if (row.machine_id && (row.offer_seq ?? 0) > input.acknowledged(row.machine_id))
        take(row.machine_id, (JSON.parse(row.spec) as BancadaProtocol.PartSpec).platform, row.devices_granted ?? 0)
    for (const row of queued.all()) {
      const spec: BancadaProtocol.PartSpec = JSON.parse(row.spec)
      const target = all.find((candidate) => {
        const free = room.get(candidate.machine_id)
        if (!free) return false
        if (row.refused_by === candidate.machine_id && (candidate.pulse_seq ?? 0) <= (row.refused_pulse ?? 0))
          return false
        const capabilities: Record<string, unknown> = JSON.parse(candidate.capabilities)
        if (!spec.needs.every((need) => need in capabilities)) return false
        return spec.platform === "none" || free[spec.platform] >= spec.devices.min
      })
      if (!target) continue
      const free = room.get(target.machine_id)!
      const proposed = spec.platform === "none" ? 0 : Math.min(spec.devices.max, free[spec.platform])
      const owner = job.get(row.job_id)!
      const attempt = row.attempt_n + 1
      const seq = input.send(target.machine_id, {
        type: "offer",
        job: row.job_id,
        part: row.part,
        attempt,
        spec,
        origin: JSON.parse(owner.origin),
        code: JSON.parse(owner.code),
        devices: { min: spec.devices.min, proposed },
      })
      // Until the reply, `devices_granted` holds what was proposed: the most the machine may reserve for it.
      update(row, {
        state: "oferecido",
        attempt_n: attempt,
        machine_id: target.machine_id,
        offer_seq: seq,
        devices_granted: proposed,
        since: input.now(),
      })
      take(target.machine_id, spec.platform, proposed)
      tell(row)
    }
  }

  /**
   * A machine silent for `silentMs` (asleep, or gone): what it runs becomes `incerto`, never approved nor lost by itself
   * here; it returns to its real state when the machine calls again. The silence counts only while the hub listens:
   * from the later of the machine's last call and this hub's start (after a deploy every last call is old).
   */
  const watch = () => {
    const since = input.now() - input.silentMs
    if (input.startedAt > since) return
    for (const quiet of silent.all(since)) {
      db.run("UPDATE hub_machine SET state = 'silenciosa' WHERE machine_id = ?", [quiet.machine_id])
      for (const row of runningOn.all(quiet.machine_id)) {
        update(row, { state: "incerto", held_state: row.state, since: input.now() })
        tell(row)
      }
    }
  }

  return { apply, seen, schedule, watch }
}

export type Coordinator = ReturnType<typeof makeCoordinator>
