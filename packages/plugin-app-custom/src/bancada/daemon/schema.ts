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
    // Exceptions the owner must see; the hub's about the queue, any machine's about its link.
    `CREATE TABLE alert (
      id TEXT PRIMARY KEY,
      at INTEGER NOT NULL,
      kind TEXT NOT NULL,
      text TEXT NOT NULL,
      cleared_at INTEGER
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
      repo_dir TEXT,
      root_session_id TEXT NOT NULL,
      origin TEXT NOT NULL,
      code TEXT NOT NULL,
      parts TEXT NOT NULL,
      scope TEXT NOT NULL,
      state TEXT NOT NULL,
      view TEXT NOT NULL,
      result TEXT,
      submit_seq INTEGER,
      acked_at INTEGER,
      confirmed_at INTEGER,
      snapshot TEXT,
      base TEXT,
      replaced TEXT,
      received_at INTEGER,
      notice_id TEXT,
      notice_text TEXT,
      notice_ready_at INTEGER,
      wait_inline INTEGER NOT NULL DEFAULT 0,
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
      build_mem_mb INTEGER NOT NULL DEFAULT 0,
      build_cpu_milli INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      released_at INTEGER
    )`,
    `CREATE TABLE lease_device (
      lease_id TEXT NOT NULL,
      device_id TEXT,
      port_start INTEGER NOT NULL,
      port_end INTEGER NOT NULL
    )`,
    `CREATE TABLE cost_sample (
      subject TEXT NOT NULL,
      mem_mb INTEGER NOT NULL,
      cpu_milli INTEGER NOT NULL,
      at INTEGER NOT NULL
    )`,
    "CREATE INDEX cost_sample_subject ON cost_sample (subject, at)",
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
      phone_hold TEXT,
      group_id TEXT,
      cancel_at INTEGER,
      cancel_reason TEXT,
      evidence TEXT,
      delivered INTEGER NOT NULL DEFAULT 0,
      accepted_at INTEGER NOT NULL,
      started_at INTEGER,
      ended_at INTEGER,
      outcome TEXT,
      PRIMARY KEY (job_id, part, n)
    )`,
    // The executor's working folders: one git repository each, for one attempt group at a time.
    `CREATE TABLE workdir (
      id TEXT PRIMARY KEY,
      project TEXT NOT NULL,
      path TEXT NOT NULL UNIQUE,
      busy_by TEXT,
      last_commit TEXT,
      last_used_at INTEGER NOT NULL
    )`,
    `CREATE TABLE hub_machine (
      machine_id TEXT PRIMARY KEY,
      instance_id TEXT NOT NULL,
      name TEXT NOT NULL,
      platform TEXT,
      capabilities TEXT NOT NULL DEFAULT '{}',
      phones TEXT NOT NULL DEFAULT '[]',
      hardware TEXT,
      speed TEXT NOT NULL DEFAULT 'normal',
      free TEXT,
      brake INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL,
      protocol INTEGER NOT NULL,
      pulse_stream TEXT,
      pulse_seq INTEGER,
      running TEXT NOT NULL DEFAULT '[]',
      last_sync_at INTEGER NOT NULL,
      state_since INTEGER NOT NULL DEFAULT 0
    )`,
    `CREATE TABLE hub_job (
      id TEXT PRIMARY KEY,
      origin_machine TEXT NOT NULL,
      origin TEXT NOT NULL,
      code TEXT NOT NULL,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      cancelled_at INTEGER,
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
      devices TEXT,
      waiting TEXT,
      refused_by TEXT,
      refused_pulse INTEGER,
      held_state TEXT,
      since INTEGER NOT NULL,
      outcome TEXT,
      reserved INTEGER NOT NULL DEFAULT 0,
      bypassed INTEGER NOT NULL DEFAULT 0,
      retry_used INTEGER NOT NULL DEFAULT 0,
      only_scenarios TEXT,
      previous TEXT,
      missing INTEGER NOT NULL DEFAULT 0,
      told TEXT,
      reason_at INTEGER,
      est_ms INTEGER,
      offered_at INTEGER,
      acked_at INTEGER,
      started_at INTEGER,
      built_at INTEGER,
      adopt_until INTEGER,
      needs_code INTEGER NOT NULL DEFAULT 0,
      evidence TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY (job_id, part)
    )`,
    // Every attempt of a part, also the old ones: a late report changes only its own row. By machine too: a hub that
    // forgot a request numbers its attempts again, and another machine may still run one with the same number.
    `CREATE TABLE hub_attempt (
      job_id TEXT NOT NULL,
      part TEXT NOT NULL,
      n INTEGER NOT NULL,
      machine_id TEXT NOT NULL,
      state TEXT NOT NULL,
      outcome TEXT,
      cancelled INTEGER NOT NULL DEFAULT 0,
      at INTEGER NOT NULL,
      PRIMARY KEY (job_id, part, n, machine_id)
    )`,
    // A transfer the hub created (`docs/bancada.md`, "Blobs"): who sends, who receives, what arrived (index → sha256).
    `CREATE TABLE hub_blob (
      transfer TEXT PRIMARY KEY,
      job_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      uploader TEXT NOT NULL,
      downloader TEXT NOT NULL,
      files TEXT NOT NULL DEFAULT '[]',
      received TEXT NOT NULL DEFAULT '{}',
      state TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )`,
    // The origin's side of a code transfer: the bundle it made for it, sent in chunks until the hub has it all.
    `CREATE TABLE code_out (
      transfer TEXT PRIMARY KEY,
      job_id TEXT NOT NULL,
      have TEXT NOT NULL,
      file TEXT,
      size INTEGER,
      sha256 TEXT,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )`,
    // The executor's side of an evidence transfer: the files of an attempt, sent until the hub has them all.
    `CREATE TABLE evidence_out (
      transfer TEXT PRIMARY KEY,
      job_id TEXT NOT NULL,
      files TEXT NOT NULL,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )`,
    // The executor's side: a request whose code it asked for, the transfer the hub named and the file once checked.
    `CREATE TABLE code_in (
      job_id TEXT PRIMARY KEY,
      project TEXT NOT NULL,
      state TEXT NOT NULL,
      transfer TEXT,
      file TEXT,
      reason TEXT,
      tries INTEGER NOT NULL DEFAULT 0,
      asked_at INTEGER NOT NULL
    )`,
    // A hold this machine decides (`docs/bancada.md`, "Holds"): a light slot for an emulator or simulator a session
    // starts, or a phone of its catalog. `esperando` rows are the queue, in request order.
    // The devices this machine made for attempts (`devices/pool.ts`): only these, by name, are ever stopped.
    `CREATE TABLE device (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      profile TEXT NOT NULL,
      choice TEXT NOT NULL,
      spec TEXT NOT NULL,
      state TEXT NOT NULL,
      running TEXT,
      attempt TEXT,
      part_dir TEXT,
      falls INTEGER NOT NULL DEFAULT 0,
      quarantined_until INTEGER,
      mute_since INTEGER,
      last_used_at INTEGER
    )`,
    `CREATE TABLE hold (
      id TEXT PRIMARY KEY,
      origin_machine TEXT NOT NULL,
      origin TEXT NOT NULL,
      root_session_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      platform TEXT,
      target TEXT NOT NULL,
      lease_id TEXT,
      state TEXT NOT NULL,
      requested_at INTEGER NOT NULL,
      acquired_at INTEGER,
      last_activity_at INTEGER,
      last_seen_at INTEGER NOT NULL,
      ended_at INTEGER,
      reason TEXT,
      attempt TEXT
    )`,
    // What this server's sessions hold, here or on another machine, as the machine that has the device said.
    `CREATE TABLE grant_mirror (
      hold TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      root_session_id TEXT NOT NULL,
      machine_id TEXT NOT NULL,
      target TEXT NOT NULL,
      state TEXT NOT NULL,
      machine_name TEXT,
      device TEXT,
      expires_at INTEGER,
      position INTEGER,
      reason TEXT,
      requested_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )`,
    // Notes to put in a session (a hold came out, a hold expired), each with its message id drawn once.
    `CREATE TABLE note (
      key TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      text TEXT NOT NULL,
      resume INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      delivered_at INTEGER
    )`,
    // Which machine decides a hold another machine's session asked, to relay its answers back.
    `CREATE TABLE hub_hold (
      hold TEXT PRIMARY KEY,
      origin_machine TEXT NOT NULL,
      target_machine TEXT NOT NULL,
      state TEXT NOT NULL,
      at INTEGER NOT NULL
    )`,
    `CREATE TABLE hub_lock (
      name TEXT PRIMARY KEY,
      job_id TEXT NOT NULL,
      part TEXT NOT NULL,
      since INTEGER NOT NULL
    )`,
    // The last results of each scenario of a project's test, for "falhou N das últimas M vezes" in the notice.
    `CREATE TABLE hub_scenario (
      project TEXT NOT NULL,
      test TEXT NOT NULL,
      scenario_id TEXT NOT NULL,
      last TEXT NOT NULL,
      PRIMARY KEY (project, test, scenario_id)
    )`,
    `CREATE TABLE hub_duration (
      project TEXT NOT NULL,
      test TEXT NOT NULL,
      machine_id TEXT NOT NULL,
      samples TEXT NOT NULL,
      PRIMARY KEY (project, test, machine_id)
    )`,
  ],
  // When an executor first asked for a request's code: past `limits.codeWaitMs` it gives up (`transfers.ts`).
  ["ALTER TABLE code_in ADD COLUMN first_asked_at INTEGER"],
  // The most devices an attempt with a plan may grow to: what the hub proposed for it (`executor.ts`, `grow`).
  ["ALTER TABLE attempt ADD COLUMN devices_cap INTEGER"],
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
