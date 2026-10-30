#!/bin/zsh
# Espaço em disco against a throwaway fixture: fake repositories, worktrees and a fake `$TMPDIR/opencode` in a new
# folder under `$TMPDIR/opencode`, with fake sessions (`sessions.json`) and two `sleep` processes standing in for
# work in progress. The Debug app (`-OpenCodeMacDiskFixture`) scans only that folder, classifies, previews and
# cleans it (`MacDiskChecks`), then this script deletes the folder and stops the processes. Nothing real is read for
# removal or removed: the scan ignores the fixture server's projects and the cleaner refuses paths outside the folder.
#
#   packages/ios-custom/script/test-mac-disk.sh
#   OPENCODE_MAC_DERIVED=<derived data>  OPENCODE_MAC_CAPTURES=<folder for the PNGs>  OPENCODE_MAC_SKIP_BUILD=1
set -euo pipefail
package=${0:A:h:h}
root=${package:h:h}
temp=${TMPDIR%/}/opencode
derived=${OPENCODE_MAC_DERIVED:-$temp/mac-disco-work/derived}
captures=${OPENCODE_MAC_CAPTURES:-$temp/mac-disco-prints}
domain=br.com.alexandrem.opencode.mac.debug.disk-tests
fixture=$(mktemp -d "$temp/mac-disk-fixture.XXXXXX")
fixture=${fixture:A}
copy="$fixture-app/OpenCodeMacDiskTests.app"
pids=()
cleanup() {
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  # Anything else still naming the fixture (the checks' own `tail`), never another process.
  pkill -f -- "$fixture" 2>/dev/null || true
  rm -rf "$fixture" "$fixture-app"
  defaults delete "$domain" 2>/dev/null || true
  rm -rf "$HOME/Library/Saved Application State/$domain.savedState" "$HOME/Library/Preferences/$domain.plist"
}
trap cleanup EXIT

if [[ "${OPENCODE_MAC_SKIP_BUILD:-0}" != 1 ]]; then
  xcodebuild -project "$package/OpenCode.xcodeproj" -scheme OpenCodeMac -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" build -quiet
fi

# Repositories: `alpha` with a bare remote, and its worktrees in `Worktrees/`, all a month old.
export GIT_AUTHOR_DATE=2026-10-01T09:00:00 GIT_COMMITTER_DATE=2026-10-01T09:00:00
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
repo=$fixture/repos/alpha
W=$fixture/Worktrees
T=$fixture/tmp
mkdir -p "$W" "$T" "$fixture/remotes"
git init -q --bare -b main "$fixture/remotes/alpha.git"
git init -q -b main "$repo"
echo "alpha" > "$repo/README.md"
git -C "$repo" add . && git -C "$repo" commit -q -m inicial
git -C "$repo" remote add origin "$fixture/remotes/alpha.git"
git -C "$repo" push -q -u origin main
git -C "$repo" remote set-head origin main
worktree() { git -C "$repo" worktree add -q -b "$2" "$W/$1" main; }
commit() { echo "$2" > "$W/$1/$2.txt"; git -C "$W/$1" add . && git -C "$W/$1" commit -q -m "$2"; }
worktree alpha-limpa feat/limpa; commit alpha-limpa limpa; git -C "$W/alpha-limpa" push -q -u origin feat/limpa
worktree alpha-integrada feat/integrada
worktree alpha-arquivada feat/arquivada; commit alpha-arquivada arquivada; git -C "$W/alpha-arquivada" push -q -u origin feat/arquivada
worktree alpha-recente feat/recente; commit alpha-recente recente; git -C "$W/alpha-recente" push -q -u origin feat/recente
worktree alpha-suja feat/suja; echo mudou >> "$W/alpha-suja/README.md"; echo a > "$W/alpha-suja/novo-1.txt"; echo b > "$W/alpha-suja/novo-2.txt"
worktree alpha-local feat/local; commit alpha-local local
worktree alpha-com-sessao feat/sessao
worktree alpha-parada feat/parada
worktree alpha-em-uso feat/em-uso
# Ignored files: `.env` is lost work; `node_modules` is recreated by an install.
worktree alpha-ignorado feat/ignorado
printf '.env\nnode_modules/\n' > "$W/alpha-ignorado/.gitignore"
git -C "$W/alpha-ignorado" add .gitignore && git -C "$W/alpha-ignorado" commit -q -m ignore
git -C "$W/alpha-ignorado" push -q -u origin feat/ignorado
echo SEGREDO=1 > "$W/alpha-ignorado/.env"
mkdir -p "$W/alpha-ignorado/node_modules/pkg" && echo x > "$W/alpha-ignorado/node_modules/pkg/index.js"
worktree alpha-so-node-modules feat/so-node-modules
echo node_modules/ > "$W/alpha-so-node-modules/.gitignore"
git -C "$W/alpha-so-node-modules" add .gitignore && git -C "$W/alpha-so-node-modules" commit -q -m ignore
git -C "$W/alpha-so-node-modules" push -q -u origin feat/so-node-modules
mkdir -p "$W/alpha-so-node-modules/node_modules/pkg" && echo x > "$W/alpha-so-node-modules/node_modules/pkg/index.js"
# An initialized submodule with a commit sent nowhere, under a worktree with one uncommitted file.
git init -q --bare -b main "$fixture/remotes/lib.git"
git init -q -b main "$fixture/repos/lib"
echo lib > "$fixture/repos/lib/README.md"
git -C "$fixture/repos/lib" add . && git -C "$fixture/repos/lib" commit -q -m lib
git -C "$fixture/repos/lib" push -q "$fixture/remotes/lib.git" main
worktree alpha-submodulo feat/submodulo
git -C "$W/alpha-submodulo" -c protocol.file.allow=always submodule add -q "$fixture/remotes/lib.git" lib
git -C "$W/alpha-submodulo" commit -q -m submodulo && git -C "$W/alpha-submodulo" push -q -u origin feat/submodulo
echo local > "$W/alpha-submodulo/lib/local.txt"
git -C "$W/alpha-submodulo/lib" add . && git -C "$W/alpha-submodulo/lib" commit -q -m trabalho-local-do-submodulo
echo solto > "$W/alpha-submodulo/solto.txt"
git clone -q "$fixture/remotes/alpha.git" "$W/clone-solto"
mkdir -p "$W/pasta-comum" && echo nota > "$W/pasta-comum/nota.txt"

