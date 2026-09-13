#!/bin/sh
set -eu

mode="${1:?usage: run-conformance.sh <oracle|upstream> /path/to/worktree}"
root="${2:?usage: run-conformance.sh <oracle|upstream> /path/to/worktree}"
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
tests="$root/packages/server/test"
runtime="$tests/.poc-ui-undo-runtime"

case "$mode" in
  upstream)
    names="overlap-descendants-first overlap-root-first background"
    ;;
  oracle)
    names="overlap provenance"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

if [ -e "$runtime" ]; then
  echo "refusing to overwrite existing $runtime" >&2
  exit 2
fi
for name in $names; do
  target="$tests/poc-ui-undo-runner-$name.test.ts"
  if [ -e "$target" ]; then
    echo "refusing to overwrite existing $target" >&2
    exit 2
  fi
done

cleanup() {
  for name in $names; do
    rm -f "$tests/poc-ui-undo-runner-$name.test.ts"
  done
  rm -rf "$runtime"
}
trap cleanup EXIT INT TERM

mkdir -p "$runtime/plugin-package"
cp "$here/index.ts" "$runtime/index.ts"
cp "$here/plugin.ts" "$runtime/plugin.ts"
cp "$here/rpc.ts" "$runtime/rpc.ts"
cp "$here/plugin-package/index.ts" "$runtime/plugin-package/index.ts"
cp "$here/plugin-package/package.json" "$runtime/plugin-package/package.json"

files=""
for name in $names; do
  cp "$here/integration/$mode-$name.test.ts" "$tests/poc-ui-undo-runner-$name.test.ts"
  files="$files test/poc-ui-undo-runner-$name.test.ts"
done

cd "$root/packages/server"
bun typecheck
# Intentional word splitting: Bun receives each generated test path separately.
bun test $files
