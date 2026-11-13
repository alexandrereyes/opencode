import { Schema } from "effect"
import { LiveActivity } from "./rpc.js"
import { clip, limits, type Derived } from "./tracker.js"

/** Contract: `packages/plugin-app-custom/docs/unified-summary.md`. */

/** The link's version: a summary with another number is not read, and its server counts as away. */
export const protocol = 1

/**
 * What a server publishes to the one that writes the "Todos" activity: always its **own** state, never a joined one,
 * so two servers reading each other cannot loop.
 */
export interface Summary extends Schema.Schema.Type<typeof Summary> {}
export const Summary = Schema.Struct({
  protocol: Schema.Literal(protocol),
  instanceID: Schema.String.check(Schema.isMinLength(1)),
  name: Schema.String,
  /** The Live Activity state before the 4 KB fitting: the lists already cut to the contract's limits. */
  state: LiveActivity.AgentsState,
  /** `sessionID` → the time each `state.sessions` row is ordered by inside its status (`Derived.order`). */
  order: Schema.Record(Schema.String, Schema.Number),
  /** Every urgency key of the server (`Derived.marks`), untruncated. */
  marks: Schema.Array(Schema.String),
}).annotate({ identifier: "LiveActivity.Summary" })

export const decodeSummary = Schema.decodeUnknownOption(Summary)

export function summary(
  identity: { readonly instanceID: string; readonly name: string },
  derived: Pick<Derived, "state" | "order" | "marks">,
): Summary {
  return {
    protocol,
    instanceID: identity.instanceID,
    name: identity.name,
    state: derived.state,
    order: Object.fromEntries(derived.order),
    marks: [...derived.marks.keys()],
  }
}

/** A server the writer reads; without `summary`, it has not answered for a while and is shown as offline. */
export type Peer = {
  readonly instanceID: string
  readonly name: string
  readonly summary?: Summary
}

const joining = new Set(["de", "da", "do", "das", "dos", "e", "of", "the", "and"])

/** The badge's initials, by the apps' rule (`ServerSwitcher.initials`): "Linux BRS" → LB, "Mac de Alexandre" → MA. */
export function initials(name: string) {
  const words = name.split(/[^\p{L}\p{N}]+/u).filter(Boolean)
  const named = words.filter((word) => !joining.has(word.toLowerCase()))
  const kept = named.length > 0 ? named : words
  const letters = kept.length > 1 ? kept.slice(0, 2).map((word) => Array.from(word)[0]) : Array.from(kept[0] ?? name)
  return letters.slice(0, 2).join("").toUpperCase()
}

/** The card's `host` for builds that do not read `servers`: "Linux BRS + Mac", "Linux BRS · Mac offline". */
function label(servers: readonly LiveActivity.Server[]) {
  const online = servers.filter((server) => !server.offline).map((server) => server.name)
  const offline = servers.filter((server) => server.offline).map((server) => `${server.name} offline`)
  return clip([online.join(" + "), ...offline].join(" · "), limits.host)
}

const statusRank: Record<LiveActivity.RowStatus, number> = {
  question: 0,
  permission: 1,
  browser: 2,
  failed: 3,
  working: 4,
  idle: 5,
}
const needRank: Record<LiveActivity.NeedKind, number> = { question: 0, permission: 1, browser: 2, failed: 3, unread: 4 }
const waits = (kind: string) => kind === "question" || kind === "permission" || kind === "browser"

/**
 * One state for the "Todos" activity from the writer's own summary and its peers': counts added, lists interleaved by
 * the tracker's order and cut to the same limits, every row tagged with its server. A peer without a summary only
 * appears in `servers`, as offline. Pure: the result depends on its input alone. Ties go to the writer, then to the
 * peers in the given order, then to the session ID.
 */
export function join(input: { readonly self: Summary; readonly peers: readonly Peer[] }): {
  readonly state: LiveActivity.AgentsState
  readonly marks: ReadonlyMap<string, true>
} {
  // A peer that turns out to be this server (its socket points back here) would count every session twice.
  const peers = input.peers.filter(
    (peer, index, all) =>
      peer.instanceID !== input.self.instanceID &&
      all.findIndex((item) => item.instanceID === peer.instanceID) === index,
  )
  const parts = [input.self, ...peers.flatMap((peer) => (peer.summary ? [peer.summary] : []))]
  const position = new Map(parts.map((part, index) => [part.instanceID, index]))
  const tie = (a: { server: string; sessionID: string }, b: { server: string; sessionID: string }) =>
    (position.get(a.server) ?? 0) - (position.get(b.server) ?? 0) || a.sessionID.localeCompare(b.sessionID)
  const sum = (read: (state: LiveActivity.AgentsState) => number) =>
    parts.reduce((total, part) => total + read(part.state), 0)

  const holder = parts.find((part) => part.state.focus)
  const focus = holder?.state.focus ? { ...holder.state.focus, server: holder.instanceID } : undefined
  const focused = (row: { server: string; sessionID: string }) =>
    focus !== undefined && row.server === focus.server && row.sessionID === focus.sessionID

  const attention = parts
    .flatMap((part) => part.state.attention.map((item) => ({ ...item, server: part.instanceID })))
    .toSorted((a, b) => a.since - b.since || tie(a, b))
  const needs = parts
    .flatMap((part) => (part.state.needs ?? []).map((item) => ({ ...item, server: part.instanceID })))
    .toSorted(
      (a, b) =>
        needRank[a.kind] - needRank[b.kind] || (waits(a.kind) ? a.since - b.since : b.since - a.since) || tie(a, b),
    )
  const sessions = parts
    .flatMap((part) =>
      part.state.sessions.map((row) => ({
        row: { ...row, server: part.instanceID },
        at: part.order[row.sessionID] ?? 0,
      })),
    )
    .toSorted(
      (a, b) =>
        statusRank[a.row.status] - statusRank[b.row.status] ||
        (a.row.status === "working" ? Number(focused(b.row)) - Number(focused(a.row)) : 0) ||
        (waits(a.row.status) ? a.at - b.at : b.at - a.at) ||
        tie(a.row, b.row),
    )
    .map((item) => item.row)

  const servers: LiveActivity.Server[] = [
    { instanceID: input.self.instanceID, name: input.self.name, short: initials(input.self.name) },
    ...peers.map((peer) => ({
      instanceID: peer.instanceID,
      name: peer.name,
      short: initials(peer.name),
      ...(peer.summary ? {} : { offline: true }),
    })),
  ]
  const browser = sum((state) => state.counts.browser ?? 0)
  return {
    state: {
      v: 1,
      updatedAt: input.self.state.updatedAt,
      host: label(servers),
      counts: {
        working: sum((state) => state.counts.working),
        question: sum((state) => state.counts.question),
        permission: sum((state) => state.counts.permission),
        failed: sum((state) => state.counts.failed),
        idle: sum((state) => state.counts.idle),
        unread: sum((state) => state.counts.unread ?? 0),
        ...(browser > 0 ? { browser } : {}),
      },
      activeTotal: sum((state) => state.activeTotal),
      ...(focus ? { focus } : {}),
      attention: attention.slice(0, limits.attention),
      attentionTotal: sum((state) => state.attentionTotal),
      sessions: sessions.slice(0, limits.rows),
      needs: needs.slice(0, limits.needs),
      servers,
    },
    // Qualified by server: an imported session has the same ID on both.
    marks: new Map(parts.flatMap((part) => part.marks.map((mark) => [`${part.instanceID}/${mark}`, true] as const))),
  }
}
