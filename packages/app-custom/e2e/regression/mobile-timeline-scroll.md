# Custom timeline scroll port

Source: upstream `81523d4a8` (`fix(app): stabilize mobile timeline touch scrolling`).
Custom baseline: `0141846ef1c761f4e809b36a0f1bf42b71d29f09`.

## Baseline (before implementation)

On macOS with Bun 1.4.2:

- Root `bun run check`: passed (39 package typechecks).
- `packages/app-custom`: `bun typecheck` passed; `bun run test:unit` passed
  (1,050 passed, one skipped).
- `packages/ui-custom`: `bun typecheck` and `bun test src --only-failures`
  passed (109 tests).
- Production-build `regression/session-panel-scrollbar.spec.ts`: two passed.

## Scope

The virtualizer, reconnect-aware offset observer and ScrollView now match the
upstream implementations, except for custom package imports. The custom offset
reset override and its three implementation-specific test cases were removed
as part of the requested alignment. The remaining reconnect tests are retained.
The shared TanStack patch already contains the upstream changes.

The mobile regression fixture exercises the real custom UI with isolated API
data: drag reversal during streaming, one and two delayed images, nested scroll
ownership/chaining, keyboard endpoints, and touch targets replaced by streaming.
Chromium supplies native touch gestures with Pixel/iPhone user agents; this is
not a physical iOS/WebKit validation. Per-movement positions are checked exactly;
after release, native momentum is allowed to continue in the gesture direction.

## Reproduce

From `packages/app-custom`, with an unused test port:

```sh
PLAYWRIGHT_PORT=4189 bun run test:e2e:built \
  regression/mobile-timeline-scroll.spec.ts \
  regression/session-panel-scrollbar.spec.ts --workers=1
```

The fixture uses a temporary preview server and does not require the live backend.

## Validation after the port

- Root `bun run check` and both package typechecks pass.
- App unit tests: 1,047 passed, one skipped (the three removed override tests
  explain the difference from baseline). UI unit tests: 109 passed.
- The regression command above passes all 16 tests, without retries.
- Production source parity was checked against the upstream-owned files. No
  upstream-owned UI files or shared dependency patches were changed.

## Existing E2E typecheck limitation

`bun run typecheck:e2e` reports the same 15 errors on the clean baseline and the
feature: `markdownGate`, canvas/scroll overloads, obsolete `CatalogUpdated`,
missing `started` in event fixtures, and readonly-header deletion in unrelated
regressions. Root `bun run check` does not include this separate E2E tsconfig.
These errors were reproduced on the clean baseline and left outside this port.

## Exploratory upstream-suite limitations

Running the unmodified upstream mobile suite against the custom build also
exposed failures in the Pixel 7 RTL post-release displacement assertion and the
390px session-tab switch locator. Both were reproduced against a separately
built, clean `0141846ef` custom worktree. The broad exploratory run was interrupted
by its 120-second command limit after the tab-switch timeout; it is not a passing
full-suite result. The RTL behavior remains an unresolved baseline limitation;
the upstream tab locator does not match the custom mobile drawer. Neither was
used to expand this port into additional product changes.
