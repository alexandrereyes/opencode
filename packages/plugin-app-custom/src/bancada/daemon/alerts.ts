import type { Database } from "bun:sqlite"

/**
 * Exceptions the owner must see (`docs/bancada.md`, "Notice and evidence"): one row per subject while it lasts, so a
 * condition seen every round raises it once. A cleared alert raised again is new. Every machine keeps its own: the
 * hub's queue raises those of the queue; any machine, those of its link to the hub. Texts in Portuguese, for the app.
 */
export function makeAlerts(db: Database, now: () => number, log: (line: string) => void) {
  const active = db.query<{ id: string; kind: string; text: string; at: number }, []>(
    "SELECT id, kind, text, at FROM alert WHERE cleared_at IS NULL ORDER BY at, id",
  )
  const find = db.query<{ cleared_at: number | null }, [string]>("SELECT cleared_at FROM alert WHERE id = ?")

  return {
    /** Raises the alert `id` unless it is already up; says whether it is new. */
    raise: (id: string, kind: string, text: string) => {
      const known = find.get(id)
      if (known && known.cleared_at === null) return false
      db.run("INSERT OR REPLACE INTO alert (id, at, kind, text, cleared_at) VALUES (?, ?, ?, ?, NULL)", [
        id,
        now(),
        kind,
        text,
      ])
      log(`alert: ${text}`)
      return true
    },
    clear: (id: string) => db.run("UPDATE alert SET cleared_at = ? WHERE id = ? AND cleared_at IS NULL", [now(), id]),
    active: () => active.all(),
  }
}

export type Alerts = ReturnType<typeof makeAlerts>
