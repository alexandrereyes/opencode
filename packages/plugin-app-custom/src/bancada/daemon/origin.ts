import type { Database } from "bun:sqlite"
import type { BancadaProtocol } from "../protocol.js"
import type { Alerts } from "./alerts.js"

/** A request of one of this server's sessions, already resolved against the project's `.bancada.toml`. */
export type NewJob = {
  readonly id: string
  readonly sessionID: string
  readonly rootSessionID: string
  readonly sessionTitle?: string
  readonly rootTitle?: string
  readonly code: BancadaProtocol.Code
  readonly parts: ReadonlyArray<BancadaProtocol.PartSpec>
  /** The session's repository root, where the commit is frozen (an executor on this machine fetches from it). */
  readonly repository?: string
}

/** Where each part stands, as the hub last said. */
export type PartView = {
  readonly state: BancadaProtocol.PartState
  readonly attempt: number
  readonly machine?: { readonly machineID: string; readonly name: string }
  readonly position?: number
  readonly etaMs?: number
  readonly reason?: BancadaProtocol.Reason
}

type JobRow = {
  readonly id: string
  readonly session_id: string
  readonly code: string
  readonly parts: string
  readonly acked_at: number | null
  readonly state: string
  readonly view: string
  readonly result: string | null
  readonly created_at: number
}

/** A job whose result arrived and whose notice the session has not received yet. */
export type Notice = {
  readonly job: string
  readonly sessionID: string
  readonly parts: ReadonlyArray<BancadaProtocol.PartResult>
}

/**
 * The requests of this server's sessions (`docs/bancada.md`, "Origin"): sent to the hub, mirrored as the hub tells,
 * closed when the result arrives and delivered once. A request whose id exists is the same request: the first wins.
 */
