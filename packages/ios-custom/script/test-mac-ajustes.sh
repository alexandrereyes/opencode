#!/bin/zsh
# Offline checks of the Mac adjustment round (MacAjustesChecks) on the production views, with AppKit captures.
# Uses its own app copy and defaults domain, the closed in-memory fixture and no microphone; restores the
# clipboard after the image check and exits every app process. The copy runs in the background
# (`-OpenCodeMacBackground`): no Dock icon, menu bar or focus taken, windows off-screen.
#
#   [OPENCODE_MAC_THEME=openchamber-light] OPENCODE_MAC_DERIVED=<DerivedData> OPENCODE_MAC_CAPTURES=<folder> zsh packages/ios-custom/script/test-mac-ajustes.sh [mode …]
set -euo pipefail
package=${0:A:h:h}
derived=${OPENCODE_MAC_DERIVED:-${TMPDIR%/}/opencode/mac-ajustes-work/mac-derived}
prints=${OPENCODE_MAC_CAPTURES:-${TMPDIR%/}/opencode/mac-ajustes-prints/checks}
mkdir -p "$prints"
copy="$prints/OpenCodeMacAjustesChecks.app"
domain=br.com.alexandrem.opencode.mac.ajustes.tests
# `caminhos`: an audio file outside the project, under the resolved temporary folder (`/private/var/folders/…`).
samples=${${TMPDIR%/}:A}/opencode/mac-caminhos-$$
ditto "$derived/Build/Products/Debug/OpenCodeMac.app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $domain" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
# cfprefsd may still write the last app's preferences right after it exits.
trap 'sleep 1; defaults delete "$domain" 2>/dev/null || true; rm -f "$HOME/Library/Preferences/$domain.plist"; rm -rf "$copy" "$samples" "$HOME/Library/Saved Application State/$domain.savedState"' EXIT
failed=0
# Without arguments, every mode (zsh does not split `${@:-…}` into words).
modes=(composer question quote image viewer archived numbers width dictation jump master divider markdown arquivos ampliar progresso contexto caminhos)
(( $# )) && modes=("$@")
for mode in $modes; do
  # Each mode starts from a fresh window: no restored window, reading place or Contexto width.
  defaults delete "$domain" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/$domain.savedState"
  extra=()
  case $mode in
    quote) extra=(-OpenCodeMacDetailCase quotes) ;;
    # The answers record with the fake microphone and the fixtures' reviewer.
    question) extra=(-OpenCodeMacFakeDictation) ;;
    archived) extra=(-OpenCodeMacSearchFixture) ;;
    width) extra=(-OpenCodeMacCaptureSize 2400x1300) ;;
    jump) extra=(-OpenCodeMacCaptureSize 1500x700) ;;
    divider) extra=(-OpenCodeMacCaptureSize 1800x1000) ;;
    arquivos) extra=(-OpenCodeMacCaptureSize 2400x1300) ;;
    ampliar) extra=(-OpenCodeMacCaptureSize 1800x1000) ;;
    # Wide and narrow Contexto, a subagent open over the root, its own subagent and the way back, in one launch.
    contexto) extra=(-OpenCodeMacCaptureSize 2400x1300) ;;
    # The sheets' composers (Nova sessão, Pergunta paralela, a comment) record with the fake microphone too; the
    # fixtures' reviewer answers in 2.5 s, so "Ajustando texto…" can be seen and cancelled.
    dictation) extra=(-OpenCodeMacFakeDictation -OpenCodeDictationReview 2500) ;;
    caminhos)
      mkdir -p "$samples"
      afconvert -f m4af -d aac /System/Library/Sounds/Ping.aiff "$samples/amostra.m4a"
      extra=(-OpenCodeMacPathSample "$samples/amostra.m4a") ;;
  esac
  set +e
  timeout 150 "$copy/Contents/MacOS/OpenCodeMac" -OpenCodeMacFixture contexto \
    -OpenCodeMacFixtureRoot "${package:h:h}" -OpenCodeTheme "${OPENCODE_MAC_THEME:-openchamber-dark}" "${extra[@]}" \
    -OpenCodeMacBackground -OpenCodeMacAjustes "$mode" -OpenCodeMacCapture "$prints" -OpenCodeMacCaptureName "$mode" \
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
