# Agents Live Activity (`custom.live-activity`) — contract v1

One iOS Live Activity (Lock Screen + Dynamic Island) per connected server that summarizes the agent sessions running
on that server. It only informs: there are **no buttons and no Live Activity intents**. Tapping opens the app.

This document is the contract between the backend (`packages/plugin-app-custom/src/live-activity`) and the iOS app
(`packages/ios-custom`). Both sides implement exactly what is written here. The example payloads in
[`live-activity/`](live-activity/) are normative fixtures: the backend tests must produce them (modulo IDs and times)
and the iOS tests must decode and render them.

Approved visual references (not versioned): `.agent-artifacts/live-activity/progresso-pergunta-a.png` (one pending
question), `progresso-duas-perguntas.png` (two), and the Dynamic Island of `opcao-3-painel-cotas.png`.

## Ownership

| Concern | Owner |
| --- | --- |
| Which sessions count, their status, focus choice, activity text, progress, ordering, truncation | Backend |
| Token storage, start/update/end decisions, throttling, alerts, APNs delivery | Backend |
| Widget UI (Lock Screen, Dynamic Island), colors, copy layout, deep links | iOS |
| Token collection and registration, local start/update while in foreground, duplicate cleanup | iOS |
| Theme snapshot | iOS produces it, backend stores and echoes it, never interprets it |

The backend never sends UI copy other than session titles, project names, `activity`, `text` and push `alert`
strings defined below. All user-visible strings are pt-BR.

## Wire conventions

- JSON, camelCase keys. Optional fields are **omitted** when absent (decoders must also accept `null`).
- All times inside `content-state`, `attributes` and RPC payloads are **epoch milliseconds** (integer). ActivityKit
  decodes `Date` from push JSON with its own reference date, so iOS stores these as `Int64`/`Double` and converts.
  Only the APNs `aps` fields `timestamp`, `stale-date` and `dismissal-date` are epoch **seconds**, as Apple requires.
- Tokens are lowercase hex strings.
- IDs: `sessionID` is the V2 Session ID. `directory` is the Session's Location directory (absolute path).

## ActivityAttributes (static)

Swift type name must be exactly **`AgentsActivityAttributes`** (it is the APNs `attributes-type`).

```ts
AgentsActivityAttributes {
  serverKey: string        // opaque, chosen by the app at `register`; identifies the server inside the app (1–100 chars)
  theme: Record<string, string>  // role name → "#RRGGBBAA"; produced by the app, echoed verbatim by the backend
}
```

`theme` keys are `ThemeRole` case **names** (not raw values). Required keys: `background`, `surface`, `border`,
`textStrong`, `text`, `textSecondary`, `textWeak`, `primary`, `success`, `warning`, `error`, `accent`. At most 24
entries; keys ≤ 32 chars; values match `^#[0-9a-fA-F]{8}$`. Attributes are immutable for the life of an activity, so
a theme change applies to the next activity.

## ContentState (`AgentsState`, dynamic)

```ts
AgentsState {
  v: 1
  updatedAt: number                 // epoch ms when the backend computed this state
  host: string                      // machine display name, e.g. "MacBook Pro" (macOS ComputerName), ≤ 40 chars
  counts: {
    working: number                 // top-level sessions executing with no pending request
    question: number                // sessions with ≥1 pending question (form) request
    permission: number              // sessions with a pending permission request and no pending question
    failed: number                  // sessions stopped with an error (see "Failed")
    idle: number                    // sessions that finished successfully in the last 30 minutes (kept for older builds)
    unread?: number                 // rev. 2026-10-28: finished sessions with unread output (see "Unread")
  }
  activeTotal: number               // working + question + permission ("4 ativas")
  focus?: Focus                     // the session shown with progress; absent when nothing is working
  attention: Attention[]            // pending questions/permissions, oldest first, at most 3
  attentionTotal: number            // question + permission (may exceed attention.length)
  sessions: Row[]                   // rows for the expanded Dynamic Island, at most 4, ordered (see below)
  needs?: Need[]                    // rev. 2026-10-29: what needs Alexandre, at most 3, ordered (see "Needs")
}

SessionRef { sessionID: string, title: string /* ≤ 80 */, project: string /* ≤ 40 */, directory: string }

Focus = SessionRef & {
  startedAt: number                 // epoch ms the current execution started (drives the on-device timer)
  activity?: string                 // pt-BR, ≤ 60 chars, e.g. "Editando ConversationStore.swift"
  progress?: Progress
}

Progress { done: number, total: number, unit: "subagents" }   // total ≥ 1, 0 ≤ done ≤ total

Attention = SessionRef & {
  kind: "question" | "permission"
  since: number                     // epoch ms the oldest pending request of this kind was asked
  text?: string                     // question text, or permission summary such as "bash · bun test --filter oauth"; ≤ 120
}

Row = SessionRef & {
  status: "question" | "permission" | "failed" | "working" | "idle"
  progress?: Progress               // only for working rows
}

Need = SessionRef & {
  kind: "question" | "permission" | "failed" | "unread"
  since: number                     // asked (oldest pending request), failed (execution end) or answered (unread time)
}
```

