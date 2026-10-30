# Host context wrappers

`src/index.ts` hands every module the host's `Plugin.Context` with two members replaced (`src/context.ts`). Both used to be
custom additions to Core and the plugin SDK; since 2026-10-30 they live here and the host APIs are upstream's again.

## Storage `update` (`src/storage.ts`)

`ctx.storage.update(key, callback)` reads the value, runs the synchronous callback and writes its next value, returning
the callback's result. A throwing callback writes nothing. `set` and `remove` take the same lock, so a plain write cannot
land between the read and the write of an update.

The lock is one `Semaphore` in a global slot (`globalThis.opencodeCustomStorageLock`), not module scope: the plugin loader
evaluates this module again for every Location (`prepareSource` clears the module cache of the local graph; the release
bundle is one local file), so module state is per Location while plugin storage is shared by all of them. One lock for all
keys serializes the plugin's writes the way the database write lock serialized the former host `KV.update` transaction.
It covers this server process only; one process owns the database.

`test/storage.test.ts` evaluates the module twice and runs 50 concurrent increments through both, with a read that
yields before the write; with module-scope locks it loses updates.

## Request times (`src/request-times.ts`)

`ctx.request.pending()` adds `created` to every pending permission and form: the `created` of its `permission.asked` or
`form.created` event, or the time the plugin first read the request if no instance saw the event. Every Location instance
records events into one global map (`globalThis.opencodeCustomRequestTimes`), because `pending` reports the requests of
every live Location; `permission.replied`, `form.replied` and `form.cancelled` remove them. A late event does not replace a
first read. Requests live in memory and do not survive a restart, so the map starts empty with the process.

Consumers: `since` of watch requests (`src/watch/requests.ts`) and Live Activity rows (`src/live-activity/tracker.ts`),
`permissionAt`/`questionAt` in `custom.navigation`, and the request order in `custom.session-family`. The host's
permission and form payloads (HTTP and events) no longer carry `created`; no native app decodes it there.
