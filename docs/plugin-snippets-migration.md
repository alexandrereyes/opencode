# Snippets plugin migration

Base: `origin/custom` at `153208eab`.

## Frozen feature contract

- Same installed custom plugin and registration ID `custom.app-mentions`.
- Module/export: `@opencode/plugin-app-custom/snippets/rpc`, namespace `Snippets`.
- RPC ID `custom.snippets`.
- `list({}) -> { items: Info[] }`; `save(Info) -> Info`;
  `remove({ id }) -> {}`; declared save error `conflict` with `{ name }`.
- Event `updated` carries `{}` and invalidates the server-wide catalog.
- Move the existing ID/Info schemas into the plugin, preserving validation,
  optional project, aliases, content, IDs, case-insensitive per-project name
  uniqueness, replace-by-ID, and idempotent removal.

## Generic storage capabilities

The current Snippet service is process-global and serializes catalog writes.
The migration must preserve that consistency across Location plugin instances.

Add both Effect and Promise versions of:

- `storage.update<A>(key, callback) -> A`, where the synchronous callback receives
  `Json | undefined` and returns a readonly `[next: Json, result: A]`. The host
  performs the read and write atomically in its database transaction; no async
  callbacks or external operations run inside it. A thrown callback leaves the
  previous value intact.
- `storage.adoptLegacy(key) -> boolean`: initialize this plugin's namespaced key
  from the same unnamespaced legacy key, atomically and only once. Preserve an
  existing destination. A durable adoption marker prevents importing again if
  the destination is later removed. Legacy data may remain as historical data.
  Keep this generic: no snippet key, schema, or behavior in Core/Server. It must
  not adopt another plugin's namespaced storage.

At plugin initialization adopt `snippets:catalog` before initializing an absent
catalog to `[]`. Existing persisted snippets must be preserved without manual
export/import, including concurrent Location startup. Conflict is returned from
the synchronous update as a value, then translated to the declared RPC error.

## UI and removals

The server-global snippets UI uses the default server Location for RPC calls;
the custom runtime already activates the plugin there. It listens to the RPC
event across Locations of that server, refreshes after reconnect, and preserves
existing pending/error states, CRUD, suggestions, project precedence, and prompt
expansion. Use portable plugin types instead of generated Snippet types.

Remove the old Core service, Schema/event definitions, Protocol group, Server
handler/wiring, and generated-client surfaces. Regenerate from `packages/client`.
The already-migrated plugin features remain functional.

## Validation and delivery

Test atomic concurrent writes from different Location instances, callback
rollback, legacy adoption/restarts, existing destination, no reimport after
deletion, full data preservation, duplicate names, project scoping, removal,
and invalidation events observed by a server-global client. Use actual storage,
normal plugin loading and HTTP RPC in integration fixtures. Verify removed
routes return 404, UI RPC errors and refresh, and existing composer expansion.
Run focused checks/builds and any App benchmark required by files touched.

Implementation is reviewed before commit, followed by a single squash/push to
`custom`. Activation remains manual: no sync, production prepare, pending/held
release changes, MyEnv changes, global configuration edits or live restarts.
Preexisting upstream bugs are outside scope.