`unit` is an enum so a future task list can add `"tasks"`; iOS renders unknown units as a bare `done/total`.

### Backend rules

- **Tracked sessions:** top-level (no parent), not archived, across **all** Locations of the server. Subagent child
  sessions never appear as rows; their state **rolls up into their top-level session** (at any depth), the same way
  the Sessões screen rolls up running state and requests.
- **Working (rolled up, rev. 2026-10-27):** a top-level session is working when it **or any descendant** is
  executing. A parent whose own execution ended while background subagents still run is working, not idle. Its
  `startedAt` is the start of the top-level session's most recent execution (the turn that spawned the running
  descendants), falling back to the earliest start among the executing descendants.
- **Background jobs (rev. 2026-10-28):** an unfinished background task of the session or of any descendant (a shell
  moved to the background, a background subagent and equivalents) also makes the family working, even while nothing
  executes. It stops counting when the task ends; the completion notice then wakes the session as a new execution.
  Without any known turn of the top-level session, `startedAt` falls back to the earliest start among executing
  descendants and unfinished tasks. With only tasks pending, `activity` describes the newest one (`Rodando <command>`).
- **Status precedence per session:** question > permission > working > failed > idle (rev. 2026-10-29: working
  outranked by failed before; now a failure whose family still works, such as a background shell, is working, like
  its Sessões row).
- **Failed:** the session's latest execution ended with `session.execution.failed` (a user interruption is not a
  failure). It stays failed until a new execution starts, the session is viewed (`session.viewed`), archived or
  deleted, or 24 hours pass.
- **Idle:** neither the session nor any descendant is executing or has an unfinished background task (rev.
  2026-10-28), and its latest execution succeeded within the last 30 minutes.
- **Unread (rev. 2026-10-28):** a top-level session that is not working, has no pending request and is not failed,
  whose latest assistant output is newer than its viewed watermark (`time.viewed`) — the same rule as the orange
  unread dot in Sessões. Muting is gone (2026-10-28: "Avisar ao terminar" replaced it, see
  [session-notifications.md](session-notifications.md)), so `mutedSessions` no longer hides anything. No time window: it stays
  unread until the session is viewed (`session.viewed`), archived or deleted. Chats follow the same rule as other
  top-level sessions; the current Sessão mestra (`masterSessions.local`), which Sessões never lists, is never unread
  (rev. 2026-10-29). Unread sessions never keep a Live Activity alive (the end rule is unchanged).
