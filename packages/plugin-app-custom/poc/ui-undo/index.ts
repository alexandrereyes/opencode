import { Schema } from "effect"

/**
 * Experimental public-API-only family undo orchestrator.
 *
 * This module is intentionally not exported by the production plugin. It accepts
 * the generated Promise client structurally, which keeps the candidate usable by
 * either a UI or a separately loaded experiment without Core/Server access.
 */

export interface SessionInfo {
  readonly id: string
  readonly parentID?: string
  readonly location: { readonly directory: string; readonly workspaceID?: string }
  readonly revert?: { readonly messageID: string }
}

export interface MessageInfo {
  readonly id: string
  readonly type: string
  readonly time: { readonly created: number }
  readonly content?: ReadonlyArray<unknown>
}

export interface InboxInfo {
  readonly id: string
  readonly type: string
}

export const Provenance = Schema.Struct({
  childSessionID: Schema.String,
  inputID: Schema.String,
  assignedSeq: Schema.Number,
  origin: Schema.NullOr(
    Schema.Struct({ parentSessionID: Schema.String, parentMessageID: Schema.String, toolCallID: Schema.String }),
  ),
})
export interface Provenance extends Schema.Schema.Type<typeof Provenance> {}

const Participant = Schema.Struct({
  sessionID: Schema.String,
  messageID: Schema.optional(Schema.String),
  pendingIDs: Schema.Array(Schema.String),
  files: Schema.Boolean,
  depth: Schema.Number,
})
export const Operation = Schema.Struct({
  version: Schema.Literal(1),
  rootSessionID: Schema.String,
  rootMessageID: Schema.String,
  phase: Schema.Literals(["planned", "staging", "staged", "failed"]),
  participants: Schema.Array(Participant),
  staged: Schema.Array(Schema.String),
  error: Schema.optional(Schema.String),
})
export interface Operation extends Schema.Schema.Type<typeof Operation> {}

const Coverage = Schema.Struct({ version: Schema.Literal(1), parentSessionID: Schema.String })
type Coverage = Schema.Schema.Type<typeof Coverage>

export const CaptureObservation = Schema.Union([
  Schema.Struct({
    kind: Schema.Literal("input"),
    sessionID: Schema.String,
    inputID: Schema.String,
  }),
  Schema.Struct({
    kind: Schema.Literal("origin"),
    parentSessionID: Schema.String,
    parentMessageID: Schema.String,
    toolCallID: Schema.String,
    childSessionID: Schema.String,
  }),
])
export type CaptureObservation = Schema.Schema.Type<typeof CaptureObservation>

export const LegacyAssignment = Schema.Struct({
  inputID: Schema.String,
  parentSessionID: Schema.String,
  childSessionID: Schema.String,
  assignedSeq: Schema.Number,
  messageID: Schema.String,
  toolCallID: Schema.String,
})
export interface LegacyAssignment extends Schema.Schema.Type<typeof LegacyAssignment> {}

const MigrationMarker = Schema.Struct({ version: Schema.Literal(1), rows: Schema.Number })
type MigrationMarker = Schema.Schema.Type<typeof MigrationMarker>

const AssignmentEvent = Schema.Struct({
  type: Schema.Literal("session.subagent.input.assigned"),
  durable: Schema.Struct({ seq: Schema.Number }),
  data: Schema.Struct({
    sessionID: Schema.String,
    childSessionID: Schema.String,
    inputID: Schema.String,
    origin: Schema.Struct({ messageID: Schema.String, toolCallID: Schema.String }),
  }),
})
const SyncedEvent = Schema.Struct({ type: Schema.Literal("log.synced"), aggregateID: Schema.String })
const DurableEvent = Schema.Struct({ durable: Schema.Struct({ aggregateID: Schema.String, seq: Schema.Number }) })

const ShellContent = Schema.Struct({
  type: Schema.Literal("tool"),
  state: Schema.Struct({ metadata: Schema.Struct({ shellID: Schema.String }) }),
})

export interface Storage {
  get(key: string): Promise<unknown>
  set(key: string, value: Operation | Provenance | Coverage | CaptureObservation | MigrationMarker): Promise<void>
  remove(key: string): Promise<void>
  scan(input: { prefix: string; after?: string; limit?: number }): Promise<{
    entries: ReadonlyArray<{ key: string; value: unknown }>
    next?: string
  }>
}

