import type { Database } from "bun:sqlite"

/**
 * The machine's database (`bancada.db`) as an ordered list of steps; `meta.schema_version` counts the steps applied.
 * A step never changes once released: later changes are new steps. Three roles share the file (`docs/bancada.md`,
 * "State"): the origin (`job`), the executor (`attempt`, `lease`) and, where the queue of every machine runs, the
 * hub (`hub_*`); `peer` and `outbox` carry the messages between machine and hub.
 */
export const steps: ReadonlyArray<ReadonlyArray<string>> = [
  [
    // Per peer: this side's stream to it (the last sequence number written and the last it acknowledged) and the
    // peer's stream to this side (the last sequence number applied).
    `CREATE TABLE peer (
      peer TEXT PRIMARY KEY,
      out_stream TEXT NOT NULL,
      out_seq INTEGER NOT NULL,
      out_acked INTEGER NOT NULL,
      in_stream TEXT,
      in_seq INTEGER NOT NULL
    )`,
    // A message the handler could not apply (it threw): kept with the error, and the stream goes on past it.
    `CREATE TABLE dead_letter (
      peer TEXT NOT NULL,
      stream TEXT NOT NULL,
      seq INTEGER NOT NULL,
      body TEXT NOT NULL,
      error TEXT NOT NULL,
      at INTEGER NOT NULL,
      PRIMARY KEY (peer, stream, seq)
    )`,
    `CREATE TABLE outbox (
      peer TEXT NOT NULL,
      seq INTEGER NOT NULL,
      body TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (peer, seq)
    )`,
    `CREATE TABLE job (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      root_session_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      code TEXT NOT NULL,
      parts TEXT NOT NULL,
      scope TEXT NOT NULL,
      state TEXT NOT NULL,
      view TEXT NOT NULL,
      result TEXT,
      confirmed_at INTEGER,
      notice_ready_at INTEGER,
      delivered_at INTEGER,
      created_at INTEGER NOT NULL
    )`,
    `CREATE TABLE lease (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      owner TEXT NOT NULL,
      android INTEGER NOT NULL,
      ios INTEGER NOT NULL,
      mem_mb INTEGER NOT NULL,
      cpu_milli INTEGER NOT NULL,
      builds INTEGER NOT NULL,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      released_at INTEGER
    )`,
    `CREATE TABLE attempt (
      job_id TEXT NOT NULL,
      part TEXT NOT NULL,
      n INTEGER NOT NULL,
      origin TEXT NOT NULL,
      code TEXT NOT NULL,
      spec TEXT NOT NULL,
      devices INTEGER NOT NULL,
      only_scenarios TEXT,
      state TEXT NOT NULL,
      lease_id TEXT NOT NULL,
      accepted_at INTEGER NOT NULL,
      started_at INTEGER,
      ended_at INTEGER,
      outcome TEXT,
      PRIMARY KEY (job_id, part, n)
    )`,
    `CREATE TABLE hub_machine (
      machine_id TEXT PRIMARY KEY,
      instance_id TEXT NOT NULL,
      name TEXT NOT NULL,
      platform TEXT,
      capabilities TEXT NOT NULL DEFAULT '{}',
      speed TEXT NOT NULL DEFAULT 'normal',
      free TEXT,
      brake INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL,
      protocol INTEGER NOT NULL,
      pulse_stream TEXT,
      pulse_seq INTEGER,
      last_sync_at INTEGER NOT NULL
    )`,
    `CREATE TABLE hub_job (
      id TEXT PRIMARY KEY,
      origin_machine TEXT NOT NULL,
      origin TEXT NOT NULL,
      code TEXT NOT NULL,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      closed_at INTEGER
    )`,
    `CREATE TABLE hub_part (
      job_id TEXT NOT NULL,
      part TEXT NOT NULL,
      idx INTEGER NOT NULL,
      spec TEXT NOT NULL,
      state TEXT NOT NULL,
      attempt_n INTEGER NOT NULL,
      machine_id TEXT,
      offer_seq INTEGER,
      devices_granted INTEGER,
      refused_by TEXT,
      refused_pulse INTEGER,
      since INTEGER NOT NULL,
      outcome TEXT,
      PRIMARY KEY (job_id, part)
    )`,
  ],
]

/** A database written by a newer release: opening it could corrupt it, so this release stays unavailable. */
export class NewerSchemaError extends Error {
  constructor(
    readonly found: number,
    readonly known: number,
  ) {
    super(
      `bancada.db is at schema version ${found}, newer than this release knows (${known}); the Bancada stays unavailable until a release that knows it runs`,
    )
  }
}

/** Applies the missing steps, each in its own transaction with the version it reaches. */
export function migrate(db: Database, list: ReadonlyArray<ReadonlyArray<string>> = steps) {
  db.run("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
  const row = db.query<{ value: string }, []>("SELECT value FROM meta WHERE key = 'schema_version'").get()
  const current = Number(row?.value ?? 0)
  if (current > list.length) throw new NewerSchemaError(current, list.length)
  list.slice(current).forEach((statements, index) =>
    db.transaction(() => {
      statements.forEach((statement) => db.run(statement))
      db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)", [String(current + index + 1)])
    })(),
  )
}
