# Custom macOS runtime

Runtime source entrypoint: `packages/cli/script/custom-server.ts`.
The maintenance API and Core activity barrier are maintained in this fork.

The operational updater, autonomous Astra reviewer/worker pipeline, launchd deployment,
and runbook are versioned in [alexandrereyes/my-env](https://github.com/alexandrereyes/my-env):
`deploy/opencode-custom/` and `docs/opencode-custom.md`.

Backend source and production UI must come from the same release commit. The MyEnv
controller owns isolated persistence, idle-leased activation, backups, and process handoff.

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
