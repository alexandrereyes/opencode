#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$root/environment.sh"
release=$(CDPATH='' cd -- "$root/current" && pwd -P)
export OPENCODE_TUI_UPDATER="$release/plugin/tui.js"
export OPENCODE_PASSWORD="$("$release/bin/opencode" service get password)"
server=$("$release/bin/opencode" service status)
if [ "$server" = stopped ]; then
  echo 'The launchd service is not running.' >&2
  exit 1
fi
# Explicit connection prevents a client-version mismatch from replacing launchd's server.
exec "$release/bin/opencode" --server "$server" "$@"