export interface PublicApi {
  readonly session: {
    list(input: {
      parentID: string
      limit: number
      order?: "asc"
      cursor?: string
    }): Promise<{ data: ReadonlyArray<SessionInfo>; cursor: { next?: string | null } }>
    get(input: { sessionID: string }): Promise<SessionInfo>
    interrupt(input: { sessionID: string; continue: false }): Promise<unknown>
    wait(input: { sessionID: string }): Promise<void>
    revert: {
      stage(input: { sessionID: string; messageID: string; files: boolean }): Promise<unknown>
      clear(input: { sessionID: string }): Promise<void>
      commit(input: { sessionID: string }): Promise<void>
    }
    inbox: {
      list(input: { sessionID: string }): Promise<ReadonlyArray<InboxInfo>>
      cancel(input: { sessionID: string; inboxID: string }): Promise<void>
    }
    log(input: { sessionID: string; after?: number; follow: false }): AsyncIterable<unknown>
  }
  readonly message: {
    list(input: {
      sessionID: string
      limit: number
      order?: "asc"
      cursor?: string
    }): Promise<{ data: ReadonlyArray<MessageInfo>; cursor: { next?: string | null } }>
  }
  readonly shell: {
    list(input: { location: SessionInfo["location"] }): Promise<{ data: ReadonlyArray<ShellInfo> }>
    remove(input: { id: string; location: SessionInfo["location"] }): Promise<void>
  }
}

interface ShellInfo {
  readonly id: string
  readonly metadata: Record<string, unknown>
}

export class UnsatisfiedError extends Error {
  readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.name = "UnsatisfiedError"
    this.code = code
  }
}

export class PublicApiUndo {
  constructor(
    private readonly api: PublicApi,
    private readonly storage: Storage,
    private readonly options?: { readonly stageOrder?: "descendants-first" | "root-first" },
  ) {}

  async recordProvenance(value: Provenance) {
    const decoded = Schema.decodeUnknownSync(Provenance)(value)
    await this.storage.set(provenanceKey(decoded.childSessionID, decoded.inputID), decoded)
  }

  /** Run against the custom backend before removing it; its public log is the migration source. */
  async migrateProvenance(rootSessionID: string, source: { assignmentEvents: true }) {
    if (!source.assignmentEvents) throw new UnsatisfiedError("migration-source", "Assignment events are required")
    const root = await this.api.session.get({ sessionID: rootSessionID })
    for (const parent of [root, ...(await this.descendants(root))]) {
      let synced = false
      let durable = false
      for await (const item of this.api.session.log({ sessionID: parent.id, follow: false })) {
        if (Schema.is(SyncedEvent)(item) && item.aggregateID === parent.id) synced = true
        if (Schema.is(DurableEvent)(item) && item.durable.aggregateID === parent.id) durable = true
        if (!Schema.is(AssignmentEvent)(item)) continue
        await this.recordProvenance({
          childSessionID: item.data.childSessionID,
          inputID: item.data.inputID,
          assignedSeq: item.durable.seq,
          origin: {
            parentSessionID: item.data.sessionID,
            parentMessageID: item.data.origin.messageID,
            toolCallID: item.data.origin.toolCallID,
          },
        })
      }
      if (!synced) throw new UnsatisfiedError("migration-incomplete", `Public log did not sync ${parent.id}`)
      if (!durable)
        throw new UnsatisfiedError(
          "migration-history-unavailable",
          `Public log did not replay history for ${parent.id}`,
        )
      await this.storage.set(coverageKey(parent.id), { version: 1, parentSessionID: parent.id })
    }
  }

  async importLegacy(rows: ReadonlyArray<LegacyAssignment>) {
    const marker = await this.storage.get("ui-undo/migration/session-causal-v1")
    if (Schema.is(MigrationMarker)(marker)) return { migrated: 0, alreadyApplied: true as const }
    const decoded = Schema.decodeUnknownSync(Schema.Array(LegacyAssignment))(rows)
    for (const row of decoded)
      await this.recordProvenance({
        childSessionID: row.childSessionID,
        inputID: row.inputID,
        assignedSeq: row.assignedSeq,
        origin: {
          parentSessionID: row.parentSessionID,
          parentMessageID: row.messageID,
          toolCallID: row.toolCallID,
        },
      })
    for (const parentSessionID of new Set(decoded.map((row) => row.parentSessionID)))
      await this.storage.set(coverageKey(parentSessionID), { version: 1, parentSessionID })
    await this.storage.set("ui-undo/migration/session-causal-v1", { version: 1, rows: decoded.length })
    return { migrated: decoded.length, alreadyApplied: false as const }
  }