- **Needs (rev. 2026-10-29):** every session that needs Alexandre, the rows of the Sessões "Precisa de você" section
  and the iOS `counts.forYou` = question + permission + failed + unread (one per session, by the precedence above):
  question, permission (oldest `since` first), failed (most recent first), unread (most recent first); cut to 3.
  `attention` keeps only requests, so older apps (and the watch's Responder, which needs a request) are unchanged.
  The watch gateway's `/state` also answers while only unread sessions wait; `snapshot` and `changed` stay `null`
  then.
- **Focus:** among working sessions, keep the current focus while it is still working; otherwise pick the one whose
  execution started most recently. Absent when `counts.working == 0`.
- **activity** (from the latest step activity of the most recently active **executing** session in the focus
  family: the focus itself or one of its descendants): edit/write/patch → `Editando <basename>`; read →
  `Lendo <basename>`; shell → `Rodando <command, first 40 chars>`; grep/glob → `Buscando <pattern>`; webfetch or
  websearch → `Pesquisando na web`; subagent → `Delegando para <agent>`; reasoning → `Pensando`; text →
  `Escrevendo resposta`; otherwise omit.
- **progress:** subagent children created by the focus session's most recent execution; `done` = children whose
  execution finished (any outcome). Omit when there are none.
- **sessions order:** question, permission (oldest `since` first), failed (most recent first), working (focus first,
  then most recent activity), unread (most recent first); cut to 4. Rows with `status: "idle"` are emitted **only for
  unread sessions** (rev. 2026-10-28; read sessions no longer appear as rows). The status string stays `idle` so older
  builds keep decoding it; newer builds label it `Não lida`.
- **Size:** the whole APNs body must stay ≤ 4096 bytes. Trim in this order until it fits: `attention[].text`, then
  `needs` beyond 2, then `sessions` beyond 3, then `attention` beyond 2, then shorten titles.

## RPC `custom.live-activity`

Same plugin RPC mechanism as `custom.device` (iOS calls it with `rpc("custom.live-activity", "<method>", ...)`).

| Method | Input | Output |
| --- | --- | --- |
| `register` | `{ deviceID, serverKey, environment: "sandbox" \| "production", theme, pushToStartToken? }` | `{ push: "configured" \| "unconfigured" }` |
| `activity` | `{ deviceID, activityID, pushToken }` | `{}` |
| `ended` | `{ deviceID, activityID, reason: "ended" \| "dismissed" }` | `{}` |
| `unregister` | `{ deviceID }` | `{}` |
| `snapshot` | `{}` | `{ state: AgentsState \| null }` (`null` = nothing working, waiting or failed) |

Event **`changed`**: `{ state: AgentsState | null }`, emitted when the state changes, coalesced to at most one per
second. Wire type `rpc.custom.live-activity.changed`. Exactly one delivery per change to a connected app, even with
several Location plugin instances.

- `deviceID` is the same ID the app already uses for `custom.device` (1–100 chars).
- `register` is idempotent and is called on every launch/foreground and whenever the push-to-start token or the
  theme changes. `activityID` is ActivityKit's `Activity.id`.
- `push: "unconfigured"` means no APNs credentials: the backend accepts and stores everything but sends nothing; the
  app keeps the activity updated only while it is running.
- Registrations are kept in plugin storage (shared by every Location instance) and dropped after 30 days without
  `register`, on `unregister`, or when APNs reports the token invalid.

## Lifecycle

**Start.** A device/serverKey may have at most one live activity **on screen, in any state** (rev. 2026-10-27: the
device showed an ended card lingering above a new one). Ended activities never stay visible.

- In foreground the app starts it locally (`Activity.request(..., pushType: .token)`) when `snapshot`/`changed`
  returns a non-null state and none exists, then calls `activity` with its push token.
- With the app closed, the backend sends **push-to-start** when `activeTotal` goes from 0 to > 0, the device has a
  `pushToStartToken`, and no activity is registered for it. At most one push-to-start per device per 5 minutes. If
  the user dismissed the previous activity (`ended` with `dismissed`), do not push-to-start again until `activeTotal`
  returns to 0 and rises again.
- If two activities end up existing for the same `serverKey` (local start racing a push start, or an older one still
  on screen), the app keeps the newest, ends the others **with immediate dismissal** and reports them with `ended`.
  It enforces this whenever it gets runtime: launch, foreground, each `activityUpdates` element (including the
  background wake after a push-to-start) and before any local start.

**Update.** The backend pushes `update` to every registered activity token:

- Immediately with `apns-priority: 10` when the set of attention items or failed sessions changes. Only additions
  carry an `alert`: `Pergunta pendente` / `Permissão pendente` / `Sessão parou com erro`, body
  `<title> · <project>`.
- Otherwise coalesced, `apns-priority: 5`, at most one every 10 seconds per activity.
- A heartbeat update every 10 minutes while active. Every push sets `stale-date` = now + 15 minutes.

**End.** When `activeTotal` and `counts.failed` have been 0 for 10 minutes, the backend pushes `end` with the final
state and `dismissal-date` = now (**immediate removal**, rev. 2026-10-27; it used to linger 30 minutes). While the
app runs it does the same locally with `.immediate` dismissal; a null state never keeps an idle-only card.

## APNs (backend)

- HTTP/2 to `api.sandbox.push.apple.com` or `api.push.apple.com` according to the stored `environment`,
  `POST /3/device/<pushToken or pushToStartToken>`.
- Headers: `authorization: bearer <ES256 JWT {iss: teamID, iat}, kid: keyID>` (reuse the JWT for ~50 minutes),
  `apns-push-type: liveactivity`, `apns-topic: br.com.alexandrem.opencode.push-type.liveactivity`,
  `apns-priority: 5|10`, `apns-expiration` = stale-date.
- Configuration (never committed): `OPENCODE_APNS_KEY_PATH` (`.p8`), `OPENCODE_APNS_KEY_ID`,
  `OPENCODE_APNS_TEAM_ID` (default `ERRYZ68LX5`), `OPENCODE_APNS_BUNDLE_ID` (default `br.com.alexandrem.opencode`).
  Missing key or key ID ⇒ `unconfigured`.
- `410` or `400 BadDeviceToken`/`Unregistered` ⇒ drop that token. Other errors are logged and retried on the next
  scheduled push; never block session execution.
- Bodies: [`push-start.json`](live-activity/push-start.json), [`push-update.json`](live-activity/push-update.json),
  [`push-end.json`](live-activity/push-end.json). `push-start` carries `attributes-type`, `attributes` and
  `input-push-token: 1`, so iOS issues an update token for the new activity, which the app reports with `activity`.
- Every body includes `aps.relevance-score: 50`, matching `OpenCodeKit.LiveActivityRelevance.agents`.
  Voice uses 100 on every local start/update, including network recovery. This orders this app's activities
  on the iPhone Lock Screen and in the Dynamic Island without ending/restarting agents or losing its token.
  Relevance is independent of APNs delivery priority (5/10), urgency, counters and progress.

## iOS rendering rules

Colors come from `attributes.theme` roles. Mascot = the app icon robot.

**Lock Screen — ring and counters** (rev. 2026-10-27, approved mock `v3-opcao-3-anel-contadores.png`; replaces the
focus layout, which highlighted one arbitrary session). The card summarizes **all** top-level sessions and never
singles one out as "the" session; `focus` is no longer rendered here (it stays in the state for other surfaces).

- **Header:** mascot + `OpenCode`, `host` on the right (unchanged).
- **Ring** (left): a closed circular gauge split into arcs proportional to the counts, in this order clockwise from
  12 o'clock: `working` (`success`), `question` (`accent`), `permission` (`warning`), `failed` (`error`), `unread`
  (`primary`, rev. 2026-10-28; falls back to `idle` in `textSecondary` when `unread` is absent), with small gaps
  between arcs. The total is the sum of those five counts. In
  the centre: `activeTotal` in large bold `textStrong` and `ativas` in small `textSecondary` below it.
- **Counters** (right of the ring), one line per **non-zero** count, coloured dot + bold number + label:
  `trabalhando` (`success`), `pergunta`/`perguntas` (`accent`), `permissão`/`permissões` (`warning`), `com erro`
  (`error`), `não lida`/`não lidas` (`primary` dot, `textSecondary` text, not bold; rev. 2026-10-28, replaces
  `concluídas há pouco`, which only remains as the fallback when `unread` is absent). At most 4 lines; when 5 are
  non-zero, drop the `não lidas` line first.
- **Attention line** (bottom, only when `attention` is not empty), after a hairline: dot in the kind colour (`accent`
  question, `warning` permission) + bold first `attention` title + ` · há N min` (`textSecondary`, from `since`);
  when `attentionTotal > 1`, append ` +K` with the remaining count. One line, title truncates first.
- **Failed only** (`activeTotal == 0`, `failed > 0`): ring with the red and gray arcs, centre `0` / `ativas`, counters
  `com erro` and `não lidas`, no attention line.
- Fixed metrics; the card must fit the 160 pt Lock Screen limit in every state without vertical `ViewThatFits`.

**Attention first (rev. 2026-10-29, Option A of `.agent-artifacts/atencao/live-atencao.png`).** While `forYou`
(question + permission + failed + unread) is above zero, the ring draws only those arcs (same colors, same order)
with `forYou` / `para você` in the centre; the counters list them first and `N trabalhando` last in `textSecondary`,
dropped first beyond four lines; the attention line shows the first `needs` item with its kind (`pergunta`,
`permissão`, `erro`, `respondeu`) and `+K` = `forYou` − 1. Compact: `forYou` in a `primary` pill. Expanded: `forYou
para você · N trabalhando` over the first two `needs`. Card taps open the first `needs` session. With `forYou` zero
the rules below apply unchanged. Without `needs` (older backends) the app uses `attention`, then failed and idle rows.

**Dynamic Island** (from `opcao-3-painel-cotas.png`):

- Compact: leading mascot. Trailing `attentionTotal/activeTotal` (first number `warning`, second `textSecondary`)
  when `attentionTotal > 0`; otherwise `activeTotal` in `success`.
- Expanded: header `N ativas · M precisa(m) de você` (second part `warning`), plus ` · K com erro` in `error` when
  failed > 0; then `sessions` rows (avatar, title, project, status at right: `Pergunta` `accent`, `Permissão`
  `warning`, `Erro` `error`, `Trabalhando` `success` with ` · done/total` when progress, `Não lida` `primary` for `idle` rows).
  **Rows are single-line** (rev. 2026-10-27): small avatar, title (truncating) followed by the project in
  `textSecondary` on the same line, status at the right. At most 3 rows; the whole expanded presentation must fit
  without clipping on every iPhone with Dynamic Island, so the row count is fixed by measured row height, never by
  `ViewThatFits` (the expanded region proposes unbounded height and clips on device).
- **Minimal** (the small circle), first match wins:
  1. `counts.failed > 0` → exclamation mark + `counts.failed`, in `error`;
  2. `counts.question > 0` → question mark + `counts.question`, in `accent`;
  3. `counts.permission > 0` → raised hand + `counts.permission`, in `warning`;
  4. otherwise the mascot with a `success` ring.

**Apple Watch Smart Stack** (`.small` supplemental family, rev. 2026-10-27; approved mock
`.agent-artifacts/watch/smartstack-b3-anel-segmentado.png`). No watchOS app: declare
`.supplementalActivityFamilies([.small])` and branch on `@Environment(\.activityFamily)` in the Lock Screen closure.

- Left: the mascot inside a **segmented progress ring**. With `focus.progress`: `total` arcs with small gaps, the
  first `done` in `success`, the rest in a dim track (`border`); above 8 subagents, one continuous arc filled
  `done/total`. Working without progress: full `success` ring. Nothing working: track only.
- Badge overlapping the bottom of the ring, same priority as the minimal island: `!N` (`error`), `?N` (`accent`), hand
  + N (`warning`); none when there is no attention or failure.
- Right: the first 2 `sessions` rows, separated by a hairline. Each row: bold title (one line, truncating) and a status
  line: `Pergunta · há N min` (`accent`), `Permissão · há N min` (`warning`), `since` taken from the matching
  `attention` item; `Erro` (`error`); `Trabalhando` (`success`) with ` · done/total` when the row has progress;
  `Não lida` (`primary`) for `idle` rows.
- Fixed metrics that fit the `.small` size on the smallest supported watch without clipping. Tap uses the same
  `widgetURL` as the Lock Screen card.

**Taps:** the Lock Screen card opens the first attention session, else the focus session, else the Sessões list;
attention rows and expanded-island rows link to their own session. Deep links are an iOS concern.

## Fixtures

All in [`live-activity/`](live-activity/), generated for 2026-10-27 09:41 BRT (`updatedAt` 1793104860000).

| File | Shows |
| --- | --- |
| `attributes.json` | `AgentsActivityAttributes` with the `openchamber-dark` theme |
| `state-one-question.json` | Focus with progress + one pending question (approved mock A) |
| `state-two-questions.json` | Focus + two pending questions (list layout) |
| `state-mixed.json` | Question + permission + 2 failed (minimal shows `!2` in `error`) |
| `state-working.json` | Only working sessions, no attention (minimal shows the ring) |
| `state-failed-only.json` | No focus, one failed session (minimal `!1`) |
| `push-start.json` / `push-update.json` / `push-end.json` | Complete APNs bodies |

## Change control

Neither side changes this contract alone. A needed change is reported to the coordinator first; until it is agreed,
implement the contract as written.

## Backend implementation notes

Code: `src/live-activity/` (`rpc.ts` contract schemas, `tracker.ts` state, `lifecycle.ts` registrations and push
decisions, `apns.ts` HTTP/2 client, `index.ts` hub and plugin wiring). Tests: `test/live-activity*.test.ts`.

**One aggregator per process.** Every Location runs its own plugin instance, and `ctx.event.subscribe()` inside a
plugin is not Location-filtered: each instance sees every server event. The plugin loader also evaluates the plugin
module again for every Location (it clears the module cache per load), so module scope is per Location; the hub
therefore lives in a process-global slot (`globalThis.opencodeCustomLiveActivityHub`). The first instance starts the
aggregator in a process-level scope (consuming only its own event stream), later instances just join, and the last one
to leave closes it. `changed` is emitted through the oldest instance still attached, so the global event stream
carries it once. The RPC methods of every instance read and write the same hub and the same plugin storage. The first
evaluation's code serves the process: after an in-process plugin reload with several Locations, the new code takes
over only when every instance has left or the server restarts.

**Family rollup.** The tracker keeps every session it meets with its `parentID` (the child → parent map); a session
it does not know yet, reported by an execution event, the running set or a pending request, is read with
`ctx.session.get` together with its unknown ancestors, and kept as the cache. Each derivation groups executing,
nonarchived sessions by their top-level session, so creating, finishing, deleting or archiving any descendant
recomputes its family. A family is working when any member executes; failed and idle still come from the top-level
session's own latest execution, so a failed subagent does not mark its parent failed. `startedAt` is the top-level
session's latest own execution start (from `session.execution.started`), else the earliest start among the executing
members. `activity` comes from the executing member with the latest tool, reasoning or text event. `progress` counts
direct children created since the top-level session's latest execution started (or, without one, since the earliest
executing member was created), finished or not. Working rows are ordered by the family's latest activity.

