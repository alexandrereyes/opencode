export * as SessionRevertPlan from "./revert-plan.js"

import { CausalRevert } from "@opencode/schema/causal-revert"
import { Location } from "@opencode/schema/location"
import { AbsolutePath } from "@opencode/schema/schema"
import { and, eq, inArray, min, sql } from "drizzle-orm"
import { Effect, Option, Schema } from "effect"
import { Database } from "../database/database.js"
import { Instance } from "../instance/service.js"
import { PluginHooks } from "../plugin/hooks.js"
import { Plugin } from "../plugin/service.js"
import { MessageNotFoundError } from "./error.js"
import { SessionMessage } from "./message.js"
import { SessionSchema } from "./schema.js"
import { SessionCausalTable, SessionInboxTable, SessionMessageTable, SessionTable } from "./sql.js"

const decodePlan = Schema.decodeUnknownEffect(CausalRevert.Plan)

interface ToolRow {
  readonly sessionID: SessionSchema.ID
  readonly seq: number
  readonly messageID: SessionMessage.ID
  readonly toolCallID: string
}

export const load = Effect.fn("SessionRevertPlan.load")(function* (
  db: Database.Interface["db"],
  input: { readonly sessionID: SessionSchema.ID; readonly messageID: SessionMessage.ID },
  options?: { readonly causal?: boolean },
) {
  const boundary = yield* db
    .select({ seq: SessionMessageTable.seq })
    .from(SessionMessageTable)
    .where(and(eq(SessionMessageTable.session_id, input.sessionID), eq(SessionMessageTable.id, input.messageID)))
    .get()
    .pipe(Effect.orDie)
  if (!boundary) return yield* new MessageNotFoundError(input)

  const root = yield* db
    .select({
      sessionID: SessionTable.id,
      parentID: SessionTable.parent_id,
      directory: SessionTable.directory,
      workspaceID: SessionTable.workspace_id,
    })
    .from(SessionTable)
    .where(eq(SessionTable.id, input.sessionID))
    .get()
    .pipe(Effect.orDie)
  if (!root) return yield* Effect.die(new Error(`Revert root Session not found: ${input.sessionID}`))

  const rootFact = {
    sessionID: root.sessionID,
    ...(root.parentID ? { parentID: root.parentID } : {}),
    location: Location.Ref.make({
      directory: AbsolutePath.make(root.directory),
      ...(root.workspaceID ? { workspaceID: root.workspaceID } : {}),
    }),
  }
  if (options?.causal === false)
    return CausalRevert.Facts.make({
      boundary: { ...input, seq: boundary.seq },
      sessions: [rootFact],
      assignments: [],
      tools: [],
    })

  const sessions = [root]
  let frontier = [root.sessionID]
  while (frontier.length > 0) {
    const children = yield* db
      .select({
        sessionID: SessionTable.id,
        parentID: SessionTable.parent_id,
        directory: SessionTable.directory,
        workspaceID: SessionTable.workspace_id,
      })
      .from(SessionTable)
      .where(inArray(SessionTable.parent_id, frontier))
      .all()
      .pipe(Effect.orDie)
    sessions.push(...children)
    frontier = children.map((session) => session.sessionID)
  }

  const sessionIDs = sessions.map((session) => session.sessionID)
  const [assignments, tools, firstMessages, firstInbox] = yield* Effect.all([
    db.select().from(SessionCausalTable).where(inArray(SessionCausalTable.parent_session_id, sessionIDs)).all(),
    db.all<ToolRow>(sql`
      SELECT
        message.session_id AS sessionID,
        message.seq AS seq,
        message.id AS messageID,
        json_extract(content.value, '$.id') AS toolCallID
      FROM ${SessionMessageTable} AS message,
        json_each(message.data, '$.content') AS content
      WHERE message.type = 'assistant'
        AND message.session_id IN (${sql.join(
          sessionIDs.map((sessionID) => sql`${sessionID}`),
          sql.raw(","),
        )})
        AND json_extract(content.value, '$.type') = 'tool'
    `),
    db
      .select({ sessionID: SessionMessageTable.session_id, seq: min(SessionMessageTable.seq) })
      .from(SessionMessageTable)
      .where(inArray(SessionMessageTable.session_id, sessionIDs))
      .groupBy(SessionMessageTable.session_id)
      .all(),
    db
      .select({ sessionID: SessionInboxTable.session_id, seq: min(SessionInboxTable.enqueued_seq) })
      .from(SessionInboxTable)
      .where(inArray(SessionInboxTable.session_id, sessionIDs))
      .groupBy(SessionInboxTable.session_id)
      .all(),
  ]).pipe(Effect.orDie)
  const inputIDs = assignments.map((assignment) => assignment.input_id)
  const [messages, inbox] =
    inputIDs.length === 0
      ? [[], []]
      : yield* Effect.all([
          db
            .select({
              id: SessionMessageTable.id,
              sessionID: SessionMessageTable.session_id,
              seq: SessionMessageTable.seq,
            })
            .from(SessionMessageTable)
            .where(inArray(SessionMessageTable.id, inputIDs))
            .all(),
          db
            .select({
              id: SessionInboxTable.id,
              sessionID: SessionInboxTable.session_id,
              seq: SessionInboxTable.enqueued_seq,
            })
            .from(SessionInboxTable)
            .where(inArray(SessionInboxTable.id, inputIDs))
            .all(),
        ]).pipe(Effect.orDie)
  const messageInputs = new Map(messages.map((row) => [row.id, row]))
  const inboxInputs = new Map(inbox.map((row) => [row.id, row]))
  const firstMessage = new Map(
    firstMessages.flatMap((row) => (row.seq === null ? [] : [[row.sessionID, row.seq] as const])),
  )
  const firstPending = new Map(
    firstInbox.flatMap((row) => (row.seq === null ? [] : [[row.sessionID, row.seq] as const])),
  )

  return CausalRevert.Facts.make({
    boundary: { ...input, seq: boundary.seq },
    sessions: sessions
      .map((session) => ({
        sessionID: session.sessionID,
        ...(session.parentID ? { parentID: session.parentID } : {}),
        location: Location.Ref.make({
          directory: AbsolutePath.make(session.directory),
          ...(session.workspaceID ? { workspaceID: session.workspaceID } : {}),
        }),
        ...(firstMessage.has(session.sessionID) ? { firstMessageSeq: firstMessage.get(session.sessionID) } : {}),
        ...(firstPending.has(session.sessionID) ? { firstInboxSeq: firstPending.get(session.sessionID) } : {}),
      }))
      .toSorted((a, b) => a.sessionID.localeCompare(b.sessionID)),
    assignments: assignments
      .map((assignment) => {
        const storedMessage = messageInputs.get(assignment.input_id)
        const storedPending = inboxInputs.get(assignment.input_id)
        const message = storedMessage?.sessionID === assignment.child_session_id ? storedMessage : undefined
        const pending = storedPending?.sessionID === assignment.child_session_id ? storedPending : undefined
        return {
          inputID: assignment.input_id,
          parentSessionID: assignment.parent_session_id,
          childSessionID: assignment.child_session_id,
          assignedSeq: assignment.seq,
          origin: {
            parentSessionID: assignment.parent_session_id,
            messageID: assignment.message_id,
            toolCallID: assignment.tool_call_id,
          },
          ...(message
            ? { input: { state: "message" as const, seq: message.seq } }
            : pending
              ? { input: { state: "inbox" as const, seq: pending.seq } }
              : {}),
        }
      })
      .toSorted((a, b) => assignmentKey(a).localeCompare(assignmentKey(b))),
    tools: tools
      .map((row) => ({
        sessionID: row.sessionID,
        seq: row.seq,
        origin: { parentSessionID: row.sessionID, messageID: row.messageID, toolCallID: row.toolCallID },
      }))
      .toSorted((a, b) =>
        `${a.sessionID}:${a.seq}:${originKey(a.origin)}`.localeCompare(
          `${b.sessionID}:${b.seq}:${originKey(b.origin)}`,
        ),
      ),
  })
})

