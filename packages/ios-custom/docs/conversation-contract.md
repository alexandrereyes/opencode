# Conversation contract (native iOS)

Verified against this worktree's code and the isolated `http://127.0.0.1:4177` server on 2026-10-21. This is the
implementation contract for waves 1–7, not a proposal for new APIs. The approved layout is described in the README,
“Second screen: Conversa”; the web implementation is the behavioral reference. No Swift or web UI changes are needed
to use this contract.

The custom web app was removed on 2026-10-29. Its source paths cited below (`packages/app-custom`,
`packages/session-ui-custom`, `packages/ui-custom`) refer to the tag `web-custom-final`, and the
`@opencode/client/session-metrics` module cited with them was removed with it.

## Reading conventions and ownership

- All timestamps below are **Unix epoch milliseconds**, not ISO strings. Effect's internal DateTime objects are
  encoded as numbers at the boundary.
- HTTP endpoints require the server's normal authentication. Never put credentials in URLs, fixtures or logs.
- Location-scoped endpoints need `?location[directory]=<absolute directory>` (URL-encoded), or the encoded
  `x-opencode-directory` header. Session-ID endpoints resolve placement themselves. Omitting Location from a catalog
  call reads the server's own directory, not necessarily the session's.
- `RPC custom.area/method(input)` means `POST /api/rpc/custom.area/method`, JSON `{ "input": input }`, response
  `{ "output": result }`. It does **not** return the HTTP API's usual `{ "data": result }` envelope.
- Canonical schemas: `packages/schema/src/{session,session-message,session-event,prompt,prompt-input,session-inbox,
model,agent,form,permission,shell}.ts`. HTTP: `packages/protocol/src/groups/*.ts`. Plugin RPCs are deliberately
  absent from OpenAPI: `packages/plugin-app-custom/src/*/rpc.ts`.
- Examples replace local paths with `/sandbox`, and use shortened IDs where identity is unimportant. Fixtures retain
  full IDs so links can be tested. Do not decode pagination cursors to discover identity or ordering.

### Production compatibility audit (2026-10-22)

TestFlight `0.1.0 (202610221635)`, commit `020b6d1df7`, assumed a newer custom plugin than the installed backend.
Authenticated `GET /api/info` through local service discovery and the phone's
`http://opencode2-mac.alexandrem.com.br` path both identified the same process/version:
`0.0.0-custom.1de0005da68932f4ab7856e464978ad06f99d652` (PID 44906 at investigation time).
The installed `current` release symlink also pointed to that commit. No service was changed.

The backend log at `2026-10-22T16:44:00.968Z` (13:44 -03), and repeatedly throughout that minute, records
`POST /api/rpc/custom.transcript/list` returning 400. Opening a conversation sends
`{"input":{"sessionID":"<selected session>","limit":40,"order":"desc"}}`; Sessões previews use limit 3.
There is no `transcript` module or registration at the installed commit: it was added by `f9092affa7`.
The old `Rpc.call` rejects a missing registration with `rpc.unavailable`; its unchanged HTTP handler encodes HTTP 400:

```json
{"_tag":"RpcError","type":"rpc.unavailable","message":"RPC is unavailable: custom.transcript"}
```

This body is established from the installed revision's implementation, **not a captured production response**:
production logging retains the method/path/status but not the request or response body, and the diagnosis deliberately
did not replay a POST. The exact selected session ID is not in those logs. Backend receipt/rejection and the absent
registration explain the failure independently of nginx; the proxy's access log is disabled. Direct/public health
responses match, but a public-path POST comparison was not performed.

The client now mirrors the web's `withLeanTranscript`: failed lean reads use the native message endpoint with the same
limit and either `order=desc` or the unchanged opaque `cursor` (never both). This covers the initial tail, history,
restoration/search paging, parent transcript and Sessões previews. Native responses can include full inline tool media;
both Swift decoders accept them. Cancellation is propagated, and native failures are never replaced with empty history.

Audit coverage against `1de0005…` → `020b6d1df7`:

| Surface | Contract comparison / action |
| --- | --- |
| HTTP API, message/event/Session/model/agent/request schemas | `packages/protocol/openapi.json` and the entire `packages/schema` tree are identical. Session info, native messages, inbox, active, models/default, agents/providers, shells/output, forms/permissions/replies, prompt/model/agent selection, queue, interrupt/background, rename/view, command/compact/side-question and file APIs use that same contract. Location query encoding is unchanged. |
| Custom conversation reads | Family snapshot/page, worktree availability/locate and preferences (other than mute) have unchanged schemas and implementations. Only the optional lean transcript RPC needed a fallback. |
| Sessões | Navigation, project inventory, archive, requests, chats, subscriptions and pin/project intents are unchanged. Previews now share the native fallback. Optional `notifySessions` decodes when absent; an old server's `sidebar.notify` rejection is translated to an explicit update-required notice, not local-only success (muting was replaced by "Avisar ao terminar" on 2026-10-28). Absence alone cannot prove lack of support because the new field is optional too. |
| Nova sessão | Worktree list/create, VCS/branch search, config/MCP/status/connect/disconnect, Session creation, prompt/command, snippets and composer catalogs are unchanged. Existing/new destination and MCP semantics require no compatibility branch. |
| Você | Info/health, pairing redemption/auth and SSE contracts are unchanged. Theme/server registry/Keychain actions are local. |

The remaining backend-update requirement is **muting**, not opening or reading conversations. Swift transport tests cover
old/new transcript responses, request limits/cursor/order, full media, canonical failures, cancellation, old preferences
and the unsupported mute intent. No production mutation, simulator-to-production launch or backend update is required.

Verification: `swift test` passes all **147 tests**; simulator `build-for-testing` has no warnings. All four
`SessionReadingTests` pass in one final run, plus the live-theme/settings case and the Nova sessão selector/keyboard
case. A prior search run hit XCTest's animation-idle timeout; an isolated repeat and the final full reading run both
passed without changing UI code. Manual sandbox launch also opened the seeded history conversation without an error
banner; screenshot: `$TMPDIR/opencode/ios-compat-conversation-live.png`. Logs use the `ios-compat-*` prefix there.
Only this verification's disposable imported histories were removed; sandbox seeds and service lifecycle were untouched.

Follow-up native-reader proof: a throwaway Swift executable outside the repository loaded `OpenCodeKit` as a local package
and decoded five real production Session tails plus an older cursor page, acquired exclusively with `opencode api get`.
Both `ConversationPage` and `TranscriptPage` decoded **6/6 pages, 215 messages**, with **0 failures**. The real data included
215 tools, 128 reasoning parts, 16 subagent calls, one user attachment, 12 tool-result files and one compaction; one sampled
Session was a child. The harness exercised the app's tool summaries/output/diffs, part identity, Markdown parsing (278
blocks), day/footer/unread/sticky/final-answer/running-work/context projections, search and page merge. It printed only
aggregate counts/status, never private content. All raw acquisition files were then deleted from the private temp folder.
No production-data decoding change was needed.

All seven seeded sandbox histories were also compared page-by-page between native GET and RPC: **112 messages across
16 pages including empty terminal pages**, identical after the RPC's documented inline-tool-media omission and
null-versus-omitted empty cursor normalization. Both cursor encodings already decode to nil; a regression test covers them.
DEBUG builds now expose `-OpenCodeNativeTranscript`, which bypasses the RPC into the actual fallback reader. The flag is
compiled out of Release, and its absence from the built Release executable was verified.

Final follow-up checks: **149 Swift tests**, warning-free Debug `build-for-testing` and Release simulator build, all three
`TranscriptCompatibilityTests` (each exercising both transports), and all four existing `SessionReadingTests` pass.
Dark screenshot pairs are in `$TMPDIR/opencode/ios-native-transcript-098ecd72/`, named `rpc-*.png` and `native-*.png`:
history-tail, attachment, compaction, older-page, tools-reasoning-subagents, subagent-cards, child, permission and question.
Visual review confirms matching content/presentation; captures may have different scroll offsets and animation timing.
The native older-page case begins with the first revision absent, taps **Buscar em mensagens mais antigas**, then finds and
renders **Revisão 1 concluída** through the returned native cursor. No seeded requests were answered and no prompts sent.

## 1. Transcript, parts and visual groups — wave 1

### Loading the tail and history

```http
POST /api/rpc/custom.transcript/list
Content-Type: application/json

{"input":{"sessionID":"ses_example","limit":40,"order":"desc"}}
```

```json
{
  "output": {
    "data": [{ "id": "msg_latest", "type": "user", "text": "Olá", "time": { "created": 1792600000000 } }],
    "cursor": { "previous": "opaque", "next": "opaque" }
  }
}
```

`limit` is a positive integer, maximum **200**, default **50**. `order` defaults to `desc`. The array is in requested
**persisted sequence order**, not timestamp or ID order. Reverse a descending page for display. To get older data,
send `{sessionID,limit:40,cursor:previousPage.cursor.next}`; **omit `order` when supplying `cursor`**. Reverse the
returned page, prepend, and deduplicate by message ID. Retain the old scroll anchor. Both cursor directions are
emitted on every nonempty page without look-ahead; a cursor can lead to an empty page. Stop on an empty page, not only
on an absent cursor. Deleting the anchor also yields an empty page.

The web requests 40 messages for its compact preset, otherwise 20; older pages use 20. It may fetch up to three more
pages to complete a leading partial group, without withholding the visible tail. iOS can use a fixed 40 to start.
Do not fetch an entire long conversation on opening it.

Native opening now starts health, Session metadata, execution activity and the 40-message tail together and publishes
history as soon as
those reads succeed. Directory availability, independent catalogs (in parallel), runtime work and family must not gate
first content. `hasTranscript` controls the loading indicator and, since 27 October, saved-position restoration;
`ready` still gates sending. Runtime publication never replaces the transcript a second time, preserving concurrent
search/history paging. The ordinary event-race revalidation remains unchanged, as do page sizes and both transports.
Execution activity publishes with the tail, so running-group presentation never starts from a fabricated idle state.

