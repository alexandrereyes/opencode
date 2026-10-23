# Sessão mestra

`master/` registers the hidden primary agent `mestra` (display name **Mestra**), with a short invisible system prompt,
pt-BR summaries, explicit-user-request-only actions, untrusted-transcript precautions and on-demand `opencode` skill
guidance. Preferred model: `llm-proxy/gpt-6.1-sol-ultrafast#medium`; when absent/disabled the agent inherits the server
default. Its rules allow direct execution. `custom.master/info` advertises version 1 and the preferred model when present.

All tools use Standard Schema inputs/outputs in the `opencode` namespace. Non-Mestra contexts omit the control tools;
every captured executor independently rejects other agents. Existing `session_read` is unchanged. Controls target only
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
create/send/interrupt/answers, bounded output and virtual-clock wait timeout. `test/preferences.test.ts` covers the intents.
Run package tests with `LC_ALL=C bun test` on a localized Mac: unrelated worktree tests assert English Git diagnostics.
`script/verify-master.ts` uses only the owned 4179 sandbox, managed chat and fake repositories, never service discovery or
production. It requires actual tool calls (not just catalog search) before recording its transcript.
