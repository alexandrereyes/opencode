#!/bin/bash
# Builds the Mac app (Release, signed by team ERRYZ68LX5) and installs it as ~/Applications/MyAgents.app.
#
#   packages/ios-custom/script/install-mac.sh [--dry-run] [--app <MyAgents build .app>] [--applications <folder>]
#
# The installed bundle is named after the brand (MyAgents.app); its executable (OpenCodeMac), bundle identifier
# (br.com.alexandrem.opencode.mac), Keychain, defaults and macOS grants stay the same, so it is an update of the same
# app. The legacy ~/Applications/OpenCode Mac.app is replaced too, never kept beside it as a second copy. Each
# replaced bundle stays in the same folder as "<name>.app.bak-<UTC stamp>" (no .app extension, unregistered from
# LaunchServices). The script never quits, opens or kills the app: it refuses while an installed copy is running.
#
#   --dry-run          Build (or take --app), verify and print the plan; nothing in the folder changes.
#   --app PATH         Install this Release build instead of building one.
#   --applications DIR Install into DIR instead of ~/Applications (a rehearsal folder).
set -euo pipefail

fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }

dry_run=false
app=
applications=$HOME/Applications
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --app) [[ $# -gt 1 ]] || fail '--app requires a path.'; app=$2; shift 2 ;;
    --applications) [[ $# -gt 1 ]] || fail '--applications requires a folder.'; applications=$2; shift 2 ;;
    --help|-h) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

name=MyAgents
identifier=br.com.alexandrem.opencode.mac
executable=OpenCodeMac
team=ERRYZ68LX5
package=$(cd "$(dirname "$0")/.." && pwd -P)
temporary=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$applications" ]] || fail "No folder $applications."
applications=$(cd "$applications" && pwd -P)
target="$applications/$name.app"
legacy="$applications/OpenCode Mac.app"

if [[ -z "$app" ]]; then
  derived=${OPENCODE_MAC_DERIVED:-$temporary/mac-install-derived}
  mkdir -p "$temporary"
  log=$(mktemp "${TMPDIR:-$temporary}/myagents-mac-build.XXXXXX")
  printf 'Building OpenCodeMac (Release) in %s…\n' "$derived"
  xcodebuild -quiet -project "$package/OpenCode.xcodeproj" -scheme OpenCodeMac -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$team build >"$log" 2>&1 || fail "Build failed; log: $log"
  app="$derived/Build/Products/Release/$executable.app"
fi
[[ -d "$app" ]] || fail "No app at $app."

# The bundle must be this app, branded, and signed by the team, so macOS keeps its grants and Keychain items.
verify() {
  local bundle=$1 plist=$1/Contents/Info.plist key expected value
  for key in CFBundleIdentifier:$identifier CFBundleExecutable:$executable CFBundleName:$name CFBundleDisplayName:$name; do
    expected=${key#*:}
    value=$(plutil -extract "${key%%:*}" raw -o - "$plist" 2>/dev/null || true)
    [[ "$value" == "$expected" ]] || fail "$bundle: ${key%%:*} is '$value', expected '$expected'."
  done
  codesign --verify --deep --strict "$bundle" 2>/dev/null || fail "$bundle: invalid code signature."
  value=$(codesign -dv "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$value" == "$team" ]] || fail "$bundle: signed by team '$value', expected $team."
}
verify "$app"

# An installed copy that is running would keep the replaced bundle's code; quitting it is Alexandre's call.
running=$(pgrep -fl "^($applications/$name\.app|$applications/OpenCode Mac\.app)/Contents/MacOS/" || true)
if [[ -n "$running" ]]; then
  message="Quit the Mac app first (running: ${running//$'\n'/; })."
  [[ "$dry_run" == true ]] || fail "$message"
  printf 'Warning: %s\n' "$message"
fi

stamp=$(date -u +%Y%m%d-%H%M%S)
moves=()
# Only this app (same identifier) is ever replaced; any other bundle under either name stops the install.
for old in "$target" "$legacy"; do
  [[ -e "$old" ]] || continue
  value=$(plutil -extract CFBundleIdentifier raw -o - "$old/Contents/Info.plist" 2>/dev/null || true)
  [[ "$value" == "$identifier" ]] || fail "$old is not this app (CFBundleIdentifier '$value', expected $identifier); move it away by hand."
  moves+=("$old")
done
printf 'Install %s\n     as %s\n' "$app" "$target"
for old in "${moves[@]+"${moves[@]}"}"; do printf 'Keep   %s\n     as %s.bak-%s\n' "$old" "$old" "$stamp"; done
if [[ "$dry_run" == true ]]; then
  printf 'Dry run: nothing changed.\n'
  exit 0
fi

staging="$applications/.$name.installing-$stamp"
installed=false
# Until the new bundle is in place, any exit puts the previous bundles back and drops the staging copy.
restore() {
  [[ "$installed" == false ]] || return 0
  for old in "${moves[@]+"${moves[@]}"}"; do
    if [[ -e "$old.bak-$stamp" && ! -e "$old" ]]; then mv "$old.bak-$stamp" "$old"; fi
  done
  rm -rf "$staging"
}
trap restore EXIT
ditto "$app" "$staging"
verify "$staging"
for old in "${moves[@]+"${moves[@]}"}"; do mv "$old" "$old.bak-$stamp"; done
mv "$staging" "$target"
installed=true

# LaunchServices lists the new name now and forgets the kept bundles; a rehearsal folder stays out of it.
if [[ "$applications" == "$(cd "$HOME/Applications" 2>/dev/null && pwd -P)" ]]; then
  "$lsregister" -f "$target" || true
  for old in "${moves[@]+"${moves[@]}"}"; do "$lsregister" -u "$old.bak-$stamp" 2>/dev/null || true; done
fi
printf 'Installed %s (not opened).\n' "$target"
if [[ -e "$legacy.bak-$stamp" ]]; then
  printf 'If the Dock had OpenCode Mac, replace that item with %s.\n' "$target"
fi
