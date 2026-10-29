# Mac Calendar, Reminders and Contacts (`custom.mac`)

Any agent reads Alexandre's Calendar, Reminders and Contacts through one tool, `mac_query` (namespace `mac`, code
mode). The OpenCode app on the Mac (`packages/ios-custom`, target `OpenCodeMac`) reads them on demand with EventKit
and Contacts.framework, under its own macOS grants; the server holds none and stores nothing besides presence. The
flow is the iPhone's (`docs/device.md`) with its own RPC, so an always-online Mac never answers `iphone_query`.

## Flow

```text
agent → mac_query (plugin, Location L)
  → event rpc.custom.mac.request { request: { requestID, deviceID, query, deadline, directory: L } }
  → Mac app (EventHub → MacDataAgent) runs MacDataCollectors
  → POST /api/rpc/custom.mac/respond?location[directory]=L { deviceID, requestID, answer }
  → the waiting tool call resolves
```

- **Presence** lives in plugin storage (`mac:presence`), shared by every Location's plugin instance. The app calls
  `attach` (`deviceID`, computer name, model, macOS) when its event stream connects and every 30 seconds after
  that (lease of 75 seconds), and `detach` when it quits or switches servers. The most recently seen online Mac
  answers; Macs unseen for 30 days are dropped.
- **Only the installed app answers** (bundle `br.com.alexandrem.opencode.mac`). Debug and fixture builds stay
  silent unless launched with `-OpenCodeMacData`, so development runs never take requests meant for it.
- **Pending requests** stay in the emitting plugin instance; the request carries its Location directory and the
  app answers through it, as for the iPhone.
- **Timeout:** 60 seconds, long enough for a first-time macOS prompt, which the app shows and waits for. Ordinary
  answers take milliseconds. With no online Mac the tool fails at once (`offline`) without emitting anything.
- **Answer:** the JSON the tool returns (`calendar`, `reminders`, `contacts` or `status`), or
  `{ error, source, message }`. The RPC takes it as opaque JSON and the tool decodes it, so a malformed answer
  fails the call at once instead of timing out.

## Tool

`mac_query` input: `calendar` (`from`/`to`, `calendars`, `query`, `limit` ≤ 200), `reminders` (`status`,
`from`/`to`, `lists`, `query`, `limit` ≤ 200), `contacts` (`query`, `limit` ≤ 50) or `status`. Dates are
`YYYY-MM-DD` (a whole local day, `to` inclusive) or ISO date-times; results carry the Mac time zone. Lists are bounded
by `limit` (default 50, contacts 10) and 20,000 serialized characters, with `total` and `truncated`. `status`
returns each source's macOS permission and in-app switch without prompting.

Failures become instructions for the agent: `offline` (open the app), `timeout`, `disabled` (Ajustes → Dados do
Mac), `notDetermined` (click Allow on the Mac's prompt), `denied` (enable "OpenCode" in System Settings → Privacy &
Security, with Full Access for Calendars and Reminders), `restricted`, `invalid` and `failed` (the app's message).

## App side

- `OpenCodeKit/MacData.swift`: request/attach types, the dispatcher (a source switched off answers at once; a
  collector is cut at the deadline), date parsing and `MacDataPreferences` (every source on by default).
- `OpenCodeMac/MacDataAgent.swift`: presence heartbeat, request handling, detach on quit.
- `OpenCodeMac/MacDataCollectors.swift`: the EventKit and Contacts reads, off the main actor; asks for a permission
  the first time a source is read or switched on.
- `OpenCodeMac/MacDataSettings.swift`: Ajustes → Dados do Mac, one switch per source with its permission, "Pedir
  permissão" and a link to the System Settings pane when denied.
- The usage descriptions are in `OpenCodeMac/Info.plist`; the hardened runtime also requires the
  `com.apple.security.personal-information.calendars` and `.addressbook` entitlements. The app is signed with the
  Apple Development team, so its grants survive rebuilds.