  async stage(input: { rootSessionID: string; rootMessageID: string }) {
    const operation = await this.plan(input)
    await this.storage.set(operationKey(input.rootSessionID), operation)

    const affected = [input.rootSessionID, ...operation.participants.map((item) => item.sessionID)]
    await Promise.all(affected.map((sessionID) => this.api.session.interrupt({ sessionID, continue: false })))
    await Promise.all(affected.map((sessionID) => this.api.session.wait({ sessionID })))
    await this.removeShells(operation)

    const root = {
      sessionID: input.rootSessionID,
      messageID: input.rootMessageID,
      pendingIDs: [],
      files: true,
      depth: 0,
    }
    const descendants = [...operation.participants].sort((a, b) => b.depth - a.depth)
    const order =
      this.options?.stageOrder === "root-first" ? [root, ...descendants.toReversed()] : [...descendants, root]
    const staged: string[] = []
    await this.storage.set(operationKey(input.rootSessionID), { ...operation, phase: "staging", staged })
    try {
      for (const participant of order) {
        if (!participant.messageID) continue
        await this.api.session.revert.stage({
          sessionID: participant.sessionID,
          messageID: participant.messageID,
          files: participant.files,
        })
        staged.push(participant.sessionID)
        await this.storage.set(operationKey(input.rootSessionID), { ...operation, phase: "staging", staged })
      }
    } catch (error) {
      const rollbackErrors: unknown[] = []
      for (const sessionID of staged.toReversed()) {
        try {
          await this.api.session.revert.clear({ sessionID })
        } catch (rollbackError) {
          rollbackErrors.push(rollbackError)
        }
      }
      const failure = rollbackErrors.length
        ? new AggregateError([error, ...rollbackErrors], "Undo failed and compensating clear was incomplete")
        : error
      await this.storage.set(operationKey(input.rootSessionID), {
        ...operation,
        phase: "failed",
        staged,
        error: failure instanceof Error ? failure.message : String(failure),
      })
      throw failure
    }
    const result = { ...operation, phase: "staged" as const, staged }
    await this.storage.set(operationKey(input.rootSessionID), result)
    return result
  }

  async redo(rootSessionID: string) {
    const operation = requireOperation(await this.storage.get(operationKey(rootSessionID)))
    if (operation.phase !== "staged") throw new UnsatisfiedError("operation-not-staged", "Undo is not fully staged")
    for (const sessionID of operation.staged.toReversed()) await this.api.session.revert.clear({ sessionID })
    await this.storage.remove(operationKey(rootSessionID))
  }

  async commit(rootSessionID: string) {
    const operation = requireOperation(await this.storage.get(operationKey(rootSessionID)))
    if (operation.phase !== "staged") throw new UnsatisfiedError("operation-not-staged", "Undo is not fully staged")
    for (const participant of operation.participants)
      for (const pendingID of participant.pendingIDs)
        await this.api.session.inbox.cancel({ sessionID: participant.sessionID, inboxID: pendingID })
    for (const sessionID of operation.staged) await this.api.session.revert.commit({ sessionID })
    await this.storage.remove(operationKey(rootSessionID))
  }

  async commitForMember(sessionID: string, options?: { nativeWillCommit?: boolean }) {
    const matches = (await this.operations()).filter(
      (operation) =>
        operation.phase === "staged" &&
        (operation.rootSessionID === sessionID ||
          operation.participants.some((participant) => participant.sessionID === sessionID)),
    )
    if (matches.length > 1)
      throw new UnsatisfiedError("operation-conflict", `Session ${sessionID} belongs to multiple staged operations`)
    const operation = matches[0]
    if (!operation) return
    if (!options?.nativeWillCommit) return this.commit(operation.rootSessionID)
    for (const participant of operation.participants)
      for (const pendingID of participant.pendingIDs)
        await this.api.session.inbox.cancel({ sessionID: participant.sessionID, inboxID: pendingID })
    for (const stagedID of operation.staged)
      if (stagedID !== sessionID) await this.api.session.revert.commit({ sessionID: stagedID })
    await this.storage.remove(operationKey(operation.rootSessionID))
  }

