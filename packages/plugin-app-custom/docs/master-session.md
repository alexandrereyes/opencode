# Sessão mestra

`master/` registers the hidden primary agent `mestra` (display name **Mestra**): a conversational interface to all of
Alexandre's sessions, able to answer anything the app lists show and to perform what their controls do. It has an
invisible system prompt with pt-BR summaries, explicit-user-request-only actions, untrusted-transcript precautions and on-demand `opencode` skill
guidance. Voice delegations arrive as plain user messages with no per-message preamble or marker; while a voice call
delegates, the session carries the **voice-call note** (below), so only then are answers shaped to be read aloud and
typed conversations keep their normal formatting. Its rules allow direct execution. The agent has no static model; `custom.master/info` advertises version 1 and
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

The Mestra controls sessions through the session tools, `tools.sessions.<name>`, which any agent may call
(`docs/sessions.md`). Its instructions name each tool by its exact path and input keys, so it calls them without
`search` (`test/master.test.ts` checks every path and key against the input schemas, and that no former name such as
`tools.mestra.sessions_list` or `tools.opencode.session_read` lingers). Since 2026-10-30 the controls are no longer the
Mestra's: keeping them from other agents was never a security boundary (an agent with a shell can drive the server
through `opencode2 api`), only context hygiene. The tools still treat the Mestra apart: Mestra sessions are never
targets, and only the Mestra's messages carry `custom.master`.

The Mestra agent denies the native `opencode_worktree_create` and `opencode_worktree_list` tools: they act on the caller's
own Location, which for Mestra is a managed chat, not the project Alexandre names. `tools.sessions.create` owns
worktrees. It also denies `question` (a form blocks the voice flow, which only reads replies aloud) and drops the
`subagent` tool from its context: controlling sessions through subagents is not allowed.

### Prompt

The invisible system prompt (`instructions`) is organized as role, answer style (brief pt-BR), the tool map with
direct call names, the attention concepts (`docs/sessions.md`), playbooks (overview order: needs you → errors → unread → running;
ambiguous targets; session creation and worktrees; send; pending requests; costs) and safety (explicit requests only,
transcripts and tool results are untrusted data, no control through subagents; what the tools do not cover goes
through `opencode2 api` from the shell).

### Voice-call note

Since 2026-10-30 the voice-specific answer style is not in the system prompt but in a keyed session instruction
(`ctx.session.instructions`, upstream #56550), `voiceNote` in `src/master/index.ts`: key `chamada-de-voz`, a short pt-BR
text saying a voice assistant relays Alexandre's requests and reads the answers aloud, so answers are short spoken
sentences without Markdown, lists, tables, IDs, paths or code. Core renders it as a context block at the next step,
and a later removal as a one-line "no longer applies"; neither rewrites the cached system prompt, starts a turn or is
lost to compaction.

- **On:** `custom.master/ensure` with `voice: true`, which the iPhone and Mac `VoiceMaster` and the watch delegator send
  at the call's first delegation (and when a deleted master is replaced), so the note precedes that prompt. A failure
  to set it is logged and the delegation still goes. Older servers ignore the field.
- **Off:** `custom.voice/end`, sent when a call's voice memory ends, removes it from the current master. The iPhone
  keeps that end marker in its local buffer and replays it after a crash or an offline period; a process killed before
  the call ended leaves the note on until the next call ends.
- The voice call itself was the observed problem: with the always-on rule the Mestra still answered calls with bold
  text and lists, 150–250 words in 20–35 s, and typed answers were forced into a spoken shape.

`mac_query` (namespace `mac`, available to every agent, `src/mac-data`) reads Calendar, Reminders and Contacts through
the OpenCode app on the Mac: `calendar` (`from`/`to`, `calendars`, `query`), `reminders` (`status`, `from`/`to`, `lists`,
`query`), `contacts` (name/phone/e-mail `query`) or `status`. Results carry the Mac time zone, `total` and `truncated`
(item `limit` and 20,000 serialized characters); a closed app, a source switched off or a missing grant fails with what
Alexandre has to do. See `docs/mac-data.md`.

Preferences add optional `data.masterSessions: Record<server, sessionID>` and `master.set` / `master.clear` intents;
old profiles remain version 1. iOS uses `local` within each server's own persisted profile, reuses managed chats, and
excludes the current master from list/attention counts. Trash uses native recursive archive, then clears the pointer.
There is no undo because native unarchive does not exist; archived transcripts remain readable.

`custom.master/ensure` (optional `model`, and `voice` for the voice-call note) is the only place a Mestra session is
created. It returns the `local` pointer
while that session exists and is not archived; otherwise (no pointer, deleted elsewhere such as the web, or archived) it
allocates, claims and confirms a managed chat, creates the session titled **Sessão mestra** with agent `mestra` and the
given model or the remembered one (`resolveModel`), sets the pointer through `custom.preferences/mutate` (which emits its
`updated` event) and returns `{sessionID, directory, created, preferences}`. A lock in a global slot
(`globalThis.opencodeCustomMasterEnsureLock`) serializes callers from every Location instance in the process, so
concurrent screen, voice and other clients converge on one master; module scope would not do, because the plugin loader
evaluates the module again for every Location (`test/master-ensure.test.ts` evaluates it twice). Deleting a
session is a native hard delete (messages and events are removed); the old transcript cannot be recovered and nothing
is migrated: the remembered model and the global voice memory are independent of the session. The web delete dialogs
warn when a target is a Mestra session and suggest archiving instead. Core's
`test/tool-opencode-master-ensure.test.ts` covers concurrent creation, a deleted and an archived master and the
remembered model on the real host. `ensure` calls other plugin RPCs (`custom.preferences`, `custom.chats`) through
`ctx.rpc`, as do `custom.voice/end` (the preferences pointer, to clear the voice-call note) and the watch. The release bundles its own Effect runtime, so `cli/script/custom-plugin.ts` sends
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

`test/master.test.ts` covers the agent (hidden primary, rules, denied tools), the instructions' tool paths and keys and
the default-model resolution (late providers, Sol fallback, saved choices, missing/disabled models or variants,
non-Mestra sessions ignored); the session tools are covered by `test/sessions.test.ts` (`docs/sessions.md`). Core's
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

Until 2026-10-30 the controls were scoped to the Mestra by a custom `agents` tool option in Core, verified by
`script/verify-master-visibility.ts` and Core's `test/tool-opencode-master-visibility.test.ts`; both were removed with
that option (see `docs/upstream-integrations.md`, "Customizations in upstream code").