export function makeOrigin(input: {
  readonly db: Database
  readonly now: () => number
  readonly identity: { readonly instanceID: string; readonly machineID: string; readonly name: string }
  /** Writes a message to the hub; returns its sequence number. */
  readonly send: (body: BancadaProtocol.FromMachine) => number
  /** How long a request the hub acknowledged receiving may wait for its `submit.ack` before it closes here. */
  readonly unregisteredMs: number
  readonly log: (line: string) => void
  readonly alerts: Alerts
}) {
  const db = input.db
  const find = db.query<JobRow, [string]>("SELECT * FROM job WHERE id = ?")
  const ready = db.query<JobRow, []>(
    "SELECT * FROM job WHERE state = 'concluido' AND delivered_at IS NULL ORDER BY notice_ready_at",
  )
  const waiting = db.query<JobRow, [number]>(
    "SELECT * FROM job WHERE state = 'aguardando_confirmacao' AND submit_seq IS NOT NULL AND submit_seq <= ?",
  )

  const submit = (request: NewJob) =>
    db.transaction(() => {
      const existing = find.get(request.id)
      if (existing) return existing
      const origin: BancadaProtocol.Origin = {
        ...input.identity,
        sessionID: request.sessionID,
        rootSessionID: request.rootSessionID,
        ...(request.sessionTitle ? { sessionTitle: request.sessionTitle } : {}),
        ...(request.rootTitle ? { rootTitle: request.rootTitle } : {}),
      }
      const view: Record<string, PartView> = Object.fromEntries(
        request.parts.map((spec) => [
          spec.part,
          {
            state: "na_fila",
            attempt: 0,
            reason: { code: "aguardando_confirmacao", text: "aguardando confirmação do hub" },
          },
        ]),
      )
      db.run(
        "INSERT INTO job (id, session_id, repo_dir, root_session_id, origin, code, parts, scope, state, view, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'hub', 'aguardando_confirmacao', ?, ?)",
        [
          request.id,
          request.sessionID,
          request.repository ?? null,
          request.rootSessionID,
          JSON.stringify(origin),
          JSON.stringify(request.code),
          JSON.stringify(request.parts),
          JSON.stringify(view),
          input.now(),
        ],
      )
      const seq = input.send({
        type: "submit",
        job: request.id,
        origin,
        code: request.code,
        parts: [...request.parts],
        createdAt: input.now(),
      })
      db.run("UPDATE job SET submit_seq = ? WHERE id = ?", [seq, request.id])
      return find.get(request.id)!
    })()

  const view = (row: JobRow, part: string, next: (current: PartView | undefined) => PartView) => {
    const all: Record<string, PartView> = JSON.parse(row.view)
    db.run("UPDATE job SET view = ? WHERE id = ?", [JSON.stringify({ ...all, [part]: next(all[part]) }), row.id])
  }

  /** Called inside the transaction that applies the hub's message. */
  const apply = (message: BancadaProtocol.FromHub) => {
    if (message.type === "submit.ack") {
      // Requests this one replaced entirely close without a notice: the session asked again.
      message.superseded.forEach((replaced) =>
        db.run("UPDATE job SET state = 'entregue', delivered_at = ? WHERE id = ? AND state <> 'entregue'", [
          input.now(),
          replaced,
        ]),
      )
      const row = find.get(message.job)
      if (!row) return
      if (row.state === "aguardando_confirmacao")
        db.run("UPDATE job SET state = 'na_fila', confirmed_at = ? WHERE id = ?", [input.now(), row.id])
      return message.parts.forEach((item) =>
        view(find.get(message.job)!, item.part, (current) => ({
          state: current?.state ?? "na_fila",
          attempt: current?.attempt ?? 0,
          ...(item.position === undefined ? {} : { position: item.position }),
          ...(item.etaMs === undefined ? {} : { etaMs: item.etaMs }),
          ...(item.reason ? { reason: item.reason } : {}),
        })),
      )
    }
    if (message.type === "job.update") {
      const row = find.get(message.job)
      if (!row || row.state === "concluido" || row.state === "entregue") return
      view(row, message.part, (current) =>
        current && current.attempt > message.attempt
          ? current
          : {
              state: message.state,
              attempt: message.attempt,
              ...(message.machine ? { machine: message.machine } : {}),
              ...(message.position === undefined ? {} : { position: message.position }),
              ...(message.etaMs === undefined ? {} : { etaMs: message.etaMs }),
              ...(message.reason ? { reason: message.reason } : {}),
            },
      )
      return
    }
    if (message.type === "result") {
      const row = find.get(message.job)
      if (!row || row.state === "concluido" || row.state === "entregue") return
      db.run("UPDATE job SET state = 'concluido', result = ?, notice_ready_at = ? WHERE id = ?", [
        JSON.stringify(message.parts),
        input.now(),
        row.id,
      ])
    }
  }

  /**
   * Nothing waits forever here: a request whose `submit` the hub acknowledged (its handler may have failed, and the
   * message went to its `dead_letter`) and that still has no `submit.ack` `unregisteredMs` later closes as `invalido`,
   * with an alert (`docs/bancada.md`, "Request"). Called in a round, with what the hub acknowledged of this stream.
   */
  const unregistered = (acknowledged: number) => {
    for (const row of waiting.all(acknowledged)) {
      if (row.acked_at === null) {
        db.run("UPDATE job SET acked_at = ? WHERE id = ?", [input.now(), row.id])
        continue
      }
      if (input.now() - row.acked_at < input.unregisteredMs) continue
      const specs: BancadaProtocol.PartSpec[] = JSON.parse(row.parts)
      const outcome: BancadaProtocol.Outcome = {
        verdict: "invalido",
        reason: "o hub não conseguiu registrar o pedido",
        planned: [],
        scenarios: [],
        lost: [],
        approved: false,
      }
      db.run("UPDATE job SET state = 'concluido', result = ?, view = ?, notice_ready_at = ? WHERE id = ?", [
        JSON.stringify(specs.map((spec) => ({ part: spec.part, state: "invalido", attempts: 0, outcome }))),
        JSON.stringify(Object.fromEntries(specs.map((spec) => [spec.part, { state: "invalido", attempt: 0 }]))),
        input.now(),
        row.id,
      ])
      input.alerts.raise(
        `nao_registrado:${row.id}`,
        "pedido",
        `o hub confirmou o recebimento do pedido ${row.id} mas não conseguiu registrá-lo; o pedido fechou como inválido`,
      )
    }
  }

  /**
   * The hub forgot (another database): every request of this origin still open is sent again, as it was (the hub is
   * idempotent by id); one already answered is not, its result is here (`docs/bancada.md`, "When a side forgot").
   */
  const resubmit = () =>
    db
      .query<JobRow & { origin: string; created_at: number }, []>(
        "SELECT * FROM job WHERE state IN ('aguardando_confirmacao', 'na_fila')",
      )
      .all()
      .forEach((row) => {
        const seq = input.send({
          type: "submit",
          job: row.id,
          origin: JSON.parse(row.origin),
          code: JSON.parse(row.code),
          parts: JSON.parse(row.parts),
          createdAt: row.created_at,
          again: true,
        })
        db.run("UPDATE job SET submit_seq = ?, acked_at = NULL WHERE id = ?", [seq, row.id])
      })

  /** A delivered request keeps only its id and state for `tombstoneMs` (a resend of its id never runs it again). */
  const forget = (tombstoneMs: number) =>
    db.run("DELETE FROM job WHERE state = 'entregue' AND delivered_at < ?", [input.now() - tombstoneMs])

  /** The session cancels its request: the hub stops what runs and closes the parts `cancelado` (its result says so). */
  const cancel = (jobID: string) =>
    db.transaction(() => {
      const row = find.get(jobID)
      if (!row || row.state === "concluido" || row.state === "entregue") return false
      input.send({ type: "cancel", job: jobID })
      return true
    })()

  return {
    submit,
    apply,
    cancel,
    unregistered,
    resubmit,
    forget,
    repository: (job: string) =>
      db.query<{ repo_dir: string | null }, [string]>("SELECT repo_dir FROM job WHERE id = ?").get(job)?.repo_dir ??
      undefined,
    /** Results waiting to reach their sessions. */
    notices: (): Notice[] =>
      ready.all().map((row) => ({ job: row.id, sessionID: row.session_id, parts: JSON.parse(row.result ?? "[]") })),
    /** The session received the notice: once, and the hub may clean up. */
    delivered: (job: string) =>
      db.transaction(() => {
        const row = find.get(job)
        if (!row || row.state !== "concluido") return
        db.run("UPDATE job SET state = 'entregue', delivered_at = ?, view = '{}', result = NULL WHERE id = ?", [
          input.now(),
          job,
        ])
        input.send({ type: "delivered", job })
      })(),
    /** The request as this server knows it. */
    status: (job: string) => {
      const row = find.get(job)
      if (!row) return undefined
      return {
        job: row.id,
        state: row.state,
        commit: (JSON.parse(row.code) as BancadaProtocol.Code).commit,
        parts: JSON.parse(row.view) as Record<string, PartView>,
        ...(row.result ? { result: JSON.parse(row.result) as BancadaProtocol.PartResult[] } : {}),
      }
    },
  }
}

export type Origin = ReturnType<typeof makeOrigin>
