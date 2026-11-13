# Single Live Activity for every server (unified summary) — contract v1

The apps show the sessions of several servers together, under a scope the user picks: **Todos** or one server. The
Live Activity follows that scope: **one activity per scope, one on screen**. In the "Todos" scope it summarizes the
sessions of every server and is written by one server, the **hub** (`custom.instance` `hub: true`, the Linux BRS),
to which the other servers send their summaries, and which joins them with its own.

This document is the contract between the backend (`src/live-activity/unified.ts`, `link.ts`, the hub in `index.ts`)
and the iOS app, and between two servers on the link. It extends [live-activity.md](live-activity.md); everything not
said here (the state's fields, the lifecycle, APNs, rendering) is as written there. The payloads in
[`unified-summary/`](unified-summary/) are normative fixtures: the backend tests produce them and the iOS tests must
decode and render them.

**Nothing changes without the configuration below.** A server that is neither the hub nor pointed at one behaves
exactly as before: its own Live Activity, no new field in any payload. Every new field is optional; older apps ignore
them and older servers ignore the new input.

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
  the server is not the hub (or is a server from before this contract, which ignores the input field): the registration then gets that server's own state and the app should treat the activity as that
  server's, not as "Todos".
- A device has **one registration per server** (keyed by `deviceID`), so re-registering with or without `scope`
  switches what that server pushes to the device's activity from then on.

### Changing scope

The app is in the foreground when the scope changes. In this order:

1. `register` on the new scope's writer (with `scope: "all"` when it is "Todos").
2. Start the new activity locally with the new scope's `serverKey`, call `activity` there with its push token.
3. End the previous scope's activity with immediate dismissal (the ordered swap of "Manual recreation" in
   live-activity.md), then tell its server, which depends on who wrote it:
   - **Another server wrote it** (Todos ↔ the Mac's scope, or one server's scope ↔ another's): call **`unregister`
     on that server, never `ended`** (rev. 2026-11-14). `ended` keeps the registration and rearms its push-to-start
     (it is how the backend learns that iOS ended an activity and a new one may start), so that server would start a
     card of its own with its next work. `unregister` removes the device's whole Live Activity registration there:
     the activity token, the push-to-start token and every memory of dismissal or rearming; nothing is pushed to the
     device's activities from that server until it registers there again. It does not touch `custom.notifications`,
     a separate registration that stays valid on that server, so its alerts now go out as plain notifications.
   - **The same server writes both** (Todos ↔ the hub's own scope): nothing more. The `register` of step 1 replaced
     the registration and the `activity` of step 2 the activity; an `ended` for the old activity is harmless there
     (it names an activity other than the registered one, which changes nothing) but is not needed.
4. The same rule for a duplicate the app finds later (an activity of a scope that is not the current one, on a
   background wake after a push-to-start for instance): end it at once and `unregister` on its server when that is
   not the current scope's writer; `ended` only for an extra activity of the current scope's own writer.
5. If the previous writer cannot be reached, retry `unregister` when it comes back. The servers also settle most of
   this between themselves ("Stale registrations" below), so the retry is a second line, not the only one.

### Reading the state in the foreground

`snapshot` and the `changed` event gain one optional field:

```ts
{ state: AgentsState | null, unified?: AgentsState }
```

- `state`: the server's own state, unchanged.
- `unified`: the joined state, present **only from the hub**. In the "Todos" scope the
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
  offline?: true            // the server is away (below): its work in progress is not in the state; what waited
                            // there (requests, failures, unread answers) is, as last known
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
- A server appears in `servers` once it has sent the hub a summary (the hub remembers it across restarts and forgets
  it after 30 days of silence). The hub alone, before any other server sent one, is the only entry.

### How the joined state is computed

A pure function (`join` in `src/live-activity/unified.ts`) over the hub's own state and each other server's latest
summary:

- `counts.*`, `activeTotal`, `attentionTotal`: sums. `counts.browser` only when the sum is above zero.
- `attention`: every server's items, oldest `since` first; cut to 3.
- `needs`: question, permission, browser (oldest `since` first), failed, unread (most recent first); cut to 3.
- `sessions`: question, permission, browser (oldest first), failed (most recent first), working (the focus first, then
  most recent activity), unread (most recent first); cut to 4. The times come from each server's `order` (below).
- `focus`: the hub's own focus while it has one, else the first other server's. Another server's focus is an ordinary working
  row.
- Ties: the hub first, then the other servers in the order the hub first heard from them, then `sessionID`.
- Then the same rules as any state: the 4096-byte fitting (`fit`, same trimming order; `servers` and `server` are
  never trimmed), `relevance-score`, `stale-date`, parked when `counts.working == 0`, urgency (priority 10) when the
  set of things that need Alexandre changes **on any server**, the 10-second coalescing, the heartbeat, push-to-start
  when the joined `activeTotal` rises from 0, dismissal and expiry. All of them are evaluated on the joined state for
  the "Todos" devices and on the server's own state for the others, independently.
- **Offline (`servers[].offline`).** A server is away when it stopped renewing a summary that had work in progress
  (60 seconds without one, "Link" below) or said it was stopping. Its **work in progress leaves** the state (working
  rows, the focus, `counts.working`, its share of `activeTotal`), because nothing says it still runs. **What waited
  there stays, as last known**: its pending questions and permissions, failures and unread answers, in the counts and
  in the rows. They are still true, and they are answered when the server is back.
- A server going offline or coming back is **urgent** like a change in what needs Alexandre: the update goes out at
  once with priority 10, also on a parked card.
- **A parked server is never marked offline by silence.** With nothing working, a server sends nothing until its
  state changes, so the hub cannot tell a parked Mac that sleeps from one that is awake: its last summary stays in
  force, which is what it would say if asked. Rows of a server the app cannot reach right now can therefore be on the
  card without `offline`; the app's own connection state to that server is what says whether it can be opened.

Fixtures, for 2026-10-27 09:41 BRT (`updatedAt` 1793104860000):

| File                                                                 | Shows                                                                                                                                                     |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`summary-linux.json`](unified-summary/summary-linux.json)           | The hub's own summary: 2 working, 1 question, 1 unread                                                                                                    |
| [`summary-mac.json`](unified-summary/summary-mac.json)               | The Mac's summary (`live-activity/state-mixed.json` plus `order` and `marks`)                                                                             |
| [`state-joined.json`](unified-summary/state-joined.json)             | `join` of the two: counts added, the Mac's older question before the hub's, rows cut to 4                                                                 |
| [`state-peer-offline.json`](unified-summary/state-peer-offline.json) | The same with the Mac away: its working session and focus gone, its question, permission and failures still there, `Linux BRS · Mac de Alexandre offline` |

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

With the Mac away, `servers[1]` gains `"offline": true`, `host` reads `Linux BRS · Mac de Alexandre offline`,
`counts.working` drops to 2 and `activeTotal` to 5; the Mac's question, permission and failures stay.

## Link (server to server), protocol 1

The hub cannot reach the other servers, but they reach it as any client does (the Mac's app already talks to
`http://opencode-svc` over the private network). So each other server **sends** its summary to the hub, from inside
the plugin, through the hub's normal API. Nothing else is involved: no tunnel, no socket, no extra process.

### RPC `custom.summary` (on the hub; called by servers, never by the apps)

| Method    | Input                      | Output                                    | Errors                                                              |
| --------- | -------------------------- | ----------------------------------------- | ------------------------------------------------------------------- |
| `publish` | `Summary`                  | `{ protocol: 1, devices?: Registered[] }` | `not_hub`, `protocol_mismatch` (`data.expected`), `invalid_summary` |
| `leave`   | `{ protocol, instanceID }` | `{}`                                      | `not_hub`                                                           |

Over HTTP, as every plugin RPC: `POST <hub>/api/rpc/custom.summary/publish` with the body `{"input": <Summary>}`.

```ts
Summary {                            // unified-summary/summary-mac.json
  protocol: 1
  instanceID: string                 // the sender's custom.instance instanceID
  name: string                       // its custom.instance name
  state: AgentsState                 // its OWN state before the 4 KB fitting, lists already cut (3/4/3)
  order: Record<sessionID, number>   // epoch ms each `state.sessions` row is ordered by inside its status:
                                     // asked (requests), ended (failed), latest activity (working), unread since
  marks: string[]                    // every `<status>:<sessionID>` that needs Alexandre, untruncated (urgency keys)
  devices?: Registered[]             // rev. 2026-11-14: every Live Activity registration the sender holds
}
Registered { deviceID: string, registeredAt: number }   // epoch ms of the device's last `register` on that server
```

- **Only the hub accepts.** A server without `OPENCODE_HUB=1` answers `not_hub` (HTTP 400) to both methods.
- **Version.** A `protocol` other than the hub's is refused with `protocol_mismatch`; a body of this protocol that
  does not decode (for example a newer server sending a status the hub does not know) with `invalid_summary`. Nothing
  is stored, and **the hub goes on with its own sessions** (plus whatever that server last sent validly, by the
  rules below) until both are updated. `protocol` changes only for an incompatible change of `Summary`; new optional
  fields do not change it.
- **Never the joined state.** A server always sends its own state, also when it is a hub itself, so servers pointed
  at each other cannot loop. A summary whose `instanceID` is the hub's own is ignored in the join.
- **Authentication:** the hub's normal one, HTTP Basic, user `opencode` and the hub's server password: the call is a
  client call like the apps'. The sender takes the password from where it already is, in this order:
  1. `OPENCODE_SUMMARY_HUB_PASSWORD` in the server's **private environment** (`manual.json` `mycred`, see
     `docs/custom-macos.md`), for a hub whose password differs; the plain environment is accepted too, for tests;
  2. otherwise **this server's own password**, which production's two servers share
     (`core-infra/opencode-docker/FORK.md`): `password` of `service-custom.json` in `OPENCODE_CONFIG_DIR`, the
     managed service's own credential file, else `<OPENCODE_CUSTOM_HOME>/password` (a source server or sandbox).

  The plugin API gives a plugin neither the server's password nor its address, so the plugin reads the file the
  server itself reads. No new secret is created or copied anywhere, and the password is never logged (a refusal is
  logged as `unauthorized`).

