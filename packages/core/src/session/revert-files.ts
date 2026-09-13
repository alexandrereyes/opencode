export * as SessionRevertFiles from "./revert-files.js"

import { and, eq, sql } from "drizzle-orm"
import { Effect } from "effect"
import type { Database } from "../database/database.js"
import { RelativePath } from "../schema.js"
import { Snapshot } from "../snapshot.js"
import { MessageNotFoundError } from "./error.js"
import type { SessionMessage } from "./message.js"
import type { SessionSchema } from "./schema.js"
import { SessionMessageTable, SessionTable } from "./sql.js"

interface Boundary {
  readonly sessionID: SessionSchema.ID
  readonly messageID: SessionMessage.ID
}

export const plan = Effect.fn("SessionRevertFiles.plan")(function* (
  db: Database.Interface["db"],
  input: {
    readonly session: Pick<SessionSchema.Info, "id" | "location">
    readonly messageID: SessionMessage.ID
    readonly children?: readonly {
      readonly sessionID: SessionSchema.ID
      readonly messageID?: SessionMessage.ID
    }[]
  },
) {
  // One stage owns one Snapshot service. Cross-Location children therefore
  // participate in history rollback but not this Location's filesystem plan.
  const children = yield* Effect.filter(
    (input.children ?? []).flatMap((child) =>
      child.messageID ? [{ sessionID: child.sessionID, messageID: child.messageID }] : [],
    ),
    (child) =>
      db
        .select({ directory: SessionTable.directory, workspaceID: SessionTable.workspace_id })
        .from(SessionTable)
        .where(eq(SessionTable.id, child.sessionID))
        .get()
        .pipe(
          Effect.orDie,
          Effect.map(
            (row) =>
              row?.directory === input.session.location.directory &&
              (row.workspaceID ?? undefined) === input.session.location.workspaceID,
          ),
        ),
  )
  const boundaries = [
    {
      sessionID: input.session.id,
      seq: yield* boundarySeq(db, { sessionID: input.session.id, messageID: input.messageID }),
    },
    ...(yield* Effect.forEach(children, (child) =>
      boundarySeq(db, child).pipe(Effect.map((seq) => ({ sessionID: child.sessionID, seq }))),
    )),
  ]
  const files = new Map<RelativePath, Snapshot.ID>()
  const rows = (yield* Effect.forEach(boundaries, (boundary) =>
    db
      .all<{ readonly id: string; readonly timeCreated: number; readonly tree: string; readonly file: string }>(
        sql`
      SELECT
        message.id AS id,
        message.time_created AS timeCreated,
        json_extract(message.data, '$.snapshot.start') AS tree,
        file.value AS file
      FROM ${SessionMessageTable} AS message,
        json_each(message.data, '$.snapshot.files') AS file
      WHERE message.session_id = ${boundary.sessionID}
        AND message.type = 'assistant'
        AND message.seq > ${boundary.seq}
        AND json_extract(message.data, '$.snapshot.start') IS NOT NULL
    `,
      )
      .pipe(Effect.orDie),
  ))
    .flat()
    .toSorted((a, b) => a.timeCreated - b.timeCreated || a.id.localeCompare(b.id))
  for (const row of rows) {
    const file = RelativePath.make(row.file)
    if (!files.has(file)) files.set(file, Snapshot.ID.make(row.tree))
  }
  return files
})

const boundarySeq = Effect.fnUntraced(function* (db: Database.Interface["db"], input: Boundary) {
  const boundary = yield* db
    .select({ seq: SessionMessageTable.seq })
    .from(SessionMessageTable)
    .where(and(eq(SessionMessageTable.session_id, input.sessionID), eq(SessionMessageTable.id, input.messageID)))
    .get()
    .pipe(Effect.orDie)
  if (!boundary) return yield* new MessageNotFoundError(input)
  return boundary.seq
})