**Retained conversations (27 October).** A conversation screen no longer starts from an empty store:
`SessionStore.conversations` keeps the five most recently opened conversations of the server, plus every one on the
navigation stack, with their loaded pages, older cursor, projections, expansion choices, fetched tool output, table
offsets and the exact passage last shown. Returning to one publishes nothing new and needs no read; its tail read
runs behind and merges. A read whose messages and execution activity are unchanged bumps no `revision`. When the new
tail no longer overlaps the retained messages (more than a page arrived while away), the store reads back with the
cursor until it does, at most five pages, and otherwise starts again from the tail like a fresh opening, so a retained
history never has a silent gap. A memory warning releases everything off the stack and drops fetched tool output.
The transcript view itself is retained with its conversation, so a return shows the very view that was left; a cold
opening shows nothing until it is laid out at the saved place, for at most 400 ms (2.5 s with an indicator while
history pages toward that place), and a failed or empty load shows at once.
The header session switcher captures the source place and replaces the route only after its sheet dismisses;
the destination uses this same registry. Successful archive and deletion, including batch selection, evict the
affected retained family. Failed requests keep it; archiving keeps durable reading positions and drafts.
The switcher reuses the main Sessões chips, grouping, headers and rows. Its search/chip and collapse state are local;
it opens on Todas (Chats for a chat), always at the top; the current row is marked but never a scroll target.
Reopening, changing the chip or changing the search starts at the top as well. Its header's +
uses the selected chip for Nova sessão, while the conversation menu still inherits the conversation's origin.
Both native Lists defer automatic reordering and section moves until scrolling is idle. Current data and request
actions keep updating, and selection uses the displayed IDs. This is independent of transcript scroll ownership.
Todas now includes ordinary chats in the same attention/activity/date groups as repository sessions. Mixed lists
use the shared chat avatar; the local Chats filter uses each chat's own avatar. The bell represents the server's
"Avisar ao terminar" preference, not a mute filter.
Tables keep their horizontal position in `TranscriptMemory`: a reconstructed native table restores that position
after measuring its content width. Grid separators and cells share the scrolling content coordinate space.

The PWA similarly renders an available tail independently of catalogs/family. Its server-scoped data store retains
messages across navigation and deduplicates `sync` reads until invalidated; the home page's first-two prefetch warms
Session metadata only, and row hover reveals directory metadata rather than prefetching transcripts. No corresponding
native cache or old-server workaround was added: the measured newer-server bottleneck was the first-render dependency
chain, not decoding or projection.

At the installed `1de0005…` revision, the PWA uses `sdk.api` directly: `runtime/server/transcript.ts` does not yet exist,
so it does not pay the native app's missing-RPC round trip at all. The current PWA source has the optional lean wrapper.

Opening measurements (2026-10-22, iPhone 18 Pro simulator/iOS 27, existing sandbox history, actual row action → first
transcript display frame; individual samples, not a device/network benchmark):

| Transport | Before | After |
| --- | ---: | ---: |
| New backend, loopback | 724 ms | 167 ms |
| New backend, DEBUG 400-ms delay per request | 4,204 ms | 538 ms |
| Missing RPC + native GET, same DEBUG delay | 4,453 ms | 1,049 ms |

On the real production hostname, three 40-message tails were **0.53 / 0.37 / 7.53 MB**, with median GET totals
**916 / 532 / 1,117 ms**, offline Swift decode on the Mac **7.2 / 4.0 / 9.5 ms**, and grouping/merge projection
**0.8 / 0.5 / 0.4 ms**.
Health median was 432 ms, motivating the conservative 400-ms simulation. GET TTFB includes both routing and server work;
the API does not expose their separate timings. Historical missing-RPC server spans had median 0 ms/p95 1 ms, but no
production POST was replayed. Production tap-to-render was deliberately **not** exercised: all app launches used the
sandbox; the old-path row above is explicitly emulated. Raw production responses were deleted after profiling.

`$TMPDIR/opencode/ios-abertura-prints/{before,after}.png` and `timings.json` retain the simulator evidence. The timing
runner isolates the real history row locally in DEBUG so unrelated fixture-list scrolling does not become the test.

Final checks: 195 Swift Testing tests, 12 app-hosted tests (including early publication, concurrent paging, execution
activity, partial failure and cancellation), all four SessionReading cases, all three RPC/native compatibility cases,
and history/relaunch plus parent/child reading continuity pass. Debug and Release builds have zero warnings; opening
diagnostic switches are absent from the Release executable. Verification imports are removed without changing seeds.

Sources: `packages/plugin-app-custom/src/transcript/{rpc,index}.ts`,
`packages/schema/src/session-message-page.ts`, `packages/core/src/session/store.ts`,
`packages/app-custom/src/runtime/server/transcript.ts`, `packages/client/src/solid/data.ts`,
`packages/app-custom/src/session/timeline/model.ts`.

### Message shapes

Every message has `id`, `type`, `time.created`, optional `metadata`. There is no common `role`, `sessionID`, or `parts`
field inside a message. The session comes from the endpoint/event envelope.

| `type`                             | Content and interpretation                                                                                                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `user`                             | `text`; optional materialized `files`, `agents`, `skills`. Bubble text may instead use `metadata.displayText`, comments and quotes (sections 7, 14).                                       |
| `assistant`                        | `agent`, `model:{id,providerID,variant?}`, `content:[]`, optional `tokens`, `cost`, `finish`, `error`, `retry`, `snapshot`. `time` has `created`, optional `streamed`, `completed`.        |
| `synthetic`, `system`              | `text`, optional short `description`. Render an appropriate notice, not a user bubble.                                                                                                     |
| `skill`                            | `skill` ID, `name`, `text`.                                                                                                                                                                |
| `agent-switched`, `model-switched` | `agent` / `model`, optional `previous`.                                                                                                                                                    |
| `location-switched`                | `location`, optional `projectID`, `subpath`, `previous`.                                                                                                                                   |
| `shell`                            | A direct shell message: `shellID`, `command`, `status`, optional `exit`, `output`, `time.completed`. Not an assistant tool part.                                                           |
| `compaction`                       | `status`: `running`/`completed`/`failed`; `reason`: `auto`/`manual`. Running/completed have `summary`, `recent`; completed may include `model`, provider state, usage; failed has `error`. |
| `idle`                             | `outcome`: `succeeded`/`failed`/`interrupted`, optional `error`; backend execution boundary, not a text response.                                                                          |

Assistant `content` is an ordered union:

```ts
{ type: "text", text: string, state?: object }
{ type: "reasoning", text: string, state?: object, time?: {created:number,completed?:number} }
{ type: "tool", id:string, name:string, executed?:boolean,
  providerState?:object, providerResultState?:object,
  time:{created:number,ran?:number,completed?:number}, state: ToolState }

type ToolState =
  | {status:"streaming",input:string} // incomplete JSON; not an object yet
  | {status:"running",input:object,metadata:object}
  | {status:"completed",input:object,content:ToolContent[],metadata?:object}
  | {status:"error",input:object,error:StructuredError,content?:ToolContent[],metadata?:object}
type ToolContent = {type:"text",text:string} | {type:"file",uri:string,mime:string,name?:string}
type StructuredError = {type:string,message:string,status?:number,response?:{body:string}}
```

Completed content is nonempty. `error` is structured, not a bare string. Assistant retry is
`{attempt,at,error}`; show the scheduled retry separately from a permanent failure. `streamed` means provider response
body ended **before** tool settlement. `finish:"tool-calls"` is not final-answer completion.

### Tool summaries and expansion

There is **no server-provided tool summary or “Usou N” group**. Preserve unknown tool names and render a generic
expandable input/output fallback. Source: `packages/session-ui-custom/src/tools/tool-renderer.tsx`,
`src/message/current-tool-state.ts`, `src/components/{message-part,session-diff,tool-error-card}.tsx`.

| Tool                     | Data for the collapsed line and expansion                                                                                                                                                                                                                                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `read`                   | `input.path`, `offset`, `limit`; output text starts `Read file path, lines 1-212`, followed by numbered lines. **There is no canonical `lineCount` field**. Parse this known output header for “212 linhas”, otherwise omit the count. Current native metadata includes `truncated`; do not invent `metadata.total`.                  |
| `shell`                  | `input.command`; elapsed time from `time.ran ?? time.created` through `time.completed ?? now`. Running metadata may carry `shellID`, `output`, `command`; completed metadata may include `exit`, `timeout`, `outputPath`. Nonzero exit can still be tool `completed`: display exit failure in output, not a fabricated `state:error`. |
| `edit`, `write`, `patch` | `input.path` for edit/write, patch body for patch. Current diffs are `metadata.files:[{file,patch,additions,deletions,status}]` (`added`/`modified`/`deleted`); aggregate `additions`/`deletions` for `+48 −0`, and expand the actual patch. Older data can differ; use generic fallback when no diff exists.                         |
| `glob`, `grep`           | Pattern plus path/include; optional metadata `count` / `matches`; text result for expansion.                                                                                                                                                                                                                                          |
| `websearch`, `webfetch`  | `input.query` / `input.url`; optional search `metadata.provider`; expandable output.                                                                                                                                                                                                                                                  |
| `execute`                | `input.code`; output may contain nested `metadata.toolCalls`. A completed execute can have `metadata.error:true` or failed nested calls.                                                                                                                                                                                              |
| `subagent`               | `input.agent`, `description`, `prompt`, optional `background`, `model`, `sessionID`; authoritative child link from `state.metadata.sessionID`. See section 5.                                                                                                                                                                         |
| `question`               | Tool input has questions; pending interaction is a **Form**. The web hides the pending question tool in favor of its question card. Completed result remains expandable.                                                                                                                                                              |
| `skill`                  | Display `metadata.name`, falling back to input ID/name.                                                                                                                                                                                                                                                                               |