### Stale registrations (rev. 2026-11-14)

When the scope changes while the previous writer is unreachable, the app cannot `unregister` there. That server would
keep a registration and the token of an activity the app already ended: back up with the app closed, it would send
its alerts through that dead activity (lost when APNs still accepts the token) and could start a card of its own by
push-to-start. The two servers settle it with the summary, with no call from the app:

- A device is in one scope at a time and calls `register` only on that scope's writer (on every launch and
  foreground), so **between the hub's "Todos" registration of a device and another server's own registration of the
  same `deviceID`, the one with the newer `registeredAt` is where the device is; the older one is dropped**, exactly
  as `unregister` would (the Live Activity registration only; `custom.notifications` stays).
- **Went to "Todos":** `publish` answers with `devices`, the hub's registrations with `scope: "all"`. The sender drops
  each of its own registrations whose `deviceID` is there with a **strictly newer** `registeredAt`.
- **Left "Todos" for that server:** the summary carries `devices`, every registration the sender holds. The hub drops
  each of its `scope: "all"` registrations whose `deviceID` is there with a strictly newer `registeredAt` (and does
  not list it in its answer).
- Only a `scope: "all"` registration takes part, on the hub's side. Registrations without a scope on both servers
  are never compared: that is an app from before the scopes, which keeps one activity per server.
