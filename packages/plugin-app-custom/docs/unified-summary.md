# Single Live Activity for every server (unified summary) — contract v1

The apps show the sessions of several servers together, under a scope the user picks: **Todos** or one server. The
Live Activity follows that scope: **one activity per scope, one on screen**. In the "Todos" scope it summarizes the
sessions of every server and is written by one server, the **hub** (`custom.instance` `hub: true`, the Linux BRS),
which reads the other servers' summaries over a private link and joins them with its own.

This document is the contract between the backend (`src/live-activity/unified.ts`, `link.ts`, the hub in `index.ts`)
and the iOS app, and between two servers on the link. It extends [live-activity.md](live-activity.md); everything not
said here (the state's fields, the lifecycle, APNs, rendering) is as written there. The payloads in
[`unified-summary/`](unified-summary/) are normative fixtures: the backend tests produce them and the iOS tests must
decode and render them.

**Nothing changes without the configuration below.** A server with neither variable set behaves exactly as before:
its own Live Activity, no new field in any payload. Every new field is optional; older apps ignore them and older
servers ignore the new input.

## Who writes which activity

| Scope in the app | Where the app registers `custom.live-activity` | State pushed to the activity        |
| ---------------- | ---------------------------------------------- | ----------------------------------- |
| Todos            | **only on the hub**, with `scope: "all"`       | the joined state (this document)    |
| One server       | **only on that server**, without `scope`       | that server's own state (as always) |

An activity's push token and the device's push-to-start token are registered **only on the server that writes the
current scope**. Two servers never hold the same token, so they never write to the same card: there is no leader
election, no lease and no automatic failover. If the hub is down, "Todos" is unavailable; Alexandre switches the scope
to another server by hand and the app registers a new activity there.

Alerts follow from that with no new mechanism ([session-notifications.md](session-notifications.md#live-activity-alerts)):

- Sessions of the hub, in "Todos": through the card, as before, in a priority-10 update that carries the **joined**
  state and the `alert`.
- Sessions of another server, in "Todos": that server has no activity registered for the device, so its question,
  permission and failure alerts go out as **plain notifications** (the device keeps `custom.notifications` registered
  on every server). The hub never alerts for another server's sessions: it only sends the silent priority-10 update
  that moves the counters. So each event buzzes once. Alerts are not forwarded over the link.

## What the app does

### Registering

`custom.live-activity` / `register` gains one optional input field and one optional output field:

```ts
register input  { deviceID, serverKey, environment, theme, pushToStartToken?, scope?: "all" }
register output { push: "configured" | "unconfigured", scope?: "all" }
```

- **"Todos" scope:** call `register` **on the hub** with `scope: "all"`. `serverKey` stays opaque and the app's own:
  use the scope's key (for example `todos`) so the app tells this activity from a server's
  (`AgentsActivityAttributes.serverKey`, echoed in the push-to-start attributes). Then `activity`, `ended` and
  `unregister` as always, on the hub.
- **One server's scope:** call `register` on that server **without `scope`** (never send another value: only `"all"`
  is accepted), with that server's `serverKey`, as today.
- **The output's `scope: "all"` is the confirmation** that this registration gets the joined state. It is absent when
  the server reads no peer (not configured as the writer, or a server from before this contract, which ignores the
  input field): the registration then gets that server's own state and the app should treat the activity as that
  server's, not as "Todos".
- A device has **one registration per server** (keyed by `deviceID`), so re-registering with or without `scope`
  switches what that server pushes to the device's activity from then on.

### Changing scope

The app is in the foreground when the scope changes. In this order:

1. `register` on the new scope's writer (with `scope: "all"` when it is "Todos").
2. Start the new activity locally with the new scope's `serverKey`, call `activity` there with its push token.
3. End the previous scope's activity with immediate dismissal (the ordered swap of "Manual recreation" in
   live-activity.md), and on the **previous writer**, when it is another server, call `unregister` so it stops writing
   and never sends a push-to-start. When both scopes are written by the same server (Todos ↔ the hub's own scope), no
   `unregister`: the registration of step 1 replaced the old one, and `ended` for the old activity changes nothing.
4. If the previous writer cannot be reached, retry `unregister` when it comes back. Until then it may still send a
   push-to-start when its own work rises: the duplicate rule (keep the activity of the current scope, end the others
   at once, report `ended`) already runs on that background wake.

### Reading the state in the foreground

`snapshot` and the `changed` event gain one optional field:

```ts
{ state: AgentsState | null, unified?: AgentsState }
```

- `state`: the server's own state, unchanged.
- `unified`: the joined state, present **only from a server that reads its peers** (the hub). In the "Todos" scope the
  app starts and updates the local activity from `unified`; in a server's scope, from `state`. `changed` is emitted
  when either changes.

### New fields of the state

Only a **joined** state carries them; a server's own state never does.

```ts
AgentsState += {
  servers?: Server[]        // every server the state covers; the first is the writer (the hub)
}
Server {
  instanceID: string        // the server's `custom.instance` instanceID
  name: string              // its `custom.instance` name ("Linux BRS", "Mac de Alexandre")
  short: string             // the badge's initials by the apps' rule (ServerSwitcher.initials): "LB", "MA"
  offline?: true            // the hub has no fresh summary of it; none of its sessions are in the state
}
SessionRef += {
  server?: string           // the instanceID of the server the session lives on
}
```

- `server` is on `focus` and on every item of `attention`, `sessions` and `needs`. A session is identified by
  **(`server`, `sessionID`)**: an imported session has the same ID on two servers and appears as two rows. The app
  opens a row on the server whose `custom.instance` `instanceID` equals `server`, and draws its badge from the
  `servers` entry with that `instanceID` (`short`).
- `host` of a joined state is ready-made copy for builds that do not read `servers`: the online servers' names joined
  by `+`, then `· <name> offline` for each offline one, clipped to 40 characters: `Linux BRS + Mac de Alexandre`,
  `Linux BRS · Mac de Alexandre offline`. A newer build lays out the header from `servers` instead.
- A server appears in `servers` once the hub has read it at least once (the hub remembers it across restarts).
  A configured peer that never answered is not listed.

### How the joined state is computed

A pure function (`join` in `src/live-activity/unified.ts`) over the hub's own state and each peer's latest summary:

- `counts.*`, `activeTotal`, `attentionTotal`: sums. `counts.browser` only when the sum is above zero.
- `attention`: every server's items, oldest `since` first; cut to 3.
- `needs`: question, permission, browser (oldest `since` first), failed, unread (most recent first); cut to 3.
- `sessions`: question, permission, browser (oldest first), failed (most recent first), working (the focus first, then
  most recent activity), unread (most recent first); cut to 4. The times come from each server's `order` (below).
- `focus`: the hub's own focus while it has one, else the first peer's. Another server's focus is an ordinary working
  row.
- Ties: the hub first, then the peers in configuration order, then `sessionID`.
- Then the same rules as any state: the 4096-byte fitting (`fit`, same trimming order; `servers` and `server` are
  never trimmed), `relevance-score`, `stale-date`, parked when `counts.working == 0`, urgency (priority 10) when the
  set of things that need Alexandre changes **on any server**, the 10-second coalescing, the heartbeat, push-to-start
  when the joined `activeTotal` rises from 0, dismissal and expiry. All of them are evaluated on the joined state for
  the "Todos" devices and on the server's own state for the others, independently.
- **Offline:** a peer whose last summary is older than 60 seconds leaves the state (counts and rows) and stays in
  `servers` with `offline: true`. Its sessions leaving or returning change the set of things that need Alexandre, so
  that update is urgent.

Fixtures, for 2026-10-27 09:41 BRT (`updatedAt` 1793104860000):

| File                                                                 | Shows                                                                                     |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| [`summary-linux.json`](unified-summary/summary-linux.json)           | The hub's own summary: 2 working, 1 question, 1 unread                                    |
| [`summary-mac.json`](unified-summary/summary-mac.json)               | The Mac's summary (`live-activity/state-mixed.json` plus `order` and `marks`)             |
| [`state-joined.json`](unified-summary/state-joined.json)             | `join` of the two: counts added, the Mac's older question before the hub's, rows cut to 4 |
| [`state-peer-offline.json`](unified-summary/state-peer-offline.json) | The same hub with the Mac away: only its sessions, `Linux BRS · Mac de Alexandre offline` |

The joined state, abridged (`state-joined.json` has it whole):

```json
{
  "v": 1,
  "updatedAt": 1793104860000,
  "host": "Linux BRS + Mac de Alexandre",
  "counts": { "working": 3, "question": 2, "permission": 1, "failed": 2, "idle": 1, "unread": 2 },
  "activeTotal": 6,
  "focus": {
    "sessionID": "ses_01JZSWARMMIGRATION00000011",
    "title": "Migrar o AbacatoV3 para o Swarm",
    "project": "abacato-v3",
    "directory": "/srv/dev/abacato-v3",
    "startedAt": 1793104136000,
    "activity": "Rodando docker stack deploy",
    "server": "3f0c1f4e-6c0b-4a57-9d55-0a4f3b1c9e21"
  },
  "attention": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "kind": "question",
      "since": 1793104680000,
      "text": "Qual banco usar no cache?",
      "server": "9b2e7c60-1d4f-4e0a-8a3b-5c6d7e8f9a10"
    }
  ],
  "attentionTotal": 3,
  "sessions": [
    {
      "sessionID": "ses_01JZCACHEDATABASE000000002",
      "title": "Escolher banco do cache",
      "project": "core",
      "directory": "/Users/alexandremartins/Dev/opencode2",
      "status": "question",
      "server": "9b2e7c60-1d4f-4e0a-8a3b-5c6d7e8f9a10"
    }
  ],
  "needs": [],
  "servers": [
    { "instanceID": "3f0c1f4e-6c0b-4a57-9d55-0a4f3b1c9e21", "name": "Linux BRS", "short": "LB" },
    { "instanceID": "9b2e7c60-1d4f-4e0a-8a3b-5c6d7e8f9a10", "name": "Mac de Alexandre", "short": "MA" }
  ]
}
```

With the Mac away, `servers[1]` gains `"offline": true`, `host` reads `Linux BRS · Mac de Alexandre offline` and no
row or count of the Mac remains.

## Link (server to server), protocol 1

The hub cannot reach the other server over HTTP; the other server publishes its summary on a **Unix socket**, and the
deployment carries that socket to the hub (in production, a reverse SSH tunnel of the `mac-bridge`).

- **Served:** plain HTTP on the socket, one route: `GET /summary` → `200` with the JSON below (`503` is reserved for
  a server with no state to give; today the socket only opens once the Live Activity hub is ready). Any other path or
  method → `404`. Read-only: nothing on the link changes anything.
- **Body** (`Summary`, [`summary-mac.json`](unified-summary/summary-mac.json)):

  ```ts
  Summary {
    protocol: 1
    instanceID: string                 // the server's custom.instance instanceID
    name: string                       // its custom.instance name
    state: AgentsState                 // its OWN state before the 4 KB fitting, lists already cut (3/4/3)
    order: Record<sessionID, number>   // epoch ms each `state.sessions` row is ordered by inside its status:
                                       // asked (requests), ended (failed), latest activity (working), unread since
    marks: string[]                    // every `<status>:<sessionID>` that needs Alexandre, untruncated (urgency keys)
  }
  ```

- **Never the joined state.** A server always publishes its own state, also when it reads peers itself, so two
  servers pointed at each other cannot loop. A peer whose `instanceID` is the reader's own (its own socket listed as a
  peer) is ignored.
- **Authentication:** none in the protocol; the socket's permissions are the boundary. The server creates it `0600`
  in a `0700` folder, so only its own user opens it. Whoever carries it elsewhere decides who reads it there (see
  "Deployment"). No secret, no token.
- **Reading:** the hub requests every peer each 5 seconds with a 3-second deadline and keeps the last good answer for
  60 seconds.
- **Degradation, all the same to the app:** a missing socket, a refused connection, a deadline, a non-200 answer, a
  body with another `protocol`, or a body that does not decode as this version's `Summary` (for example a newer
  server sending a status this one does not know) is a failed read. After 60 seconds without a good read the peer's
  part leaves and it is `offline`; **servers on incompatible versions therefore show the hub's sessions alone** until
  both are updated. The log says why once per kind of failure (`Unified summary peer is not readable`, with
  `reason`), and `Unified summary peer is back` when it returns.
