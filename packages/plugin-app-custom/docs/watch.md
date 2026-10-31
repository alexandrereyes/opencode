# Apple Watch app and gateway (`custom.watch`) — contract v1

A native watchOS app for Alexandre's Apple Watch Ultra 3 that works **without the iPhone nearby**: a complication,
a dashboard of agent sessions, answering pending requests, and a realtime voice conversation (GPT Live) with the
Sessão mestra. This document is the contract between the backend (`packages/plugin-app-custom/src/watch`) and the
watch/iOS side (`packages/ios-custom`). Both implement exactly what is written here; neither changes it alone.

Approved references in `.agent-artifacts/watch/` (not versioned): complication `opcao-1-anel-estados.png`, screens
`app-1-painel.png` (dashboard), `app-2-voz-mestra.png` (voice), `app-3-responder-pergunta.png` (answer).

The proof of concept of 2026-10-27 established the voice path on the physical watch, over cellular, without the
iPhone: **CallKit** unlocks low-level networking (an `AVAudioSession` alone gets `ENETDOWN`, TN3135), the
**OpenClaw watch WebRTC engine** (MIT, `str0m`) carries Opus over UDP directly to OpenAI, and the call is created
through a server that also attaches the GPT Live **sideband**. Spike code, logs and the NAT64/port fix:
`$TMPDIR/opencode/watch-spike-snapshot/` (read it; do not copy its secrets).

## Topology

```text
Watch ──HTTPS──▶ watch-mac.alexandrem.com.br (Cloudflare Access, service token)
                  └▶ cloudflared (Mac tunnel) ──▶ http://host.docker.internal:4192 ──▶ watch gateway (plugin)
                                                                                         ├▶ live-activity hub, requests, sessions
                                                                                         └▶ llm-proxy: GPT Live call + sideband
Watch ══UDP (Opus, DTLS/ICE-lite)══▶ OpenAI GPT Live  (media never crosses the Mac)
```

- The gateway listens on `127.0.0.1:${OPENCODE_WATCH_GATEWAY_PORT:-4192}`, **one listener per server process**
  (same process-global hub pattern as `custom.live-activity`). It is not the OpenCode API: it exposes only the
  allowlisted routes below, so the public hostname never reaches shell, files or arbitrary sessions.
- The Cloudflare side already exists (`core-infra/cloudflare-one/watch-mac-cloudflare-manifest.json`). The service
  token is in `~/.config/opencode/watch/cf-access-service-token.json` (`{clientId, clientSecret}`, 0600). Every watch
  request sends `CF-Access-Client-Id`, `CF-Access-Client-Secret` and a non-default `User-Agent: OpenCodeWatch/<v>`
  (Cloudflare blocks some default agents with error 1010).
- Before the gateway can bind 4192, the spike relay (tmux `watch-spike-relay`) must be stopped. Development and
  tests use another port and a sandbox; never bind 4192 from a sandbox.

## Pairing and authentication

1. The iPhone app (connected through WARP as today) calls RPC `custom.watch` → `pair({ deviceName })`.
2. The backend creates a **watch device token** (random 32 bytes, base64url), stores only its SHA-256 with
   `{deviceID, name, createdAt, lastSeenAt}` in plugin storage, and returns:
   `{ deviceID, deviceToken, gatewayURL: "https://watch-mac.alexandrem.com.br", access: { clientId, clientSecret },
voice: { voiceID } }` (`voiceID` defaults to `rio`; the iPhone overrides it with its local voice preference).
3. The iPhone sends that payload to the watch with WatchConnectivity (`transferUserInfo`, plus
   `updateApplicationContext` for re-sync). The watch stores it in its Keychain. The iPhone keeps nothing.
4. Every gateway request carries `Authorization: Bearer <deviceToken>` in addition to the Access headers. Unknown,
   revoked or malformed tokens get `401` with no detail.
