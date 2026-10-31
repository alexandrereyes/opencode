#!/bin/bash
# Never echo authentication arguments, including when invoked with bash -x.
set +x
set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage: testflight.sh [--allow-dirty] [--dry-run | --unsigned-check] [--auth auto|api-key|xcode]

Default: archive and upload to private, internal-only TestFlight.
  --dry-run         Signed archive and local IPA export; no upload.
  --unsigned-check  Unsigned Release archive only; no credentials or upload.
  --allow-dirty     Build with uncommitted changes in packages/ios-custom.
  --auth MODE       auto (default): API key if configured, otherwise the Xcode account.
                    api-key: require an API key. xcode: use the existing Xcode account.

Credentials: ASC_KEY_ID, ASC_ISSUER_ID, optional ASC_KEY_PATH; alternatively
~/.appstoreconnect/opencode.env (or ASC_CONFIG_FILE outside the repository).
Default key: ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
On the OrbStack Linux machine these are Mac paths, read through `mac`; the key never leaves the Mac.
USAGE
}

fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }

mode=upload
auth=auto
allow_dirty=false
while [[ $# -gt 0 ]]; do
  argument=$1
  shift
  case "$argument" in
    --allow-dirty) allow_dirty=true ;;
    --dry-run|--unsigned-check)
      [[ "$mode" == upload ]] || fail 'Choose only one of --dry-run and --unsigned-check.'
      mode=${argument#--}
      ;;
    --help|-h) usage; exit 0 ;;
    --auth)
      [[ $# -gt 0 ]] || fail '--auth requires auto, api-key, or xcode.'
      auth=$1
      shift
      case "$auth" in auto|api-key|xcode) ;; *) fail '--auth requires auto, api-key, or xcode.' ;; esac
      ;;
    *) usage >&2; fail 'Unknown argument.' ;;
  esac
done

package=$(cd "$(dirname "$0")/.." && pwd -P)
repository=$(git -C "$package" rev-parse --show-toplevel)
commit=$(git -C "$repository" rev-parse --short HEAD)
temporary=/private/var/folders/pm/6v20wxls42nf7_5f9jfd_xh00000gn/T/opencode

# On the OrbStack Linux machine, xcodebuild and swift already run on the Mac, which sees /home/... through
# ~/OrbStack/dev and takes /mnt/mac/<path> as the literal Mac <path>. The App Store Connect config and key, and
# DerivedData, stay on the Mac: this shell reads Mac files only through `mac`, never through the shared mount.
if [[ "$(uname -s)" == Linux ]] && command -v mac >/dev/null; then
  host_home=/Users/$(id -un)
  host_repository=$host_home/OrbStack/dev$repository
  host_path() { printf '/mnt/mac%s' "$1"; }
  on_host() {
    local arguments=("${@:2}")
    mac "$1" "${arguments[@]/#\//\/mnt\/mac\/}"
  }
  # On the Linux disk, which the Mac sees; not XDG_CACHE_HOME, which an agent shell inherits from the server.
  archives=$HOME/.cache/opencode/ios-archives
else
  host_home=$HOME
  host_repository=$repository
  host_path() { printf '%s' "$1"; }
  on_host() { "$@"; }
  archives=$temporary/ios-archives
fi

require_clean() {
  if [[ "$allow_dirty" == false && -n "$(git -C "$repository" status --porcelain --untracked-files=all -- packages/ios-custom)" ]]; then
    fail 'Uncommitted changes in packages/ios-custom. Commit them first, or pass --allow-dirty.'
  fi
}

require_clean
printf 'Commit: %s\n' "$commit"
if [[ "$allow_dirty" == true ]]; then
  printf 'Dirty working tree permitted; the commit identifies the base, not uncommitted edits.\n'
fi

