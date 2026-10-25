# iPhone data on demand (`custom.device`)

The Sessão mestra reads live data from Alexandre's iPhone through two direct tools, `iphone_status` and
`iphone_query`, registered only for the `mestra` agent. The iOS app (`packages/ios-custom`) collects the data on
demand; nothing is synchronized in the background and nothing is stored on the server besides presence.

## Flow

```text
mestra → iphone_query (plugin, Location L)
  → event rpc.custom.device.request { request: { requestID, deviceID, query, deadline, directory: L } }
  → app (EventHub, /api/event) runs the collector
  → POST /api/rpc/custom.device/respond?location[directory]=L { deviceID, requestID, answer }
  → the waiting tool call resolves
```

- **Presence** lives in plugin storage (`device:presence`), shared by every Location's plugin instance. The app calls
  `attach` when its event stream connects and every 30 seconds after that (lease of 75 seconds), and `detach` when
  the stream stops for good (app in the background without a voice call). A device is online while its lease is
  valid and it has not detached. Devices unseen for 30 days are dropped.
- **Pending requests** stay in memory in the plugin instance that emitted them. The host evaluates the plugin
  module once per Location, so a module-level map would not be shared between Locations. Instead the request
  carries its Location directory, and the app answers through that Location, which routes the RPC to the same
  instance.
- **Timeout:** 5 seconds by default, 1–30 seconds through `timeoutSeconds`. With no online device or a source turned
  off in the app, the tool answers immediately without emitting anything.

## Tools

`iphone_status({})` returns `{ online, devices: [{ deviceID, name, model, system, online, lastSeen, sources }] }`;
`sources` lists each source's switch and iOS authorization (`notDetermined`, `authorized`, `limited`, `requested`,
`denied`, `restricted`, `unavailable`). HealthKit never reveals read denials, so it reports only `requested`.

`iphone_query({ source, metrics?, from?, to?, granularity?, limit?, thumbnails?, timeoutSeconds? })` returns
`{ source, status, device?, lastSeen?, collectedAt?, data?, note?, truncated?, files? }`; photo thumbnails are
attached to the tool result as image file content (data URIs).

| Source | Data |
| --- | --- |
| `device` | battery percent and state, low power mode, thermal state, storage, model, iOS, locked, app state |
| `network` | connected or not, interfaces (Wi-Fi, cellular, wired), expensive, constrained, IPv4/IPv6 (no SSID) |
| `location` | coordinates, accuracy, timestamp and age, reverse-geocoded address; foreground only ("While Using"); in the background, the last known position with a note |
| `health` | `steps`, `activeEnergy`, `restingHeartRate`, `hrv`, `weight` as daily aggregates; `sleep` as nights with minutes per stage; `workouts`; `granularity: "sample"` adds sleep samples; at most 90 days, default the last 7 |
| `motion` | per day: steps, distance, floors and minutes per activity (walking, running, automotive, cycling, stationary); CoreMotion keeps only 7 days |
| `photos` | the most recent photos (1–10, default 5): date, kind, size, favorite, coordinates and a 384-pixel JPEG thumbnail |

Statuses: `ok`, `offline` (app not running), `timeout`, `locked` (HealthKit unreadable and no cached summary),
`disabled` (switch off in the app), `denied` (no iOS permission), `unavailable`, `error`.

With the iPhone locked, HealthKit cannot be read. The app keeps a daily summary of the last 90 days, written with
`completeUntilFirstUserAuthentication` protection and refreshed at most every 30 minutes while the app is active,
and answers from it with a note giving its timestamp.

The Mestra's instructions gain one line (`instructions` in `src/device/index.ts`), appended by this module's own
agent transform after `registerMaster`, so the master prompt in `src/master/index.ts` stays untouched.
