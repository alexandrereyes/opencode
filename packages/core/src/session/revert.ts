export * as SessionRevert from "./revert.js"

import { and, eq, sql } from "drizzle-orm"
import { Effect } from "effect"
import { Database } from "../database/database.js"
import { Bus } from "../bus.js"
import { Instance } from "../instance/service.js"
import { RelativePath } from "../schema.js"
import { Snapshot } from "../snapshot.js"
import { SessionEvent } from "./event.js"
import { MessageNotFoundError } from "./error.js"
import { SessionMessage } from "./message.js"
import { SessionSchema } from "./schema.js"
import { SessionMessageTable, SessionTable } from "./sql.js"

export { MessageNotFoundError }

interface BoundaryInput {
  readonly sessionID: SessionSchema.ID
  readonly messageID: SessionMessage.ID
}

export const stage = Effect.fn("SessionRevert.stage")(function* (input: {
  session: SessionSchema.Info
  messageID: SessionMessage.ID
  files?: boolean
  children?: readonly {
    readonly sessionID: SessionSchema.ID
    readonly messageID?: SessionMessage.ID
    readonly pendingIDs: readonly SessionMessage.ID[]
  }[]
}) {
  const instances = yield* Instance.Service
  const database = yield* Database.Service
  const bus = yield* Bus.Service

  return yield* Effect.gen(function* () {
    const snapshot = yield* Snapshot.Service
    const original = input.session.revert?.snapshot
      ? Snapshot.ID.make(input.session.revert.snapshot)
      : yield* snapshot.capture()
    // This stage owns one Snapshot service. Child file plans are therefore composable only
    // while they share the root Location; history rollback still applies across Locations.
    const fileChildren =
      input.files === false
        ? []
        : yield* Effect.filter(
            (input.children ?? []).flatMap((child) =>
              child.messageID ? [{ sessionID: child.sessionID, messageID: child.messageID }] : [],
            ),
            (child) =>
              database.db
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
    const next =
      input.files === false
        ? new Map<RelativePath, Snapshot.ID>()
        : yield* plan(database.db, { sessionID: input.session.id, messageID: input.messageID }, fileChildren)
    const restore = new Map<RelativePath, Snapshot.ID>()
    if (original) {
      for (const file of input.session.revert?.files ?? []) restore.set(RelativePath.make(file.file), original)
    }
    if (input.files !== false) for (const [file, tree] of next) restore.set(file, tree)
    if (restore.size) yield* snapshot.restore({ files: restore })
    const paths = input.files === false ? [] : Array.from(next.keys())
    const files = original
      ? yield* snapshot.diff({ from: original, to: (yield* snapshot.capture()) ?? original, paths })
      : []
    const revert = {
      messageID: input.messageID,
      snapshot: original,
      files,
      children: input.children?.slice(),
    } satisfies SessionSchema.Info["revert"]
    yield* bus.publish(SessionEvent.RevertEvent.Staged, {
      sessionID: input.session.id,
      revert,
    })
    return revert
  }).pipe(instances.provide(input.session))
})

export const clear = Effect.fn("SessionRevert.clear")(function* (session: SessionSchema.Info) {
  const instances = yield* Instance.Service
  const bus = yield* Bus.Service
  yield* Effect.gen(function* () {
    const snapshot = yield* Snapshot.Service
    if (!session.revert) return
    const original = session.revert.snapshot ? Snapshot.ID.make(session.revert.snapshot) : undefined
    if (original)
      yield* snapshot.restore({
        files: new Map((session.revert.files ?? []).map((file) => [RelativePath.make(file.file), original])),
      })
    yield* bus.publish(SessionEvent.RevertEvent.Cleared, {
      sessionID: session.id,
    })
  }).pipe(instances.provide(session))
})

export const commit = Effect.fn("SessionRevert.commit")(function* (bus: Bus.Interface, session: SessionSchema.Info) {
  if (!session.revert) return
  yield* bus.publish(SessionEvent.RevertEvent.Committed, {
    sessionID: session.id,
    to: session.revert.messageID,
  })
})

const plan = Effect.fn("SessionRevert.plan")(function* (
  db: Database.Interface["db"],
  input: BoundaryInput,
  children?: readonly {
    readonly sessionID: SessionSchema.ID
    readonly messageID: SessionMessage.ID
  }[],
) {
  const boundaries = [
    { sessionID: input.sessionID, seq: yield* messageBoundarySeq(db, input) },
    ...(yield* Effect.forEach(children ?? [], (child) =>
      messageBoundarySeq(db, { sessionID: child.sessionID, messageID: child.messageID }).pipe(
        Effect.map((seq) => ({ sessionID: child.sessionID, seq })),
      ),
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

const messageBoundarySeq = Effect.fnUntraced(function* (db: Database.Interface["db"], input: BoundaryInput) {
  const boundary = yield* db
    .select({ seq: SessionMessageTable.seq })
    .from(SessionMessageTable)
    .where(and(eq(SessionMessageTable.session_id, input.sessionID), eq(SessionMessageTable.id, input.messageID)))
    .get()
    .pipe(Effect.orDie)
  if (!boundary) return yield* new MessageNotFoundError(input)
  return boundary.seq
})
