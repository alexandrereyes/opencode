# Session family reads

The custom context panel and composer share `custom.session-family.snapshot`. It returns the descendant count and cost, active descendant metadata, and pending question/websearch/permission requests. `page` returns at most 100 descendants (the UI asks for 10); the next cursor is a stable Session ID, independent of mutable titles, costs and update times. Both include archived descendants, matching the previous Session list behavior. Summary cost excludes the root, which the UI adds separately.

The plugin owns pending-request classification and root-before-descendant priority. It reuses `ctx.request.pending()` and resolves only pending owners and their ancestors with a per-snapshot cache. It never revives historical Locations, scans all Sessions, or reads transcripts. Pending snapshots remain best-effort across live Locations, as defined by that existing plugin API. An unavailable root produces the RPC's declared `read_failed` error.

`ctx.session.family(input)` is the reusable extension point. Its host validates root existence, passes the native process-global active set, and delegates to the dedicated `SessionFamily` Core module. That module uses the indexed SQLite parent relation for count/sum, a bounded metadata page, and active-descendant metadata. It does not change event semantics, execution ownership, persistence tables, Protocol or HttpApi. The Promise plugin adapter decodes and encodes the same canonical Schema contract.

The browser loads one shared snapshot when a Session is watched. Opening the initially collapsed list reads one page. Show more reads exactly one further page; hidden row details do not fetch messages or models. Opening a row's context reads at most 20 assistant messages; opening its link uses the normal Session history route. Closing the panel/list or changing Session aborts optional requests, including queued fetches, and prevents writes from late responses. Page and context caches survive collapse/reopen. Events invalidate summaries and page membership; body deltas do not. Runtime and topology bursts are coalesced. Reconnect refreshes pending requests even when their owners have never been listed. Aggregated permissions also feed the existing automatic approver, including pending owners absent from the Session cache. Resolutions clear immediately and invalidate older snapshots. Failed snapshots get three delayed retries and an explicit compositor retry action.

## Integration overlap

Fixed upstream baseline: `e5ecb5719de37759e06c57ff05ffc668e98f6f30` (the upstream parent of the existing custom integration `6f39d5d3d409e0bf58cde853e2035cd6ff8eb788`). Development base: `44aaf6f2e5cd627b0509d1841af33765a475b54c`.

Existing upstream-owned implementation bodies are preserved. This feature adds 19 lines across four existing runtime integration files:

| File                            | Added by this feature | Cumulative overlap with fixed upstream baseline |
| ------------------------------- | --------------------: | ----------------------------------------------: |
| `core/src/plugin/host.ts`       |                     7 |                                        +90 / -3 |
| `plugin/src/effect/session.ts`  |                     2 |                                        +12 / -1 |
| `plugin/src/promise/session.ts` |                     2 |                                        +11 / -0 |
| `plugin/src/promise/adapter.ts` |                     8 |                                        +36 / -1 |

The dedicated Core reader (73 lines) and Schema contract (22 lines) are new files with zero overlap with upstream implementation bodies. Existing test-host fixtures gain the corresponding service/method. The custom policy, RPC, UI, and behavioral tests stay in their owning packages. No upstream UI file or generated client file changes.

## Verification

- Core: real SQLite fixture with 154 descendants, archived grandchildren, active filtering, exact count/cost, bounded cursor pages, and ordering stable under updates.
- Plugin: pending grandchild and permission outside loaded UI pages, shared ancestor lookups, root/ancestor priority, unrelated/global form exclusion, root failure.
- Server: real plugin RPC over HTTP, 154 imported descendants, pagination, question reply and declared missing-root error.
- UI: bounded opening/page/detail requests through the real Promise HTTP client, shared watcher deduplication, cache reopen, cancellation and late response rejection, pending descendants, reconnect, active-to-idle reconciliation, and coalesced runtime events without text-delta reads.
- Existing sidebar inventory/incremental projection, background-shell/subagent and websearch tests remain applicable and are run with the focused suite.

The entry request profile is bounded in HTTP count, not independent of active work: the summary payload includes currently active descendants and actual pending requests. SQLite still traverses the selected family to aggregate it. No latency improvement is claimed without a comparable measured workload.