5. `custom.watch` → `devices()` returns `{ devices: [{ deviceID, name, createdAt, lastSeenAt }] }`; `revoke({ deviceID })` removes one. The iOS app shows them in
   Você → Apple Watch with "Parear Apple Watch" and "Remover".
6. `custom.watch` → `stats()` (diagnostics, rev. 2026-10-29) returns in-memory counters since the server started:
   `{ at, devices: [{ deviceID, day: Usage, hours: [{ hour } & Usage] }] }`, `day` summing the last 24 hours and
   `hours` listing those with activity, newest first. `Usage = { state: { app, background, widget, unknown },
pushes: { urgent, coalesced, failed }, capped }`: `/state` reads by reader (each `widget` read is one complication
   reload, which WidgetKit budgets), WidgetKit pushes sent by reason, failed pushes, and how often a push waited for
   the daily cap.

## Gateway HTTP API (`/watch/v1`)

JSON bodies, camelCase, times in **epoch milliseconds**, optional fields omitted. Errors:
`{ "error": { "code": string, "message": string (pt-BR, short) } }` with a meaningful status. Rate limit per device:
60 requests/minute outside an active call (voice heartbeats exempt) → `429`.

| Method | Path                                               | Body                                                              | Response                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------ | -------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GET    | `/watch/v1/ping`                                   | —                                                                 | `{ ok: true, server: string, version: string }`                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| GET    | `/watch/v1/state`                                  | — (header `X-Watch-Client: app \| background \| widget`)          | `{ state: AgentsState \| null, host: string }` — the same `AgentsState` as the Live Activity contract (`docs/live-activity.md`, schema and rollup rules), from the same hub, **plus `requestID` on every `attention` item**; a working row with a Progresso carries `progress.unit: "todos"` and `current` (rev. 2026-10-30, [progress.md](progress.md)), which the Painel shows as `Agora: …` (the oldest pending request of that kind for that session; watch-only, never in APNs payloads) |
| GET    | `/watch/v1/requests/:requestID`                    | —                                                                 | `WatchRequest` (below), `404` when no longer pending                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| POST   | `/watch/v1/requests/:requestID/reply`              | `WatchReply`                                                      | `{ ok: true }`, `409` when already answered                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| POST   | `/watch/v1/widget-token`                           | `{ token: string (hex), environment: "sandbox" \| "production" }` | `{ ok: true }`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| POST   | `/watch/v1/voice/calls`                            | `{ sdp: string, voiceID?: string }`                               | `{ callID, sdp, leaseSeconds }`                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| POST   | `/watch/v1/voice/calls/:callID/heartbeat`          | `{ sent: number, received: number }`                              | `{ ok: true }`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| GET    | `/watch/v1/voice/calls/:callID/events?after=<seq>` | —                                                                 | long-poll ≤ 25 s: `{ events: VoiceEvent[], next: number, ended: boolean }`                                                                                                                                                                                                                                                                                                                                                                                                                    |
| DELETE | `/watch/v1/voice/calls/:callID`                    | —                                                                 | `{ ok: true }`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| POST   | `/watch/v1/diagnostics`                            | `{ events: object[] ≤ 50 }`                                       | `{ ok: true }` — logged with the device ID, secrets redacted                                                                                                                                                                                                                                                                                                                                                                                                                                  |

```ts
WatchRequest =
  | { kind: "question", requestID, sessionID, title, project, since,
      questions: { id: string, text: string, options: { id: string, label: string, recommended?: boolean }[],
                   multiple: boolean, allowText: boolean }[] }
  | { kind: "permission", requestID, sessionID, title, project, since,
      action: string, resources: string[], summary: string /* e.g. "bash · bun test --filter oauth" */ }

WatchReply =
  | { kind: "question", answers: { questionID: string, optionIDs?: string[], text?: string }[] }
  | { kind: "permission", decision: "once" | "always" | "reject" }

VoiceEvent = { seq: number, at: number } & (
  | { type: "status", status: "connecting" | "live" | "ended", reason?: string }
  | { type: "caption", role: "user" | "assistant", text: string, final: boolean }
  | { type: "master", state: "running" | "idle", text: string }   // Sessão mestra progress line
  | { type: "error", code: string, message: string })
```