For long shell output, `GET /api/shell/{shellID}/output?location[directory]=…&cursor=…&limit=…` returns
`{location,data:{output,cursor,size,truncated}}`. The web polls a live output once a second, keeping a 64-KiB tail;
the cursor is an absolute byte cursor, not a transcript cursor. `GET /api/shell/{id}` provides final status/exit even
after the running-only shell list no longer contains it. See `packages/session-ui-custom/src/tools/shell-output.ts`.

**Images:** `custom.transcript` blanks only inline `data:` URIs in terminal assistant tool content to
`data:<mime>;base64,`. It retains their MIME/name and does **not** strip user image bytes, text, metadata or provider
state. Do not show the empty URI as a broken image. Fetch
`GET /api/session/{sid}/message/{messageID}` on expansion to recover the original content, or load the referenced
file via `GET /api/fs/read/<relative-path>?location[directory]=…`. The latter is what the web's file/image renderer
uses. Native single-message response is `{data:message}`. `message-full-tool-image.json` versus
`transcript-history.json` demonstrates this distinction. The web falls back to native message listing on any
non-abort lean-RPC error, so fallback may contain full media.

Native image follow-up (2026-10-22): `FeedImageReference`, `FeedImageClient`, `FeedImageLoader` and `FeedImageView`
cover Markdown/HTML references, user attachment `data`, and tool `{type:"file",uri,mime,name}` content. Absolute,
tilde and relative paths normalize on the server side, then use basename + parent `location[directory]` exactly as
`app-custom/src/runtime/server/image.ts` does. The file route streams binary, confines lexical/real paths to that
requested Location, supports Range, and requires ordinary authentication; neither an image-only policy nor a size
cap is imposed by the backend. Native loading requests a bounded range and applies a 32-MiB client limit.
No backend or protocol change is required, including for existing temp files outside the Session directory.

The read-only **Temas** audit found six relative Markdown images and 20 stored PNG tool parts, no user attachments;
all files still existed. Shell output repeated six Markdown images and 12 HTML tags (six relative, six signed
SeaweedFS links); 18 internal-URL occurrences represented six objects. Generic PWA tool output is text-only, while
its read-image card reloads the path; Markdown local images use the file route. HTTP image links are not proxied.
These implementations and the file route match installed `1de0005…`; its missing lean RPC cannot explain discarded
stored images. The iOS decoder/resolver was also exercised directly on a GET-acquired real page, without launching
the app against production; raw data was deleted afterwards. SeaweedFS needs separate WARP DNS/routing and a valid
signature. Serving stable artifacts under an authenticated backend namespace would remove that dependency, but
requires a separately approved backend/storage design rather than an arbitrary-URL proxy.

Native file follow-up (2026-10-23), checked against `1042585c28`: explicit local Markdown links do not need an existence
gate. Inline-code candidates use the web punctuation/filename rules, `GET /api/fs/list` for absolute parents and
`GET /api/fs/find?type=file&limit=200` for relative exact/suffix matches. Ambiguous suffixes open a picker; missing
inline candidates stay ordinary code. Native `~` resolution additionally uses `custom.directories/home`. User prompt
bodies stay literal, as in the web. Ellipsis paths remain incomplete; no guessed prefix is substituted.

`FileTransfer.fileRequest` reuses `imageFileRequest` authentication and parent Location but removes its image-only
Accept and 32-MiB Range. Metadata requests use `Range: bytes=0-0` (not HEAD); `Content-Range` supplies total size,
including the empty-file `416 bytes */0` case. Files above 50 MiB require explicit consent before the actual download.
URLSession download delegates publish progress and cancellation; completed files move atomically into a protected,
app-owned temporary folder. Dismissal removes only that download's folder; app launch removes stale owned folders.
The backend still confines each read lexically and by realpath to the selected Location, not permanently to the
Session directory. No backend changes are needed for temp-folder evidence. Images use the shared zoom component;
AVPlayer/Quick Look consume downloaded local URLs, never a Mac `file://` path or a password/token embedded in a URL.
Share exports the actual local file, and Copy path preserves the resolved server path.

### Groups, sticky prompt, days and unread

Web projection sources: `packages/session-ui-custom/src/timeline/{projection,detail,timeline-row}.ts`,
`src/timeline/session-timeline-row.tsx`; sticky positioning:
`packages/app-custom/src/session/timeline/virtualizer.tsx` (`data-sticky-user`).

- A backend step is one assistant message / one LLM call. The web can group adjacent activity **across** assistant
  messages; the activity card is a display group, not a separate API object or an LLM call count. The iOS transcript
  hosts the shared `ConversationActivityCard` and `ConversationTimeline` with the “Atividade” header, categories,
  tool count and elapsed time. Group, detail, filename and diff disclosures participate in cached cell heights;
  fetched outputs remain in per-key transcript memory across navigation.
- Count tool/direct-shell entries, not reasoning parts. If there are only reasoning parts, count those instead.
  Deduplicate localized tool names in first appearance order. Notices do not increment the tool count.
- Keep content order; reasoning duration is its own `time.completed - time.created` when available. Do not guess
  reasoning duration from the full step when its timestamps are absent.
- A group is pending when busy or any included tool is `streaming/running`. The approved iOS presentation opens the
  current group and collapses finished groups; tapping expands without another transcript request.
- Tool IDs are real wire IDs. Stable text/reasoning UI IDs are respectively `${message.id}:text:${ordinal}` and
  `${message.id}:reasoning:${ordinal}`, with ordinals counted **within that content type**. Use these for quotes.
- Failed tools remain visible even if a display category is hidden. `todowrite` (behind `experimental.todo`, rev.
  2026-10-30) is shown as the Progresso pill above the composer instead (`plugin-app-custom/docs/progress.md`): its
  successful calls do not render as rows, do not count in “Usou” or its kinds summary, and contribute no final-answer
  boundary; a failed call stays visible like any failed tool. The web's `idle` marker is not itself rendered as a row.
  Compaction and selection/location notices split groups.
- Final-answer separators are projected over each whole user group, including history: completed, error-free,
  retry-free `finish:"stop"` text rows form sequences delimited by rendered activity. Prefer the first
  `state.phase:"final_answer"`, otherwise the first text of the last eligible message in that sequence. Commentary
  after an explicit final answer starts another sequence. Draw only after earlier activity, never before the
  exchange's first content. Several separators can belong to one exchange; hidden activity contributes no boundary.
  They are not server messages and do not change text/quote part IDs.
- Sticky prompt is the **same** latest user bubble positioned under the header and clamped to two lines, not a second
  message. Preserve identity and selection anchors while scrolling.
- `Hoje`/`Ontem` are local-calendar grouping of `time.created`; never sort the history by that date. Like the custom
  web, there is no unread-message count, frozen boundary, divider or upward jump. One ↓ **Ir para a mais recente**
  control appears beyond `max(400, viewport height)` points from the bottom, or beyond 24 points once content was
  added below the end the reader last saw (growth, arrivals, even while hidden). It scrolls to the end once; nothing
  follows growth (iOS, 27 October): sending moves the sent prompt to the top of the transcript, and its answer grows
  below it without moving the screen. Route entry acknowledges the session's
  observed idle independently of position, transcript paging and catalogs, including child sessions, through the
  unchanged `POST /api/session/:id/view` payload `{idle}` on installed `1de0005…`. No API moves viewed backwards.

## 2. Live updates — wave 1

`GET /api/event` returns global SSE, across all Locations. Frames are `data: <JSON>\n\n`; `: heartbeat\n\n` arrives
every 15 seconds. The first frame is `{"id":"evt_…","type":"server.connected","data":{}}` (no `created`).
Normal envelope:

```ts
{id:string,type:string,created:number,location?:{directory:string,workspaceID?:string},
 metadata?:object,data:object,durable?:{aggregateID:string,seq:number,version:number}}
```

Filter by `data.sessionID`/owned family IDs, not Location alone. Execution events can lack Location. SSE has no
`id:` replay header; its JSON event ID is not a resume cursor. It is volatile; a slow subscriber is disconnected,
and missed frames are never replayed. The server queue is bounded at 4,096. Handle partial UTF-8 chunks, comments,
blank frame delimiters, and reconnects. Existing iOS byte framing and 45-second no-byte watchdog remain appropriate.

In the table, **S**=`sessionID`, **A**=`S,assistantMessageID`, **T**=`A,id` (tool call ID). “Live” means ephemeral.

