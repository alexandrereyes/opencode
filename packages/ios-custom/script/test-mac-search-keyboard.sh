#!/bin/zsh
# The ⌘K window search with real keyboard and mouse events: builds OpenCodeMac (Debug), runs a copy under its own
# bundle identifier against the closed in-memory fixture and drives it with `mac-search-keyboard.swift`, which
# posts CGEvents to the HID stream (click, ⌘K, typing, ↓/↑, ⌃N/⌃P, Return, Esc, outside clicks, ⌥⌘N, ⌘W) and checks
# focus and the results panel through Accessibility and the app's `-OpenCodeMacSearchTrace` lines.
#
#   packages/ios-custom/script/test-mac-search-keyboard.sh [captures folder]
#
# It needs an unlocked screen and Accessibility for the terminal. The events go to the front app, so it first
# waits until the keyboard and mouse have been idle for OPENCODE_MAC_IDLE seconds (default 5) and gives the front
# back to the previous app at the end. Nothing reaches a server.
set -euo pipefail
package=${0:A:h:h}
root=${package:h:h}
derived=${OPENCODE_MAC_DERIVED:-${TMPDIR%/}/opencode/mac-app-work/mac-derived}
captures=${1:-${TMPDIR%/}/opencode/mac-busca-fix-prints}
logs=$(mktemp -d "${TMPDIR%/}/opencode/mac-search-keyboard.XXXXXX")
mkdir -p "$captures"
xcodebuild -project "$package/OpenCode.xcodeproj" -scheme OpenCodeMac -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" build -quiet
swiftc -O "$package/script/mac-search-keyboard.swift" -o "$logs/driver"
domain=br.com.alexandrem.opencode.mac.debug.searchkeys
copy="$logs/OpenCodeMacSearchKeys.app"
ditto "$derived/Build/Products/Debug/OpenCodeMac.app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $domain" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
pid=""
cleanup() {
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  defaults delete "$domain" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/$domain.savedState" "$HOME/Library/Preferences/$domain.plist" "$copy"
}
trap cleanup EXIT
need=${OPENCODE_MAC_IDLE:-5}
for _ in $(seq 1 600); do
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { value = $NF } END { print int(value / 1000000000) }')
  (( idle >= need )) && break
  sleep 1
done
open -n -a "$copy" --stdout "$logs/app.log" --stderr "$logs/app.log" --args -OpenCodeMacFixture contexto \
  -OpenCodeMacFixtureRoot "$root" -OpenCodeServerURL http://127.0.0.1:4207 -OpenCodeMacSearchFixture \
  -OpenCodeTheme openchamber-dark -OpenCodeMacSearchTrace -ApplePersistenceIgnoreState YES
for _ in $(seq 1 50); do
  pid=$(pgrep -f "$copy/Contents/MacOS/OpenCodeMac" || true)
  [[ -n "$pid" ]] && break
  sleep 0.2
done
[[ -n "$pid" ]] || { echo "the app did not start; log: $logs/app.log"; exit 1 }
sleep 3
"$logs/driver" "$pid" "$logs/app.log" "$captures"