- Questions map from the session form schema; the backend owns that mapping and only offers what the watch can
  render (choice fields, with optional free text). Unsupported forms return `kind: "question"` with an empty
  `questions` array and the watch offers "Abrir no iPhone".
- Request IDs, session IDs and project names come only from pending requests and the hub; the gateway never
  accepts an arbitrary session or directory from the watch.

## Voice

**Signaling (backend).** `POST /voice/calls` reserves the llm-proxy lease (`/_gpt-live/sessions/{uuid}`), creates
the call with `POST /backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas` and the iPhone's headers
(see `packages/ios-custom/docs/voice.md`, "Contrato privado do llm-proxy"), returns the answer SDP, and attaches the
sideband (`/v1/live` through the llm-proxy). The watch offer is audio-only Opus with no data channel and no local
candidates; the answer must be ICE-lite with UDP candidates, otherwise `502 {code:"unsupported_answer"}`.

- **Session config is built by the backend**, equivalent to the iPhone's (`OpenCodeKit/Voice.swift`): model,
  `voiceID`, the same pt-BR instructions, and `initial_items` from voice memory (`custom.voice`, scope `global`).
  Both Watch and iPhone fetch `custom.voice/instructions` for each call. It rereads `voice.md` from the global
  config directory (`OPENCODE_CONFIG_DIR`, otherwise `$XDG_CONFIG_HOME/opencode` or `~/.config/opencode`).
  Edits apply to the next call without restarting; absent files use `src/voice/voice.md` bundled with the plugin.
  Empty or unreadable files fail call creation before reserving a proxy lease.
- **Lease and liveness:** the backend renews the lease every 5 s **only while heartbeats arrive** (the watch sends
  one every 5 s). No heartbeat for 15 s, a `DELETE`, a sideband close or the 30-minute cap ends the call: close the
  sideband, `DELETE` the lease, emit `status: ended`. One active call per device; a new call ends the previous.
- **Captions:** sideband transcript events become `caption` events (merge deltas; `final` at turn end).
- **Delegation (server-side):** the backend handles GPT Live delegation on the sideband with the same behaviour as
  the iPhone's `VoiceMaster` (`OpenCode/Voice/VoiceMaster.swift`): `delegation.created` → ensure the Sessão mestra
  (`custom.master`) and send the task to it (steer by default, queue when asked), stream its progress back with
  `delegation.context.append` (`channel: speakable`, ≤ 500 UTF-8 bytes per part) and as `master` events. The
  admission confirmation, tool activity and tool or step failures produce only visual `master` events (GPT Live
  acknowledges the request itself, and spoke "já encaminhei" for every admission); the Mestra's text updates,
  blockers and results supply voice context, without naming the Mestra. Turns are
  appended to voice memory (`custom.voice.append`) so the watch and the iPhone share one memory. First verify on the
  Mac, with one short call, which `session.delegation` setting makes `delegation.created` arrive on the sideband and
  whether appends sent there are accepted; record the result in "Backend implementation notes".

**Media (watch).** Exactly the proven path: CallKit outgoing call (`CXStartCallAction`; no `contactIdentifier`), then,
after `provider(_:didActivate:)`, the duplex audio and the UDP flows (one per remote, system-chosen interface and
port, ICE sees the original IPv4 pair, sockets carry the bytes; see the spike fix), Opus 48 kHz 20 ms. Wrist-down
operation must keep the call. Ending the call from the system call UI ends it on the gateway.

## Complication and widget push