  async cancelLateSubagentNotification(input: { sessionID: string; inboxID: string; childSessionID: string }) {
    const operation = (await this.operations()).find(
      (item) =>
        item.phase !== "failed" &&
        item.rootSessionID === input.sessionID &&
        item.participants.some((participant) => participant.sessionID === input.childSessionID),
    )
    if (!operation) return false
    await this.api.session.inbox.cancel({ sessionID: input.sessionID, inboxID: input.inboxID })
    return true
  }

  async plan(input: { rootSessionID: string; rootMessageID: string }): Promise<Operation> {
    const root = await this.api.session.get({ sessionID: input.rootSessionID })
    const descendants = await this.descendants(root)
    const stored = await this.storage.get(operationKey(root.id))
    const owned = Schema.is(Operation)(stored) && stored.phase === "staged" ? new Set(stored.staged) : new Set<string>()
    const messages = new Map<string, ReadonlyArray<MessageInfo>>()
    const pending = new Map<string, ReadonlyArray<InboxInfo>>()
    for (const session of [root, ...descendants]) {
      messages.set(session.id, await this.messages(session.id))
      pending.set(session.id, await this.api.session.inbox.list({ sessionID: session.id }))
    }
    if (!messages.get(root.id)?.some((message) => message.id === input.rootMessageID))
      throw new UnsatisfiedError("boundary-not-found", `Message ${input.rootMessageID} is not publicly visible`)

    const provenance = await this.provenance()
    for (const child of descendants) {
      if (!child.parentID) continue
      const inputs = [
        ...(messages.get(child.id) ?? []).filter((message) => message.type === "user" || message.type === "synthetic"),
        ...(pending.get(child.id) ?? []),
      ]
      const covered = Schema.is(Coverage)(await this.storage.get(coverageKey(child.parentID)))
      const missing = inputs.find((item) => !covered && !provenance.has(provenanceKey(child.id, item.id)))
      if (missing)
        throw new UnsatisfiedError(
          "provenance-unavailable",
          `Public history does not identify the parent tool call for ${child.id}/${missing.id}`,
        )
    }

    const boundary = new Map<string, string>([[root.id, input.rootMessageID]])
    const participants: Array<Operation["participants"][number]> = []
    const queue = descendants.filter((session) => session.parentID === root.id)
    while (queue.length) {
      const child = queue.shift()
      if (!child?.parentID) continue
      const parentBoundary = boundary.get(child.parentID)
      if (!parentBoundary) continue
      const parentMessages = messages.get(child.parentID) ?? []
      const boundaryIndex = parentMessages.findIndex((message) => message.id === parentBoundary)
      const links = [...provenance.values()].filter(
        (item) =>
          item.childSessionID === child.id &&
          item.origin?.parentSessionID === child.parentID &&
          parentMessages.findIndex((message) => message.id === item.origin?.parentMessageID) >= boundaryIndex,
      )
      const delivered = links
        .filter((link) => (messages.get(child.id) ?? []).some((message) => message.id === link.inputID))
        .sort(
          (a, b) =>
            (messages.get(child.id) ?? []).findIndex((message) => message.id === a.inputID) -
            (messages.get(child.id) ?? []).findIndex((message) => message.id === b.inputID),
        )
      const queued = links.filter((link) => (pending.get(child.id) ?? []).some((item) => item.id === link.inputID))
      if (delivered.length || queued.length) {
        if (child.revert && !owned.has(child.id))
          throw new UnsatisfiedError(
            "independent-revert-present",
            `Oracle also rejects replacing selected child ${child.id}'s independent marker`,
          )
        const cut = delivered[0]?.inputID
        if (cut) boundary.set(child.id, cut)
        participants.push({
          sessionID: child.id,
          ...(cut ? { messageID: cut } : {}),
          pendingIDs: queued.map((item) => item.inputID),
          files: sameLocation(root.location, child.location),
          depth: depth(child, descendants),
        })
      }
      queue.push(...descendants.filter((session) => session.parentID === child.id))
    }
    return {
      version: 1,
      rootSessionID: root.id,
      rootMessageID: input.rootMessageID,
      phase: "planned",
      participants,
      staged: [],
    }
  }