| Event                                                  | `data` fields in addition to S/A/T                                                              |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| `session.created`                                      | S, projectID, location, slug, version; optional title/agent/model/parentID/metadata/permissions |
| `session.step.started`                                 | A, agent, model, started, snapshot?                                                             |
| `session.step.streamed`                                | A                                                                                               |
| `session.step.ended`                                   | A, finish, cost, tokens, rawFinish?, providerState?, snapshot?, files?                          |
| `session.step.failed`                                  | A, error, finish?, rawFinish?, providerState?, cost?, tokens?, snapshot?, files?                |
| `session.text.started`, `session.reasoning.started`    | A, ordinal; reasoning additionally state?                                                       |
| `session.text.delta`, `session.reasoning.delta` (live) | A, ordinal, delta                                                                               |
| `session.text.ended`, `session.reasoning.ended`        | A, ordinal, text, state?                                                                        |
| `session.tool.input.started`                           | T, name                                                                                         |
| `session.tool.input.delta` (live)                      | T, delta                                                                                        |
| `session.tool.input.ended`                             | T, text                                                                                         |
| `session.tool.called`                                  | T, input object, executed, state?                                                               |
| `session.tool.progress` (live)                         | T, metadata; **replace**, do not merge the previous metadata                                    |
| `session.tool.success`                                 | T, content, executed, metadata?, resultState?                                                   |
| `session.tool.failed`                                  | T, error, executed, content?, metadata?, resultState?                                           |
| `session.retry.scheduled`                              | A, attempt, at, error                                                                           |
| `session.execution.started`, `.succeeded`              | S                                                                                               |
| `session.execution.failed`                             | S, error                                                                                        |
| `session.execution.interrupted`                        | S, reason:`user`/`shutdown`/`superseded`/`inactivity`                                           |
| `session.inbox.enqueued`                               | S, inboxID, item:{type,payload,delivery}                                                        |
| `session.inbox.delivered`, `.cancelled`                | S, inboxID                                                                                      |
| `session.inbox.delivery.changed`                       | S, inboxID, delivery:`steer`/`queue`                                                            |
| `session.compaction.started`                           | S, reason, recent, inputID?                                                                     |
| `session.compaction.delta` (live)                      | S, text                                                                                         |
| `session.compaction.ended`                             | S, reason, text, recent, model?, providerState?, providerContext?, cost?, tokens?               |
| `session.compaction.failed`                            | S, reason, error, inputID?, cost?, tokens?                                                      |
| `session.agent.selected`, `.model.selected`            | S, agent/model, previous?                                                                       |
| `session.moved`                                        | S, location, projectID, subpath?                                                                |
| `session.synthetic`                                    | S, text, description?, metadata?                                                                |
| `session.skill.activated`                              | S, id, name, text                                                                               |
| `session.shell.started`, `.ended`                      | S, shell; ended also output                                                                     |
| `session.usage.updated` (live)                         | S, cost, tokens (session totals)                                                                |
| `session.revert.staged`, `.cleared`, `.committed`      | S; staged adds `revert`, committed adds `to` message ID                                         |
| `permission.asked` (live)                              | Full Permission.Request; see section 10                                                         |
| `permission.replied` (live)                            | S, requestID, reply:`once`/`always`/`reject`                                                    |
| `form.created` (live)                                  | form:Form.Info (session ID inside form)                                                         |
| `form.replied` (live)                                  | S, id, answer                                                                                   |
| `form.cancelled` (live)                                | S, id                                                                                           |

There is **no current public `message.created`/`message.updated` or `message.part.*` contract** to build on. Step start,
inbox delivery and control events create their respective projected messages. Internal
`session.message.content.updated` is not in the public event manifest. Legacy similarly-named events are not this API.

### Recommended iOS strategy

1. Open SSE, then load session, tail, inbox and family/request snapshots. Buffer/coalesce invalidations during that
   load so an event racing a response schedules one more tail read.
2. Apply text/reasoning deltas by `(assistantMessageID, ordinal)` and tool deltas by `(assistantMessageID,id)` to a
   known current message. End events carry authoritative complete text. Batch UI updates; do not fetch per token.
3. On missing target, structural change, completion/failure/interruption, or terminal tool event, debounce/refetch the
   tail and affected snapshots. Merge by message ID; do not replace already-loaded older pages with the tail.