- Families: `accessoryCircular` (the approved ring with the mascot in the bottom gap), `accessoryCorner` (the ring
  closed around the number) and `accessoryRectangular` (the ring, `N para você` and its detail). All of them, the
  Painel and the Live Activity draw the same **state ring** (rev. 2026-10-30, `docs/live-activity.md`, "State ring"):
  one segment per state (`question` lavender, `permission` amber, `failed` red, `unread` orange, `working` green, or
  gray while something needs Alexandre), `N para você` in orange in the centre, else the sessions working; with
  nothing active, the mascot alone over the gray track. Tap opens the app on the dashboard.
- Data: the widget timeline reads `/watch/v1/state` (high-level `URLSession`, allowed in widget extensions) and
  caches the last good state in the shared Keychain group; it refreshes when the app runs, on WidgetKit push, on the
  app's background refresh, and on its own timeline (rev. 2026-10-29: every 60 minutes, as a fallback).
- **Budget (rev. 2026-10-29).** WidgetKit counts every reload of the complication outside the foreground app,
  pushed, scheduled or requested by a background app, against one daily budget: Apple quotes 40 to 70 reloads a
  day for a widget that is looked at often. On 2026-10-28 the server sent 150 pushes in about 20 hours (up to 18 an
  hour) on top of a 15-minute timeline, so WidgetKit ignored most of them and only opening the app updated the
  complication. The sources now split the budget:
  - **Urgent WidgetKit pushes, at once:** a new question or permission (`attentionTotal` rises), a new failure
    (`counts.failed` rises), a **new unread answer** (`unread`, or `idle` from older backends, rises; rev.
    2026-10-30: on 30/10 a session that finished unread waited up to 30 minutes for a folded push and Alexandre had to
    open the app to see it), or `activeTotal` reaching or leaving 0. At most **one a minute** per device: sessions
    that finish together go out as one push with the state at the end of that minute. They use `apns-priority` 10
    (APNs may hold priority 5 and deliver it in bursts; Apple's widget push example omits the header, which means
    10).
  - **Any other change of what the complication draws** (`activeTotal`, `attentionTotal`, the ring's counts
    `working`, `question`, `permission`, `failed` and `unread`, or `idle` from older backends): one folded push at
    most every **30 minutes** after the device's previous push, with the state current at that moment, so the
    final state is never lost. 30 minutes caps folded pushes at 2 an hour, about 28 over a 14-hour working day.
    Progresso advances and activity text are not part of what the complication draws, so they never push it
    (rev. 2026-10-30); the Painel reads them when it polls `/state`.
  - **Daily cap (rev. 2026-10-30):** at most **50 pushes per device in any 24 hours**; folded ones stop at **25**,
    keeping the other 25 for urgent changes (unread answers moved from folded to urgent, so the reserve grew; folded
    pushes now only carry decreases and the working count). A held change goes out when a slot frees (the oldest push leaves the 24 hours); until
    then the watch's own refreshes cover it.
  - **Nothing for a state the watch already has:** every `/state` read (app, background refresh or widget) tells the
    server what the watch cached, and pushes compare against that, not against the last push.
  - **Watch side:** the background refresh (about every 30 minutes) fetches the state into the cache and reloads the
    complication only when what it draws changed; the timeline policy is 60 minutes; the app in front reloads freely
    (not budgeted). Worst case on a busy day: the 50 pushes (each one reload, which also refreshes the cache, so the
    background refresh then finds nothing new) + about 10 idle-time timeline reloads, near 60, inside the 40–70; a
    quiet day stays far below. On 29–30/10 the device read `/state` as `background` 1–2 times an hour all night and as
    `widget` 1–9 times an hour, with 0–3 urgent pushes an hour.
- **Data age (rev. 2026-10-29):** the rectangular complication and the Painel show how old the state is: `agora`
  during its first minute, then the live relative text (`há 3 min.`), from the cache's fetch time. The circular and
  corner families have no room for it.
- **WidgetKit push (backend):** APNs `apns-push-type: widgets`, topic
  `br.com.alexandrem.opencode.watchkitapp.push-type.widgets`, priority 10 when urgent and 5 when folded, body
  `{"aps":{"content-changed":true}}`,
  reusing the existing APNs key (`OPENCODE_APNS_KEY_*`), following the rules above.

