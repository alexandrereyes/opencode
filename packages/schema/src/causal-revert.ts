export * as CausalRevert from "./causal-revert.js"

import { Schema } from "effect"
import { Location } from "./location.js"
import { NonNegativeInt, optional } from "./schema.js"
import { SessionID } from "./session-id.js"
import { SessionMessage } from "./session-message.js"

export interface Origin extends Schema.Schema.Type<typeof Origin> {}
export const Origin = Schema.Struct({
  parentSessionID: SessionID,
  messageID: SessionMessage.ID,
  toolCallID: Schema.String,
}).annotate({ identifier: "CausalRevert.Origin" })

export interface SessionFact extends Schema.Schema.Type<typeof SessionFact> {}
export const SessionFact = Schema.Struct({
  sessionID: SessionID,
  parentID: SessionID.pipe(optional),
  location: Location.Ref,
  firstMessageSeq: NonNegativeInt.pipe(optional),
  firstInboxSeq: NonNegativeInt.pipe(optional),
}).annotate({ identifier: "CausalRevert.SessionFact" })

export interface AssignmentFact extends Schema.Schema.Type<typeof AssignmentFact> {}
export const AssignmentFact = Schema.Struct({
  inputID: SessionMessage.ID,
  parentSessionID: SessionID,
  childSessionID: SessionID,
  assignedSeq: NonNegativeInt,
  origin: Origin,
  input: Schema.Struct({
    state: Schema.Literals(["message", "inbox"]),
    seq: NonNegativeInt,
  }).pipe(optional),
}).annotate({ identifier: "CausalRevert.AssignmentFact" })

export interface ToolFact extends Schema.Schema.Type<typeof ToolFact> {}
export const ToolFact = Schema.Struct({
  sessionID: SessionID,
  seq: NonNegativeInt,
  origin: Origin,
}).annotate({ identifier: "CausalRevert.ToolFact" })

export interface Facts extends Schema.Schema.Type<typeof Facts> {}
export const Facts = Schema.Struct({
  boundary: Schema.Struct({
    sessionID: SessionID,
    messageID: SessionMessage.ID,
    seq: NonNegativeInt,
  }),
  sessions: Schema.Array(SessionFact),
  assignments: Schema.Array(AssignmentFact),
  tools: Schema.Array(ToolFact),
}).annotate({ identifier: "CausalRevert.Facts" })

export interface Participant extends Schema.Schema.Type<typeof Participant> {}
export const Participant = Schema.Struct({
  sessionID: SessionID,
  messageID: SessionMessage.ID.pipe(optional),
  pendingIDs: Schema.Array(SessionMessage.ID),
}).annotate({ identifier: "CausalRevert.Participant" })

export interface Plan extends Schema.Schema.Type<typeof Plan> {}
export const Plan = Schema.Struct({
  participants: Schema.Array(Participant),
  origins: Schema.Array(Origin),
  pendingOrigins: Schema.Array(Origin),
  discardedSessionIDs: Schema.Array(SessionID),
}).annotate({ identifier: "CausalRevert.Plan" })

export interface PlanEvent {
  /** Immutable provenance snapshot. Planning may be repeated when these facts change. */
  readonly facts: Facts
  /** Replace with a deterministic plan; do not perform I/O from the planning callback. */
  plan: Plan
}
