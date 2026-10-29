# Session notifications

Contract between the plugin and the iOS app (`packages/ios-custom`) for the APNs alerts the server sends to every
registered iPhone. There are no switches besides the per-session bell (rev. 2026-10-29):

| What | Alerts | Rule |
| --- | --- | --- |
| Question | always, any top-level session (subagents roll up) | at once, once per request and device |
| Permission | always, any top-level session | only if still pending after 3 s and auto-approval is off |
| Failure that stops the session | always | once per stop; provider retries do not alert |
| Success | only with "Avisar ao terminar" | once per finish |
| Interruption (by Alexandre or a shutdown) | never | — |

Everything is `interruption-level: active`: the iPhone's Focus / Do Not Disturb decides, nothing is time-sensitive
(no Time Sensitive entitlement).

## Preference

- `custom.preferences` `notifySessions`: server-qualified session keys (`["http://localhost:4096","ses_…"]`, or bare
  IDs in older profiles), like `pinnedSessions`. Absent means none: every session starts with the bell off.
- Intent `{"type":"sidebar.notify","session":"<key>","notify":true|false}` adds (idempotently) or removes a key.
  Turning it off removes every key of that session.
- `mutedSessions` and `sidebar.mute` remain accepted so app builds from before this change keep working, but nothing
  reads them anymore: muted sessions show the normal unread dot, light their chip, count as unread in the Live
  Activity and appear in the Mestra summaries. Mutes are not converted into bells.

## Registration (`custom.notifications`)

Every call is `POST /api/rpc/custom.notifications/<method>` with `{"input":{…}}`.

| Method | Input | Output |
| --- | --- | --- |
| `register` | `deviceID` (1–100), `serverKey` (the app's key for this server, 1–100), `environment` (`sandbox`/`production`), `token` (hex APNs device token, ≤ 512) | `{"push":"configured"\|"unconfigured"}` |
| `unregister` | `deviceID` | `{}` |

- One token per install (`deviceID`); several devices are supported. Registering again replaces that device's token;
  a token reported under another device ID (a reinstall) replaces the old entry.
- Kept in plugin storage (`notifications:devices`), shared by every Location's instance. A device that does not
  register for 30 days is forgotten; the app registers on every connection while notifications are authorized.
- `unconfigured` means the server has no APNs credentials: registrations are stored, nothing is sent.
- An APNs `410` or `400 BadDeviceToken`/`Unregistered` drops that device's token; other failures are logged and not
  retried (the next finish tries again).

## When a session stops

The Live Activity hub's tracker is the source of truth, with its "working" roll-up (rev. 2026-10-28): a top-level
session works while its own execution, any descendant's execution, or an unfinished background shell of the family
runs. For each known, unarchived top-level session:

1. The work must be seen by this process (a stop that happened while the server was down alerts nothing). A session
   first seen idle after startup that worked meanwhile (it started and failed between two evaluations) counts.
2. When the family stops working it must stay quiet for **5 seconds** (`limits.graceMs`): a background shell or
   subagent that ends wakes its parent a moment later, and that gap is not the end of the work. Working again inside
   the window cancels it.
3. Then the outcome of the root's own latest execution decides: `failed` → "Parou com erro · projeto" (any
   session); `succeeded` → "Terminou · projeto", only with the bell and only for work newer than the bell (a run that
   ended before it was turned on is not reported); `interrupted` alerts nothing.

**Retries.** A retryable provider error (rate limit, 5xx, timeout) schedules `session.retry.scheduled` and keeps the
execution running through the backoff (2, 4, 8, then 10 s gaps, up to 10 retries, about 84 s), so nothing alerts; only
`session.execution.failed`, after the retries are exhausted or for a non-retryable error, does.

One alert per stop and device; nothing more until the family works again.

## Questions and permissions