## Watch app (screens)

All copy pt-BR, theme colors from `openchamber-dark` (no theme picker on the watch).

1. **Painel** (root, `app-1-painel.png`): the state ring (rev. 2026-10-30) with `N para você`; rows from
   `attention` first (lavender question, amber permission), then `sessions` (status colors as in the Live Activity);
   a Liquid Glass microphone button bottom-right starts voice. Pull to refresh; refresh every 10 s while visible.
   Session rows have no navigation in v1 (no chevron); only attention rows open Responder. The list takes the
   whole screen and the microphone floats over its bottom trailing corner (rev. 2026-10-30); the list's end leaves
   room for it, so it never hides the last row. Offline/unpaired states: "Abra o OpenCode no iPhone para parear" / "Mac indisponível" with the last update time.
2. **Responder** (`app-3-responder-pergunta.png`): opens from an attention row; question text, one large button per
   option (recommended first, orange), "Responder por voz" dictation for `allowText`; permissions show the summary
   and Negar / Permitir uma vez / Sempre permitir. Success returns to the dashboard with haptic feedback.
3. **Voz** (`app-2-voz-mestra.png`): CallKit call; mascot with live audio levels, `Sessão mestra` status line from
   `master` events, the last two captions, timer, Mute and End buttons; errors in pt-BR with a retry.

## Packaging (iOS side)

- watchOS app target **`OpenCodeWatch`**, bundle `br.com.alexandrem.opencode.watchkitapp`, embedded in the iOS app
  (shipped by the same `script/testflight.sh` upload), `WKRunsIndependentlyOfCompanionApp = YES`, deployment target
  watchOS 27, background modes `audio` and `voip`. Shared state between the watch app and its widget uses the
  **Keychain access group** `ERRYZ68LX5.br.com.alexandrem.opencode.watch` (rev. 2026-10-27: the App Store Connect API
  key cannot create App Groups; switch to an App Group only if one is created in the portal).
