#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$root/environment.sh"
release=$(CDPATH='' cd -- "$root/current" && pwd -P)
export OPENCODE_DISTRIBUTION_RELEASE="$(basename -- "$release")"
export OPENCODE_CONFIG_CONTENT="$(cat "$release/server-config.json")"
handoff=$("$OPENCODE_BUILD_BUN" "$release/plugin/handoff.js" "$root/state/opencode/service-custom.json")
unset OPENCODE_PTY_HANDOFF
if [ -n "$handoff" ]; then export OPENCODE_PTY_HANDOFF="$handoff"; fi
unset OPENCODE_TUI_UPDATER
# exec preserves launchd's process ownership. NodeRuntime owns graceful SIGTERM.
exec "$release/bin/opencode" serve --service
