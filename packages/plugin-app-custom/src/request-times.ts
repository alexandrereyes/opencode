import type { Plugin } from "@opencode/plugin/effect"
import type { Form } from "@opencode/schema/form"
import type { Location } from "@opencode/schema/location"
import type { Permission } from "@opencode/schema/permission"
import { Clock, Effect, Stream } from "effect"

/** When the host announced the request, or when this process first read it if the announcement was not seen. */
type Created = { readonly created?: number }

export interface PendingSnapshot {
  readonly location: Location.Ref
  readonly permissions: ReadonlyArray<Permission.Request & Created>
  readonly forms: ReadonlyArray<Form.Info & Created>
}

export interface Requests {
  readonly pending: () => Effect.Effect<ReadonlyArray<PendingSnapshot>>
}

declare global {
  var opencodeCustomRequestTimes: Map<string, number> | undefined
}

/**
 * Announcement times by permission or form ID. A global slot, not module scope: the plugin loader evaluates this
 * module again for every Location, while `pending` reports the requests of every live Location.
 */
function times() {
  globalThis.opencodeCustomRequestTimes ??= new Map()
  return globalThis.opencodeCustomRequestTimes
}

/** Records announcement times from the process-wide event stream until this plugin instance unloads. */
export const trackRequestTimes = (event: Plugin.Context["event"]) =>
  event
    .subscribe({ types: ["permission.asked", "permission.replied", "form.created", "form.replied", "form.cancelled"] })
    .pipe(
      Stream.runForEach((item) =>
        Effect.sync(() => {
          const known = times()
          if (item.type === "permission.asked" && !known.has(item.data.id)) known.set(item.data.id, item.created)
          if (item.type === "form.created" && !known.has(item.data.form.id)) known.set(item.data.form.id, item.created)
          if (item.type === "permission.replied") known.delete(item.data.requestID)
          if (item.type === "form.replied" || item.type === "form.cancelled") known.delete(item.data.id)
        }),
      ),
      Effect.catchCause((cause) => Effect.logWarning("Request time tracking failed", { cause })),
      Effect.forkScoped({ startImmediately: true }),
    )

/** Adds announcement times to pending requests; a request read before its announcement arrives keeps its first read time. */
export function timed(request: Plugin.Context["request"]): Requests {
  return {
    pending: () =>
      Effect.gen(function* () {
        const snapshots = yield* request.pending()
        const now = yield* Clock.currentTimeMillis
        const created = <A extends { readonly id: string }>(item: A): A & Created => {
          const known = times()
          if (!known.has(item.id)) known.set(item.id, now)
          return { ...item, created: known.get(item.id) }
        }
        return snapshots.map((snapshot) => ({
          ...snapshot,
          permissions: snapshot.permissions.map(created),
          forms: snapshot.forms.map(created),
        }))
      }),
  }
}
