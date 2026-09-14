---
name: update-custom-app
description: Use when the user asks to update, deploy, activate, check, roll back, or clean releases of their installed custom OpenCode app, backend, web UI, plugin, or TUI; provides the routine custom:update command and the one-time legacy migration workflow.
---

# Update Custom App

Use this skill for the installed macOS custom OpenCode instance built from the
`custom` branch of `~/Dev/opencode2`. Backend, custom web app, custom plugin, and
TUI must always come from the same immutable release commit.

## Routine Update

For every update after the one-time migration, give the user this single command:

```sh
cd ~/Dev/opencode2 && git pull --ff-only origin custom && bun run custom:update
```

`custom:update` prepares and activates the release, backs up the SQLite database,
and verifies the authenticated health response and exact running version. Do not
independently replace frontend, backend, plugin, TUI, or files inside a release.

Activating a release briefly interrupts the installed instance. Do not execute the
update or restart the app/server unless the user explicitly asks the agent to perform
that operational action. When the user only asks how to update, return the command.

## Verification

Check the installed release without changing it:

```sh
cd ~/Dev/opencode2 && bun run custom:status
```

Confirm that `prepared`, `current`, and `running` identify the expected commit and
that `health` is `ready`. Never print or expose the runtime password.

## One-Time Legacy Migration

Do not use migration for routine updates. It is only for an installation that still
uses the legacy custom service and separate beta `opencode2` service:

```sh
cd ~/Dev/opencode2 && git pull --ff-only origin custom && bun run custom:prepare && bun run custom:migrate --replace-launcher --stop-beta
```

The current machine has already completed this migration unless inspection proves
otherwise. Never suggest rerunning it merely to update the app.

## Recovery and Retention

Show status:

```sh
bun run custom:status
```

Preview or prune old releases while protecting current, previous, and prepared:

```sh
bun run custom:prune --dry-run --keep=3
bun run custom:prune --keep=3
```

Rollback requires the operator to review database migrations and explicitly assert
compatibility:

```sh
bun run custom:rollback --database-compatible
```

Do not claim that `--database-compatible` proves compatibility or restores a backup.
Consult `docs/custom-macos.md` for persistence, backup restoration, startup failure,
and migration details.