  private async descendants(root: SessionInfo) {
    const result: SessionInfo[] = []
    const queue = [root.id]
    while (queue.length) {
      const parentID = queue.shift()
      if (!parentID) continue
      let cursor: string | undefined
      do {
        const page = await this.api.session.list({
          parentID,
          limit: 100,
          order: cursor ? undefined : "asc",
          cursor,
        })
        result.push(...page.data)
        queue.push(...page.data.map((session) => session.id))
        cursor = page.cursor.next ?? undefined
      } while (cursor)
    }
    return result
  }

  private async messages(sessionID: string) {
    const result: MessageInfo[] = []
    let cursor: string | undefined
    do {
      const page = await this.api.message.list({
        sessionID,
        limit: 100,
        order: cursor ? undefined : "asc",
        cursor,
      })
      result.push(...page.data)
      cursor = page.cursor.next ?? undefined
    } while (cursor)
    return result
  }

  private async provenance() {
    const result = new Map<string, Provenance>()
    let after: string | undefined
    do {
      const page = await this.storage.scan({ prefix: "ui-undo/provenance/", after, limit: 100 })
      for (const entry of page.entries) if (isProvenance(entry.value)) result.set(entry.key, entry.value)
      after = page.next
    } while (after)
    return result
  }

  private async operations() {
    const result: Operation[] = []
    let after: string | undefined
    do {
      const page = await this.storage.scan({ prefix: "ui-undo/operation/", after, limit: 100 })
      result.push(...page.entries.map((entry) => entry.value).filter(Schema.is(Operation)))
      after = page.next
    } while (after)
    return result
  }

  private async removeShells(operation: Operation) {
    const boundaries = [
      { sessionID: operation.rootSessionID, messageID: operation.rootMessageID },
      ...operation.participants.flatMap((participant) =>
        participant.messageID ? [{ sessionID: participant.sessionID, messageID: participant.messageID }] : [],
      ),
    ]
    const shellIDs = new Set<string>()
    for (const boundary of boundaries) {
      const messages = await this.messages(boundary.sessionID)
      const index = messages.findIndex((message) => message.id === boundary.messageID)
      for (const message of messages.slice(index))
        for (const content of message.content ?? []) {
          if (Schema.is(ShellContent)(content)) shellIDs.add(content.state.metadata.shellID)
        }
    }
    const sessionIDs = boundaries.map((boundary) => boundary.sessionID)
    const sessions = await Promise.all(sessionIDs.map((sessionID) => this.api.session.get({ sessionID })))
    const locations = [
      ...new Map(sessions.map((session) => [locationKey(session.location), session.location])).values(),
    ]
    for (const location of locations) {
      const shells = await this.api.shell.list({ location })
      for (const shell of shells.data)
        if (shellIDs.has(shell.id)) await this.api.shell.remove({ id: shell.id, location })
    }
  }
}

function depth(session: SessionInfo, sessions: ReadonlyArray<SessionInfo>): number {
  const byID = new Map(sessions.map((item) => [item.id, item]))
  const parent = session.parentID ? byID.get(session.parentID) : undefined
  return parent ? depth(parent, sessions) + 1 : 1
}

function sameLocation(left: SessionInfo["location"], right: SessionInfo["location"]) {
  return left.directory === right.directory && left.workspaceID === right.workspaceID
}

function locationKey(location: SessionInfo["location"]) {
  return `${location.directory}\0${location.workspaceID ?? ""}`
}

function provenanceKey(sessionID: string, inputID: string) {
  return `ui-undo/provenance/${sessionID}/${inputID}`
}

function coverageKey(sessionID: string) {
  return `ui-undo/coverage/${sessionID}`
}

function operationKey(sessionID: string) {
  return `ui-undo/operation/${sessionID}`
}

const isProvenance = Schema.is(Provenance)

function requireOperation(value: unknown): Operation {
  if (!Schema.is(Operation)(value)) throw new UnsatisfiedError("operation-missing", "No valid undo operation exists")
  return value
}
