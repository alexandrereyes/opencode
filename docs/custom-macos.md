# Custom macOS runtime

Runtime source entrypoint: `packages/cli/script/custom-server.ts`.
The maintenance API and Core activity barrier are maintained in this fork.

The operational updater, autonomous Astra reviewer/worker pipeline, launchd deployment,
and runbook are versioned in [alexandrereyes/my-env](https://github.com/alexandrereyes/my-env):
`deploy/opencode-custom/` and `docs/opencode-custom.md`.

Backend source and production UI must come from the same release commit. The MyEnv
controller owns isolated persistence, idle-leased activation, backups, and process handoff.

Production is the main UI at **4096**; **4177 is ephemeral development only**, started on demand
from a feature worktree based on `origin/custom`. First adoption of the old managed backend
requires an explicit cold maintenance window: never stop the live service hosting a session.
The main runtime may reuse the original database through `OPENCODE_CUSTOM_DB` and original
configuration through `OPENCODE_CONFIG_DIR`, only after the MyEnv cold-adoption checks/backup.

## Mobile composer

On mobile layouts (below 768px), Enter inserts a new line and Shift+Enter submits the
composer. Desktop keeps Enter to submit and Shift+Enter for a new line. Mod+Enter
retains alternate delivery, and Enter still selects an open suggestion before submission.

Touch devices (a coarse primary pointer, including iPhone and iPad) enable autocorrection,
sentence capitalization, and spellcheck in normal chat mode. Desktop pointer input and shell
mode keep these disabled. Writing assistance follows the input device, not viewport width.

## Prompt snippets

Settings → Snippets manages reusable text with a name, description, comma-separated search aliases,
and content. Snippets are stored persistently in the OpenCode server database, globally or scoped
to a project. Settings selects the server to manage; all its devices share the same catalog and
receive live updates. Existing device-local snippets are not migrated.
Project snippets override global snippets with the same name. Type `#` in the composer, search,
and select with Enter, Tab, or a click. Selected tokens use the theme accent and expand to their
captured content on submission, including when a command is prefixed from the composer menu.
Drafts and prompt history retain the structured token. Snippets do not require server config files.

## Chat quotes

Select prose or code inside one assistant text part and choose **Comment**. The composer
keeps the selected passage and an optional editable comment in **Chat quotes** above the
prompt. Quotes can be removed, collapsed, or sent without additional prompt text.
Confirming with the checkmark, Escape, or Cmd/Ctrl+Enter finishes editing and collapses
the quotes panel; plain Enter inserts a line break. The chip reopens saved quotes.

Drafts are scoped to their Session and server and survive reloads. Submission appends the
quoted passages, source message/part IDs, and comments to the model-visible text while
keeping structured quote metadata for history, queue editing, and revert. Failed prompt
admission restores the submitted quotes. Selection cannot span different text parts.

The implementation uses existing prompt APIs; no Protocol or generated client changes.
This ports the chat-comment workflow, not OpenChamber's separate Notes feature.

Validation: production-build browser scenarios at 1440px and 390px cover selection,
editing, persistence, quote-only submission, history recall, and removal. Existing queue
regressions and composer/persistence tests also pass. A cold-session entry benchmark
measured 307ms first correct / 333ms stable on the base and 236ms / 266ms with the feature
(one local sample each, not a statistically significant performance comparison).

## Session mentions

Type `@` in the web composer to search recent top-level sessions on the current server by
title or exact ID. Sessions from other projects are included; the current session, archived
sessions, and subagents with a parent are excluded. The existing mention query ends at a space.
Session suggestions show a conversation icon, title, directory, and shortened ID, and selected
references use a distinct chip alongside Mac app, file, and agent mentions.

References retain their identity through drafts, history, queue edits, and same-server copy/paste.
Submission adds compact, deduplicated references. The `opencode.session_read` tool retrieves
text on demand in newest-first pages: 20 messages by default, up to 50, with a 20,000-character
message-text budget. Tool payloads and reasoning are omitted; truncated messages are marked.

Pending autocomplete searches keep the composer visible and focused. Browser regressions cover
delayed results, duplicate titles, Mac apps with the same label, and long chips on mobile.

## Inference footer

Assistant response metadata stays visible on desktop and mobile, with trailing copy actions.
Icon-labelled items show model, recorded reasoning variant, agent, output tokens per second,
processing duration, and local date/time (`dd/MM HH:mm`). TPS uses existing output-token and
provider-stream timestamps; unavailable metrics are omitted. No API changes are required.

## Session context overview

The existing Context tab prioritizes context usage, session and descendant costs, project/branch,
LLM proxy subscriptions, subagent navigation, background tasks, and MCP connection controls above the detailed statistics.
Session data follows the live event stream. Subscription snapshots refresh every 60 seconds while
the tab is visible (and on manual refresh); they are read-only and do not trigger upstream polling.

Set `OPENCODE_LLM_PROXY_URL` on the backend to the internal proxy base URL. The authenticated
`GET /api/server/subscriptions` endpoint reads `/_admin/status` server-side and returns only quota
metadata. Weekly percentages are shown as remaining quota; dates are quota resets, not subscription
or OAuth expirations. Missing/stale usage is marked explicitly. No credits balance is displayed.
Panel tab selection is persisted per server and Session, including across Location changes.
The chat/side-panel divider width is a shared local preference: resizing it in any Session
applies to existing and new Sessions and survives reloads. Narrow windows clamp the rendered
width without overwriting the saved preference.
Entering a desktop Session opens the side panel automatically, selecting Context when no
previous panel tab is saved. Existing selections are restored; mobile navigation is unchanged.

Subscriptions initially shows a collapsed Pro-pool overview. The weekly percentage is the mean
remaining quota of enabled, authenticated Pro accounts (observed plan wins over the login claim).
If any participating account lacks a fresh weekly measurement, the balance is unknown rather
than a partial average. Availability separately requires fresh upstream capacity and no cooldown.
The update time reflects the oldest measurement included. Expanding reveals every subscription,
including accounts outside the Pro pool. Banked resets are not added to the balance.
The always-visible summary also shows the fresh banked-reset inventory for the Pro pool, with
the first and last expiration (or no expiration). Unknown inventory is not reported as zero.
On mobile, Usage and its live context ring occupy the fourth tab; Terminal is in More options.
Background task rows are single-line previews. Selecting one opens its full text in a dialog,
with an Open subagent link for agent tasks.
