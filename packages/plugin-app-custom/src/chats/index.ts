import { randomUUID } from "node:crypto"
import fs from "node:fs/promises"
import type { Stats } from "node:fs"
import os from "node:os"
import path from "node:path"
import { Plugin } from "@opencode/plugin/effect"
import { AbsolutePath } from "@opencode/schema/schema"
import { Session } from "@opencode/schema/session"
import { Effect, Schema, Semaphore, Stream } from "effect"
import { Chats } from "./rpc.js"

const key = "chats:allocations"
const Allocation = Schema.Struct({
  id: Schema.String,
  directory: AbsolutePath,
  createdAt: Schema.Number,
  revision: Schema.Number,
  status: Schema.Literals(["reserved", "pending", "confirmed", "cleanup"]),
  sessionID: Schema.optional(Session.ID),
})
const Allocations = Schema.Array(Allocation)
const LegacyAllocations = Schema.Array(
  Schema.Struct({
    directory: AbsolutePath,
    createdAt: Schema.Number,
    sessionID: Schema.optional(Session.ID),
    pendingCleanup: Schema.optional(Schema.Boolean),
  }),
)
export type Allocation = typeof Allocation.Type
const decodeStored = Schema.decodeUnknownSync(Schema.Union([Allocations, LegacyAllocations]))
const encode = Schema.encodeSync(Allocations)

function decode(value: unknown): Allocation[] {
  return decodeStored(value).map((item) => {
    if ("status" in item) return item
    return {
      id: randomUUID(),
      directory: item.directory,
      createdAt: item.createdAt,
      revision: 0,
      status: item.pendingCleanup ? "cleanup" : item.sessionID ? "confirmed" : "reserved",
      sessionID: item.sessionID,
    }
  })
}

export const registerChats = Effect.fn("Chats.register")(function* (ctx: Plugin.Context) {
  yield* ctx.storage.update(key, (current) => [encode(decode(current ?? [])), undefined])
  const reconcileLock = Semaphore.makeUnsafe(1)
  const registration = ctx.rpc
    .register(Chats.Definition, {
      info: (_, context) => operation(() => chatRoot(), context.error).pipe(Effect.map((root) => ({ root }))),
      allocate: (_, context) =>
        operation(async () => allocateChat(await chatRoot()), context.error).pipe(
          Effect.tap((allocation) =>
            ctx.storage.update(key, (current) => [
              encode([
                ...decode(current ?? []),
                { ...allocation, createdAt: Date.now(), revision: 0, status: "reserved" as const },
              ]),
              undefined,
            ]),
          ),
        ),
      claim: (input, context) => mutation(ctx, input, "pending", context.error),
      confirm: (input, context) => mutation(ctx, input, "confirmed", context.error),
    })
    .pipe(Effect.orDie, Effect.asVoid)

  yield* activateChatRuntime(
    registration,
    reconcileAllocations(ctx, reconcileLock).pipe(Effect.catchCause(Effect.logWarning)),
    ctx.event.subscribe().pipe(
      Stream.filter((event) => event.type === "session.deleted"),
      Stream.runForEach((event) => markDeletedAndReconcile(ctx, reconcileLock, event.data.sessionID)),
      Effect.catchCause((cause) => Effect.logWarning("managed chat cleanup subscription failed", { cause })),
    ),
  )
})

export function activateChatRuntime<R1, R2, R3>(
  registration: Effect.Effect<void, never, R1>,
  reconcile: Effect.Effect<void, never, R2>,
  consume: Effect.Effect<void, never, R3>,
) {
  return Effect.gen(function* () {
    yield* registration
    yield* startChatLifecycle(reconcile, consume)
  })
}

export function startChatLifecycle<R1, R2>(
  reconcile: Effect.Effect<void, never, R1>,
  consume: Effect.Effect<void, never, R2>,
) {
  return Effect.gen(function* () {
    yield* reconcile.pipe(Effect.forkScoped)
    yield* consume.pipe(Effect.forkScoped)
  })
}

function operation<A, E>(
  run: () => Promise<A>,
  error: (type: "operation_failed", message: string, data: { message: string }) => E,
) {
  return Effect.tryPromise({ try: run, catch: (cause) => new Error(message(cause)) }).pipe(
    Effect.mapError((cause) => error("operation_failed", cause.message, { message: cause.message })),
  )
}

