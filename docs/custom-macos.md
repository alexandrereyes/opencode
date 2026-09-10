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
