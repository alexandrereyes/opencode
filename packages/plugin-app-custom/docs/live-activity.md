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
    idle: number                    // sessions that finished successfully in the last 30 minutes
  }
  activeTotal: number               // working + question + permission ("4 ativas")
  focus?: Focus                     // the session shown with progress; absent when nothing is working
  attention: Attention[]            // pending questions/permissions, oldest first, at most 3
  attentionTotal: number            // question + permission (may exceed attention.length)
  sessions: Row[]                   // rows for the expanded Dynamic Island, at most 4, ordered (see below)
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
```

`unit` is an enum so a future task list can add `"tasks"`; iOS renders unknown units as a bare `done/total`.

### Backend rules

- **Tracked sessions:** top-level (no parent), not archived, across **all** Locations of the server. Subagent child
  sessions never appear as rows; they feed their parent's `progress`.
- **Status precedence per session:** question > permission > failed > working > idle.
- **Failed:** the session's latest execution ended with `session.execution.failed` (a user interruption is not a
  failure). It stays failed until a new execution starts, the session is viewed (`session.viewed`), archived or
  deleted, or 24 hours pass.
- **Idle:** latest execution succeeded within the last 30 minutes.
- **Focus:** among working sessions, keep the current focus while it is still working; otherwise pick the one whose
  execution started most recently. Absent when `counts.working == 0`.
- **activity** (from the focus session's latest step activity): edit/write/patch → `Editando <basename>`; read →
  `Lendo <basename>`; shell → `Rodando <command, first 40 chars>`; grep/glob → `Buscando <pattern>`; webfetch or
  websearch → `Pesquisando na web`; subagent → `Delegando para <agent>`; reasoning → `Pensando`; text →
  `Escrevendo resposta`; otherwise omit.
- **progress:** subagent children created by the focus session's current execution; `done` = children whose
  execution finished (any outcome). Omit when there are none.
- **sessions order:** question, permission (oldest `since` first), failed (most recent first), working (focus first,
  then most recent activity), idle (most recent first); cut to 4.
- **Size:** the whole APNs body must stay ≤ 4096 bytes. Trim in this order until it fits: `attention[].text`, then
  `sessions` beyond 3, then `attention` beyond 2, then shorten titles.

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

**Start.** A device/serverKey may have at most one live activity.

- In foreground the app starts it locally (`Activity.request(..., pushType: .token)`) when `snapshot`/`changed`
  returns a non-null state and none exists, then calls `activity` with its push token.
- With the app closed, the backend sends **push-to-start** when `activeTotal` goes from 0 to > 0, the device has a
  `pushToStartToken`, and no activity is registered for it. At most one push-to-start per device per 5 minutes. If
  the user dismissed the previous activity (`ended` with `dismissed`), do not push-to-start again until `activeTotal`
  returns to 0 and rises again.
- If two activities end up existing for the same `serverKey` (local start racing a push start), the app keeps the
  newest, ends the others and reports them with `ended`.

**Update.** The backend pushes `update` to every registered activity token:

- Immediately with `apns-priority: 10` when the set of attention items or failed sessions changes. Only additions
  carry an `alert`: `Pergunta pendente` / `Permissão pendente` / `Sessão parou com erro`, body
  `<title> · <project>`.
- Otherwise coalesced, `apns-priority: 5`, at most one every 10 seconds per activity.
- A heartbeat update every 10 minutes while active. Every push sets `stale-date` = now + 15 minutes.

**End.** When `activeTotal` and `counts.failed` have been 0 for 10 minutes, the backend pushes `end` with the final
state and `dismissal-date` = now + 30 minutes. While the app runs it does the same locally.

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

## iOS rendering rules

Colors come from `attributes.theme` roles. Mascot = the app icon robot.

**Lock Screen** (`progresso-pergunta-a.png`): header mascot + `OpenCode` and `host` on the right; focus block (avatar,
title, project, timer from `startedAt` using a system timer text, `activity`, progress bar with `done/total` and the
unit label `subagentes`); then, when `attention` is not empty, the pending block. With one item: caps label
`PERGUNTA PENDENTE` (or `PERMISSÃO PENDENTE`), `há N min` from `since`, avatar + bold title + project + chevron, and
`text`. With more items, the list layout of `progresso-duas-perguntas.png` (`N PERGUNTAS PENDENTES`, or
`N PENDÊNCIAS` when kinds are mixed). Questions use `accent`, permissions `warning`. Footer with the non-zero counts:
`trabalhando` (`success`), `pergunta(s)` (`accent`), `permissão(ões)` (`warning`), `com erro` (`error`), `ociosas`
(`textSecondary`). Without focus, the card shows the pending block and the footer only.

**Dynamic Island** (from `opcao-3-painel-cotas.png`):

- Compact: leading mascot. Trailing `attentionTotal/activeTotal` (first number `warning`, second `textSecondary`)
  when `attentionTotal > 0`; otherwise `activeTotal` in `success`.
- Expanded: header `N ativas · M precisa(m) de você` (second part `warning`), plus ` · K com erro` in `error` when
  failed > 0; then `sessions` rows (avatar, title, project, status at right: `Pergunta` `accent`, `Permissão`
  `warning`, `Erro` `error`, `Trabalhando` `success` with ` · done/total` when progress, `Concluída` `textSecondary`).
- **Minimal** (the small circle), first match wins:
  1. `counts.failed > 0` → exclamation mark + `counts.failed`, in `error`;
  2. `counts.question > 0` → question mark + `counts.question`, in `accent`;
  3. `counts.permission > 0` → raised hand + `counts.permission`, in `warning`;
  4. otherwise the mascot with a `success` ring.

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

**Startup.** The aggregator subscribes first, then rebuilds from `ctx.session.active()`, a scan of top-level
nonarchived sessions (running, or with a terminal outcome in the last 24 h: `outcome`, `time.idle`, `time.viewed`),
the direct children of running sessions (`ctx.session.family`), and `ctx.request.pending()`. After a rebuild the
execution start is approximated by the latest user message (or the previous idle time) and the activity text stays
empty until the next step event. The hub exists only while some Location is instantiated, which happens as soon as a
session runs or a client calls an RPC.

**Field sources.** `title`: the session title (`Sem título` when empty). `project`: basename of the Location
directory joined with the session `subpath`. `host`: macOS `ComputerName` (`scutil`), else the host name. Pending
questions are forms with `metadata.kind` `question` or `websearch.provider`; `text` is the first field's description
(the question), else its title, else the form title. Permission `text` is `<action> · <resources joined by space>`.
Requests owned by subagent children count for their top-level session. `since` is the request's `created`, or when
it was first seen. Pending requests are reread on every `form.*`, `permission.*` and `session.execution.*` event.
Working rows are ordered by the latest tool, reasoning, text or execution event; `progress` is computed for every
working row.

**Push decisions.** The push-to-start alert is `OpenCode` / `N sessões trabalhando` (plus pending counts). A
push-to-start requires an observed `activeTotal` of 0 after the device's last start push or registered activity, so
work already running at boot or registration does not start one. Alerts: when several items are added at once, the
first in the order question, permission, failed. An activity registered with `activity` gets a routine update within
10 s. `end` is sent with priority 10 and also respects the 10 s per-activity spacing; after it is delivered (or the
token is invalid) the activity is removed from the registration. A failed update clears the "already sent" marker so
the next 10 s slot retries; a failed start is retried after the 5-minute window.

**APNs configuration.** Set `OPENCODE_APNS_KEY_PATH` (the `.p8` file) and `OPENCODE_APNS_KEY_ID`; optionally
`OPENCODE_APNS_TEAM_ID` and `OPENCODE_APNS_BUNDLE_ID`. They are read once when the hub starts; an unreadable key logs a
warning and keeps pushes off (`unconfigured`). Pushes run in their own fibers with a 10 s request timeout; the HTTP/2
connection per host is unreferenced so it never keeps the process alive. `makeClient` accepts an `origin` override,
used only by the tests' local HTTP/2 server.

**Size.** When a body still exceeds 4096 bytes after the contract's trimming (titles are shortened down to 6
characters), it is sent as is and APNs rejects it; only very long directories can cause that.
