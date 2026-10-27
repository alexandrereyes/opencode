#!/usr/bin/env bash
# Installs the private, pinned Rust toolchain that builds the Apple Watch WebRTC engine
# (Vendor/OpenClawWatchRTC). Everything lives under ~/.local/share/opencode-ios/rust; shell
# profiles and any global Rust installation are left untouched. Safe to run again.
set -euo pipefail

package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="${OPENCODE_IOS_RUST_HOME:-$HOME/.local/share/opencode-ios/rust}"
toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$package/Vendor/OpenClawWatchRTC/rust-toolchain.toml")"
[[ -n "$toolchain" ]] || { echo "Pinned toolchain not found in rust-toolchain.toml" >&2; exit 1; }

export CARGO_HOME="$root/cargo" RUSTUP_HOME="$root/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
mkdir -p "$root"

if [[ ! -x "$CARGO_HOME/bin/rustup" ]]; then
  host="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
  base="https://static.rust-lang.org/rustup/dist/$host/rustup-init"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL "$base" -o "$work/rustup-init"
  curl --proto '=https' --tlsv1.2 -fsSL "$base.sha256" -o "$work/rustup-init.sha256"
  expected="$(cut -d ' ' -f 1 "$work/rustup-init.sha256")"
  actual="$(shasum -a 256 "$work/rustup-init" | cut -d ' ' -f 1)"
  [[ "$expected" == "$actual" ]] || { echo "rustup-init checksum mismatch" >&2; exit 1; }
  chmod +x "$work/rustup-init"
  "$work/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none
fi

rustup toolchain install "$toolchain" --profile minimal --component rust-src
rustup run "$toolchain" rustc --version
printf 'Watch Rust toolchain ready: %s (%s)\n' "$toolchain" "$root"
