#!/usr/bin/env bash
# Builds OpenCodeWatch for the watchOS simulator and captures its DEBUG fixture screens (no network, no
# pairing). Usage: script/capture-watch.sh <simulator-udid> <output-dir> [fixture …]
# OPENCODE_WATCH_COMBO=working|working-unread|question-working-unread|nothing picks the state ring's combination
# (the files get it as a suffix).
set -euo pipefail

package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
simulator=${1:?simulator UDID}
output=${2:?output directory}
shift 2
fixtures=("$@")
[[ ${#fixtures[@]} -gt 0 ]] || fixtures=(dashboard question permission voice complications offline unpaired)
derived=${OPENCODE_WATCH_DERIVED:-/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode/watch-app-derived}

xcodebuild -quiet -project "$package/OpenCode.xcodeproj" -scheme OpenCodeWatch -configuration Debug \
  -destination "id=$simulator" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
xcrun simctl bootstatus "$simulator" -b >/dev/null
xcrun simctl install "$simulator" "$derived/Build/Products/Debug-watchsimulator/OpenCodeWatch.app"
mkdir -p "$output"
combo=${OPENCODE_WATCH_COMBO:-}
for fixture in "${fixtures[@]}"; do
  name="real-$fixture${combo:+-$combo}.png"
  xcrun simctl launch --terminate-running-process "$simulator" br.com.alexandrem.opencode.watchkitapp \
    -OpenCodeWatchFixture "$fixture" ${combo:+-OpenCodeWatchCombo "$combo"} >/dev/null
  sleep 4
  xcrun simctl io "$simulator" screenshot "$output/$name" >/dev/null 2>&1
  printf 'captured %s\n' "$output/$name"
done