4. A tail read of a **running** message lacks the text its deltas already streamed (the server keeps a part's text
   when the part ends), and deltas arriving while a read is in flight are not applied. iOS records text/reasoning
   deltas as they arrive (`ConversationStreamLog`) and extends each read part to the streamed text that begins with
   it, so a refresh never takes text back or leaves a gap. Retained conversations keep recording while off screen
   (from the app's single event connection, without publishing), so a return mid-answer is complete and live. A part
   already running before any log saw it shows the deltas that arrive after a `…` marker, and its `.ended` event
   carries the whole text. After a real disconnection, deltas sent meanwhile are lost: a part that lost some keeps its
   text and takes no more deltas until its `.ended` event.
5. On every reconnection/foreground return refetch authoritative state. A tail refetch also restores final phase,
   snapshot and error data that a simplified delta reducer may omit. Preserve the pre-view unread boundary.
   iOS keeps its conversation event loop across background and foreground (only leaving the screen ends it); the
   reconnection that follows a return merges the tail and republishes nothing when it is unchanged.
6. Maintain execution activity separately from latest message's completion: the root can be idle while children run,
   and a completed background subagent tool can refer to a running child.

The web applies deltas to its cache, batching at 16 ms, with reconnect revalidation. Its reducer often targets the
last text/unfinished reasoning part rather than wire ordinal; iOS should keep ordinal identity. It strips tool media
from live terminal events too. It does not always preserve `text.ended.state` or all snapshot fields until refetch,
so copying its reducer literally is unnecessary. Sources: `packages/client/src/solid/{data,connection}.ts`,
`packages/app-custom/src/runtime/server/{client,runtime,transcript}.tsx` (transcript is `.ts`),
`packages/app-custom/src/session/session-resolution.ts`.

For a native reducer, `step.started.data.started` is assistant creation time; `step.streamed`'s envelope `created`
becomes `time.streamed`, and the terminal step event's `created` becomes `time.completed`. Reasoning/tool lifecycle
events similarly supply part timestamps through the envelope. `inbox.delivered` contains only the inbox ID: recover
the user content from the cached enqueue item or refetch, never fabricate an empty bubble. An external revert can
remove already-loaded messages; refetch/prune rather than treating it as an append-only update.

The separate `GET /api/experimental/session/{sid}/log?after=<seq>&follow=true` is a durable event-log stream, with
`log.synced` watermarks. It does not replay ephemeral deltas. Do not add it just to avoid tail revalidation.
Event source: `packages/schema/src/{session-event,event,event-manifest,permission,form}.ts`,
`packages/server/src/{event-feed,handlers/event}.ts`. Real captured sequence: `events-live-step.json`.

### Native foreground alerts — wave 7

The single app-wide hub listener announces only live root `session.execution.succeeded`/`.failed`,
`permission.asked`, and `form.created` with `form.metadata.kind:"question"`. Requests in descendants resolve to their
root for navigation, title and mute policy; the currently open owner/root is silent. Root or owner mute suppresses
the banner without changing the request/attention snapshot. Auto-approved permissions are silent. Child terminal
events, tool failures, retries and user interruption do not create a failure banner.

Claims use server + actual event owner + event kind + terminal `created` watermark/request ID and are bounded to the
latest 500, persisted locally. Refresh snapshots never create alerts. Each connection starts a new live-time boundary;
signals older than it are discarded, and an in-flight metadata lookup cannot cross a disconnection/generation change.
There is no bulk replay, system notification, push registration or background-delivery promise.

## 3. Assistant footer — wave 1

- Display name: look up the assistant's **`model.providerID` and `model.id` pair** in `/api/model`, then catalogs already
  loaded for this server and the server-default Location catalog. Missing directories do not prevent that fallback.
  Fall back to the raw ID only when none knows the pair.
- Effort: assistant's `model.variant`. The web suppresses `"default"`; missing variant is not a reason to invent one.
- Finished gate: don't show a final response footer while the corresponding response group is working. The web
  attaches it to the last nonempty text part of the last assistant with text, not every tool step.
- **Timestamp distinction:** the web footer displays `assistant.time.created`, although `time.completed` exists.
  For the approved iOS “completion time” semantics use `time.completed` and explicitly fall back to created for old
  imported history. Do not mistake created for completion. Format in the user's local timezone as `dd/MM HH:mm`.
- Copy concatenates the response text; it is a local clipboard action, no endpoint. Agent, tokens/sec and duration
  are intentionally omitted in the native approved footer.

Web sources: `packages/session-ui-custom/src/message/message-content.tsx`,
`src/timeline/session-timeline-row.tsx`; optional web metrics in `packages/client/src/session-metrics.ts`.

## 4. Context ring and details — waves 1–2

### Native context/cache surfaces (2026-10-23)

Review 1 replaces the per-answer metrics with **one fixed line below the conversation composer**, left-aligned with
its inner padding. Answer footers return to model/date and copy only. `ContextUsage` remains the shared pure pt-BR
projection/formatter for this line, the top **Uso da sessão** section and subagent task rows. The fixed line uses the
conversation's latest measured assistant step for both context and cache, exactly like the header ring. A newer
unmeasured streaming step does not clear it; before the first measurement it is hidden. Child and master stores never
borrow the parent's/target's measurement or cumulative Session tokens.

The line is a tappable native button opening the existing Details sheet, with the shared `.micro` typography and
monospaced digits. It participates in the normal VStack below the composer, above the bottom safe area/keyboard;
its height reduces the timeline viewport automatically, as does the voice bar above the composer. No overlay or
hand-maintained keyboard offset can cover the last message. The line is removed while the fullscreen composer is open
and does not exist in the Nova sessão view. Search and unavailable-composer notices retain their existing bottom area.

The ring opens the existing **Detalhes da sessão** sheet, initially large (medium remains available), not a popover.
Its context numerator and limit belong to the latest measured step. Its separate Cache row uses **Session totals**:
`session.tokens.cache.read / (session.tokens.input + session.tokens.cache.read + session.tokens.cache.write)`.
Read/write counts and Tokens also come from Session totals; cost is `session.cost`, with `family.cost` and their sum
shown separately when descendants exist. No tokens or costs are silently added across the family.

Task rows use the `context:{id,tokens,model}` already returned on each family member, **not** its cumulative `tokens`.
Swift `Session.context` now retains that previously ignored field. The installed backend
`1042585c285c25d4b5d4fd292d0b7eb5fb7c470e` was verified by authenticated GET health plus its exact schema, family SQL
selection and RPC `encodeMember` implementation; no production RPC POST was replayed. The existing family-page,
transcript, Session and model-list requests are unchanged. Existing live event invalidations refresh family contexts.

Unknown/nonpositive limits omit the percentage, not the measured token count. A zero input-side cache denominator is
unknown (`—`), not 0%. Display uses `k`/`M` and a decimal comma; VoiceOver retains the exact capacity, including
“1 milhão e 50 mil” for Luna's 1,050,000 window. Drawing alone clamps to [0,1]; severity uses the unrounded fraction
(warning only strictly above 80%). A bounded 512-entry, store-local formatting cache keys measured facts and limit,
not changing text/tool payloads. No per-row or per-render network request is introduced.

The old per-answer measurement map is no longer needed; the current measurement is selected by scanning backwards
from the tail, and metric lookup does not merge/sort model catalogs. The 300-message scroll fixture has no measurements,
so an additional DEBUG-only variant supplies 223 measured assistant steps without changing IDs, body text or the production component.
Pre-review five-iteration, four-gesture simulator results: original conversation dragging/deceleration **2.620 s**, then
unmeasured **2.570 s**, measured **2.570 s**; current CPU **3.459 s** unmeasured versus **2.832 s** measured. CPU varied
between runs even in Sessões (where this feature does not render); these are recorded samples, not an isolated claim
that metrics improve CPU. Sessões durations stayed **2.580 → 2.589 s**, with preview updates **2.560 → 2.566 s**.
Raw XCTest metrics and source/binary hashes live under `ios-cache-prints/{before-metrics,after-cached}*`.

Review verification covers fixed-line visibility, tap-to-details, keyboard/fullscreen transitions, Nova sessão,
unmeasured streaming retention and the voice bar's combined insets in both themes. A real owned Luna-6/low child
updates the fixed line live; family context also changes while **Agentes e tarefas** remains open. All owned runs,
shells and histories are stopped/removed afterwards.
Existing conversation/details and subagent/alert UI cases are exercised separately with owned fixtures. The details
regression checks visible geometry of read-only labels rather than their unreliable native `isHittable` flag, and
reveals the renamed row before waiting for it in the longer fixture list. Chat-ring privacy checks retain their
directory assertions and now expect **Detalhes da sessão** after the approved presentation change.

Review-1 evidence is in `ios-cache-prints/review-1/`: `cache-fixed-*`, `cache-keyboard-*`, `cache-child-*`, plus expanded
composer, live-update and voice/keyboard captures. The final run passes 14 UI cases (seven in each theme), including
tap-to-details with the keyboard already open. The live runner waits for a child interruption to settle before its
next prompt so the verification itself cannot race prompt admission against cancellation. The importer deliberately
drops unfinished assistant messages, so streaming retention is checked against the real owned running child instead
of an imported incomplete row.

Use the **latest loaded assistant with `tokens`**, and that message's model catalog entry, not session total usage:

```text
total = input + output + reasoning + cache.read + cache.write
fraction = total / model.limit.context
webPercent = round(100 * fraction)
cacheHit = cache.read / (input + cache.read + cache.write)
```

The ring is a measurement, not progress. Clamp the drawn fraction to `[0,1]`; retain the real numeric total in the
sheet. Missing measurement or model limit means unknown (web renders zero), not a guessed window. Apply the approved
neutral color / warning above 80% using theme tokens. The latest measurement excludes unmeasured queued input and
currently growing output. A model switch does not retroactively change the previous measurement's denominator.

Read `GET /api/session/{sid}` for title, directory, times, total `cost` and `tokens`; `custom.transcript/list` for latest
step usage; `/api/model?location[directory]=…` for `limit:{context,input?,output?}` and model name. The sandbox's
`llm-proxy/gpt-6-luna` is **1,050,000** context tokens and named **Luna 6**; another provider can use the same model ID.

The sheet can show token components, provider/model, context limit, used/total/percentage, cache-hit fraction,
session cost, family cost, grand total, branch, directory, child work and background tasks. Family paging includes
each child's last measurement without fetching child transcripts (section 5). `GET /api/mcp?location[directory]=…`
provides MCP status if porting the entire web overview. Branch comes from existing `custom.worktrees/locate`.

Web detail message/user/assistant counts are **loaded-page** counts. Its “system prompt” is the latest loaded
`system.text`, not the full assembled model instruction. “Last activity” is latest measured assistant creation.
`GET /api/session/{sid}/context` returns active history after the latest completed compaction, including that
compaction; it is **not** a usage endpoint. Compaction's own tokens measure its request, not the new context size.

Sources: `packages/app-custom/src/session/timeline/session-context-usage.tsx`,
`packages/app-custom/src/session/files/{context-overview,session-context-tab}.tsx`,
`packages/app-custom/src/session/files/subagent-context-usage.ts`, `packages/schema/src/token-usage.ts`.

## 5. Running agents, background tasks and family — waves 1–2

Read:

```text
GET /api/session/active                                      → {data:{[sessionID]:{type:"running"}}}
RPC custom.session-family/snapshot({sessionID})             → {count,cost,active,forms,permissions}
RPC custom.session-family/page({sessionID,limit:10,after?})  → {data:[SessionInfo & {context?}],next?}
GET /api/shell?location[directory]=…                         → {location,data:ShellInfo[]}
```

`snapshot.count` counts **all descendants**, including completed ones; it is not the capsule count. `active` contains
active descendants, not the root. `page` sorts active first, then latest execution descending, and ID for ties;
`after` is the returned descendant ID (not a base64 cursor). Maximum page size 100, default 10 in the RPC. A member's
`context:{id,tokens,model}` is its last measured assistant. `snapshot` asks for no page, so avoids reading transcripts.

The web's running capsule derives:

1. Foreground running subagent tool parts (`state.status:"running"`), even while starting without a child ID.
2. Active immediate child sessions, including completed/backgrounded tool results referring to those children.
3. Running shell records whose `metadata.sessionID` is the owner, excluding any shell already represented by a
   foreground blocking tool. **Foreground shell is excluded** from the capsule (it is in the tray/timeline).
4. Deduplicate tasks by ID. Background tool metadata `status:"running"` is historical, not authoritative forever:
   reconcile with `/api/session/active` and runtime shells. Completed tool ≠ completed child.

When viewing a child, the menu's owner is its parent; it shows siblings and the parent's background shells. The phone
count excludes the **viewed child**. A child opens through the same session GET/transcript calls, by `sessionID`, and
shows a return-to-parent action. Wave 7 deliberately allows ordinary prompting in children, with the same composer,
queue and delivery semantics driven by the child's own execution. The child's agent is read-only: neither prompt
nor command submission calls the agent-selection endpoint; model/effort selection remains available. No extra notice
is shown. A continuation after the original subagent Job delivered stays in the child and does not rewrite or redeliver
the parent's historical tool result. Background and archive remain root-only. Permission and question responses still
use their actual owner. Clicking a shell instead reveals its tool in the owner's
timeline; it does not open a fabricated child session. To stop one child use `/api/session/{childID}/interrupt`;
to stop a standalone shell use `DELETE /api/shell/{id}?location[directory]=…`.

Sources: `packages/app-custom/src/session/header/{running-work.ts,session-running-menu.tsx}`,
`packages/app-custom/src/session/requests/{background,model}.ts`, `packages/app-custom/src/session/family.ts`,
`packages/plugin-app-custom/src/session-family/{rpc,index}.ts`, `packages/core/src/session/family.ts`,
`packages/schema/src/session-family.ts`, `packages/protocol/src/groups/shell.ts`.

### `read_failed` investigation

The existing Swift `OpenCodeClient.family(_:)` sends the **correct** `{input:{sessionID}}`; no extra Location is
required. Live calls succeeded for the existing Sessões parent, its pending-permission session, the new root with
two running descendants, and paged children. The new snapshot returns count=3, active=2, and correct child identity.
`family-working.json` and `family-page.json` preserve these responses.

The plugin first verifies the root via `ctx.session.family`, then gathers globally pending requests and walks their
ancestors. It maps **any typed failure** to `read_failed`, concealing the original cause. A nonexistent/stale root ID
reproduces HTTP 400 `{_tag:"RpcError",type:"read_failed",data:{sessionID}}`; see `family-missing.json` and the existing
test `packages/plugin-app-custom/test/session-family.test.ts`. The previous iOS failure's original request/underlying
error was not retained in the available evidence, so its exact historical cause is **unconfirmed**. Do not label it a
proven Location/encoding bug or silently treat every failure as an empty family. Re-fetch the root, retain last good
snapshot, and offer retry. No backend fix was justified or applied, and no sandbox restart was needed.

## 6. Agents and their colors — waves 1–2

`GET /api/agent?location[directory]=…` gives `{location,data:[{id,name,mode,hidden,color?,model?,…}]}`. Use ID on the wire,
display `name`. Modes are `primary|subagent|all`; composer filters hidden and subagent-only, mention/subagent picker
filters hidden and primary-only. Verified core entries: build/Build (primary), general/General and explore/Explore
(subagent). Custom agents are also returned; do not hardcode a list.

`color` is optional and can be a semantic name or CSS color. **`v2Color` is not an API field**: the web derives it in
`taskAgent()` in `packages/session-ui-custom/src/tools/tool-renderer.tsx`. Semantic names map:
primary→text-accent, secondary→text-muted, accent→icon-accent, success/warning/error/info→their state foregrounds.
Without explicit color it uses `v2-agent-{build,explore,plan,review,writer}-solid` for those built-ins, then the older
agent tone/hash palette. The running header uses `v2-agent-<id>-solid` with a neutral fallback. Native colors must
come through theme roles; do not parse an absent `v2Color` or copy mockup RGBs.

For subagent cards use `input.description` and `input.agent`, link `metadata.sessionID`, and consult the child's active
state for animated/static icon. Tool duration uses its times; an immediately backgrounded call's short duration is
only launch time, not child lifetime. For running background children use child creation/execution timestamps (web
runtime work state) for elapsed work. The tool input's `background:true` is optional and not inferable merely from a
completed tool; runtime state decides whether it is still running. Implementation:
`packages/core/src/tool/plugin/subagent.ts`.

## 7. Prompting and prompt presentation — wave 2

```http
POST /api/session/ses_example/prompt

{"id":"msg_unique","text":"Confira @docs/infra.md","files":[{"uri":"file:///sandbox/repos/ios-conversation/docs/infra.md","mention":{"start":8,"end":22,"text":"@docs/infra.md"}}],"metadata":{"displayText":"Confira @docs/infra.md","comments":[]},"delivery":"steer"}
```

Optional request fields: `id`, `files:[{uri,name?,description?,mention?}]`, `agents:[{name,mention?}]`,
`skills:[{id,mention?}]`, `metadata`, `delivery:steer|queue`, `resume`. `text` is required. **No top-level agent, model,
variant, raw `data`/`mime`, quote or snippet field exists on this endpoint.** Select agent/model separately (section 11).

The response is `{data:InboxUser}` with `id,sessionID,type:"user",time:{created},delivery,payload`. Admission resolves
files into base64/materialized metadata and skills into their prepared form. It is not a response message. Visible
user bubbles appear on delivery. `resume:false` admits without scheduling a new wake; it does not pause an already
running session. First admission wins for a repeated `(id,sessionID,type)`, including after delivery; retry payload
and delivery changes are ignored. Cross-session/type reuse conflicts. The web retries one failed admission with the
same ID. Do not create a new ID for an ambiguous retry.

Idle submission uses `steer`; busy submission uses `custom.preferences.data.settings.followUpBehavior` (`queue` or
`steer`), alternate submit uses the other. `steer` means next safe step boundary, not immediate tool interruption.
The fixture's safe admission/retry probe confirms first-wins and cancels its own item without executing it.

Web presentation metadata (not native execution parameters):

```ts
{displayText:string, comments:PromptComment[], quotes?:ChatQuote[],
 apps?:AppPart[], sessions?:SessionPart[],
 attachments?:{name,mime,path,mention?}[], agent?:string,
 model?:{providerID:string,modelID:string,variant?:string}}
```

`modelID` here differs from native `Model.Ref.id`. `readPromptPresentation()` requires **both** `displayText` and a
`comments` array; send `comments:[]` when empty. Otherwise web restoration falls back to raw model-facing text.
`text` contains expanded snippets followed by attachment/MCP/file-comment/app/session/quote instructions. Append
context **after** display text so mention offsets stay valid. Normalize CRLF/CR to LF; offsets are UTF-16 code units,
like JavaScript `slice`, not UTF-8 byte or Swift grapheme indices.

Sources: `packages/app-custom/src/composer/{submit,request,prompt-parts,schema}.ts`,
`packages/schema/src/{prompt-input,prompt,session-inbox}.ts`, `packages/core/src/session/{prompt,inbox}.ts`.

## 8. Queue / inbox — wave 2

```text
GET    /api/session/{sid}/inbox                         → {data:InboxItem[]}
PATCH  /api/session/{sid}/inbox/{inboxID}  {delivery:"steer"} → 204
DELETE /api/session/{sid}/inbox/{inboxID}                → 204
```

List is enqueue order, **unconsumed only**. Item types include user, synthetic, compaction, move. Queue UI displays
only user items with `delivery:"queue"`. “Enviar agora” is PATCH queue→steer; it wakes execution and is **not** a new
prompt. Cancel an already unavailable item is a no-op. A delivered item is absent, not retained with status delivered.

There is no text-edit/reorder endpoint. Web editing restores the item's draft, submits a replacement ID, then cancels
the original. Reordering replaces the changed suffix with `resume:false` admissions before cancelling originals;
queued control items restrict it. Do not PATCH `{text:…}` or reuse an ID expecting replacement. Keep the original
visible if replacement fails. Sources: `packages/app-custom/src/session/composer/{queue.ts,queue-panel.tsx}`,
`packages/protocol/src/groups/session.ts`, `packages/schema/src/session-inbox.ts`.

## 9. Running tray / interruption / background — wave 2

`POST /api/session/{sid}/interrupt` returns **`{interrupted:boolean}`**. Idle/unowned execution is a no-op, unknown
session is rejected. The web composer Stop uses `?resume=true`: it interrupts active execution and then permits
pending steer/control work to resume; queued prompts remain parked. A strict stop without resuming pending steering
uses the omitted/default flag. Never interrupt a root just to refresh it.

`POST /api/session/{sid}/background` (empty/no body) moves active **backgroundable foreground tools** into background
observation; idle is a no-op. It is not “pause”, “send app to background” or “run the whole session asynchronously”.
The web offers it for blocking shell/subagent work on the primary session, not arbitrary text generation or child
views. A shell can continue while its tool call completes.

Web running text is model label plus general thinking / running command / waiting-for-agent state according to
blocking work; it does not expose a single server status sentence. Approved iOS deliberately simplifies this to
`<model> · trabalhando`, with command details only in the transcript. Pending permissions/questions take precedence
for the header `aguardando você`; otherwise execution activity→`trabalhando…`, otherwise branch alone. Use current
execution state, not `session.outcome` (which describes the last **finished** execution).

Sources: `packages/app-custom/src/session/timeline/message-timeline.tsx`,
`packages/app-custom/src/session/composer/`, `packages/app-custom/src/session/requests/{model,background}.ts`,
`packages/protocol/src/groups/session.ts`.

## 10. Permission and question cards — wave 2

```text
GET /api/session/{sid}/permission       → {data:Permission.Request[]}
GET /api/session/{sid}/permission/{id}  → {data:Permission.Request}
POST /api/session/{sid}/permission/{id}/reply  {decision:"once"|"always"|"reject",message?:string}
```

Request fields: `id,sessionID,action,resources`, optional `created,save,metadata,message,source`. Tool source is
`{type:"tool",messageID,id}`. For the approved single “Permitir”, use **once**, not always. `always` is a separate
explicit choice. `resources[0]` supplies the `git push origin neon-mountain` display; an action alone is insufficient.
Reply to `request.sessionID`, which may be a descendant rather than the open root. `custom.requests/permissions`
provides global pending permission snapshots; family snapshot filters to this tree. Web auto-approve is a client
responder sending once, not a server permission-rule update.

```text
GET    /api/session/{sid}/form          → {data:Form.Info[]}
GET    /api/session/{sid}/form/{id}     → {data:Form.Info & {state}}
POST   /api/session/{sid}/form/{id}/reply {answer:{q0:"MIT"}}
DELETE /api/session/{sid}/form/{id}?message=<optional dismissal text>
```

Form info: `id,sessionID,title,fields`, optional `created,metadata`. A question has `metadata.kind:"question"`, with
tool link in `metadata.tool`. Native fields are generic: `string`, `number`, `integer`, `boolean`, `multiselect`,
`external`. The web question dock handles string and multiselect fields. Options are `{value,label,description?}`;
send **value**, not label. `custom:true` allows free text for a string field. Multiselect sends a string array:
`{answer:{q0:["MIT","EPL-2.0"]}}`. `required`, `hidden` and `when:[{key,op:eq|neq,value}]` control visibility/validation.
Inactive fields must not be submitted. Multiple questions use their actual field keys (`q0`, `q1`, …), not indexes
as object keys. Omit unanswered optional values.

State is `{status:"pending"}`, `{status:"answered",answer}`, or `{status:"cancelled",message?}`. Dismiss is DELETE,
not an empty answer. `metadata.kind:"websearch.provider"` is a different form flow. The web suppresses ordinary
composer while a request blocks it; the approved native card can remain above its composer, but don't silently
auto-answer when sending text.

Sources: `packages/schema/src/{permission,form}.ts`, `packages/protocol/src/groups/{permission,session}.ts`,
`packages/app-custom/src/session/requests/{session-permission-dock,session-question-dock}.tsx`,
`packages/app-custom/src/session/requests/{model,auto-approve}.ts`.

## 11. Model, effort and agent selection — wave 2

Catalogs: `GET /api/model`, `/api/model/default`, `/api/agent`, each with Location. Models include `id,providerID,name`,
`enabled`, `capabilities:{tools,input,output,temperature?}`, `variants:[{id,settings}]`, `limit`. Effort choices are
the chosen model's **variant IDs**, not a universal enum. Do not select a model using only `id`.

```text
POST /api/session/{sid}/agent {agent:"build"}
POST /api/session/{sid}/model {model:{providerID:"llm-proxy",id:"gpt-6-luna",variant:"low"}}
```

The web keeps chooser state locally until submit. On **steer**: switch agent, commit staged revert if any, switch
model, admit prompt. On **queue**: don't mutate the active session's agent/model. Intended selections in presentation
metadata do **not** override execution configuration at later delivery. iOS must not pretend per-prompt model fields
exist. Agent/model selection produces timeline notices; reconnect reads the session's current selection.

`RPC custom.preferences/get({})` returns `{version:1,revision,imported,data}`. Relevant data:

```ts
{models:{user:{providerID,modelID,visibility:"show"|"hide",favorite?:boolean}[],
         variant:Record<string,string>,favorites?:{providerID,modelID}[],
         providerOrder?:string[],default?:{providerID,modelID,variant?}},
 settings:{followUpBehavior:"queue"|"steer",autoApprove:boolean,autoSave:boolean,
           notifications:{agent:boolean,permissions:boolean,errors:boolean},…},…}
```

Mutations to `custom.preferences/mutate` are intent objects, e.g.
`{type:"settings.followUpBehavior",value:"queue"}`, `{type:"model.favorite",providerID,modelID,favorite:true}`,
`{type:"model.visibility",providerID,modelID,visibility:"show"}`,
`{type:"model.variant",providerID,modelID,variant:"low"}`,
`{type:"model.default",model:{providerID,modelID,variant}}` (null clears). These are preferences, not immediate session
switches. The web may use a designated authority server for preferences; the single-server iOS route uses the same
server as Sessões.

Sources: `packages/app-custom/src/providers/models/selection.tsx`,
`packages/plugin-app-custom/src/preferences/rpc.ts`, `packages/app-custom/src/preferences/context.tsx`,
`packages/protocol/src/groups/{model,agent,session}.ts`.

## 12. Composer triggers — wave 3

The four triggers are **client grammar**, not a universal backend text parser. A selected token needs structured
serialization; typing raw `@foo`, `$foo` or `#foo` does not automatically resolve it at admission.

| Trigger        | Discovery and selected-token behavior                                                                                                                                                                                                                                                                                         |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `&` files      | `/api/fs/find?location[directory]=…&query=infra&limit=20`, `{location,data:[FileSystem.Entry]}`; keep relative path, type and display metadata. Recent file picks are client-local. Selected file becomes `files:[{uri:"file:///absolute/path",name?,mention}]`. Optional `?start=10&end=20` selects 1-based inclusive lines. |
| `@` references | `/api/reference?location[directory]=…`; hide hidden references. Directory reference becomes a file URI for `reference.path`, producing a directory listing.                                                                                                                                                                   |
| `@` sessions   | `/api/session?parentID=null&order=desc&limit=50` (+`search`), dropping archived roots client-side (the list has no archive filter) and reading up to four pages until 10 (30 when searching) live ones remain. Exclude the current session; the current master is labeled "Mestra atual"; repeated titles show `directory · age`. Store `metadata.sessions` and append a reference instruction; not an embedded transcript.                                                                                                           |
| `@` agents     | `/api/agent`; hidden/primary-only excluded. `agents:[{name,mention}]`, not a session selection or immediate child spawn.                                                                                                                                                                                                      |
| `@` MCP        | `/api/mcp/resource?location[directory]=…` returns resource catalog. Append `MCP resource <uri> (server: <name>)`; non-file MCP URI is not a prompt file attachment.                                                                                                                                                           |
| `@` apps       | `custom.app-mentions/list({})`, Location-scoped, returns `{apps}`. Store metadata.apps and append app/tool guidance. This can expose user applications; not needed to fake the approved files/sessions/agents examples.                                                                                                       |
| `$`            | `/api/skill?location[directory]=…`; display name/description, submit `skills:[{id,mention}]`. Catalog can contain full local skill content: never dump it unredacted into fixtures.                                                                                                                                           |
| `#`            | `custom.snippets/list({})` → `{items:[{id,name,description,aliases,content,project?}]}`. Project-specific names override global case-insensitively. Replace token with content **on send**, shift subsequent UTF-16 offsets. No `snippets` API field.                                                                         |
| `/`            | Merge backend command catalog, enabled client command handlers, and skills with `slash:true` that don't collide with commands. Dispatch as below.                                                                                                                                                                             |

Registered backend command: `GET /api/command?location[directory]=…` returns `{location,data:[{name,description?}]}`.
Execute `POST /api/session/{sid}/command` with `{name:"conversation-review",text:"arguments",files?,agents?,skills?,delivery?}`.
`name` excludes `/`; `text` excludes the command prefix. Response 204. The callback runs immediately (delivery is
available to it); this endpoint has **no** prompt idempotency ID or presentation metadata field.

Client commands are not backend names just because they appear next to them:

- `/btw`: open a local side-question sheet, section 14.
- `/compact`: `POST /api/session/{sid}/compact`, optionally `{id,delivery}`, returns a compaction inbox admission.
  Default steer; no need to wait for idle.
- `/undo`: local revert workflow, not `/command {name:"undo"}`. The web restores the last user draft, cascades child
  boundaries through `custom.session-family/revert({sessionID,cutoff})`, interrupts/waits, stages
  `POST /api/session/{sid}/revert/stage {messageID,files?}`, and cancels pending prompts referring to the old history.
  `/redo` clears/advances staged reverts. Fork is outside this screen's initial scope. Native sent-message revert
  is specified below.
- `/model`, `/agent`, `/new`, etc. open local pickers/navigation.
- A slash-enabled skill becomes a **normal prompt** with `skills:[{id,mention}]`; it is not `/command`.
  `POST /api/experimental/session/{sid}/skill {id,resume?}` exists for explicit activation, but is not the web
  composer's slash-skill send path.
- Unrecognized slash text falls through to a normal prompt.

Source: `packages/app-custom/src/composer/{model,submit,prompt-parts,session-reference}.ts`,
`packages/app-custom/src/composer/suggestions/machine.ts`,
`packages/app-custom/src/session/commands/use-session-commands.tsx`, `packages/app-custom/src/session/revert.ts`,
`packages/plugin-app-custom/src/{snippets,app-mentions}/rpc.ts`.

### Sent-message undo (23 October)

Compatible unchanged with installed custom `1042585c285c25d4b5d4fd292d0b7eb5fb7c470e`:

1. The loaded user message supplies restoration data. Lean history omits only assistant tool-result media.
2. `custom.session-family/revert({sessionID,cutoff:target.time.created})`, scoped to the viewed Session's directory,
   returns descendant boundaries in breadth-first order. This RPC **does not perform rollback**.
3. In that order: interrupt/wait each busy child, then `POST /api/session/:child/revert/stage`
   `{messageID,files:false}`. Child Sessions remain present, including their preferences and local drafts.
4. Always bodyless POST parent `interrupt`, then `/api/experimental/session/:id/wait`, then parent
   `/revert/stage` with `{messageID}`. Only parent staging rolls back files through its native snapshots.
5. Capture pending parent user inbox items, GET `/inbox`, and cancel the union of captured IDs and authoritative
   user rows created by the post-stage cutoff. This is best effort, like the web; child inboxes remain untouched.

Each child/planning failure is reported while continuing; a parent failure restores the server timeline boundary.
The restored draft remains editable. Repeated same-target requests join; other reverts serialize while immediately
projecting the requested boundary/draft. Submission waits for the operations, including inbox cleanup. The
per-server/session coordinator survives conversation remounts.

Every delivered root/master user bubble (also its sticky header and long-press menu) offers
**Redefinir para este ponto**, after a native confirmation (iOS only; the web has none). Child bubbles omit it, as the web does. Hidden history begins
at the selected user message. **Refazer** advances one user boundary; at the last boundary it asks
`custom.session-family/clear({sessionID})`, clears descendants sequentially (interrupt/wait busy ones), then
bodyless `DELETE /api/session/:id/revert` and resets the composer. No Session DELETE is involved.

Restoration replaces text, valid token spans, inline/path attachments, quotes and unmentioned file/comment context;
keeps agent/model selection; and clears queue-edit/submission identity. Web presentation metadata requires a string
`displayText` plus `comments` array; otherwise restoration uses wire text. Files and context survive draft persistence.
The next prompt/command switches agent, commits the staged parent boundary via bodyless
`POST /api/session/:id/revert/commit`, switches model, then admits work. Queue commits before admission too.
SSE staged/cleared/committed events trigger authoritative history reconciliation and filtering by the current boundary.

References and verified web request traces: `.agent-artifacts/desfazer/WEB.md`, `web-cascade-result.txt`,
`web-redo-result.txt`. The dedicated runner `script/test-revert.py` only creates/mutates its ledger-owned 4177 fake
repositories and Sessions; native transport failure injection is DEBUG-only and restricted to one named Session.

## 13. Attachments — wave 3

Request versus stored attachment are deliberately different:

```ts
// Prompt input (URI only)
{uri:"data:image/png;base64,…",name:"exemplo.png"}
// Delivered user message
{data:"base64…",mime:"image/png",source:{type:"inline"},name:"exemplo.png"}
```

Server accepts `data:` and `file:` only, detects MIME from bytes, normalizes images, and materializes them at
admission. HTTP attachment URLs are unsupported. File source after materialization is `{type:"uri",uri}`. Directory
attachments become directory listings. Text files support 1-based inclusive `start/end` line query parameters.

The web first stages **every blob**, including inline images, into the server's `paths.tmp` from `/api/info`:

```http
POST /api/experimental/fs/write?location[directory]=…&path=<tmp>/uploads/<uuid>/example.png
Content-Type: application/octet-stream

<raw bytes>
```

Response `{location,data:{path}}`. Uploads are not multipart. A local preexisting source path can bypass staging only
when genuinely accessible to that server (an iPhone Photos URL is not a server file path).

Inline web allowlist: PNG/JPEG/GIF/WebP and PDF, at most **20 MiB**, and only when the selected model advertises that
input capability. Other files, unsupported media or larger blobs are uploaded/staged and referenced as
``Attached file: `/absolute/path` `` in model-facing text plus `metadata.attachments`, rather than forced into `files`.
Server embedding limit is also 20 MiB. Do not confuse the upload capability with an unlimited inline prompt budget.
The current fixture includes a valid 96×64 PNG with two colored shapes. The original 1×1 sample had invalid PNG
checksums and was replaced during the wave-1 review; the native decoder rejects that malformed sample in tests.

Sources: `packages/app-custom/src/composer/attachments/{deliver,destination}.ts`,
`packages/app-custom/src/composer/request.ts`, `packages/core/src/session/prompt.ts`,
`packages/protocol/src/groups/fs.ts`, `packages/schema/src/prompt-input.ts`.

## 14. Selection, comments and side questions — wave 4

Copy is local. “Comentar” adds a local draft quote, sent with the next message; no quote endpoint exists.
Hiding a sent quote's response mark (after an acknowledged send or “Remover marcação”) is also local to the device and
never rewrites `metadata.quotes`.

```ts
type ChatQuote = {
  id: string
  messageID: string
  partID: string
  text: string
  comment: string
  commentPrompt?: ComposerPart[]
  anchor?: { start: number; end: number; exact: string }
}
```

Preserve message ID, stable UI part ID (section 1), selected exact text, UTF-16 offsets within that text part, and
comment. `metadata.quotes` restores quoted blocks inside sent user bubbles. A quote-only message is sendable even
without main composer text. Append this to model-facing `text`:

```text
Comments on earlier assistant messages:

1. Quoted from message msg_example (part msg_example:text:0):
> tem integração nativa com o GitHub
User comment: Confere essa integração antes do PR
```

File-review comments are separate `metadata.comments:[{path,selection?:{startLine,startChar,endLine,endChar},comment,
preview?,origin?:"review"|"file"}]`; send their file attachment and model-facing explanation as well. Quotes are not
file-review comments. The web renders “Quoted from an earlier message”, quote, then comment in the user bubble; the
native card may use `Citações · 1` before sending. Files/agents/skills embedded in a quote comment must be extracted
into prompt arrays without the main text's mention offsets; quote inline files follow main files in quote order.
Comment attachments are `commentPrompt` parts: `{type:"image",id,filename,mime}` becomes inline bytes plus
`blob:{id,url:""}` when the model accepts images, otherwise a staged `{type:"path",id,filename,mime,path}`; other files
(PDFs included) are always staged paths, listed as `File attached to this comment: \`…\``.

Sources: `packages/app-custom/src/composer/chat-quote*.{ts,tsx}`, `src/composer/{comments,chat-quotes}.tsx`,
`src/composer/{comment-note,request}.ts`, `packages/session-ui-custom/src/message/user-message-quote.tsx`.

### `/btw` / “Pergunta paralela”

```http
POST /api/session/{sid}/generate

{"prompt":"The user is asking a quick side question about the conversation so far. Answer directly and concisely in markdown from what you already know. Do not call any tools and do not take any actions.\n\n> Huly · EPL-2.0\n\nA EPL-2.0 permite uso comercial?"}
```

Response **`{data:{text:"…"}}`**, one JSON response, **not SSE**. Keep local thinking/loading state until it arrives.
The endpoint uses the session's committed context/model, not the composer's uncommitted model chip. It does not
admit a prompt, fork, create saved messages, or save side-question history. Web includes at most five previous local
side Q&As, truncating questions to 1,000 and answers to 3,000 characters. Selection opens the sheet with the quote as
blockquote. Binary attachments are dropped; textual references/snippets remain text. Cancel via the request's abort
signal; never interrupt the main session. The no-tools policy is the web's instruction, not a dedicated `/btw` API.
Closing the sheet discards its local conversation.

Sources: `packages/app-custom/src/session/btw/{model,state,question}.ts`, `{panel,composer}.tsx`,
`packages/core/src/session/generate.ts`, `packages/protocol/src/groups/session.ts`.

## 15. Viewed acknowledgement — wave 1

```http
POST /api/session/{sid}/view

{"idle":1792600000000}
```

Use the **observed `session.time.idle`**, not wall-clock now. While open and visible, acknowledge each newly observed
idle watermark after presenting the corresponding result; deduplicate in-flight requests. On opening, capture the
old viewed boundary for `Novas mensagens` first. Skip missing idle or values already covered by viewed. The server
only moves the watermark forward and rejects/ignores a value newer than its current idle. It is not a per-message
read receipt, and no arbitrary “mark unread” write exists. Update local viewed after success, then reconcile SSE.

Sources: `packages/app-custom/src/shell/notifications/session-viewed.ts`,
`packages/core/src/session/session.ts`, `packages/protocol/src/groups/session.ts`.

## Reproduction, fixtures and verification

```sh
bun packages/ios-custom/script/seed-conversation.ts
bun packages/ios-custom/script/capture-conversation.ts
# Refresh only snapshots, preserving the already-recorded real SSE sequence (no model call):
bun packages/ios-custom/script/capture-conversation.ts --snapshot-only
# Stop only this seed's sessions, leaving their history:
bun packages/ios-custom/script/seed-conversation.ts --stop
# Recreate only this seed (interrupts/deletes its own manifest IDs):
bun packages/ios-custom/script/seed-conversation.ts --reset
```

Both scripts reject non-localhost targets and production ports, and verify the sandbox ownership manifest.
`--home`/`--url` select another explicitly owned sandbox. No port 4096/4178 calls or persistence access occurred.
Manifest: `<sandbox-home>/seed-conversation.json`; fake repository: `<sandbox-home>/repos/ios-conversation`, branch
`neon-mountain`. This is an independent fake repo, not a new development worktree. The seed does not alter Sessões
permissions, questions, sessions or preferences. Existing `revisar` and `resumo` snippets are reused; only missing
names are added. `conversation-review` command and `conversation-check` skill are defined inside the fake repo.

The imported data deliberately supplies exact Portuguese Markdown, reasoning, read/edit/subagent examples and dates.
Actual running shell, pending permission and question are created with tiny `llm-proxy/gpt-6-luna`, `low` calls.
Long work is `sleep 86400` / a cheap Bun sleep script; no research, remote git push or real test suite executes.
The pending git push never runs without approval and the fake repo has no remote. Live tools run in a subsequent
step after deterministic imported activity, with an explicit synthetic instruction rather than an extra user bubble.
Thus all mockup operations are represented, but they are **not literally one simultaneously executing imported step**.
The background children are linked imported sessions, not fabricated claims that the launch tool is still running.

Testing exposed Luna treating an imported child's “aguarde” instruction as still binding. The script was corrected
to use an unambiguous authorized child prompt; the final complete reset and capture both passed without intervention.
Imported usage gives the approved 42% (A), 58% (B), and 61% (C) rings; those are explicit fixture measurements, not
claims about tokens billed by live calls. The real model and low variant are retained rather than inventing Opus
calls. Long sleepers remain subject to backend inactivity/shutdown; use the
manifest and active snapshot to check before screenshots. Do not silently restart someone else's sessions.

### Current session IDs

| ID                                     | Title / purpose                     | Verified state                                                                                |
| -------------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------------------- |
| `ses_1da0e2e23e224422ae503af32a04e31b` | Conversa A — trabalhando            | Foreground Bun sleep, imported reasoning/read/+48 edit, queue=1; two live children            |
| `ses_76e015509e16427da0c7b98f7c5cd7fe` | Comparar alternativas Linear        | Explore child; sleeping                                                                       |
| `ses_83c38d2b26d746fdadd99341aefbc6be` | Revisar licença dos projetos        | General child; completed                                                                      |
| `ses_3a190f409abc498e8c30c13e07321e0a` | Avaliar integrações disponíveis     | Explore child; sleeping                                                                       |
| `ses_375412831b964188afaa08e1ffb7230e` | Conversa B — precisa de você        | Final Markdown + follow-up; pending `git push origin neon-mountain`                           |
| `ses_8a70f2ed257f40819da687a6aefbeaae` | Conversa C — histórico e compositor | 89 messages, three pages (40/40/9), image, quote anchor, errors/retry/compaction, unread tail |
| `ses_8ab40d49ba554de5bfe2e34258b64a3d` | Conversa D — pergunta               | Pending license question with three options and free text                                     |
| `ses_5ec9997204354097b64b51099cb1b6bd` | Conversa — captura SSE              | Completed `printf OK` + text; safe admission/idempotency/view/side-question probe             |

IDs change on reset; use the manifest, not hardcoded IDs in app code. Existing screenshot reference
`ses_ea11cf618ffe7awBL1pt5cnKA2` was not modified.

Fixtures live in `OpenCodeKit/Tests/OpenCodeKitTests/Fixtures/Conversation/`. `index.json` lists every file and
capture time. Included: latest/older/oldest transcript pages; root/child session data; full tool image vs lean
transcript; actual SSE sequence and its final transcript; inboxes; permission/form; family summary/page/error;
context; models, agents, commands, fixture skill, snippets, file search/references, shells; prompt request/admission
and viewed session. The event sequence contains 20 event types, including real tool progress/success, text deltas,
step lifecycle, admission/delivery and execution success. It does not fabricate a reasoning stream or permission reply.
Catalog skill capture is scoped to the fixture-owned skill to avoid exporting inherited private skill documents;
agent instructions, credential-like fields, local paths and account addresses are redacted. Wire shape/envelopes
are preserved; these sanitized paths are not usable live URLs. `btw-response.json` is the real transient generation
response; a separate before/after transcript comparison confirmed the side question creates no saved message.

Validation on this checkout: final seed reset and capture succeeded; 41 JSON files parsed, with 111 projected
messages plus session/model/agent/request/family records decoded against the repository schemas. The two existing
`test/session-family.test.ts` tests passed. `bun run check` completed successfully (the repository reports lint
warnings, not a warning-free baseline); both scripts also bundled for Bun. URL-guard, secret/path/account scan,
Prettier and `git diff --check` passed. No Swift/UI tests were added or required for these data-only deliverables.

### Pitfalls

- Cursor presence is not evidence of another nonempty page; timestamps do not define message ordering.
- Tool completion, child completion, assistant streaming completion and execution completion are different facts.
- `snapshot.count` is all descendants, not active work; foreground shell must not inflate the agents capsule.
- `read_failed` is a broad RPC error. The current Swift call is correct; the old failure's root cause remains unknown.
- Prompt input uses URI attachments; stored messages use base64 files. Model selection is not a per-prompt field.
- Footer web time is creation; the approved native completion time should use completed. Model IDs need provider IDs.
- The ring is latest measured assistant context, not summed session tokens or compaction cost.
- UI text/reasoning part IDs are derived; preserve their type-specific ordinal for quotes and stable row identity.
- `always` permission approval is not the same as “Permitir uma vez”; a blank question answer is not dismissal.
- `/btw`, `/compact`, `/undo` are not interchangeable `/command` requests. Side questions are transient JSON requests.
- Never dump entire inherited skill/config/provider payloads into fixtures assuming path redaction removes private data.
