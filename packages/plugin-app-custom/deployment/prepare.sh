#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$root/environment.sh"
# This finite entrypoint synchronizes upstream before release preparation.
script="$root/bin/prepare.js"
if [ -f "$root/current/plugin/prepare.js" ]; then
  script="$root/current/plugin/prepare.js"
fi
exec "$OPENCODE_BUILD_BUN" "$script" "$root"
