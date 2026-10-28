# Session notifications ("Avisar ao terminar")

Contract between the plugin and the iOS app (`packages/ios-custom`) for the per-session bell that replaced
"Silenciar" on 2026-10-28. When a session with the bell on finishes its work, the server sends an APNs alert to every
registered iPhone. Permission and question requests are out of scope: they stay with the Live Activity and the in-app
alerts.

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

## When a session finishes

The Live Activity hub's tracker is the source of truth, with its "working" roll-up (rev. 2026-10-28): a top-level
session works while its own execution, any descendant's execution, or an unfinished background shell of the family
runs. For each known, unarchived top-level session in `notifySessions`:

1. It must be seen working by this process (a finish that happened while the server was down, or before the bell
   was turned on, alerts nothing).
2. When the family stops working it must stay quiet for **5 seconds** (`limits.graceMs`): a background shell or
   subagent that ends wakes its parent a moment later, and that gap is not the end of the work. Working again inside
   the window cancels it.
3. Then the outcome of the root's own latest execution decides: `succeeded` → "Terminou", `failed` → "Terminou com
   erro". `interrupted` (Alexandre stopped it, or a shutdown) alerts nothing: he caused it, so there is nothing to
   learn from a notification.

One alert per finish and device; nothing more until the family works again. Turning the bell off before the end
cancels it.

## Payload

`apns-push-type: alert`, topic = the bundle ID (`OPENCODE_APNS_BUNDLE_ID`, default `br.com.alexandrem.opencode`),
priority 10, expiration 24 hours. Each device's own APNs environment and `serverKey` are used.

```json
{
  "aps": {
    "alert": { "title": "Corrigir login OAuth", "body": "Terminou · app-custom" },
    "sound": "default",
    "thread-id": "ses_01JZOAUTHLOGIN000000000003"
  },
  "opencode": {
    "kind": "session.finished",
    "serverKey": "mac-principal",
    "sessionID": "ses_01JZOAUTHLOGIN000000000003",
    "directory": "/Users/alexandremartins/Worktrees/opencode2-oauth-login",
    "outcome": "succeeded"
  }
}
```

The title is the session title clipped to 80 characters ("Sem título" when empty); the body names the project like
the Live Activity rows (last segment of the directory and subpath). `thread-id` groups a session's alerts; the Apple
Watch mirrors them.

## App behavior

- The bell is off for every session. The first time Alexandre turns one on, the app asks for notification permission
  (never at launch); with permission it registers for remote notifications and sends the token to the connected
  server, then again on every connection.
- Presentation (`willPresent`): with the app in the foreground and that session's conversation open on the same
  server, the alert is not shown; otherwise it shows (banner, list, sound). Tapping it opens the session, switching
  servers through `serverKey` like a Live Activity link.
- The in-app banner skips completions of sessions with the bell on while this server pushes, so a finish is not
  announced twice.

## Compatibility

- **New app, old server:** `sidebar.notify` is rejected (`rpc.invalid_input`) and the app shows "Atualize o servidor
  para usar o aviso ao terminar"; no local-only bell is fabricated. A missing `custom.notifications` RPC only stops
  the token registration.
- **Old app, new server:** "Silenciar" keeps writing `mutedSessions`, which is accepted and ignored.
- **Order:** both work in either order; the bell needs the server (`custom:update`) and the app (TestFlight).

## Testing without Apple

`OPENCODE_APNS_ORIGIN` (tests only) sends every APNs request to a local cleartext HTTP/2 stand-in instead of Apple's
hosts; the log warns when it is set. `test/notifications.test.ts` covers the finish rule, payload, registry and hub.
