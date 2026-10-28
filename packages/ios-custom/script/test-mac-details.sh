#!/bin/zsh
# Offline production-view checks and AppKit captures; uses its own defaults domain and exits every app process.
set -euo pipefail
package=${0:A:h:h}
derived=${OPENCODE_MAC_DERIVED:-${TMPDIR%/}/opencode/mac-detalhes-derived}
prints=${OPENCODE_MAC_CAPTURES:-${TMPDIR%/}/opencode/mac-detalhes-prints}
mkdir -p "$prints"
copy="$prints/OpenCodeMacDetails.app"
domain=br.com.alexandrem.opencode.mac.detalhes.tests
ditto "$derived/Build/Products/Debug/OpenCodeMac.app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $domain" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
trap 'defaults delete "$domain" 2>/dev/null || true; rm -rf "$copy"' EXIT
for mode in quotes details bubble shell; do
  timeout 90 "$copy/Contents/MacOS/OpenCodeMac" -OpenCodeMacFixture contexto \
    -OpenCodeMacFixtureRoot "${package:h:h}" -OpenCodeTheme openchamber-dark \
    -OpenCodeMacDetailCase "$mode" -OpenCodeMacCapture "$prints" -OpenCodeMacCaptureName "$mode" \
    -OpenCodeMacCaptureQuit >"$prints/$mode.log" 2>&1
  grep "MacDetails $mode ok" "$prints/$mode.log"
done
