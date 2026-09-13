export * as SessionRevertPersistence from "./revert-persistence.js"

import { and, eq, gte, inArray } from "drizzle-orm"
import { Effect, Schema } from "effect"
import { PersistedRevert } from "@opencode/schema/session-revert"
import type { Bus } from "../bus.js"
import type { Database } from "../database/database.js"
import { SessionEvent } from "./event.js"
import { InstructionState } from "./instruction-state.js"
import { SessionCausalTable } from "./causal.sql.js"
import { SessionInboxTable, SessionMessageTable, SessionTable } from "./sql.js"
import type { SessionSchema } from "./schema.js"

type DatabaseService = Database.Interface["db"]
type Revert = typeof PersistedRevert.Type
type Child = NonNullable<Revert["children"]>[number]

const decodeRevert = Schema.decodeUnknownSync(PersistedRevert)

export const registerProvenance = Effect.fn("SessionRevertPersistence.registerProvenance")(function* (
  db: DatabaseService,
  bus: Bus.Interface,
) {
  yield* bus.project(SessionEvent.SubagentInputAssigned, (event) =>
    db
      .insert(SessionCausalTable)
      .values({
        input_id: event.data.inputID,
        parent_session_id: event.data.sessionID,
        child_session_id: event.data.childSessionID,
        seq: event.durable.seq,
        message_id: event.data.origin.messageID,
        tool_call_id: event.data.origin.toolCallID,
      })
      .onConflictDoNothing()
      .run()
      .pipe(Effect.orDie, Effect.asVoid),
  )
})

export const prepareStage = Effect.fn("SessionRevertPersistence.prepareStage")(function* (
  db: DatabaseService,
  input: {
    readonly sessionID: SessionSchema.ID
    readonly revert: Revert
    readonly created: number
  },
) {
  const previous = yield* stagedChildren(db, input.sessionID)
  const next = new Set((input.revert.children ?? []).map((child) => child.sessionID))
  yield* clearDerivedMarkers(
    db,
    input.sessionID,
    previous.filter((child) => !next.has(child.sessionID)),
    input.created,
  )
  yield* Effect.forEach(
    input.revert.children ?? [],
    (child) =>
      Effect.gen(function* () {
        const messageID = child.messageID ?? child.pendingIDs[0]
        if (!messageID) return yield* Effect.die(new Error(`Causal revert child has no boundary: ${child.sessionID}`))
        yield* db
          .update(SessionTable)
          .set({ revert: { messageID, parentID: input.sessionID, files: [] }, time_updated: input.created })
          .where(eq(SessionTable.id, child.sessionID))
          .run()
          .pipe(Effect.orDie)
      }),
    { discard: true },
  )
})

export const prepareClear = Effect.fn("SessionRevertPersistence.prepareClear")(function* (
  db: DatabaseService,
  sessionID: SessionSchema.ID,
  created: number,
) {
  yield* clearDerivedMarkers(db, sessionID, yield* stagedChildren(db, sessionID), created)
})

export const prepareCommit = Effect.fn("SessionRevertPersistence.prepareCommit")(function* (
  db: DatabaseService,
  sessionID: SessionSchema.ID,
) {
  return yield* stagedChildren(db, sessionID)
})

export const commitChildren = Effect.fn("SessionRevertPersistence.commitChildren")(
  (db: DatabaseService, children: readonly Child[]) =>
    Effect.forEach(children.toReversed(), (child) => commitChild(db, child), { discard: true }),
)

export const deleteRootProvenance = Effect.fn("SessionRevertPersistence.deleteRootProvenance")(
  (db: DatabaseService, sessionID: SessionSchema.ID, seq: number) =>
    db
      .delete(SessionCausalTable)
      .where(and(eq(SessionCausalTable.parent_session_id, sessionID), gte(SessionCausalTable.seq, seq)))
      .run()
      .pipe(Effect.orDie, Effect.asVoid),
)

export const clearCommitted = Effect.fn("SessionRevertPersistence.clearCommitted")(
  (db: DatabaseService, sessionID: SessionSchema.ID, children: readonly Child[], created: number) =>
    clearDerivedMarkers(db, sessionID, children, created),
)

export const isStaged = Effect.fn("SessionRevertPersistence.isStaged")(function* (
  db: DatabaseService,
  sessionID: SessionSchema.ID,
) {
  const session = yield* db
    .select({ revert: SessionTable.revert })
    .from(SessionTable)
    .where(eq(SessionTable.id, sessionID))
    .get()
    .pipe(Effect.orDie)
  return session?.revert !== null && session?.revert !== undefined
})

const stagedChildren = Effect.fnUntraced(function* (db: DatabaseService, sessionID: SessionSchema.ID) {
  const staged = yield* db
    .select({ revert: SessionTable.revert })
    .from(SessionTable)
    .where(eq(SessionTable.id, sessionID))
    .get()
    .pipe(Effect.orDie)
  return staged?.revert ? (decodeRevert(staged.revert).children ?? []) : []
})

const commitChild = Effect.fnUntraced(function* (db: DatabaseService, child: Child) {
  if (child.messageID) {
    const message = yield* db
      .select({ seq: SessionMessageTable.seq })
      .from(SessionMessageTable)
      .where(and(eq(SessionMessageTable.session_id, child.sessionID), eq(SessionMessageTable.id, child.messageID)))
      .get()
      .pipe(Effect.orDie)
    if (!message) return yield* Effect.die(new Error(`Causal revert boundary not found: ${child.messageID}`))
    yield* deleteChildFrom(db, child.sessionID, message.seq)
    yield* InstructionState.reset(db, child.sessionID)
  }
  if (child.pendingIDs.length === 0) return
  yield* db
    .delete(SessionInboxTable)
    .where(and(eq(SessionInboxTable.session_id, child.sessionID), inArray(SessionInboxTable.id, child.pendingIDs)))
    .run()
    .pipe(Effect.orDie)
})

const deleteChildFrom = Effect.fnUntraced(function* (db: DatabaseService, sessionID: SessionSchema.ID, seq: number) {
  yield* db
    .delete(SessionMessageTable)
    .where(and(eq(SessionMessageTable.session_id, sessionID), gte(SessionMessageTable.seq, seq)))
    .run()
    .pipe(Effect.orDie)
  yield* db
    .delete(SessionInboxTable)
    .where(and(eq(SessionInboxTable.session_id, sessionID), gte(SessionInboxTable.enqueued_seq, seq)))
    .run()
    .pipe(Effect.orDie)
  yield* db
    .delete(SessionCausalTable)
    .where(and(eq(SessionCausalTable.parent_session_id, sessionID), gte(SessionCausalTable.seq, seq)))
    .run()
    .pipe(Effect.orDie)
})

const clearDerivedMarkers = Effect.fnUntraced(function* (
  db: DatabaseService,
  parentID: SessionSchema.ID,
  children: readonly { readonly sessionID: SessionSchema.ID }[],
  created: number,
) {
  yield* Effect.forEach(
    children,
    (child) =>
      Effect.gen(function* () {
        const row = yield* db
          .select({ revert: SessionTable.revert })
          .from(SessionTable)
          .where(eq(SessionTable.id, child.sessionID))
          .get()
          .pipe(Effect.orDie)
        if (!row?.revert || decodeRevert(row.revert).parentID !== parentID) return
        yield* db
          .update(SessionTable)
          .set({ revert: null, time_updated: created })
          .where(eq(SessionTable.id, child.sessionID))
          .run()
          .pipe(Effect.orDie)
      }),
    { discard: true },
  )
})
