#!/usr/bin/env bash
# Xcode build phase of OpenCodeWatch: builds libopenclaw_watch_rtc.a for the current watchOS
# platform and architectures with the private toolchain from setup-watch-rust.sh. Finished
# slices are cached by content fingerprint (sources, compiler, SDK, target) under
# ~/.local/share/opencode-ios/watch-rtc-cache, so a fresh DerivedData does not rebuild Rust.
set -euo pipefail

package="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root="${OPENCODE_IOS_RUST_HOME:-$HOME/.local/share/opencode-ios/rust}"
platform="${PLATFORM_NAME:?Run from Xcode or set PLATFORM_NAME}"
output="${OPENCODE_WATCH_RTC_DIR:?Set OPENCODE_WATCH_RTC_DIR}"
read -r -a architectures <<<"${ARCHS:?Set ARCHS}"

if [[ ! -x "$root/cargo/bin/rustup" ]]; then
  echo "error: Watch WebRTC needs the private Rust toolchain. Run packages/ios-custom/script/setup-watch-rust.sh" >&2
  exit 1
fi

# Xcode's environment (SDKROOT, deployment targets, compiler flags) would leak into Cargo's
# host build scripts. build.sh sets everything it needs for the Watch target itself.
exec env -i HOME="$HOME" PATH="$root/cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
  CARGO_HOME="$root/cargo" RUSTUP_HOME="$root/rustup" \
  OPENCLAW_WATCH_RTC_CACHE_DIR="$(dirname "$root")/watch-rtc-cache" \
  WATCHOS_DEPLOYMENT_TARGET="${WATCHOS_DEPLOYMENT_TARGET:-27.0}" \
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}" \
  "$package/Vendor/OpenClawWatchRTC/build.sh" "$platform" "$output" "${architectures[@]}"