# The agents' temporary folder.
derived_data() {
  mkdir -p "$1/Build/Products/Debug" "$1/Logs/Build"
  head -c 2000000 /dev/zero > "$1/Build/Products/Debug/blob"
  plutil -create xml1 "$1/info.plist"
  plutil -insert WorkspacePath -string "$2" "$1/info.plist"
}
bundle() { mkdir -p "$1/$2" && plutil -create xml1 "$1/$2/Info.plist" && head -c "$3" /dev/zero > "$1/blob"; }
derived_data "$T/dd-velho" "$fixture/nao-existe/App.xcodeproj"
derived_data "$T/dd-recente" "$repo/App.xcodeproj"
derived_data "$T/dd-em-uso" "$fixture/nao-existe/App.xcodeproj"
derived_data "$T/Build Pasta" "$fixture/nao-existe/App.xcodeproj"
mkdir -p "$T/Velho.app/Contents" "$T/Copia App.app/Contents" "$T/trabalho" "$T/uploads" "$T/job" "$fixture/fora/job"
bundle "$T/Velho.app" Contents 500000
bundle "$T/Copia App.app" Contents 100000
bundle "$T/teste.xcresult" . 300000
bundle "$T/editado.xcresult" . 300000
bundle "$T/job/test.xcresult" . 100000
bundle "$fixture/fora/job/test.xcresult" . 100000
echo log > "$T/velho.log"
head -c 200000 /dev/zero > "$T/captura.png"
head -c 900000 /dev/zero > "$T/backup.db"
derived_data "$T/trabalho/derived" "$fixture/nao-existe/Outro.xcodeproj"
echo nota > "$T/trabalho/notas.txt"
echo upload > "$T/uploads/arquivo.txt"
# Source with a Build folder and a DerivedData-like info.plist: a checkout, at the top and nested.
for source in "$T/fonte-com-build" "$T/trabalho/fonte"; do
  derived_data "$source" "$fixture/nao-existe/App.xcodeproj"
  git init -q -b main "$source"
  mkdir -p "$source/Sources" && echo 'let a = 1' > "$source/Sources/novo.swift"
done
# Build/ and info.plist, but no WorkspacePath nor logs: not a DerivedData.
mkdir -p "$T/falso-dd/Build" && plutil -create xml1 "$T/falso-dd/info.plist"
# One 1-MB file with two names.
mkdir -p "$T/duplo" && head -c 1048576 /dev/urandom > "$T/duplo/a" && ln "$T/duplo/a" "$T/duplo/b"
# `alpha-parada`'s session works in a subfolder that no longer exists, named through /var instead of /private/var.
cat > "$fixture/sessions.json" <<EOF
[{"id":"ses_sessao","directory":"$W/alpha-com-sessao","archived":false,"running":true},
 {"id":"ses_parada","directory":"${W#/private}/alpha-parada/packages/app","archived":false,"running":false},
 {"id":"ses_arquivada","directory":"$W/alpha-arquivada","archived":true,"running":false}]
EOF

# Everything a month old, except what must look recent.
find "$fixture" -exec touch -h -t 202610010900 {} +
find "$W/alpha-recente" "$T/dd-recente" -exec touch {} +
echo log > "$T/novo.log"
# Work in progress: processes inside a worktree and a build folder, and two naming paths with spaces.
(cd "$W/alpha-em-uso" && exec sleep 900) &
pids+=($!)
(cd "$T/dd-em-uso" && exec sleep 900) &
pids+=($!)
(exec -a "$T/Copia App.app/Contents/MacOS/Copia App" sleep 900) &
pids+=($!)
/usr/bin/perl -e 'sleep 900' -- -derivedDataPath "$T/Build Pasta" &
pids+=($!)

mkdir -p "$captures" "$fixture-app"
ditto "$derived/Build/Products/Debug/OpenCodeMac.app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $domain" "$copy/Contents/Info.plist"
codesign --force --deep --sign - "$copy" 2>/dev/null
log=$captures/checks.log
set +e
timeout 300 "$copy/Contents/MacOS/OpenCodeMac" -OpenCodeMacFixture contexto -OpenCodeMacFixtureRoot "$root" \
  -OpenCodeServerURL http://127.0.0.1:4221 -OpenCodeTheme openchamber-dark \
  -OpenCodeMacDiskFixture "$fixture" -OpenCodeMacDiskChecks "$captures" >"$log" 2>&1
code=$?
set -e
grep '^MacDiskChecks' "$log" || true
[[ $code -eq 0 ]] && grep -q '^MacDiskChecks ok$' "$log"