export const acquire = Effect.fn("SessionRevertPlan.acquire")(function* (
  instances: Instance.Interface,
  session: SessionSchema.Info,
) {
  return yield* Effect.gen(function* () {
    yield* Plugin.awaitActivation
    const hooks = yield* PluginHooks.Service
    if (!(yield* hooks.has("session", "revert.plan")))
      return Option.none<(facts: CausalRevert.Facts) => Effect.Effect<CausalRevert.Plan>>()
    return Option.some((facts: CausalRevert.Facts) =>
      hooks
        .trigger("session", "revert.plan", {
          facts,
          plan: CausalRevert.Plan.make({ participants: [], origins: [], pendingOrigins: [], discardedSessionIDs: [] }),
        })
        .pipe(Effect.map((event) => event.plan)),
    )
  }).pipe(instances.provide(session))
})

export const resolve = Effect.fn("SessionRevertPlan.resolve")(function* (
  planner: Option.Option<(facts: CausalRevert.Facts) => Effect.Effect<CausalRevert.Plan>>,
  facts: CausalRevert.Facts,
) {
  if (Option.isNone(planner))
    return CausalRevert.Plan.make({ participants: [], origins: [], pendingOrigins: [], discardedSessionIDs: [] })
  const snapshot = structuredClone(facts)
  freeze(snapshot)
  const plan = yield* planner.value(snapshot).pipe(Effect.flatMap(decodePlan), Effect.orDie)
  validate(facts, plan)
  return normalize(plan)
})

export function same(left: CausalRevert.Facts, right: CausalRevert.Facts) {
  return JSON.stringify(left) === JSON.stringify(right)
}