function mutation<E>(
  ctx: Pick<Plugin.Context, "storage">,
  input: { id: string; directory: AbsolutePath; sessionID: Session.ID },
  status: "pending" | "confirmed",
  error: (type: "operation_failed", message: string, data: { message: string }) => E,
) {
  return ctx.storage
    .update(key, (current) => {
      const allocations = decode(current ?? [])
      const target = allocations.find((item) => item.id === input.id && item.directory === input.directory)
      const conflict = mutationConflict(target, input.sessionID, status)
      if (conflict) return [encode(allocations), conflict]
      return [
        encode(
          allocations.map((item) =>
            item.id === input.id
              ? {
                  ...item,
                  sessionID: input.sessionID,
                  status: transitionStatus(item.status, status),
                  revision: item.revision + 1,
                }
              : item,
          ),
        ),
        undefined,
      ]
    })
    .pipe(
      Effect.flatMap((conflict) => (conflict ? Effect.fail(new Error(conflict)) : Effect.succeed({}))),
      Effect.mapError((cause) => {
        const value = message(cause)
        return error("operation_failed", value, { message: value })
      }),
    )
}

export function transitionStatus(current: Allocation["status"], requested: "pending" | "confirmed") {
  if (current === "confirmed" && requested === "pending") return current
  return requested
}

export function mutationConflict(
  target: Allocation | undefined,
  sessionID: Session.ID,
  status: "pending" | "confirmed",
) {
  if (!target) return "Unknown chat allocation"
  if (target.status === "cleanup") return "Chat allocation is being cleaned up"
  if (target.sessionID && target.sessionID !== sessionID) return "Chat allocation is already claimed"
  if (status === "confirmed" && target.status !== "pending" && target.status !== "confirmed")
    return "Chat allocation is not pending creation"
}

function markDeletedAndReconcile(ctx: Plugin.Context, lock: Semaphore.Semaphore, sessionID: Session.ID) {
  return ctx.storage
    .update(key, (current) => [
      encode(markDeleted(decode(current ?? []), sessionID)),
      undefined,
    ])
    .pipe(Effect.andThen(reconcileAllocations(ctx, lock)), Effect.catchCause(Effect.logWarning))
}

export function markDeleted(allocations: readonly Allocation[], sessionID: Session.ID) {
  return allocations.map((item) =>
    (item.status === "confirmed" || item.status === "pending") && item.sessionID === sessionID
      ? { ...item, status: "cleanup" as const, revision: item.revision + 1 }
      : item,
  )
}

export interface ChatReconcileContext {
  readonly storage: Pick<Plugin.Context["storage"], "get" | "update">
  readonly session: Pick<Plugin.Context["session"], "scan">
}

export function reconcileAllocations(ctx: ChatReconcileContext, lock = Semaphore.makeUnsafe(1)) {
  return lock.withPermit(
    Effect.gen(function* () {
      const snapshot = decode((yield* ctx.storage.get(key)) ?? [])
      if (!snapshot.some((item) => item.status !== "reserved")) return
      const sessions = yield* scanAll(ctx.session.scan)
      const directories = sessions.map((item) => item.session.location.directory)
      const candidates = yield* ctx.storage.update(key, (current) => {
        const value = decode(current ?? [])
        const next = reconcileStatesFromSnapshot(
          value,
          snapshot,
          sessions.map((item) => ({ id: item.session.id, directory: item.session.location.directory })),
        )
        const revisions = new Map(snapshot.map((item) => [item.id, item.revision]))
        return [
          encode(next),
          next.filter(
            (item) =>
              item.status === "cleanup" &&
              value.some((current) => current.id === item.id && revisions.get(item.id) === current.revision),
          ),
        ]
      })
      const results = yield* Effect.promise(() =>
        Promise.all(
          candidates.map(async (allocation) => ({
            id: allocation.id,
            directory: allocation.directory,
            removed:
              !directories.some(
                (directory) => directory === allocation.directory || isDescendant(allocation.directory, directory),
              ) && (await removeAllocation(allocation.directory)),
          })),
        ),
      )
      yield* ctx.storage.update(key, (current) => {
        return [encode(applyRemovalResults(decode(current ?? []), results)), undefined]
      })
    }),
  )
}