Pending requests come from `ctx.request.pending()` (refreshed on every `form.*`/`permission.*` event), rolled up to
their top-level session. A question alerts at once ("Pergunta: <text>"); a permission ("Permissão: <action ·
resources>") only after it has been pending for 3 s (`limits.permissionMs`) with `settings.autoApprove` off, so
auto-approved or quickly answered ones stay silent. One alert per `requestID`; requests already pending when the
server starts count as notified, so a restart repeats nothing.

## Payload

`apns-push-type: alert`, topic = the bundle ID (`OPENCODE_APNS_BUNDLE_ID`, default `br.com.alexandrem.opencode`),
priority 10, expiration 24 hours. Each device's own APNs environment and `serverKey` are used. Attention alerts also
send `apns-collapse-id: attention:<sessionID>`, so a newer request or failure of a session replaces the older one.

```json
{
  "aps": {
    "alert": { "title": "Corrigir login OAuth", "body": "Pergunta: Manter o refresh token no Keychain?" },
    "sound": "default",
    "thread-id": "ses_01JZOAUTHLOGIN000000000003",
    "interruption-level": "active"
  },
  "opencode": {
    "kind": "session.attention",
    "serverKey": "mac-principal",
    "sessionID": "ses_01JZOAUTHLOGIN000000000003",
    "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
    "attention": "question",
    "requestID": "frm_…"
  }
}
```

`attention` is `question`, `permission` (both with `requestID`) or `failed`. A bell success is
`{"kind":"session.finished", …, "outcome":"succeeded"}` without a collapse ID.

The title is the session title clipped to 80 characters ("Sem título" when empty); the body names the project like
the Live Activity rows (last segment of the directory and subpath). `thread-id` groups a session's alerts; the Apple
Watch mirrors them.

## Live Activity alerts

One alert per question, permission or failure and device (rev. 2026-10-30), preferring the Agentes Live Activity:

- **The device has a live activity** (a `custom.live-activity` registration with an activity token, same `deviceID`)
  and the card has something to show: the alert goes as that activity's update, priority 10, carrying `alert`
  (`title` = session title, `body` as above). No notification is sent. The iPhone shows it on the card and the Dynamic
  Island and the watch mirrors it, so each buzzes once.
- **Otherwise** (no activity: expired, dismissed, never started, or the device has none): the notification above.
- **The activity update fails:** APNs refusing the token (the activity just ended) drops it, rearms push-to-start and
  sends the notification instead; any other failure sends the notification too. Nothing is left without an alert.
- A bell **success** always goes as a notification: the activity only shows work and attention.
- The lifecycle's own updates (state changes, heartbeats) never carry an `alert`, and the watch complication's
  widget pushes (`content-changed`) are silent.

## App behavior

- Permission is asked never at launch: the first time a bell is turned on, or once when a question or permission
  first waits ("Avisar quando precisarem de você?", answered once). With it the app registers for remote
  notifications and sends the token to the connected server, then again on every connection.
- Presentation (`willPresent`): with the app in the foreground and that session's conversation open on the same
  server, the alert is not shown; otherwise it shows (banner, list, sound). Tapping it opens the session, switching
  servers through `serverKey` like a Live Activity link; with a `requestID` it opens at the end of the transcript,
  where pending requests sit.
- While this server pushes to the device, the in-app banner skips questions, permissions, failures and bell
  finishes, so nothing is announced twice.

## Compatibility

- **New app, old server:** `sidebar.notify` is rejected (`rpc.invalid_input`) and the app shows "Atualize o servidor
  para usar o aviso ao terminar"; no local-only bell is fabricated. A missing `custom.notifications` RPC only stops
  the token registration.
- **Old app, new server:** "Silenciar" keeps writing `mutedSessions`, which is accepted and ignored. Builds before the
  attention alerts show `session.attention` alerts as plain notifications (a tap only opens the app).
- **Order:** both work in either order; the bell needs the server (`custom:update`) and the app (TestFlight).

## Testing without Apple

`OPENCODE_APNS_ORIGIN` (tests only) sends every APNs request to a local cleartext HTTP/2 stand-in instead of Apple's
hosts; the log warns when it is set. `test/notifications.test.ts` covers the rules, payload, registry and hub;
`script/e2e-session-notifications.ts` runs them against a sandbox with real Luna 6 / low prompts.
