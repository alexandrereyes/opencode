import { Database } from "bun:sqlite"

/**
 * Opens the machine's database and takes it for this process alone: exclusive locking, WAL, and a write at once, so
 * the lock is held from the first moment. A second process on the same folder gets `SQLITE_BUSY` and receives
 * undefined. The kernel drops the lock when the process dies, even by SIGKILL: there is no stale lock to clean (prova
 * E6, on APFS, on the container's volume and between containers).
 *
 * The caller must keep the returned database for the life of the process: a `Database` the garbage collector reaches
 * is closed, and the lock goes with it while the process still runs (prova E6).
 */
export function openExclusive(file: string, now = Date.now()) {
  const db = new Database(file, { create: true })
  try {
    db.run("PRAGMA busy_timeout = 0")
    db.run("PRAGMA locking_mode = EXCLUSIVE")
    db.run("PRAGMA journal_mode = WAL")
    db.run("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('opened_at', ?)", [String(now)])
    return db
  } catch (error) {
    db.close()
    if (busy(error)) return undefined
    throw error
  }
}

function busy(error: unknown) {
  return typeof error === "object" && error !== null && "code" in error && error.code === "SQLITE_BUSY"
}
