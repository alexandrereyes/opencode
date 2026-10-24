# Sessão mestra

`master/` registers the hidden primary agent `mestra` (display name **Mestra**), with a short invisible system prompt,
pt-BR summaries, explicit-user-request-only actions, untrusted-transcript precautions and on-demand `opencode` skill
guidance. Its rules allow direct execution. The agent has no static model; `custom.master/info` advertises version 1 and
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
allows every permission. Every captured executor independently rejects other agents. Existing `session_read` is unchanged. Controls target only
nonarchived top-level sessions, excluding the caller and Mestra sessions; no subagent management or deletion is exposed.

| Tool | Input / result |
| --- | --- |
| `sessions_list` | Optional `state` (`running`, `needs-you`, `idle`), `projectID`, absolute `directory`, `since` epoch milliseconds, `limit` ≤ 50. Newest message activity first; reports truncation. |
| `session_status` | `sessionID`; real runtime state, own pending counts, unfinished step/tool, agent/model, directory/branch, activity, cost/tokens. Missing VCS is omitted. |
| `session_send` | `sessionID`, text ≤ 12,000 characters, optional `delivery` (`steer` default / `queue`). Returns durable admission ID, not completion. |
| `session_create` | Existing absolute `directory`, optional agent/model/title, first `text`. Creates a root session, not a worktree; returns ID/directory. |
| `session_interrupt` | `sessionID`; interrupts without resuming. |
| `requests_list` | Optional `sessionID`, `limit` ≤ 50. Own root questions/permissions only, with native field keys/options; 20,000 serialized-character budget, explicit truncation. |
| `request_answer` | Discriminated `question` (`requestID`, field-key/value `answer`) or `permission` (`requestID`, `allow` boolean), plus `sessionID`. Native form validation; permissions are once/reject, never persistent approval. |
| `session_wait` | `sessionID`, optional `timeoutSeconds` (30 default, 120 maximum). Caller-clock timeout without target interruption; short status + latest assistant text capped at 2,000 characters. |

Both send and create tag the admitted user prompt with `{"custom.master":{"sessionID":"<origin>"}}`.
Preferences add optional `data.masterSessions: Record<server, sessionID>` and `master.set` / `master.clear` intents;
old profiles remain version 1. iOS uses `local` within each server's own persisted profile, reuses managed chats, and
excludes the current master from list/attention counts. Trash uses native recursive archive, then clears the pointer.
There is no undo because native unarchive does not exist; archived transcripts remain readable.

## Reusable host integration points

The public plugin context previously omitted two existing client operations. With explicit approval, `session.active`
and `session.form.reply` are now exposed in Effect/Promise interfaces, the Promise adapter and the host. Form replies
resolve the owning Session's Location, check form ownership, then use native `Form.reply`. Permission replies likewise
resolve the target Location (the previous host implementation incorrectly used the plugin's own Location). No public
Protocol/HttpApi, schema, generated client, database or upstream implementation body is replaced.

`test/master.test.ts` covers boundaries, root/self filters, agent restrictions, state, requests, origin metadata,
create/send/interrupt/answers, bounded output, virtual-clock wait timeout and the default-model resolution (late
providers, Sol fallback, saved choices, missing/disabled models or variants, non-Mestra sessions ignored). Core's
`test/tool-opencode-master-model.test.ts` registers the plugin on the real host before the provider exists and follows
real `session.created`/`session.model.selected` events into `custom.master/info`. `test/preferences.test.ts` covers the intents.
The package suite runs in the default locale or `LC_ALL=C`; worktree checks assert Git state rather than translated diagnostics.
`script/verify-master.ts` uses only the owned 4179 sandbox, managed chat and fake repositories, never service discovery or
production. It requires actual tool calls (not just catalog search) before recording its transcript.

`script/verify-master-visibility.ts` verifies read-only Code Mode discovery in fresh build, Mestra, general-child and
late-configured-agent sessions in the owned 4179 sandbox. It saves bounded tool inventories under
`$TMPDIR/opencode/master-tool-visibility/` and removes only its own sessions. Core's
`test/tool-opencode-master-visibility.test.ts` covers the real custom registration and native snapshots/search; generic
direct/Code Mode scope and cache isolation are covered by `test/tool-registry.test.ts`. See
`docs/custom-master-session.md` for why a small generic snapshot extension is necessary instead of a late context hook.