export function applyRemovalResults(
  current: readonly Allocation[],
  results: readonly { id: string; directory: AbsolutePath; removed: boolean }[],
) {
  const removed = new Map(results.filter((item) => item.removed).map((item) => [item.id, item.directory] as const))
  return current.filter((item) => !(item.status === "cleanup" && removed.get(item.id) === item.directory))
}

export function markMissingOwners(allocations: readonly Allocation[], sessionIDs: readonly Session.ID[]) {
  const existing = new Set(sessionIDs)
  return allocations.map((item) =>
    item.status === "confirmed" && item.sessionID && !existing.has(item.sessionID)
      ? { ...item, status: "cleanup" as const }
      : item,
  )
}

export function reconcileStates(
  allocations: readonly Allocation[],
  sessions: readonly { id: Session.ID; directory: string }[],
) {
  const byID = new Map(sessions.map((session) => [session.id, session.directory]))
  return markMissingOwners(
    allocations.map((item) =>
      item.status === "pending" && item.sessionID && byID.get(item.sessionID) === item.directory
        ? { ...item, status: "confirmed" as const }
        : item,
    ),
    sessions.map((session) => session.id),
  )
}

export function reconcileStatesFromSnapshot(
  current: readonly Allocation[],
  snapshot: readonly Allocation[],
  sessions: readonly { id: Session.ID; directory: string }[],
) {
  const revisions = new Map(snapshot.map((item) => [item.id, item.revision]))
  const stable = current.filter((item) => revisions.get(item.id) === item.revision)
  const reconciled = new Map(reconcileStates(stable, sessions).map((item) => [item.id, item]))
  return current.map((item) => reconciled.get(item.id) ?? item)
}

function scanAll(scan: Plugin.Context["session"]["scan"]) {
  return Effect.gen(function* () {
    const rows = []
    let after: Session.ID | undefined
    for (;;) {
      const page = yield* scan({ after, limit: 500 })
      rows.push(...page.data)
      if (!page.next || page.next === after) return rows
      after = page.next
    }
  })
}

export async function chatRoot() {
  const data = process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share")
  const root = path.resolve(data, "opencode", "chats")
  await fs.mkdir(root, { recursive: true, mode: 0o700 })
  return AbsolutePath.make(path.normalize(await fs.realpath(root)))
}

export async function allocateChat(root: string, now = new Date(), id = randomUUID()) {
  const canonicalRoot = path.normalize(await fs.realpath(root))
  const day = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, "0"),
    String(now.getDate()).padStart(2, "0"),
  ].join("-")
  const parent = path.join(canonicalRoot, day)
  await fs.mkdir(parent, { recursive: true, mode: 0o700 })
  const directory = path.join(parent, `session-${id}`)
  await fs.mkdir(directory, { mode: 0o700 })
  const canonical = path.normalize(await fs.realpath(directory))
  if (!isDescendant(canonicalRoot, canonical)) throw new Error("Invalid chat allocation")
  return { id, directory: AbsolutePath.make(canonical) }
}

export async function removeAllocation(directory: string, root?: string) {
  const base = root ? AbsolutePath.make(path.normalize(await fs.realpath(root))) : await chatRoot()
  if (!isDescendant(base, directory)) return false
  const stat = await statAllocation(directory)
  if (!stat) return true
  if (!stat.isDirectory() || stat.isSymbolicLink()) return false
  const canonical = path.normalize(await fs.realpath(directory))
  if (canonical !== path.normalize(directory) || !isDescendant(base, canonical)) return false
  await fs.rm(canonical, { recursive: true })
  return true
}

export function statAllocation(directory: string, lstat: (directory: string) => Promise<Stats> = fs.lstat) {
  return lstat(directory).catch((error) => {
    if (error instanceof globalThis.Error && "code" in error && error.code === "ENOENT") return undefined
    throw error
  })
}

function isDescendant(root: string, directory: string) {
  const relative = path.relative(root, directory)
  return !!relative && !relative.startsWith("..") && !path.isAbsolute(relative)
}

function message(value: unknown) {
  return value instanceof globalThis.Error ? value.message : String(value)
}
