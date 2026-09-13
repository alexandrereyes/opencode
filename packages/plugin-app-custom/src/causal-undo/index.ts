import { CausalRevert } from "@opencode/plugin/session-revert"
import { Plugin } from "@opencode/plugin/effect"
import { Effect } from "effect"

export const registerCausalUndo = Effect.fn("CausalUndo.register")(function* (ctx: Plugin.Context) {
  yield* ctx.session.hook("revert.plan", (event) =>
    Effect.sync(() => {
      event.plan = plan(event.facts)
    }),
  )
})

export function plan(facts: CausalRevert.Facts): CausalRevert.Plan {
  const participants: CausalRevert.Participant[] = []
  const origins: CausalRevert.Origin[] = []
  const pendingOrigins: CausalRevert.Origin[] = []
  const discardedSessionIDs: CausalRevert.Plan["discardedSessionIDs"][number][] = []
  const sessions = new Map(facts.sessions.map((session) => [session.sessionID, session]))
  const assignments = Map.groupBy(facts.assignments, (assignment) => assignment.parentSessionID)
  const tools = Map.groupBy(facts.tools, (tool) => tool.sessionID)

  const visit = (parentSessionID: CausalRevert.Facts["boundary"]["sessionID"], from: number) => {
    for (const tool of tools.get(parentSessionID) ?? []) if (tool.seq >= from) origins.push(tool.origin)
    const links = (assignments.get(parentSessionID) ?? []).filter((assignment) => assignment.assignedSeq >= from)
    const childIDs = [...new Set(links.map((assignment) => assignment.childSessionID))]
    for (const childID of childIDs) {
      const child = sessions.get(childID)
      if (!child || child.parentID !== parentSessionID) continue
      const assigned = links.filter((assignment) => assignment.childSessionID === childID)
      const messages = assigned
        .filter((assignment) => assignment.input?.state === "message")
        .toSorted((a, b) => (a.input?.seq ?? 0) - (b.input?.seq ?? 0))
      const pending = assigned
        .filter((assignment) => assignment.input?.state === "inbox")
        .toSorted((a, b) => (a.input?.seq ?? 0) - (b.input?.seq ?? 0))
      const messageCut = messages[0]
      if (!messageCut && pending.length === 0) continue
      participants.push({
        sessionID: childID,
        ...(messageCut ? { messageID: messageCut.inputID } : {}),
        pendingIDs: pending.map((assignment) => assignment.inputID),
      })
      origins.push(...messages.map((assignment) => assignment.origin))
      pendingOrigins.push(...pending.map((assignment) => assignment.origin))
      if (!messageCut) continue
      if (
        (messageCut.input?.seq ?? Infinity) ===
        Math.min(child.firstMessageSeq ?? Infinity, child.firstInboxSeq ?? Infinity)
      )
        discardedSessionIDs.push(childID)
      visit(childID, messageCut.input?.seq ?? Infinity)
    }
  }

  visit(facts.boundary.sessionID, facts.boundary.seq)
  const pendingKeys = new Set(pendingOrigins.map(originKey))
  return CausalRevert.Plan.make({
    participants: participants.toSorted((a, b) => a.sessionID.localeCompare(b.sessionID)),
    origins: uniqueOrigins(origins.filter((origin) => !pendingKeys.has(originKey(origin)))),
    pendingOrigins: uniqueOrigins(pendingOrigins),
    discardedSessionIDs: [...new Set(discardedSessionIDs)].toSorted(),
  })
}

function uniqueOrigins(origins: readonly CausalRevert.Origin[]) {
  return [...new Map(origins.map((origin) => [originKey(origin), origin])).values()].toSorted((a, b) =>
    originKey(a).localeCompare(originKey(b)),
  )
}

function originKey(origin: CausalRevert.Origin) {
  return `${origin.parentSessionID}:${origin.messageID}:${origin.toolCallID}`
}