export function validate(facts: CausalRevert.Facts, plan: CausalRevert.Plan) {
  const fail = (message: string): never => {
    throw new Error(`Invalid causal revert plan: ${message}`)
  }
  const sessions = new Set(facts.sessions.map((session) => session.sessionID))
  const messageInputs = new Map(
    facts.assignments.flatMap((assignment) =>
      assignment.input?.state === "message"
        ? [[`${assignment.childSessionID}:${assignment.inputID}`, assignment] as const]
        : [],
    ),
  )
  const pendingInputs = new Map(
    facts.assignments.flatMap((assignment) =>
      assignment.input?.state === "inbox"
        ? [[`${assignment.childSessionID}:${assignment.inputID}`, assignment] as const]
        : [],
    ),
  )
  const knownOrigins = new Set([
    ...facts.tools.map((tool) => originKey(tool.origin)),
    ...facts.assignments.flatMap((assignment) =>
      assignment.input?.state === "message" ? [originKey(assignment.origin)] : [],
    ),
  ])
  const knownPendingOrigins = new Set(
    facts.assignments.flatMap((assignment) =>
      assignment.input?.state === "inbox" ? [originKey(assignment.origin)] : [],
    ),
  )
  unique(
    plan.participants.map((participant) => participant.sessionID),
    "participant",
    fail,
  )
  unique(plan.origins.map(originKey), "origin", fail)
  unique(plan.pendingOrigins.map(originKey), "pending origin", fail)
  unique(plan.discardedSessionIDs, "discarded Session", fail)
  const participantIDs = new Set(plan.participants.map((participant) => participant.sessionID))
  for (const participant of plan.participants) {
    if (participant.sessionID === facts.boundary.sessionID) fail("root cannot be a participant")
    if (!sessions.has(participant.sessionID)) fail(`unknown participant ${participant.sessionID}`)
    if (!participant.messageID && participant.pendingIDs.length === 0)
      fail(`participant ${participant.sessionID} has no boundary`)
    if (participant.messageID && !messageInputs.has(`${participant.sessionID}:${participant.messageID}`))
      fail(`unknown message boundary ${participant.messageID}`)
    unique(participant.pendingIDs, `pending input for ${participant.sessionID}`, fail)
    for (const id of participant.pendingIDs)
      if (!pendingInputs.has(`${participant.sessionID}:${id}`)) fail(`unknown pending input ${id}`)
  }
  for (const origin of plan.origins)
    if (!knownOrigins.has(originKey(origin))) fail(`unknown origin ${originKey(origin)}`)
  for (const origin of plan.pendingOrigins)
    if (!knownPendingOrigins.has(originKey(origin))) fail(`unknown pending origin ${originKey(origin)}`)
  for (const sessionID of plan.discardedSessionIDs) {
    if (!participantIDs.has(sessionID)) fail(`discarded Session is not a participant: ${sessionID}`)
    const participant = plan.participants.find((item) => item.sessionID === sessionID)
    const session = facts.sessions.find((item) => item.sessionID === sessionID)
    const boundary = participant?.messageID ? messageInputs.get(`${sessionID}:${participant.messageID}`) : undefined
    if (
      !boundary?.input ||
      !session ||
      boundary.input.seq !== Math.min(session.firstMessageSeq ?? Infinity, session.firstInboxSeq ?? Infinity)
    )
      fail(`discarded Session does not begin at its participant boundary: ${sessionID}`)
  }
}

function normalize(plan: CausalRevert.Plan): CausalRevert.Plan {
  return CausalRevert.Plan.make({
    participants: plan.participants
      .map((participant) => ({ ...participant, pendingIDs: participant.pendingIDs.toSorted() }))
      .toSorted((a, b) => a.sessionID.localeCompare(b.sessionID)),
    origins: plan.origins.slice().toSorted((a, b) => originKey(a).localeCompare(originKey(b))),
    pendingOrigins: plan.pendingOrigins.slice().toSorted((a, b) => originKey(a).localeCompare(originKey(b))),
    discardedSessionIDs: plan.discardedSessionIDs.slice().toSorted(),
  })
}

function unique(values: readonly string[], name: string, fail: (message: string) => never) {
  if (new Set(values).size !== values.length) fail(`duplicate ${name}`)
}

function assignmentKey(assignment: CausalRevert.AssignmentFact) {
  return `${assignment.parentSessionID}:${assignment.assignedSeq}:${assignment.childSessionID}:${assignment.inputID}`
}

function originKey(origin: CausalRevert.Origin) {
  return `${origin.parentSessionID}:${origin.messageID}:${origin.toolCallID}`
}

function freeze(value: unknown): void {
  if (typeof value !== "object" || value === null || Object.isFrozen(value)) return
  for (const key of Reflect.ownKeys(value)) freeze(Reflect.get(value, key))
  Object.freeze(value)
}