**Background shells (rev. 2026-10-28).** Core's jobs are process-local and plugins have no API to list them, so the
tracker follows the public events: `shell.created` (the shell tool tags `metadata.sessionID`; status `running`) adds
an unfinished shell to its session's family, `shell.exited`/`shell.deleted` or the completion notice
(`session.synthetic` with `metadata.source: "shell"` and `shellID`) remove it. Background subagents need nothing
extra: the child session executes and rolls up. A rebuild reads the last 100 messages of every tracked session: a
`shell` tool result with `metadata.status: "running"` and no later notice for its `shellID` is an unfinished shell
(its start is the tool's run time; a top-level session waiting only for such work starts at its latest prompt). After
a server restart Core admits a cancellation notice for every background shell, so none stays counted. A long-lived
background process (a dev server) keeps its session working until it exits.

**Unread (rev. 2026-10-28).** The rule is `custom.navigation`'s `unreadAt` as the web and iOS lists combine it: a
nonarchived top-level session whose `time.idle` is newer than `time.viewed`, either after a success or failure newer
than `time.viewed` (the scan's `completionAt`; live, the execution end) or with a `succeeded`/`failed` outcome. The
tracker keeps `idleAt`, `viewedAt` (monotone, from `session.viewed`) and `completionAt` per session; an interruption
moves `idleAt` like the projection (not a shutdown) but is no completion. "Avisar ao terminar" sessions come from
`custom.preferences` (`notifySessions`, server-qualified keys decoded like the Mestra inventory) at rebuild and on every
`rpc.custom.preferences.updated`, which the hub maps to an internal `preferences.updated` event; they only feed the
session alerts, never the state. A rebuild keeps every unseen top-level session whatever its age; read sessions older
than a day are dropped. `counts.idle` keeps its meaning (succeeded in the last 30 minutes, read or not) and still
drives the 30-minute wake-up; idle rows are only the unread ones, ordered by their unread time.

**Startup.** The aggregator subscribes first, then rebuilds from `ctx.session.active()`, a scan of top-level
nonarchived sessions (running, or with a terminal outcome in the last 24 h: `outcome`, `time.idle`, `time.viewed`),
and `ctx.request.pending()`. Every running session, including subagents at any depth, joins the model with its
ancestors (top-level sessions older than the scan window are read through `get`); families that run get their direct
children from `ctx.session.family` for `progress`. After a rebuild a running execution's start is approximated by its
latest user message (or the previous idle time); a top-level session that only waits for subagents starts at its
latest user message. The activity text stays empty until the next step event. The hub exists only while some Location is instantiated, which happens as soon as a
session runs or a client calls an RPC.

**Field sources.** `title`: the session title (`Sem título` when empty). `project`: basename of the Location
directory joined with the session `subpath`. `host`: macOS `ComputerName` (`scutil`), else the host name. Pending
questions are forms with `metadata.kind` `question` or `websearch.provider`; `text` is the first field's description
(the question), else its title, else the form title. Permission `text` is `<action> · <resources joined by space>`.
Requests owned by subagent children count for their top-level session. `since` is the request's `created`, or when
it was first seen. Pending requests are reread on every `form.*`, `permission.*` and `session.execution.*` event.
`progress` is computed for every working row.

**Push decisions.** The push-to-start alert is `OpenCode` / `N sessões trabalhando` (plus pending counts). A
push-to-start requires an observed `activeTotal` of 0 after the device's last start push and after the last moment a
registered activity covered active work, so work already running at boot or registration does not start one, while an
activity that ended during the calm (the backend's own `end`, sent with `dismissal-date` = now) leaves the device
armed for the next rise. Push-to-start is only sent while no activity is registered: a failed `end` keeps the
activity registered and is retried, so no new card starts beside it. Alerts: when several items are added at once, the
first in the order question, permission, failed. An activity registered with `activity` gets a routine update within
10 s. `end` is sent with priority 10 and also respects the 10 s per-activity spacing; after it is delivered (or the
token is invalid) the activity is removed from the registration. A failed update clears the "already sent" marker so
the next 10 s slot retries; a failed start is retried after the 5-minute window.

**Alerts with session notifications (rev. 2026-10-29).** A device also registered in `custom.notifications` gets
its urgent updates without `alert`, since the session alert already buzzes; others keep the alert as the fallback (see
[session-notifications.md](session-notifications.md#live-activity-alerts)).

**Expiry (rev. 2026-10-29).** ActivityKit ends an activity after 8 hours. Its token then fails (APNs 410/invalid):
the registry drops it, remembers the activity as `expired` and sets `rearm`, which arms push-to-start while work goes
on (cleared by the next start push). An `ended` report that is no user refusal also rearms. A `dismissed` report for
the expired activity, or for one registered 7 h 45 min or more ago (`limits.activityMs`; `registeredAt` now survives
token re-reports), is no refusal either: only a swipe within the 8 hours sets `dismissed` and holds push-to-start
until `activeTotal` returns to 0.

**APNs configuration.** Set `OPENCODE_APNS_KEY_PATH` (the `.p8` file) and `OPENCODE_APNS_KEY_ID`; optionally
`OPENCODE_APNS_TEAM_ID` and `OPENCODE_APNS_BUNDLE_ID`. They are read once when the hub starts; an unreadable key logs a
warning and keeps pushes off (`unconfigured`). Pushes run in their own fibers with a 10 s request timeout; the HTTP/2
connection per host is unreferenced so it never keeps the process alive. `makeClient` accepts an `origin` override,
used only by the tests' local HTTP/2 server; `OPENCODE_APNS_ORIGIN` sets it from the environment (with a warning in the
log) so a sandbox can exercise delivery against a local stand-in without reaching Apple or any device. The same client
also sends the session alerts of [session-notifications.md](session-notifications.md).

**Size.** When a body still exceeds 4096 bytes after the contract's trimming (titles are shortened down to 6
characters), it is sent as is and APNs rejects it; only very long directories can cause that.