- A new registration makes its server send a summary at once (parked too), so the hub hears of "left Todos" within a
  second when reachable. The other direction is learned with the sender's **next** summary: at once when it comes
  back up (the case that matters), otherwise with its next change or renewal.

Limits: the times are each server's own clock, so a switch there and back inside the two clocks' difference could be
judged wrong (the app's next `register`, on its next foreground, corrects it). A switch between two scopes of
servers neither of which is "Todos" (the Mac's scope to the hub's own) is not covered: only the app's `unregister`
retry clears the old one. A server that is up but parked, which the app alone could not reach, learns of "went to
Todos" only with its next summary.

### When a server sends

Driven by changes, with as little renewal as possible (`makePublisher`, `src/live-activity/link.ts`):

- **At once when its Live Activity hub starts**, and **whenever its own state changes** (the same events that drive
  `changed`), at most once per second.
- **Renewal every 15 seconds only while something works there** (`counts.working > 0`). No event says that a working
  server fell asleep or died, and without renewal its sessions would stay "working" on the card for ever. 15 seconds
  lets three renewals in a row be lost before the hub's 60 seconds run out, and costs four small requests a minute
  only during work. It is the same idea as the activity's `stale-date` (15 minutes working, 8 hours parked).
- **Parked (nothing working): nothing is sent** until the state changes. A parked summary stays true while the
  server sleeps.
- **A send that fails is tried again** after 2, then 5, then every 15 seconds, until it gets through; so a hub that
  comes back gets the current summary within 15 seconds. This applies parked too: a change that could not be
  delivered is never dropped. The log says it once per kind of failure (`Unified summary could not be sent to the
hub; retrying`, with `reason`: `unreachable`, `unauthorized …`, `protocol_mismatch (HTTP 400)`, …) and once when it
  gets through again.
- **`leave` when the server stops** (the plugin's scope closing), best effort with a 2-second deadline, only if the
  hub ever received a summary. A crash or a sleep sends nothing.
- Sending runs in its own fiber with a 5-second request deadline: it never holds the Live Activity loop, sessions or
  pushes.

### What the hub keeps

- The latest summary of each `instanceID`, with the time it arrived.
- **Working summary** (`counts.working > 0`): in force for **60 seconds** after it arrived. Not renewed by then, the
  server is `offline` and only its settled part remains (see "Offline" above). The next summary from it puts it back.
- **Parked summary:** in force until replaced. It never expires by time.
- **`leave`:** offline at once, same treatment.
- **Across a hub restart:** the settled part of each summary is kept in plugin storage (`unified:peers`), written
  only when it changes (not on renewals, not while only the work moves) and forgotten after 30 days without news. A
  parked server has no reason to send again, so without this a hub restart would lose its unread answers and pending
  requests until its next change. After a restart a server shows as last known, not offline; if it was working, its
  next renewal (within 15 seconds) brings the work back.

### Known limits (decided, not accidents)

- **A parked server that sleeps is not shown as offline**, and what waits there stays on the card. This is true
  information, but Alexandre cannot act on it until the Mac wakes: a pending question or permission of the Mac shows
  as `1 pergunta`, and tapping it reaches a server that does not answer. The same holds for a parked Mac that
  crashes or loses power (no `leave`). The app knows by its own connection whether that server answers and should
  say so on the row or when opening it; the card cannot.
- **The Live Activity hub of a server exists only while some Location is loaded** (a session running or a client's
  RPC, see live-activity.md "Startup"). A server restarted with no client connected sends nothing until then: after
  its `leave` it stays offline on the card, with what waited there, until its first Location loads. When its last
  Location unloads while the server stays up, it also says `leave`.
- **During active work the sender may post once per second** (each change of the focus's activity text is a
  change), as `changed` does to a connected app. The hub still pushes at most once per 10 seconds.

## Configuration

| Variable                        | On                                              | Value                                         | Effect                                                                                                                     |
| ------------------------------- | ----------------------------------------------- | --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `OPENCODE_HUB`                  | the hub (Linux BRS)                             | `1`                                           | Already there ([instance.md](instance.md)). Now also: accepts `custom.summary`, confirms `scope: "all"`, answers `unified` |
| `OPENCODE_SUMMARY_HUB`          | every other server (the Mac)                    | the hub's address, e.g. `http://opencode-svc` | Sends this server's summary there                                                                                          |
| `OPENCODE_SUMMARY_HUB_PASSWORD` | the same servers, optional, private environment | the hub's password                            | Only when it differs from the sender's own                                                                                 |

- Read once, when the Live Activity hub starts. Without `OPENCODE_SUMMARY_HUB` nothing is sent.
- A hub with no other server sending is complete by itself: `unified` is its own state with `servers` listing only
  it.
- `custom-sandbox.ts up` drops production's `OPENCODE_SUMMARY_HUB` and `OPENCODE_SUMMARY_HUB_PASSWORD`, so a sandbox
  never sends its sessions to production's hub; a test sets `--summary-hub <url>` on the sandbox that sends. A source
  server started by hand (`custom-server.ts`) with production's environment **would** send to production's hub and
  appear there as one more server: unset the variable for such runs.

## Deployment (written only; nothing of this is applied)

Production today: the Linux BRS (`opencode_opencode-svc`, host-6, `OPENCODE_HUB=1` already in the compose, APNs on)
and the Mac, which reaches the Linux at `http://opencode-svc` over the private network (the address the Mac app
uses) and has the same server password. **No `mac-bridge` change, no LaunchAgent, no compose line, no vault or policy
change.**

| Server    | What changes                                                                                                                                                                                                                                         |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux BRS | Only the image: a fork build with this plugin. `OPENCODE_HUB=1` is already set, so it starts accepting summaries and answering `unified` as soon as it runs this version                                                                             |
| Mac       | A release with this plugin (`custom:update`) and one line in `~/.local/share/opencode-custom-v2/manual.json` `environment`: `"OPENCODE_SUMMARY_HUB": "http://opencode-svc"`. It takes effect on the activation that starts the service               |
| Secrets   | None, while the two passwords are equal. If they ever differ: the hub's password in the vault, listed in the Mac's `manual.json` `mycred` as `OPENCODE_SUMMARY_HUB_PASSWORD`, with the policy allowing that path (the owner's change, not made here) |

**Order: Linux first, then the Mac.** Each side is inert without the other, so the reverse is also safe, only
noisier:

1. Linux: deploy the new image (with no sessions running, as usual). Check: `custom.live-activity/snapshot` answers
   with `unified` whose `servers` lists only `Linux BRS`; `custom.summary/publish` with `{"input":{"protocol":0}}`
   answers 400 `protocol_mismatch`.
2. Mac: add the variable, `custom:update`. Check in the Mac's log: `Unified summary is sent to the hub` and no
   `could not be sent`; on the Linux, `snapshot` `unified.servers` now lists the Mac.
3. Only then an app build that registers with `scope: "all"`. An older app keeps one activity per server throughout.

If the Mac goes first, it logs once that the hub refused (`rpc.unavailable (HTTP 400)`: no such RPC there yet) and
retries every 15 seconds, which succeeds by itself once the Linux is updated.

**Rollback.** On the Mac, remove `OPENCODE_SUMMARY_HUB` from `manual.json` and activate: it stops sending; if it was
working, the hub shows it offline 60 seconds later, and what waited there stays listed until forgotten (30 days) or
until the key `unified:peers` is cleared on the hub. On the Linux, going back to the previous image removes the RPC
and `unified`; registrations stored with `scope` are then served the server's own state, and the Mac (if still
sending) logs the refusal once and keeps retrying harmlessly. Removing `OPENCODE_HUB=1` instead also turns the hub
off for the apps ([instance.md](instance.md)).

## Tests

- `test/unified-summary.test.ts`: `join` over the fixtures (sums, order, cuts, the offline server keeping what
  waits), the order inside failed/working/unread, the same session ID on two servers, a summary of the hub itself,
  the 4 KB fitting; the hub's side (a working summary expiring after 60 seconds and returning, a parked one never
  expiring, `leave`, the restart restoring the settled part, storage written only when it changes, 30 days); the
  stale registrations (the newest of a "Todos" and a server's own wins, in both directions; registrations without a
  scope are left alone; notifications stay); the sender (start, change, renewal only while working, at most one per second, the hub away and back with the 2/5/15
  waits, `leave` only after a delivery); the HTTP call (route, Basic credential, wrong password, refusal, absent
  hub) and where the password comes from; the RPC (a server that is not the hub, another protocol, an invalid body);
  and the hub with a fake APNs: the "Todos" activity gets both servers, loses and regains the other's work, alerts
  through the joined card, push-to-start from the other server's work, a server that is not the hub ignoring
  `scope`, and two servers linked in memory (what is sent is the sender's own state; stopping it says goodbye).
- `script/e2e-unified-summary.ts`: two sandboxes, one sending to the other over HTTP, each with its own fake APNs
  (see its header).