- **Version:** `protocol` changes only for an incompatible change of `Summary`. New optional fields do not change it.

## Configuration

| Variable                  | On                                             | Value                                              | Effect                                                                         |
| ------------------------- | ---------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------ |
| `OPENCODE_SUMMARY_SOCKET` | every server that is **not** the hub (the Mac) | absolute path of a Unix socket, at most ~100 bytes | Publishes this server's summary there (`GET /summary`)                         |
| `OPENCODE_SUMMARY_PEERS`  | the hub (Linux BRS)                            | comma-separated socket paths, one per other server | Reads them, joins them: accepts `scope: "all"`, answers `unified`              |
| `OPENCODE_HUB`            | the hub                                        | `1`                                                | Unchanged ([instance.md](instance.md)): tells the apps which server is the hub |

- Read once, when the Live Activity hub starts (with the first Location: a session running or a client's RPC).
  A server restarted with nobody connected publishes its socket only then, and shows as offline until then.
- The socket's folder is created `0700` when missing. A stale socket file from a dead process is replaced. A socket
  that **answers** belongs to another running server and is left alone (logged as a warning, nothing is published):
  a sandbox started with production's environment cannot take production's socket. `custom-sandbox.ts` also drops
  both variables and only sets them from `--summary-socket` / `--summary-peers`.
- The plugin does not check that `OPENCODE_SUMMARY_PEERS` is set only on the server that declares `OPENCODE_HUB=1`.
  Set both on the same single server.

## Deployment (written only; nothing of this is applied)

Production today: the Linux BRS (`opencode_opencode-svc`, host-6, `OPENCODE_HUB=1`, APNs on) and the Mac. The Mac
already opens reverse SSH tunnels to host-6 (`~/Dev/core-infra/opencode-docker/mac-bridge`), which publish Unix
sockets in `/srv/mac-bridge`, mounted read-only in the container as `/run/mac-bridge`. The summary is a third socket
of that kind.

```text
Mac server (plugin)  listens on  ~/.local/share/opencode-custom-v2/run/summary.sock   (0600, OPENCODE_SUMMARY_SOCKET)
Mac LaunchAgent com.alexandrem.mac-bridge-summary
  └─ ssh -N -R /srv/mac-bridge/summary.sock:/Users/alexandremartins/.local/share/opencode-custom-v2/run/summary.sock mac-bridge@host-6
       host-6: /srv/mac-bridge/summary.sock (0660, mac-bridge:1000) → /run/mac-bridge/summary.sock in the container
Linux server (plugin) reads  /run/mac-bridge/summary.sock   (OPENCODE_SUMMARY_PEERS)
```

What would have to be done, in `core-infra` unless noted:

1. **`mac-bridge/mac/install`**: a third tunnel job next to the two existing ones, from the same template
   (`com.alexandrem.mac-bridge-tunnel.plist.in`): label `com.alexandrem.mac-bridge-summary`, forward
   `/srv/mac-bridge/summary.sock:<the Mac socket path above>` (a socket-to-socket `-R`; the two existing ones forward
   to a TCP port), log `~/Library/Logs/mac-bridge/summary.log`; `status`/`uninstall` and the tests
   (`tests/test_mac_bridge.py`) learn the fourth LaunchAgent. A separate job on purpose, like the resources hub's:
   with `ExitOnForwardFailure=yes`, a problem with this socket never takes the `mac` command's tunnel down. The
   tunnel stays up while the Mac's server is restarting: `ssh` opens the Mac-side socket per connection.
2. **host-6 `60-mac-bridge.conf`: no change.** `AllowStreamLocalForwarding remote` already lets the `mac-bridge`
   account publish any Unix socket in `/srv/mac-bridge`, `StreamLocalBindMask 0117` gives it `0660`, and
   `StreamLocalBindUnlink yes` replaces a stale one (the README's "Host-6: nada muda" for the second socket holds for
   a third). `host/setup-host` only needs `summary.sock` added to the sockets it shows and removes.
3. **Linux compose (`docker-compose.fork.yml`)**: one environment line,
   `OPENCODE_SUMMARY_PEERS: /run/mac-bridge/summary.sock`; the bind of `/srv/mac-bridge` already exists. It needs an
   image of the fork with this plugin version.
4. **Mac (`~/.local/share/opencode-custom-v2/manual.json`, `environment`)**:
   `"OPENCODE_SUMMARY_SOCKET": "/Users/alexandremartins/.local/share/opencode-custom-v2/run/summary.sock"`. It takes
   effect on the next activation that starts the service (`custom:update` to a release with this plugin).
5. **Secrets: none.** No vault entry and no policy change. The link adds no credential: on the Mac only Alexandre's
   user opens the socket; in the container any UID-1000 process does, and such a process already has a shell on the
   Mac through `mac`, which reads far more than session titles.

**Order.** The two sides are independent and each is inert without the other, so either order is safe:

1. Mac first: `custom:update` with the variable in `manual.json`, then the LaunchAgent (`mac/install install`).
   Check on the Mac: `curl -s --unix-socket ~/.local/share/opencode-custom-v2/run/summary.sock http://summary/summary | jq .protocol`
   → `1`. Nobody reads it yet; the Mac's own Live Activity is unchanged.
2. Linux next: new image plus the compose line (a deploy with no sessions running, as usual). Check in the container:
   `curl -s --unix-socket /run/mac-bridge/summary.sock http://summary/summary | jq .name`, and the log has no
   `Unified summary peer is not readable`.
3. Only then an app build that registers with `scope: "all"`. An older app keeps one activity per server throughout.

If Linux goes first instead, it logs the peer as not readable once and writes its own sessions alone (no server is
listed as offline, as the Mac was never read) until the Mac side is up.

**Rollback.** Remove `OPENCODE_SUMMARY_PEERS` from the compose and redeploy: the hub stops confirming `scope: "all"`
and pushes its own state to every registration, old or new (a stored `scope` is ignored without peers). On the Mac,
remove the variable (next activation) and `launchctl bootout gui/$(id -u)/com.alexandrem.mac-bridge-summary`. Stored
registrations need no cleanup. To cut the link at once without touching either server, the `bootout` alone is enough:
the hub shows the Mac as offline 60 seconds later.

## Tests

- `test/unified-summary.test.ts`: `join` over the fixtures (sums, order, cuts, the offline peer), the order inside
  failed/working/unread, the same session ID on two servers, a peer that is the reader itself, the 4 KB fitting;
  the reader's degradation (a peer that stops answering, the 60 seconds, its return, identity kept across restarts,
  another protocol, an undecodable body); the real socket (only `GET /summary`, `0600`, absent socket, a live socket
  never taken over); and the hub with a fake APNs: the "Todos" activity gets both servers, loses and regains the
  peer, alerts through the joined card, push-to-start from the peer's work, a server without peers ignoring `scope`,
  and the published summary staying the server's own.
- `script/e2e-unified-summary.ts`: two sandboxes linked by a socket, each with its own fake APNs (see its header).