- Widget extension `br.com.alexandrem.opencode.watchkitapp.widgets` for the complications.
- WebRTC engine: vendor `apps/shared/OpenClawWatchRTC` (+ the spike's transport/audio Swift with its fixes) under
  `packages/ios-custom/Vendor/OpenClawWatchRTC/` with the MIT notices of OpenClaw and str0m. Build the static
  library with a **private pinned toolchain** in `~/.local/share/opencode-ios/rust` (setup script in
  `packages/ios-custom/script/`), never a global Rust install; the Xcode build phase reuses a fingerprinted cache.
- Shared Swift that has no UI goes to `OpenCodeKit` when it compiles for watchOS; otherwise to a watch-only folder.

## Out of scope for v1

Session transcripts and composing arbitrary prompts on the watch (voice covers it), multiple servers, the watch
Live Activity card (already shipped), and moving the iPhone voice to server-side delegation.

## Change control

Disagreements or gaps go to the coordinator; until resolved, implement the contract as written.

## Backend implementation notes

Code: `src/watch/` (`rpc.ts` RPC and wire types, `devices.ts` pairing and tokens, `gateway.ts` listener, routes,
authentication and rate limit, `requests.ts` form/permission mapping, `voice.ts` GPT Live calls, `delegation.ts`
Sessão mestra delegation, `widget.ts` WidgetKit pushes, `index.ts` wiring). Tests: `test/watch.test.ts`, plus the
widget push type in `test/live-activity-apns.test.ts`.

**One gateway per process.** The plugin module is evaluated again for every Location, so the gateway lives in the
global slot `globalThis.opencodeCustomWatchGateway`, like the Live Activity hub: the first instance starts it, the
last one to leave stops it (listener, calls, pushes). Requests use the oldest attached instance's context. The
listener binds `127.0.0.1:${OPENCODE_WATCH_GATEWAY_PORT:-4192}`; a busy port logs one warning and is retried every
30 s without failing the plugin. `custom-sandbox.ts` sets the variable from `--watch-port` (default `0`, any free
port) and refuses 4192.

**Pairing and authentication.** `pair` creates `watch_<random>` and a 32-byte base64url token; storage
(`watch:devices`) keeps its SHA-256, `createdAt`, `lastSeenAt` (written at most once a minute; `devices()` reports
`createdAt` until the watch first calls the gateway) and the widget token.
`access` is read from `~/.config/opencode/watch/cf-access-service-token.json` at each `pair` (a missing file fails
`pair` with `operation_failed`). `revoke` also ends the device's call. Any path outside `/watch/v1/` and any unknown
route is `404`; authentication runs before routing inside `/watch/v1/`, so an unpaired caller only ever sees `401`.
Rate limit: 60 requests in a sliding minute per device; heartbeats never count and nothing counts while the device
has an active call. Logs carry device IDs, statuses and reasons, never tokens, SDP or transcripts; diagnostics are
logged with keys such as token, secret, password, key or SDP masked and strings clipped to 500 characters.

**State.** `/state` is the hub's `snapshot` state; the hub also returns, per attention session, the oldest pending
request of that kind across the family, and the gateway adds it as `requestID` to the `attention` items of this
response only.

**Requests.** Only questions (forms of kind `question` or `websearch.provider`) and permissions whose owner, walked up
`parentID`, reaches a nonarchived top-level session are reachable; `sessionID`, `title` and `project` are that
session's. Fields: `string` (no `format`/`pattern`) → single choice, `allowText` when it has no options or
`custom`; `multiselect` → multiple choice; `boolean` → `Sim`/`Não` (`true`/`false`). Hidden fields are skipped. Any
other field, or any `when` condition, makes the form unsupported (`questions: []`; replying is `400
unsupported_form`). Option `id` is the form value; a trailing `(Recommended)`/`(Recomendado)` becomes
`recommended: true` and leaves the label. Replies must use offered options or allowed text (`400 invalid_answer`);
a request that is no longer pending is `409` (the backend cannot tell answered from unknown IDs).

**Voice.** `leaseSeconds` in the call response is the liveness window, 30: the call ends when no heartbeat
arrived for 30 s, checked at each 5 s renewal tick (renewals stop with the heartbeats). It was 15 s until 31/10: the
watch sends the next heartbeat 5 s after the previous one settles, with an 8 s timeout, so a single stuck heartbeat
could end a call whose audio was fine. The llm-proxy lease is renewed with the iPhone's rules: 408, 429, any 5xx or
network errors are retried until the confirmed lease (minus 10 s) runs out; any other refusal ends the call. An
upstream `error` is logged with its `type` and `code` (never the message) and passed to the watch as `voice_error`;
it does not end the call, which ends when the service closes the sideband (`session_closed`, `sideband_closed`). The offer must be SDP with `m=audio` and Opus 48 kHz (`400
invalid_offer`); the answer needs `a=ice-lite` and a UDP candidate (`502 unsupported_answer`). Voice IDs fall back
to `rio` then `cove` only on an explicit voice rejection, as on the iPhone. `initial_items` come from
`custom.voice.context` (2 s budget; without it the call starts without memory): summary and master state as labelled
user data items, turns with the interruption annotation. Captions accumulate `input_transcript.added` /
`output_transcript.added` deltas per role (`final: false`); `turn.done` emits the canonical transcript with `final:
true` and appends it to memory as `<callID>:<turnID>`; `custom.voice.end` runs when the call ends. An ended call's
events stay readable for 60 s. A new call ends the device's previous one (`reason: "replaced"`). Other end reasons:
`client_end`, `heartbeat_timeout`, `lease_refused`, `lease_lost`, `max_duration`, `session_closed`,
`sideband_closed`, `shutdown`.

**Delegation.** Like `VoiceMaster`: `custom.master.ensure` with `voice: true` (the Mestra's voice-call note, removed by
the call's memory `end`), one replacement ensure when the prompt fails, prompt
text only (`steer`, or `queue` for `{"text":…,"delivery":"queue"}`), duplicate delegation IDs ignored. Progress
lines are the iPhone's pt-BR texts (tool names from `session.tool.input.started`, Code Mode `toolCalls`, text,
failures, pending requests). Only text updates (`Atualização: …`), pending requests, results and execution failures
are spoken, at most one every 5 s keeping only the latest; results and failures skip the wait.
The result is the latest assistant text after the admitted prompt, read once the Mestra leaves the running set
(`session.execution.succeeded` can arrive while the drain still lists it; it is checked again every second, up to
15 times). Appends go to the latest delegation item in parts of at most 500 UTF-8 bytes; every line is also a
`master` event (`running`, or `idle` for results and failures). Ending the call stops narration, never the Mestra.

**Sideband verification (2026-10-27, Mac, spike macOS client, audio-only offer without a data channel).**
`session.delegation = {type: "client"}`, the iPhone's setting, delivers `delegation.created` on the sideband
(`/v1/live/<call>`): `item.type: "delegation"`, `target: "client"`, `content[].input_text` with the request, plus
`handoff_id` and `user_bidi_turn_id`. A `delegation.context.append` sent on the sideband was acknowledged with
`delegation.context.appended` 0.26 s later and spoken. Of the two verification calls, the first (same setting, no
`initial_items`, transcripts not logged) got `turn.created` and no reply within 17 s, so the cause is unknown; the
second answered as above. A third call went through a sandbox gateway end to end: lease, 201 with ICE-lite/UDP,
`live`, delegation to the sandbox Mestra (`sessions_list`), four progress lines, both turns in voice memory, DELETE
and `ended`. That call did not receive the final result line, which led to the settle retry above.

**WidgetKit push.** Supported: `WidgetPushHandler` and `pushHandler(_:)` are available on watchOS 26.0+ in the
watchOS 27.0 SDK (Xcode), and Apple documents the `widgets` push type for "widgets and watch complications". The
watch posts its token to `/widget-token`; pushes use the APNs client of the Live Activity with type `widgets`, topic
`<OPENCODE_APNS_BUNDLE_ID>.watchkitapp.push-type.widgets`, priority 5, `apns-expiration` now + 15 min. They follow
the Live Activity `changed` events and `/state` reads (rev. 2026-10-29, `widget.ts`): per device the planner keeps
what the watch has (`known`, from its last push or its last `/state` read), the time of the last push and the push
times of the last 24 hours. The first state after start is only recorded. A state equal to `known` sends nothing; an
urgent one (see "Budget") goes once a minute has passed since the last push and while under 50 pushes in 24 hours;
any other waits until 30 minutes after the last push and under 25 pushes in 24 hours, then sends the state current at that moment. Every push schedules a look
one window later, so a failed push (which neither counts nor changes `known`) is retried without a new change. An
invalid token is dropped. The memo and counters are in memory: a restart starts them over and records the current
state as known. WidgetKit still budgets these pushes, so the watch's background refresh and timeline remain.

**Diagnostics.** `/state` reads carry `X-Watch-Client` (`app` in front, `background` refresh, `widget` reload; older
builds send none and count as `unknown`). `stats.ts` keeps counters per device and hour (48 hours) and logs each
finished hour once, on the first count of the next one, as `Watch hourly usage` (`deviceID`, `hour`, the four
readers, `urgent`, `coalesced`, `failed`, `capped`); pushes are logged as `Watch widget push sent` with `reason`, the
start of each wait for the cap as `Watch widget push capped`, and (rev. 2026-10-30) each `widget` and `background`
read as `Watch state read` (`deviceID`, `reader`), a few dozen a day, to line reloads up with the pushes. To check the budget: the daily `widget` reads
should stay within about 40–70, and pushes within the cap.
