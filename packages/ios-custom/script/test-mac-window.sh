#!/bin/zsh
# Regression check for the Mac app's main window: builds OpenCodeMac (Debug) and runs MacStress against the
# in-memory fixture, which resizes the window to every size it can take on each screen, collapses and reopens
# Sessões and Contexto, opens Arquivos and the LLM proxy window and stays idle. A layout loop aborts the app
# (exit 134); a minimum width wider than a screen fails the run.
#
#   packages/ios-custom/script/test-mac-window.sh [runs] [idle seconds]
#
# It moves the window over the connected screens while it runs and starts from the default size (it clears the
# app's saved window frames). Nothing reaches a server.
set -euo pipefail
runs=${1:-1}
idle=${2:-30}
package=${0:A:h:h}
root=${package:h:h}
derived=${OPENCODE_MAC_DERIVED:-${TMPDIR%/}/opencode/mac-app-work/mac-derived}
logs=$(mktemp -d "${TMPDIR%/}/opencode/mac-window-stress.XXXXXX")
xcodebuild -project "$package/OpenCode.xcodeproj" -scheme OpenCodeMac -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" build -quiet
app="$derived/Build/Products/Debug/OpenCodeMac.app/Contents/MacOS/OpenCodeMac"
failed=0
for run in $(seq 1 "$runs"); do
  defaults delete br.com.alexandrem.opencode.mac.debug 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/br.com.alexandrem.opencode.mac.debug.savedState"
  log="$logs/run-$run.log"
  set +e
  timeout $((idle + 240)) "$app" -OpenCodeMacFixture contexto -OpenCodeMacFixtureRoot "$root" \
    -OpenCodeTheme openchamber-dark -OpenCodeMacStress "$idle" >"$log" 2>&1
  code=$?
  set -e
  if [[ $code -eq 0 ]] && grep -q '^MacStress ok' "$log"; then
    echo "run $run: ok"
  else
    failed=1
    echo "run $run: failed (exit $code); log: $log"
    grep -E '^MacStress|reason:' "$log" | tail -3
  fi
done
exit $failed
