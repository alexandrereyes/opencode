import type { Database } from "bun:sqlite"
import type { BancadaProtocol } from "../protocol.js"

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
  readonly send: (body: BancadaProtocol.FromMachine) => void
}) {
  const db = input.db
  const find = db.query<JobRow, [string]>("SELECT * FROM job WHERE id = ?")
  const ready = db.query<JobRow, []>(
    "SELECT * FROM job WHERE state = 'concluido' AND delivered_at IS NULL ORDER BY notice_ready_at",
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
      input.send({
        type: "submit",
        job: request.id,
        origin,
        code: request.code,
        parts: [...request.parts],
        createdAt: input.now(),
      })
      return find.get(request.id)!
    })()

  const view = (row: JobRow, part: string, next: (current: PartView | undefined) => PartView) => {
    const all: Record<string, PartView> = JSON.parse(row.view)
    db.run("UPDATE job SET view = ? WHERE id = ?", [JSON.stringify({ ...all, [part]: next(all[part]) }), row.id])
  }

  /** Called inside the transaction that applies the hub's message. */
  const apply = (message: BancadaProtocol.FromHub) => {
    if (message.type === "submit.ack") {
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

  return {
    submit,
    apply,
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
        db.run("UPDATE job SET state = 'entregue', delivered_at = ? WHERE id = ?", [input.now(), job])
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
