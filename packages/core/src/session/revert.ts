export * as SessionRevert from "./revert.js"

import { and, asc, eq, gt, gte, inArray } from "drizzle-orm"
import { Effect, Schema } from "effect"
import { Database } from "../database/database.js"
import { Bus } from "../bus.js"
import { Instance } from "../instance/service.js"
import { RelativePath } from "../schema.js"
import { Snapshot } from "../snapshot.js"
import { SessionEvent } from "./event.js"
import { MessageNotFoundError } from "./error.js"
import { SessionMessage } from "./message.js"
import { SessionSchema } from "./schema.js"
import { SessionCausalTable, SessionInboxTable, SessionMessageTable, SessionTable } from "./sql.js"

export { MessageNotFoundError }

interface BoundaryInput {
  readonly sessionID: SessionSchema.ID
  readonly messageID: SessionMessage.ID
}

const decodeMessage = Schema.decodeUnknownSync(SessionMessage.Info)

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
    const fileChildren = yield* Effect.filter(
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
    const next = yield* plan(database.db, { sessionID: input.session.id, messageID: input.messageID }, fileChildren)
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

export const causal = Effect.fn("SessionRevert.causal")(function* (db: Database.Interface["db"], input: BoundaryInput) {
  const cuts: {
    sessionID: SessionSchema.ID
    messageID?: SessionMessage.ID
    pendingIDs: SessionMessage.ID[]
  }[] = []
  const origins: {
    parentSessionID: SessionSchema.ID
    messageID: SessionMessage.ID
    toolCallID: string
  }[] = []
  const pendingOrigins: {
    parentSessionID: SessionSchema.ID
    messageID: SessionMessage.ID
    toolCallID: string
  }[] = []
  const sessionIDs: SessionSchema.ID[] = []
  const visit = (parentID: SessionSchema.ID, from: number): Effect.Effect<void> =>
    Effect.gen(function* () {
      const rows = yield* db
        .select()
        .from(SessionMessageTable)
        .where(and(eq(SessionMessageTable.session_id, parentID), gte(SessionMessageTable.seq, from)))
        .all()
        .pipe(Effect.orDie)
      const links = yield* db
        .select()
        .from(SessionCausalTable)
        .where(and(eq(SessionCausalTable.parent_session_id, parentID), gte(SessionCausalTable.seq, from)))
        .all()
        .pipe(Effect.orDie)
      rows.forEach((row) => {
        const message = decodeMessage({ ...row.data, id: row.id, type: row.type })
        if (message.type !== "assistant") return
        message.content.forEach((part) => {
          if (part.type !== "tool") return
          origins.push({ parentSessionID: parentID, messageID: message.id, toolCallID: part.id })
        })
      })
      const childIDs = [...new Set(links.map((link) => link.child_session_id))]
      yield* Effect.forEach(
        childIDs,
        (childID) =>
          Effect.gen(function* () {
            const child = yield* db
              .select({ id: SessionTable.id, parentID: SessionTable.parent_id })
              .from(SessionTable)
              .where(eq(SessionTable.id, childID))
              .get()
              .pipe(Effect.orDie)
            if (!child || child.parentID !== parentID) return
            const assigned = links.filter((link) => link.child_session_id === child.id)
            const inputIDs = assigned.map((link) => link.input_id)
            const messages = yield* db
              .select({ id: SessionMessageTable.id, seq: SessionMessageTable.seq })
              .from(SessionMessageTable)
              .where(and(eq(SessionMessageTable.session_id, child.id), inArray(SessionMessageTable.id, inputIDs)))
              .all()
              .pipe(Effect.orDie)
            const pending = yield* db
              .select({ id: SessionInboxTable.id, seq: SessionInboxTable.enqueued_seq })
              .from(SessionInboxTable)
              .where(and(eq(SessionInboxTable.session_id, child.id), inArray(SessionInboxTable.id, inputIDs)))
              .all()
              .pipe(Effect.orDie)
            const messageCut = messages.toSorted((a, b) => a.seq - b.seq)[0]
            const pendingIDs = pending.toSorted((a, b) => a.seq - b.seq).map((row) => SessionMessage.ID.make(row.id))
            if (!messageCut && pendingIDs.length === 0) return
            cuts.push({
              sessionID: child.id,
              messageID: messageCut ? SessionMessage.ID.make(messageCut.id) : undefined,
              pendingIDs,
            })
            assigned.forEach((link) => {
              const origin = {
                parentSessionID: parentID,
                messageID: link.message_id,
                toolCallID: link.tool_call_id,
              }
              if (messages.some((message) => message.id === link.input_id)) origins.push(origin)
              if (pending.some((input) => input.id === link.input_id)) pendingOrigins.push(origin)
            })
            if (!messageCut) return
            const [message, inbox] = yield* Effect.all([
              db
                .select({ seq: SessionMessageTable.seq })
                .from(SessionMessageTable)
                .where(eq(SessionMessageTable.session_id, child.id))
                .orderBy(asc(SessionMessageTable.seq))
                .limit(1)
                .get()
                .pipe(Effect.orDie),
              db
                .select({ seq: SessionInboxTable.enqueued_seq })
                .from(SessionInboxTable)
                .where(eq(SessionInboxTable.session_id, child.id))
                .orderBy(asc(SessionInboxTable.enqueued_seq))
                .limit(1)
                .get()
                .pipe(Effect.orDie),
            ])
            if (messageCut.seq === Math.min(message?.seq ?? Infinity, inbox?.seq ?? Infinity)) sessionIDs.push(child.id)
            yield* visit(child.id, messageCut.seq)
          }),
        { discard: true },
      )
    })
  yield* visit(input.sessionID, yield* messageBoundarySeq(db, input))
  const pendingKeys = new Set(
    pendingOrigins.map((origin) => `${origin.parentSessionID}:${origin.messageID}:${origin.toolCallID}`),
  )
  return {
    children: cuts.toSorted((a, b) => a.sessionID.localeCompare(b.sessionID)),
    origins: [
      ...new Map(
        origins
          .filter((origin) => !pendingKeys.has(`${origin.parentSessionID}:${origin.messageID}:${origin.toolCallID}`))
          .map((origin) => [`${origin.parentSessionID}:${origin.messageID}:${origin.toolCallID}`, origin]),
      ).values(),
    ].toSorted((a, b) =>
      `${a.parentSessionID}:${a.messageID}:${a.toolCallID}`.localeCompare(
        `${b.parentSessionID}:${b.messageID}:${b.toolCallID}`,
      ),
    ),
    pendingOrigins: [
      ...new Map(
        pendingOrigins.map((origin) => [`${origin.parentSessionID}:${origin.messageID}:${origin.toolCallID}`, origin]),
      ).values(),
    ].toSorted((a, b) =>
      `${a.parentSessionID}:${a.messageID}:${a.toolCallID}`.localeCompare(
        `${b.parentSessionID}:${b.messageID}:${b.toolCallID}`,
      ),
    ),
    sessionIDs: [...new Set(sessionIDs)].toSorted(),
  }
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
  const decode = Schema.decodeUnknownEffect(SessionMessage.Info)
  const files = new Map<RelativePath, Snapshot.ID>()
  const rows = (yield* Effect.forEach(boundaries, (boundary) =>
    db
      .select()
      .from(SessionMessageTable)
      .where(
        and(
          eq(SessionMessageTable.session_id, boundary.sessionID),
          eq(SessionMessageTable.type, "assistant"),
          gt(SessionMessageTable.seq, boundary.seq),
        ),
      )
      .all()
      .pipe(Effect.orDie),
  ))
    .flat()
    .toSorted((a, b) => a.time_created - b.time_created || a.id.localeCompare(b.id))
  for (const row of rows) {
    const message = yield* decode({ ...row.data, id: row.id, type: row.type }).pipe(Effect.orDie)
    if (message.type !== "assistant" || !message.snapshot?.start) continue
    for (const file of message.snapshot.files ?? [])
      if (!files.has(file)) files.set(file, Snapshot.ID.make(message.snapshot.start))
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
