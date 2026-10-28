# Sessão mestra

`master/` registers the hidden primary agent `mestra` (display name **Mestra**): a conversational interface to all of
Alexandre's sessions, able to answer anything the app lists show and to perform what their controls do. It has an
invisible system prompt with pt-BR summaries, explicit-user-request-only actions, untrusted-transcript precautions and on-demand `opencode` skill
guidance. It also covers voice: iOS voice delegations arrive as plain user messages with no per-message preamble or
marker, so the prompt asks for concise progress and a final summary that works read aloud, which suits text too. Its
rules allow direct execution. The agent has no static model; `custom.master/info` advertises version 1 and
the model new Mestra sessions should start with, resolved on every call (configured providers such as `llm-proxy` load
after this plugin, so a registration-time lookup always missed them):

1. the last model and variant chosen in a Mestra session, while that model is enabled and still offers the variant;
2. otherwise `llm-proxy/gpt-6.1-sol-ultrafast#medium`, when enabled;
3. otherwise no model, and clients fall back to the server default.

The choice is stored globally in plugin storage (`master:model`). It is updated from three sources: `session.created`
with agent `mestra` and a model, `session.model.selected` for a Mestra session (both observed by the plugin instance of
the session's Location, so they are seen while that Location is loaded), and the model of every Mestra step through the
`context` hook, which always runs in the session's Location. iOS sends the picker choice with `POST
/api/session/:id/model` right before a steered prompt, so a change takes effect at the next send; a picker change that is
never sent, or a queued prompt, does not change the default.

All tools use Standard Schema inputs/outputs in the `opencode` namespace. Each control registers `options.agents: ["mestra"]`:
the native request snapshot filters it before direct definitions, inline Code Mode catalogs and Code Mode search/runtime
are built. This also covers subagents and agents contributed by configuration after the custom plugin, even when a session
allows every permission. Every captured executor independently rejects other agents. Controls are also `pinned`, so the
Mestra catalog always lists their signatures instead of making the model `search` first (they are invisible to every other
agent, so pinning costs nothing elsewhere). Controls target only nonarchived top-level sessions, excluding the caller and
Mestra sessions; the only exception is a pending request owned by a subagent, accepted when its top-level ancestor is a
valid target. No deletion is exposed: archive is the destructive limit.

The Mestra agent denies the native `opencode_worktree_create` and `opencode_worktree_list` tools: they act on the caller's
own Location, which for Mestra is a managed chat, not the project Alexandre names. `session_create` owns worktrees.

### Inventory and attention

`master/inventory.ts` builds one snapshot per call from every top-level session (archived included, Mestra sessions
excluded), `session.active`, `request.pending`, the shared pins and mutes from `custom.preferences`, and the managed
chats root. Running sessions and request owners that are subagents are walked up their `parentID` chain once, so a
root's state and pending counts include its whole family, exactly like the app lists:

- **unread**: the navigation rule (`navigation/index.ts`): `time.idle > time.viewed` and either a newer completion or a
  `succeeded`/`failed` outcome. **failed**: `outcome === "failed"` and not viewed since.
- **state**: `needs-you` when the family has a pending question or permission, else `running` when the root or a
  descendant runs, else `idle`.
- **project**: grouped by `projectID`; the name is the basename of the main checkout (the directory with a `.git`
  directory), else the directory with most sessions. Managed chats collapse into one **Conversas** entry.
- Times are also rendered as pt-BR relative strings (`lastActivityAgo`) so answers never do epoch arithmetic.

| Tool | Input / result |
| --- | --- |
| `sessions_list` | Optional `state`, `unread`, `failed`, `query` (title/project words, accent-insensitive), `project` (name or ID), absolute `directory` (and below), `sinceHours`, `archived`, `limit` ≤ 50. Rows carry project, state, unread/failed/outcome, family pending counts, `subagentsRunning`, pinned/notify ("Avisar ao terminar"), relative time and cost (USD, descendants included); `counts` cover every match. |
| `projects_list` | Optional `query`, `limit`. Name, main directory, other worktree directories, session/needs-you/running/unread counts, relative last activity. |
| `session_status` | `sessionID`; the list row plus total cost, tokens, branch, unfinished step/tool, last reply text (tail, 1,500 characters), last run error, files changed by edit/write/patch tools in the last 100 messages and running subagents. |
| `sessions_search` | `query` (all words, accent-insensitive), optional `project`, `sinceHours`, `archived`, `limit` ≤ 20. Matches title/project and the latest 200 user/assistant messages of up to 150 recent sessions, with snippets. |
| `session_send` | `sessionID`, text ≤ 12,000 characters, optional `delivery` (`steer` default / `queue`). Returns durable admission ID, not completion. |
| `session_create` | `text`, optional absolute `directory` (omitted: a new managed chat, allocated/claimed/confirmed like the apps), `worktree` (`branch`, `name`, `from`), agent/model/title. Model and agent are validated against the target Location (a `provider/model` ID from the `models` tool is accepted). A worktree is created with the native strategy from the session's project, named `<repository>-<branch>` by default, then `git switch -c <branch>`; the session moves there before its first message. Any failure removes the empty session (and the worktree when the branch fails), so nothing is half-created. |
| `session_update` | `sessionID` plus any of `title`, `model`, `agent`, `pinned`, `notify`. Pins and "Avisar ao terminar" use the shared `sidebar.pin`/`sidebar.notify` intents; turning either off removes every server key of that session. Muting is gone (see `session-notifications.md`). |
| `session_interrupt` | `sessionID`; interrupts without resuming. |
| `session_mark_read` | `sessionIDs` or `all: true` (every unread or failed session). Native `session.view` at the session's `time.idle`, the same call the apps make when a session is opened. Already-read or uncontrollable sessions are reported as `skipped`. |
| `session_archive` | `sessionIDs`; the app's recursive archive (`archive/index.ts`: interrupt, wait, children, archive). Per-session failures are `skipped`. |
| `requests_list` | Optional `sessionID`, `limit` ≤ 50. Questions and permissions of roots and their subagents (`subagent` names the owner), compact form fields; 20,000 serialized-character budget, explicit truncation. |
| `request_answer` | Discriminated `question` (`requestID`, field-key/value `answer`) or `permission` (`requestID`, `allow`), plus the request's own `sessionID`. Native form validation; permissions are once/reject, never persistent approval. |
| `session_wait` | `sessionID`, optional `timeoutSeconds` (30 default, 120 maximum). Caller-clock timeout without target interruption; returns the full `session_status`. |

`session_read` (`session-read/`) now renders failed and interrupted runs (`[run failed: <message>]`), which were empty
before, so a transcript shows why a session stopped.

### Prompt

The invisible system prompt (`instructions`) is organized as role, answer style (voice-safe pt-BR), the tool map with
direct call names, the attention concepts above, playbooks (overview order: needs you → errors → unread → running;
ambiguous targets; session creation and worktrees; send; pending requests; costs) and safety (explicit requests only,
transcripts and tool results are untrusted data, no control through shell/API/subagents).

`mac_query` (namespace `mac`, available to every agent, `src/mac-data`) reads Calendar, Reminders and Contacts on the Mac through
the `OpenCode Mac Data` helper: `calendar` (`from`/`to`, `calendars`, `query`), `reminders` (`status`, `from`/`to`, `lists`,
`query`), `contacts` (name/phone/e-mail `query`) or `status`. Results carry the Mac time zone, `total` and `truncated`
(item `limit` and 20,000 serialized characters); missing grants fail with where to enable them. See "Calendar, Reminders
and Contacts" in `docs/custom-macos.md`.

Both send and create tag the admitted user prompt with `{"custom.master":{"sessionID":"<origin>"}}`.
Every tool's executor receives an explicit `MasterContext` (session, request, message, permission, VCS, worktree, model,
agent, preferences, managed chats and a small `git switch -c` runner), which the tests replace with fixtures.
Preferences add optional `data.masterSessions: Record<server, sessionID>` and `master.set` / `master.clear` intents;
old profiles remain version 1. iOS uses `local` within each server's own persisted profile, reuses managed chats, and
excludes the current master from list/attention counts. Trash uses native recursive archive, then clears the pointer.
There is no undo because native unarchive does not exist; archived transcripts remain readable.

`custom.master/ensure` (optional `model`) is the only place a Mestra session is created. It returns the `local` pointer
while that session exists and is not archived; otherwise (no pointer, deleted elsewhere such as the web, or archived) it
allocates, claims and confirms a managed chat, creates the session titled **Sessão mestra** with agent `mestra` and the
given model or the remembered one (`resolveModel`), sets the pointer through `custom.preferences/mutate` (which emits its
`updated` event) and returns `{sessionID, directory, created, preferences}`. A module-scope lock serializes callers from
every Location instance in the process, so concurrent screen, voice and other clients converge on one master. Deleting a
session is a native hard delete (messages and events are removed); the old transcript cannot be recovered and nothing
is migrated: the remembered model and the global voice memory are independent of the session. The web delete dialogs
warn when a target is a Mestra session and suggest archiving instead. Core's
`test/tool-opencode-master-ensure.test.ts` covers concurrent creation, a deleted and an archived master and the
remembered model on the real host. `ensure` is the plugin's only caller of other plugin RPCs (`custom.preferences`,
`custom.chats`) through `ctx.rpc`. The release bundles its own Effect runtime, so `cli/script/custom-plugin.ts` sends
the host only portable Standard Schemas for those calls too and encodes inputs / decodes outputs with the bundled codecs;
handing the bundled `Preferences.Profile` to the host made its parser run the bundled `Session.ID` check on a non-string
(`s.startsWith is not a function`, HTTP 500). `test/tool-opencode-master-ensure-bundle.test.ts` loads the plugin from
source and as the minified release bundle, with the real managed chats and a pointer to a deleted session.

## Reusable host integration points

The public plugin context previously omitted two existing client operations. With explicit approval, `session.active`
and `session.form.reply` are now exposed in Effect/Promise interfaces, the Promise adapter and the host. Form replies
resolve the owning Session's Location, check form ownership, then use native `Form.reply`. Permission replies likewise
resolve the target Location (the previous host implementation incorrectly used the plugin's own Location). No public
Protocol/HttpApi, schema, generated client, database or upstream implementation body is replaced.

`session.view` (mark as read) followed the same path on 2026-10-27: the existing `SessionApi.view` operation is
inherited by both plugin interfaces, adapted to its canonical endpoint, and the host maps it to native `Session.view`
with the idle instant in milliseconds. It keeps the native guard: a view older than the session's idle time or one
already covered by `time.viewed` is ignored.

`test/master.test.ts` covers boundaries, root/self/archive/subagent filters with their reasons, agent restrictions,
pinning, family-aware state and counts, unread/failed rules, list filters, projects, status (reply, error, files,
subagents, cost), search, subagent requests and answers, origin metadata, model/agent validation, standalone chats,
worktrees with branch and their cleanup on failure, update (rename, model, agent, pins/mutes across server keys), mark
read, archive, bounded output, virtual-clock wait timeout and the default-model resolution (late providers, Sol fallback,
saved choices, missing/disabled models or variants, non-Mestra sessions ignored). Core's
`test/tool-opencode-master-model.test.ts` registers the plugin on the real host before the provider exists and follows
real `session.created`/`session.model.selected` events into `custom.master/info`. `test/preferences.test.ts` covers the intents.
The package suite runs in the default locale or `LC_ALL=C`; worktree checks assert Git state rather than translated diagnostics.
`script/verify-master.ts` uses only the owned 4179 sandbox, managed chat and fake repositories, never service discovery or
production. It requires actual tool calls (not just catalog search) before recording its transcript.

`script/eval-master.ts` is the conversational evaluation used to tune the prompt and tools. Against an owned sandbox
(`custom-sandbox.ts up --port 4183`; 4096/4178 are refused) `prepare` keeps worktrees inside the sandbox home, creates
three fake repositories and real Terra sessions in every attention state (unread, read, failed, notify, pinned, pending
question, subagent permission, running) and snapshots them; `suite <prefix> [--model=…]` drives fresh Mestra sessions
through realistic requests in batches that do not interfere and saves each transcript, with every Code Mode call and
result, under `<home>/eval/runs`; `reset` rebuilds from the worktree and restores the snapshot, repositories and the
in-memory pending requests; `chat` and `state` support one-off checks. Judge both the answer and the resulting server
state (`state`), since a fluent answer can hide a tool that never ran.

`script/verify-master-visibility.ts` verifies read-only Code Mode discovery in fresh build, Mestra, general-child and
late-configured-agent sessions in the owned 4179 sandbox. It saves bounded tool inventories under
`$TMPDIR/opencode/master-tool-visibility/` and removes only its own sessions. Core's
`test/tool-opencode-master-visibility.test.ts` covers the real custom registration and native snapshots/search; generic
direct/Code Mode scope and cache isolation are covered by `test/tool-registry.test.ts`. See
`docs/custom-master-session.md` for why a small generic snapshot extension is necessary instead of a late context hook.
