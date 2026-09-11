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

## Agent dashboard

The desktop sidebar has **Agent dashboard** immediately below **New session**. The
`/agent-dashboard` route fills the central workspace with compact or comfortable cards;
selecting a card opens its normal Session. The route also fits narrow windows, while its
navigation entry follows the existing desktop-only sidebar breakpoint (768px).

The selected server's global navigation index includes sessions outside the recent page.
The default view shows active sessions, pending permissions/questions, and conversation
activity or completion in the last 24 hours. Search covers title, project name, and directory;
filters cover project, status, and subagents. Cards keep creation order during live updates.
Filters, density, the displayed
page size, and return scroll position persist per window.

Top-level sessions are the default; their cards include descendant running/attention state
and a subagent count. **Include subagents** exposes child cards individually. Completed and
error states come from execution outcomes; interrupted or never-run sessions remain idle.
Unread responses alone do not mean **Needs you**.

Navigation refreshes reconcile complete rows, removing omitted request/unread timestamps.
This clears **Needs you** in both the dashboard and sidebar after a question or permission is resolved.

The dashboard reuses existing APIs and SSE. It pages lightweight navigation metadata,
renders 60 cards at a time with **Show more** (running/attention cards bypass this limit), and reads only the three latest messages for
visible/near-visible cards, with four preview requests at most in flight. Previews retain
up to 600 text characters, omit reasoning and tool payloads, and follow live text/tool events.
Current branch reads are deduplicated by Location and requested as cards become visible;
branches are displayed on cards but are not a search criterion. A text response outside the
three-message window is not loaded. No per-card timeline or periodic history polling is mounted.

New source copy is English-only, including the **Agent dashboard** title; other locales use
the runtime fallback. This change adds a route and sidebar integration, without changing
session/timeline code; no session production-benchmark comparison is applicable. Unit
coverage exercises request/status transitions, the 24-hour boundary, filters, stable order,
descendant aggregation, preview omission, and bounded read concurrency. Reactive unit tests in
`test-browser/agent-dashboard-preview.test.ts` exercise the production preview's SSE updates,
stale reads, execution completion/interruption, and viewport/unmount cancellation using the
browser Solid runtime. Browser verification
is prepared in `e2e/regression/agent-dashboard.spec.ts` for an isolated reviewer-run server.

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

Sent quotes use a shared desktop/mobile renderer inside the user bubble, with a caption and subtle quote line.
Long passages initially show four lines and expand independently; comments remain fully visible.
Copy retains the complete underlying message, including quote context, regardless of the collapsed state.

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
Project and branch share the context header. Subagents precede Subscriptions, followed by
background tasks and MCPs; there is no separate Project section.
The current Session's Context label, ring and usage value stay together at the start edge.
Its token count uses a fixed K suffix for thousands (for example 701K), with localized decimals.
Each subagent's metadata line shows its agent icon/name and the production context ring,
compact token count, and percentage for its most recent measured assistant call. This is
not cumulative token consumption. The model and limit belong to the child; unknown limits
do not produce an invented percentage. These reads load locally without suspending Usage.
The latest measurement remains visible during an unmeasured streaming step; the next measured
step reflects compaction. A bounded recent-assistant read revalidates on opening, reconnection,
and committed revert, while live step events update the indicator without periodic polling.
Session data follows the live event stream. Subscription snapshots refresh every 60 seconds while
the tab is visible (and on manual refresh); they are read-only and do not trigger upstream polling.
Usage renders cached Session information immediately. Pending subscription and subagent requests
show the shared Spinner locally rather than suspending the whole route or mobile navigation.
MCP catalogs keep their loading state until a response arrives. Closing Usage or changing Session
invalidates its family loader before it can publish late results to the shared cache.

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

Subscriptions initially shows a collapsed available-Pro-pool overview. The weekly percentage is
the mean remaining quota of enabled, authenticated Pro accounts with fresh capacity and no cooldown
(observed plan wins over the login claim). Exhausted or cooling-down accounts do not dilute the
available balance; availability still reports available accounts over total Pro membership.
Missing or stale participating measurements make the balance unknown rather than zero or a partial
average. Account details explicitly label remaining/used quota, plan, and confirmed or
unconfirmed capacity; non-Pro accounts are marked outside the active pool.
The update time reflects the oldest measurement included. Expanding reveals every subscription,
including accounts outside the Pro pool. Banked resets are not added to the balance.
Subscription details list available Pro accounts first, followed by other Pro accounts,
Plus, and other plans. Accounts retain their source order within the same priority group;
the ordering follows quota refreshes without changing pool calculations or proxy selection.
The always-visible summary also shows the fresh banked-reset inventory for the Pro pool, with
the first and last expiration (or no expiration). Unknown inventory is not reported as zero.
Each expanded account shows its own banked-reset count beside the plan, including zero;
unavailable inventory is marked explicitly. Dividers separate the account rows.
On mobile, Usage and its live context ring occupy the fourth tab; Terminal is in More options.
Background task rows are single-line previews. Selecting one opens its full text in a dialog,
with an Open subagent link for agent tasks.
Background activity follows current runtime state and the selected Session. Historical tool
metadata saying a task was backgrounded is not evidence that it is still running after completion,
cancellation, or a server restart.
Movement messages are queried by type to discover previous Locations after a cold reload, so a
Session still shows its live shells in the original Location until they exit. Fork-copied history
does not transfer ownership, and a child reused in foreground is not duplicated in background.
