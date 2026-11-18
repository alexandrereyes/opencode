import { Effect } from "effect"
import { Resources } from "./rpc.js"

/**
 * rev. 2026-11-18 (`docs/resources.md`, "Owners"): who a resource belongs to, as this server lists it. The hub keeps the
 * last session whose command named it; here that owner expires when its session is gone from this server or has not
 * used the resource for `limits.ownerIdleMs`, and a process using it now (`Resource.test`) names its own: the session in
 * its environment (`source: process`), else the most recent session whose worktree folder it runs in (`source: folder`,
 * `probable`). An agent using it now (`agent`, `user`) keeps its owner. Titles come along so other sessions can name it.
 */
export interface Known {
  readonly sessionID: string
  readonly rootSessionID: string
  readonly agent?: string
  readonly title?: string
  readonly rootTitle?: string
}

export interface Sessions {
  /** The session and its family; undefined when this server has no such session (deleted, or another server's). */
  readonly get: (sessionID: string) => Effect.Effect<Known | undefined>
  /** Sessions whose directory ends in `folder`, most recently updated first. */
  readonly inFolder: (folder: string) => Effect.Effect<readonly Known[]>
}

export const present = Effect.fn("Resources.present")(function* (
  resources: readonly Resources.Resource[],
  sessions: Sessions,
  now: number,
) {
  return yield* Effect.forEach(resources, (resource) => presentOne(resource, sessions, now))
})

const presentOne = Effect.fn("Resources.presentOne")(function* (
  resource: Resources.Resource,
  sessions: Sessions,
  now: number,
) {
  const { owner: stored, previousOwner: _, ...rest } = resource
  const busy = resource.state === "agent" || resource.state === "user"
  const known = stored ? yield* sessions.get(stored.sessionID) : undefined
  const current =
    stored && known && (busy || now - resource.lastUsedAt < Resources.limits.ownerIdleMs)
      ? owner(stored, known, { source: "command" })
      : undefined
  const expired = stored && !current ? owner(stored, known, {}) : undefined
  const tester = resource.test && resource.state !== "stopped" && resource.state !== "gone"
    ? yield* testOwner(resource.test, sessions)
    : undefined
  // An agent's command on it now outranks a test; a test outranks an older owner.
  const chosen = busy ? (current ?? tester) : (tester ?? current)
  const previous = chosen && current && chosen !== current && current.rootSessionID !== chosen.rootSessionID ? current : expired
  return {
    ...rest,
    ...(chosen ? { owner: chosen } : {}),
    ...(previous && previous.rootSessionID !== chosen?.rootSessionID ? { previousOwner: previous } : {}),
  } satisfies Resources.Resource
})

const testOwner = Effect.fn("Resources.testOwner")(function* (test: Resources.Test, sessions: Sessions) {
  if (test.sessionID) {
    const known = yield* sessions.get(test.sessionID)
    if (known) return owner(known, known, { source: "process" })
  }
  if (!test.folder) return undefined
  const [first] = yield* sessions.inFolder(test.folder)
  return first ? owner(first, first, { source: "folder", probable: true }) : undefined
})

function owner(
  base: Pick<Resources.Owner, "sessionID" | "rootSessionID" | "agent">,
  known: Known | undefined,
  how: Pick<Resources.Owner, "source" | "probable">,
): Resources.Owner {
  const agent = base.agent ?? known?.agent
  return {
    sessionID: base.sessionID,
    rootSessionID: known?.rootSessionID ?? base.rootSessionID,
    ...(agent ? { agent } : {}),
    ...(known?.title ? { title: known.title } : {}),
    ...(known?.rootTitle ? { rootTitle: known.rootTitle } : {}),
    ...how,
  }
}
