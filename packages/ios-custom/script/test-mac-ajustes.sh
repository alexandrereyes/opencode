#!/bin/zsh
# Offline checks of the Mac adjustment round (MacAjustesChecks) on the production views, with AppKit captures.
# Uses its own app copy and defaults domain, the closed in-memory fixture and no microphone; restores the
# clipboard after the image check and exits every app process.
#
#   OPENCODE_MAC_DERIVED=<DerivedData> OPENCODE_MAC_CAPTURES=<folder> zsh packages/ios-custom/script/test-mac-ajustes.sh
set -euo pipefail
package=${0:A:h:h}
derived=${OPENCODE_MAC_DERIVED:-${TMPDIR%/}/opencode/mac-ajustes-work/mac-derived}
prints=${OPENCODE_MAC_CAPTURES:-${TMPDIR%/}/opencode/mac-ajustes-prints/checks}
mkdir -p "$prints"
copy="$prints/OpenCodeMacAjustesChecks.app"
domain=br.com.alexandrem.opencode.mac.ajustes.tests
ditto "$derived/Build/Products/Debug/OpenCodeMac.app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $domain" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
# cfprefsd may still write the last app's preferences right after it exits.
trap 'sleep 1; defaults delete "$domain" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$domain.plist"; rm -rf "$copy" "$HOME/Library/Saved Application State/$domain.savedState"' EXIT
failed=0
for mode in composer question quote image archived numbers width dictation jump master; do
  # Each mode starts from a fresh window: no restored window, reading place or Contexto width.
  defaults delete "$domain" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/$domain.savedState"
  extra=()
  case $mode in
    quote) extra=(-OpenCodeMacDetailCase quotes) ;;
    archived) extra=(-OpenCodeMacSearchFixture) ;;
    width) extra=(-OpenCodeMacCaptureSize 2400x1300) ;;
    jump) extra=(-OpenCodeMacCaptureSize 1500x700) ;;
  esac
  set +e
  timeout 150 "$copy/Contents/MacOS/OpenCodeMac" -OpenCodeMacFixture contexto \
    -OpenCodeMacFixtureRoot "${package:h:h}" -OpenCodeTheme openchamber-dark "${extra[@]}" \
    -OpenCodeMacAjustes "$mode" -OpenCodeMacCapture "$prints" -OpenCodeMacCaptureName "$mode" \
    -OpenCodeMacCaptureQuit >"$prints/$mode.log" 2>&1
  set -e
  if grep -q "MacAjustes $mode ok" "$prints/$mode.log"; then
    echo "$mode: ok"
  else
    failed=1
    echo "$mode: failed; log: $prints/$mode.log"
    grep "MacAjustes" "$prints/$mode.log" | tail -2
  fi
done
exit $failed
