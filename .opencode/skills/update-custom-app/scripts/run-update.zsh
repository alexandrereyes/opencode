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
log_file="$log_dir/opencode-custom-update.log"
: >"$log_file"
exec >>"$log_file" 2>&1

print "Starting custom OpenCode update at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
cd "$HOME/Dev/opencode2"
git pull --ff-only origin custom
target_commit=$(git rev-parse HEAD)
bun run custom:update

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
if [[ -z "$session_id" ]]; then
  print "No trusted Session ID supplied; skipping completion notification"
  exit 0
fi

short_commit=$(git rev-parse --short HEAD)
message="A atualização do OpenCode foi concluída com sucesso no commit $short_commit. Apenas confirme o resultado ao usuário; não inicie outra atualização."
payload=$(jq -nc --arg text "$message" '{resume: true, text: $text}')
"$HOME/.local/share/opencode-custom-v2/bin/opencode2" api POST "/api/session/$session_id/prompt" --data "$payload"
print "Notified Session $session_id"
