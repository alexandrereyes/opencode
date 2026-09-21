#!/bin/zsh
set -euo pipefail

if (( $# > 1 )); then
  print -u2 "usage: run-update.zsh [session-id]"
  exit 2
fi

session_id="${1:-}"
if [[ -n "$session_id" && ! "$session_id" =~ '^ses_[A-Za-z0-9]+$' ]]; then
  print -u2 "invalid session ID"
  exit 2
fi

umask 077
log_dir="${TMPDIR:-/tmp}/opencode"
mkdir -p "$log_dir"
run_dir=$(mktemp -d "$log_dir/opencode-custom-update.XXXXXXXX")
log_file="$run_dir/output.log"
result_file="$run_dir/result.txt"
phase=preflight
outcome=failed
notification=skipped
target_commit=unknown
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
finish() {
  local code=$?
  print "$(date -u +%Y-%m-%dT%H:%M:%SZ) outcome=$outcome phase=$phase exit=$code notification=$notification"
  print -r -- "outcome=$outcome
phase=$phase
exit=$code
notification=$notification
target=$target_commit
started=$started
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log=$log_file" >"$result_file.tmp"
  mv "$result_file.tmp" "$result_file"
}
trap finish EXIT
step() {
  phase="$1"
  print "$(date -u +%Y-%m-%dT%H:%M:%SZ) phase=$phase"
}
print "Update log: $log_file; result: $result_file"
exec >>"$log_file" 2>&1

print "Starting custom OpenCode update at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
cd "$HOME/Dev/opencode2"
branch=$(git branch --show-current)
if [[ "$branch" != custom ]]; then
  print -u2 "Update not started: expected branch custom; found ${branch:-detached HEAD}"
  exit 2
fi
changes=$(git status --porcelain --untracked-files=all)
if [[ -n "$changes" ]]; then
  print -u2 "Update not started: checkout contains changed or untracked paths:"
  print -ru2 -- "$changes"
  exit 2
fi
step pull
git pull --ff-only origin custom
target_commit=$(git rev-parse HEAD)
step update
bun run custom:update

step verification
release_status=$(bun packages/cli/script/custom-release.ts status)
prepared=$(jq -r '.prepared' <<<"$release_status")
current=$(jq -r '.current' <<<"$release_status")
running=$(jq -r '.running' <<<"$release_status")
health=$(jq -r '.health' <<<"$release_status")

[[ "$prepared" == "$target_commit" ]]
[[ "$current" == "$target_commit" ]]
[[ "$running" == "0.0.0-custom.$target_commit" ]]
[[ "$health" == "ready" ]]

print "Verified custom OpenCode release $target_commit"
outcome=succeeded
if [[ -z "$session_id" ]]; then
  print "No trusted Session ID supplied; skipping completion notification"
  exit 0
fi

step notification
notification=failed
short_commit="${target_commit[1,9]}"
message="A atualização do OpenCode foi concluída com sucesso no commit $short_commit. Apenas confirme o resultado ao usuário; não inicie outra atualização."
payload=$(jq -nc --arg text "$message" '{resume: true, text: $text}')
if ! "$HOME/.local/share/opencode-custom-v2/bin/opencode2" api POST "/api/session/$session_id/prompt" --data "$payload"; then
  print "Activation succeeded; completion notification failed"
  exit 0
fi
notification=sent
print "Notified Session $session_id"
