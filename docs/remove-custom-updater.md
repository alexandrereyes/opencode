# Retire automatic custom updates

## Scope

Base: custom `a42d037c5`. Remove the periodic updater and its idle-maintenance
support. Preserve the custom server entrypoint, UI/plugin loading, normal
process supervision, and native Session/Job shutdown and restart recovery.
The causal undo extensions are independent and must remain functional.

## OpenCode removal

- Remove `Maintenance.process`, its admission wrappers, activity/blocker
  tracking, and state used only by the updater.
- Remove `/api/server/maintenance` acquire/cancel/commit and their Server
  wiring; regenerate the client through `packages/client`.
- Remove `JobMaintenance` and updater-specific shutdown/handoff plumbing.
- Retire the recurring `JobUpgrade` compatibility scan without abandoning
  `job.background.upgrade/` records. Use a narrowly scoped one-time migration
  or explicit versioned conversion, tested with legacy data and conflicts.
- Preserve normal execution, permissions/forms, PTYs, shells, job generation
  guards, session claims and startup recovery.

## MyEnv operation

All versioned OpenCode deployment, configuration, updater, supervisor, and runbook
artifacts are removed from MyEnv. This source removal is not an operational uninstall:
installed files, launchd state, global configuration, and live processes remain untouched.

## Verification

Test normal startup/shutdown and recovery, including pending background
notifications; legacy bridge conversion must preserve payload/identity and
never silently overwrite conflicts. Verify removed HTTP routes, plugin loading,
and causal undo regressions. Operator tests must prove that pending releases or
controller-pointer changes do not cause automatic activation and that manual
build/dev paths work without maintenance APIs.

Measure the remaining diff against fixed upstream `0f26ad878`; remove only the
updater-related changes and preserve unrelated work. Follow each repository's
instructions. Existing upstream bugs are outside scope.

Implementation is reviewed before commit/push. Work only in isolated worktrees
and temporary test environments. Do not stop/restart installed services, change
launchd or global configuration, access production databases, create pending
releases, or activate a release. The installed updater remains disabled.

## Implemented retirement

- Core and Server no longer expose an idle-maintenance barrier or maintenance HTTP routes.
- Native Session/Job execution, durable background markers, shutdown claims, and startup recovery remain unchanged.
- Migration `20260913000000_restore-background-upgrade` converts legacy
  `job.background.upgrade/` markers exactly once. Missing destinations receive the original
  payload and timestamps. Equivalent destinations are retained even when their timestamps differ.
  A divergent destination fails and rolls back the migration, including its journal entry, so the
  conflict remains visible and startup retries after explicit resolution.
- MyEnv no longer contains an OpenCode deployment or update workflow. The custom server can be
  built and run directly from this repository through `packages/cli/script/custom-server.ts`.
