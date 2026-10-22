# Conversation contract (native iOS)

Verified against this worktree's code and the isolated `http://127.0.0.1:4177` server on 2026-10-21. This is the
implementation contract for waves 1–4, not a proposal for new APIs. The approved layout is described in the README,
“Second screen: Conversa”; the web implementation is the behavioral reference. No Swift or web UI changes are needed
to use this contract.

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

### Groups, sticky prompt, days and unread

Web projection sources: `packages/session-ui-custom/src/timeline/{projection,detail,timeline-row}.ts`,
`src/timeline/session-timeline-row.tsx`; sticky positioning:
`packages/app-custom/src/session/timeline/virtualizer.tsx` (`data-sticky-user`).

- A backend step is one assistant message / one LLM call. The web can group adjacent activity **across** assistant
  messages; “Usou” is a display group, not a separate API object or an LLM call count.
- Count tool/direct-shell entries, not reasoning parts. If there are only reasoning parts, count those instead.
  Deduplicate localized tool names in first appearance order. Notices do not increment the tool count.
- Keep content order; reasoning duration is its own `time.completed - time.created` when available. Do not guess
  reasoning duration from the full step when its timestamps are absent.
- A group is pending when busy or any included tool is `streaming/running`. The approved iOS presentation opens the
  current group and collapses finished groups; tapping expands without another transcript request.
- Tool IDs are real wire IDs. Stable text/reasoning UI IDs are respectively `${message.id}:text:${ordinal}` and
  `${message.id}:reasoning:${ordinal}`, with ordinals counted **within that content type**. Use these for quotes.
- Failed tools remain visible even if a display category is hidden, except `todowrite`: V2 removed that tool with
  no replacement. Its historical parts, including errors, are suppressed in iOS, do not count in “Usou” or its
  kinds summary, and contribute no final-answer boundary. The web's `idle` marker is not itself rendered as a row.
  Compaction and selection/location notices split groups.
- Final-answer separators are projected over each whole user group, including history: completed, error-free,
  retry-free `finish:"stop"` text rows form sequences delimited by rendered activity. Prefer the first
  `state.phase:"final_answer"`, otherwise the first text of the last eligible message in that sequence. Commentary
  after an explicit final answer starts another sequence. Draw only after earlier activity, never before the
  exchange's first content. Several separators can belong to one exchange; hidden activity contributes no boundary.
  They are not server messages and do not change text/quote part IDs.
- Sticky prompt is the **same** latest user bubble positioned under the header and clamped to two lines, not a second
  message. Preserve identity and selection anchors while scrolling.
- `Hoje`/`Ontem` are local-calendar grouping of `time.created`; never sort the history by that date. Capture the
  unread boundary before acknowledging view. There is no unread-message count or persisted divider: use the observed
  session's prior `time.viewed` and incoming assistant activity to place one `Novas mensagens` divider. No API
  supports moving the viewed watermark backwards.

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
4. On every reconnection/foreground return refetch authoritative state. A tail refetch also restores final phase,
   snapshot and error data that a simplified delta reducer may omit. Preserve the pre-view unread boundary.
5. Maintain execution activity separately from latest message's completion: the root can be idle while children run,
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

## 3. Assistant footer — wave 1

- Display name: look up the assistant's **`model.providerID` and `model.id` pair** in `/api/model`; fall back to ID.
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
shows a return-to-parent action. It is read-only as far as ordinary prompting is concerned: **no composer**. Permission
and question responses still use their actual owner. Clicking a shell instead reveals its tool in the owner's
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
| `@` files      | `/api/fs/find?location[directory]=…&query=infra&limit=20`, `{location,data:[FileSystem.Entry]}`; keep relative path, type and display metadata. Recent file picks are client-local. Selected file becomes `files:[{uri:"file:///absolute/path",name?,mention}]`. Optional `?start=10&end=20` selects 1-based inclusive lines. |
| `@` references | `/api/reference?location[directory]=…`; hide hidden references. Directory reference becomes a file URI for `reference.path`, producing a directory listing.                                                                                                                                                                   |
| `@` sessions   | `/api/session?parentID=null&order=desc&limit=10`; searching adds `search` and uses limit 30. Exclude the current session. Store `metadata.sessions` and append a reference instruction; not an embedded transcript.                                                                                                           |
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
  `/redo` clears/advances staged reverts. Do not expose a nonworking “undo” action merely for visual parity; full
  revert/fork is outside this screen's initial scope.
- `/model`, `/agent`, `/new`, etc. open local pickers/navigation.
- A slash-enabled skill becomes a **normal prompt** with `skills:[{id,mention}]`; it is not `/command`.
  `POST /api/experimental/session/{sid}/skill {id,resume?}` exists for explicit activation, but is not the web
  composer's slash-skill send path.
- Unrecognized slash text falls through to a normal prompt.

Source: `packages/app-custom/src/composer/{model,submit,prompt-parts,session-reference}.ts`,
`packages/app-custom/src/composer/suggestions/machine.ts`,
`packages/app-custom/src/session/commands/use-session-commands.tsx`, `packages/app-custom/src/session/revert.ts`,
`packages/plugin-app-custom/src/{snippets,app-mentions}/rpc.ts`.

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
