# OpenClawWatchRTC (vendored)

Apple Watch WebRTC engine from [OpenClaw](https://github.com/openclaw/openclaw), commit `e5cc2d9`
(`apps/shared/OpenClawWatchRTC` and `apps/ios/WatchApp/Sources/WatchRealtime*.swift`, `WatchOpusCodec.swift`,
`apps/ios/Sources/Permissions/PermissionRequestBridge.swift`). MIT; notices in `Licenses/` (OpenClaw, and `str0m`
with its dependencies and the Rust standard library). The original module README is `README-OpenClaw.md`.

Local changes, all from the 27 October watch spike and marked `OpenCode:` in the code:

- `src/lib.rs`: output kind 6 reports ICE state transitions (diagnostics); `src/tests.rs` accepts it and adds
  `sentinel_ipv4_candidate_behind_translation`.
- `Swift/WatchRealtimeTransport.swift`: system routing — one UDP flow per remote with no fixed local interface or
  port; the ICE engine sees the original IPv4 pair (a sentinel or mapped IPv4 local candidate) while the socket
  carries the bytes, which is what works through NAT64/CLAT on the watch's cellular path. Per-flow counters and
  diagnostic lines.
- `Swift/WatchRealtimeAudioIO.swift` / `WatchRealtimeMediaSession.swift`: activation plan (`external` after
  CallKit's `didActivate`; `duplex` only in the simulator), output level, packet counters, a short silence so the
  output renders before UDP opens.

Build: `../../script/setup-watch-rust.sh` once, then Xcode's `Build Watch WebRTC` phase
(`../../script/build-watch-rtc.sh`). Engine tests, with the private toolchain:

```sh
CARGO_HOME=~/.local/share/opencode-ios/rust/cargo RUSTUP_HOME=~/.local/share/opencode-ios/rust/rustup \
  ~/.local/share/opencode-ios/rust/cargo/bin/cargo +nightly-2026-10-02 test --locked \
  --manifest-path packages/ios-custom/Vendor/OpenClawWatchRTC/Cargo.toml --lib -- --test-threads=1
```