if [[ "$mode" != unsigned-check && "$auth" != xcode ]]; then
  config=${ASC_CONFIG_FILE:-$host_home/.appstoreconnect/opencode.env}
  if on_host test -f "$config"; then
    case "$(on_host realpath "$config")" in
      "$host_repository"/*) fail 'The private ASC config must be outside the repository.' ;;
    esac
    # Read literal KEY=value entries, never source/execute the private config.
    while IFS='=' read -r name value || [[ -n "$name" ]]; do
      value=${value%$'\r'}
      case "$name" in
        ''|\#*) continue ;;
        ASC_KEY_ID) ASC_KEY_ID=${ASC_KEY_ID:-$value} ;;
        ASC_ISSUER_ID) ASC_ISSUER_ID=${ASC_ISSUER_ID:-$value} ;;
        ASC_KEY_PATH) ASC_KEY_PATH=${ASC_KEY_PATH:-$value} ;;
        *) fail 'Invalid ASC config entry. Use unquoted ASC_KEY_ID, ASC_ISSUER_ID, and optional ASC_KEY_PATH entries.' ;;
      esac
    done < <(on_host cat "$config")
  fi
  if [[ "$auth" == auto && -z "${ASC_KEY_ID:-}" && -z "${ASC_ISSUER_ID:-}" && -z "${ASC_KEY_PATH:-}" ]]; then
    auth=xcode
  else
    [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || fail \
    'No App Store Connect API key configured. Set ASC_KEY_ID and ASC_ISSUER_ID, or create ~/.appstoreconnect/opencode.env (see README). Use --unsigned-check without credentials.'
    [[ "$ASC_KEY_ID" =~ ^[A-Za-z0-9]{10}$ ]] || fail 'ASC_KEY_ID must be a 10-character key identifier.'
    [[ "$ASC_ISSUER_ID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || fail 'ASC_ISSUER_ID must be an issuer UUID.'
    key=${ASC_KEY_PATH:-$host_home/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}
    on_host test -f "$key" -a -r "$key" || fail 'The App Store Connect private key is missing or unreadable. Set ASC_KEY_PATH or install AuthKey_<ID>.p8 in ~/.appstoreconnect/private_keys/.'
    case "$(on_host realpath "$key")" in
      "$host_repository"/*) fail 'The App Store Connect private key must be outside the repository.' ;;
    esac
    auth=api-key
  fi
fi

command -v bun >/dev/null || fail 'Bun is required to regenerate the themes.'
bun "$package/script/generate-themes.ts"
swift "$package/script/generate-icon.swift"
# Refuse newly changed generated assets too; commit regenerated themes/icons before uploading.
require_clean

build=$(date -u +%Y%m%d%H%M)
mkdir -p "$archives"
run=$(mktemp -d "$archives/OpenCode-${build}-${commit}-${mode}.XXXXXX")
archive="$run/OpenCode.xcarchive"
printf 'Build number (UTC yyyyMMddHHmm): %s\nMode: %s\nArchive: %s\n' "$build" "$mode" "$archive"

run_xcode() {
  local stage=$1
  shift
  printf '%s…\n' "$stage"
  # Xcode echoes command-line auth identifiers in its normal output. Keep all output in a
  # private local log, never replay it to the terminal, even on a failure.
  if xcodebuild -quiet -hideShellScriptEnvironment "$@" >"$run/$stage.log" 2>&1; then
    printf '%s succeeded. Log: %s\n' "$stage" "$run/$stage.log"
  else
    local status=$?
    if grep -Eq 'Failed to Use Accounts|App Store Connect access .* required' "$run/$stage.log"; then
      printf 'Xcode lacks App Store Connect access. Resolve this manually in Xcode Settings > Accounts, or configure the team API key. This script does not handle passwords or 2FA.\n' >&2
    fi
    fail "$stage failed (exit $status). Inspect the private local log: $run/$stage.log. Do not share it without redacting credential identifiers."
  fi
}

settings=(-project "$package/OpenCode.xcodeproj" -scheme OpenCode -configuration Release
  -destination 'generic/platform=iOS' -derivedDataPath "$(host_path "${OPENCODE_DERIVED_DATA:-$temporary/ios-sessoes-derived}")"
  -archivePath "$archive" "CURRENT_PROJECT_VERSION=$build" "OPENCODE_COMMIT=$commit")
if [[ "$mode" == unsigned-check ]]; then
  run_xcode Archive archive "${settings[@]}" CODE_SIGNING_ALLOWED=NO
  printf 'Unsigned archive verified; not installable or uploadable. No signing or upload was attempted.\n'
  exit 0
fi

authentication=(-allowProvisioningUpdates)
if [[ "$auth" == api-key ]]; then
  authentication+=(-authenticationKeyPath "$(host_path "$key")" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  printf 'Authentication: App Store Connect API key (identifiers hidden).\n'
else
  printf 'Authentication: existing Xcode account. If Apple requires renewed login, stop and sign in manually in Xcode.\n'
fi
run_xcode Archive archive "${settings[@]}" "${authentication[@]}" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=ERRYZ68LX5

destination=upload
[[ "$mode" != dry-run ]] || destination=export
cat >"$run/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>ERRYZ68LX5</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
PLIST
run_xcode Export -exportArchive -archivePath "$archive" -exportPath "$run/export" \
  -exportOptionsPlist "$run/ExportOptions.plist" "${authentication[@]}"

if [[ "$mode" == dry-run ]]; then
  printf 'Dry run complete. Signed IPA: %s/export (not uploaded).\n' "$run"
  exit 0
fi
printf 'Upload complete. Check TestFlight processing in App Store Connect, then the internal testing group.\n'
