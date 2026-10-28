#!/bin/zsh
# Regression check for the Mac app's main window: builds OpenCodeMac (Debug) and runs MacStress against the
# in-memory fixture, which resizes the window to every size it can take on each screen, collapses and reopens
# Sessões and Contexto, opens Arquivos and the LLM proxy window and stays idle. A layout loop aborts the app
# (exit 134); a minimum width wider than a screen fails the run.
#
#   packages/ios-custom/script/test-mac-window.sh [runs] [idle seconds]
#
# It moves the window over the connected screens while it runs and starts from the default size. It runs a copy
# of the build under its own bundle identifier (`br.com.alexandrem.opencode.mac.debug.tests`, ad-hoc signed), so
# clearing that copy's preferences and saved window state never touches the Debug app's (servers, the restored
# selection, Ajustes) used by development and the other checks. Nothing reaches a server.
set -euo pipefail
runs=${1:-1}
idle=${2:-30}
package=${0:A:h:h}
root=${package:h:h}
derived=${OPENCODE_MAC_DERIVED:-${TMPDIR%/}/opencode/mac-app-work/mac-derived}
logs=$(mktemp -d "${TMPDIR%/}/opencode/mac-window-stress.XXXXXX")
xcodebuild -project "$package/OpenCode.xcodeproj" -scheme OpenCodeMac -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" build -quiet
domain=${OPENCODE_MAC_TEST_DOMAIN:-br.com.alexandrem.opencode.mac.debug.tests}
copy="$logs/OpenCodeMacTests.app"
ditto "$derived/Build/Products/Debug/OpenCodeMac.app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $domain" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
app="$copy/Contents/MacOS/OpenCodeMac"
clear_state() {
  defaults delete "$domain" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/$domain.savedState" "$HOME/Library/Preferences/$domain.plist"
}
trap 'clear_state; rm -rf "$copy"' EXIT
failed=0
for run in $(seq 1 "$runs"); do
  clear_state
  log="$logs/run-$run.log"
  captures=()
  if [[ -n "${OPENCODE_MAC_CAPTURES:-}" ]]; then
    mkdir -p "$OPENCODE_MAC_CAPTURES"
    captures=(-OpenCodeMacCapture "$OPENCODE_MAC_CAPTURES")
  fi
  set +e
  timeout $((idle + 240)) "$app" -OpenCodeMacFixture contexto -OpenCodeMacFixtureRoot "$root" \
    -OpenCodeTheme openchamber-dark -OpenCodeMacStress "$idle" \
    "${captures[@]}" >"$log" 2>&1
  code=$?
  set -e
  if [[ $code -eq 0 ]] && grep -q '^MacStress ok' "$log" && grep -q '^MacStress duas janelas independentes ok' "$log"; then
    echo "run $run: ok"
  else
    failed=1
    echo "run $run: failed (exit $code); log: $log"
    grep -E '^MacStress|reason:' "$log" | tail -3
  fi
done
exit $failed
