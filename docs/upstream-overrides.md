# Upstream overrides

This register tracks upstream work that `custom` carries ahead of, or differently
from, the upstream revision it has integrated. Each entry says what was taken,
from which upstream revision, how it was adapted locally, and when it can be
reconciled or removed. It keeps that knowledge in Git instead of in a past
conversation.

The register starts with the change that introduced it; it is not the result of a
retroactive audit. An empty list does not mean `custom` carries no upstream
overrides. Record new cases from now on, and add older ones when they are
identified.

## When to record an entry

Add or update an entry in the same change that:

- applies an upstream PR or commit to `custom` before the integrated upstream
  baseline contains it (cherry-pick, patch, or manual copy);
- carries an upstream PR or commit in adapted form rather than as-is, including a
  deliberate port of upstream UI work into `packages/app-custom`,
  `packages/ui-custom`, or `packages/session-ui-custom`.

Do not record custom features without an upstream counterpart, upstream PRs that
are merely being watched but were not incorporated, or custom code adjusted to
upstream API changes during a routine integration (those belong in the
integration's own notes in `upstream-integrations.md`).

## When to read it

- Before integrating an upstream revision into `custom`: reconcile every open
  (`active` or `reconcile`) entry against the revision being integrated and update
  the register in the same integration.
- Before incorporating or porting an upstream PR: check whether it, or an
  overlapping change, is already recorded.
- When a recorded upstream PR is merged, closed, or materially revised.

## Reconciliation rules

- **A clean merge or ancestry does not prove equivalence.** A conflict-free merge
  only means Git combined the texts; it can silently keep both the local copy and
  the upstream version. Ancestry only shows that specific commits are reachable.
  Cherry-picks, patches, and squash merges produce different SHAs, and a PR may
  change after the reviewed revision. Compare the final upstream change with the
  local code by behavior, public API, schema and migrations, and tests.
- **Decide the outcome explicitly.** When upstream now provides the same change in
  the same path, service, or module the local code overrides, remove that redundant
  override and keep the upstream implementation. When the local behavior must
  remain, keep only the minimal documented adaptation. When upstream closes the PR
  or diverges, decide whether to keep, rewrite, or drop the local code.
- **Upstream UI trees are not an early landing zone.** `packages/app`, `packages/ui`,
  and `packages/session-ui` stay identical to the integrated upstream baseline, so an
  upstream UI change is ported into the custom packages instead. Integrating the
  upstream revision that contains it updates only the upstream trees. The custom web
  product is built from the custom packages, so an equivalent in `packages/app` does
  not make the port redundant: keep it, and update it toward the final upstream
  version where that helps.
- **Resolve only finished decisions.** Mark an entry `resolved` when its outcome is
  decided and applied and no upstream follow-up remains. An adaptation that still
  depends on upstream stays `active` or `reconcile`, with its fields updated. Resolved
  entries move to [Resolved entries](#resolved-entries) with their result; the
  register keeps that history.

## Installation notes

`bun run custom:update` installs code that is already on `custom`; it does not
incorporate or reconcile upstream PRs. An entry's `active` or `reconcile` status
alone is therefore not a reason to delay an update.

Use the **Installation** field only when installing a release that contains the
entry requires an explicit operator action outside `custom:update` (for example,
a one-time configuration change). State the action and the release it applies to.
Otherwise write `none`.

## Entry template

Add entries under [Active entries](#active-entries), newest first:

```md
### <Short title> — <upstream PR or commit link>

- **Kind:** anticipated | adaptation
- **Reviewed upstream revision:** `<full SHA>` (PR head or commit that was reviewed/applied), <YYYY-MM-DD>
- **Local change:** <commit subject(s) and SHA(s) already on custom, or the subject of the commit adding this entry>; <paths>. <How it differs from the reviewed revision, or "unchanged">.
- **Tests:** <commands/suites that validated the local change and their result>.
- **Status:** active | reconcile
- **Reconcile or remove when:** <condition, e.g. upstream merges the PR and it reaches the integrated upstream branch>.
- **Installation:** none | <explicit operator action outside custom:update and the release it applies to>
- **Result after upstream:** pending
```

A commit cannot contain its own SHA. When an entry is added or resolved in the same
commit as the change it describes, identify that commit by subject and paths.
Commits that added the entry or moved it to Resolved entries are listed by
`git log -G '<PR link>' -- docs/upstream-overrides.md`.

Status values:

- `active`: incorporated in `custom`; the upstream outcome, or an upstream
  follow-up the local code depends on, is still open.
- `reconcile`: upstream merged, closed, or materially changed the work; the next
  upstream integration must compare and decide the outcome.
- `resolved`: outcome decided and applied, with no upstream follow-up remaining;
  the entry lives under Resolved entries.

When resolving, set **Status** to `resolved` and replace **Result after upstream**
with the upstream merge commit or closure, the integrated upstream revision, the
`custom` commit that reconciled it (SHA, or subject and paths when it is the same
commit), the outcome (redundant override removed, adaptation or custom port kept,
rewritten, or dropped), and the evidence of equivalence or intended difference.

## Active entries

### One-time pairing links across the GUI — https://github.com/anomalyco/opencode/pull/53257

- **Kind:** adaptation
- **Reviewed upstream revision:** `eebe9d370fc75f211089560a935f8fcafd710627` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port one-time pairing improvements`; `packages/app-custom/src/servers/connect/{pairing.ts,pairing.test.ts,redeem.ts,scanner.tsx,screen.tsx,dialog.tsx}`, `src/runtime/server/runtime.tsx`, `src/runtime/i18n/en.ts` and `e2e/regression/server-pairing.spec.ts`. Functional part only. As upstream, `redeemPairingLink()` tries every address of a link at once (5 s timeout each) and returns `paired`, `expired` (only when a server answered 401) or `unreachable`; when another address spent the code first it keeps the first listed address if that one accepts the token. A new `useRedeemPairing()` (`redeem.ts`) gives the connect screen, the Add/Edit server dialog and the scanner one error text: expired, mixed content when every address is plain HTTP from an HTTPS page, or the new "Could not reach {{url}}…" message (until now a network failure was reported as expired). Signing in again keeps the server's address when the token works there (connect screen opened for an unauthorized server, Edit dialog) and the connect screen keeps the server's display name; the Edit dialog no longer closes without checking when the unchanged credentials are rejected; the dialog skips its health preview while the address field holds a pairing link. The scanner keeps redeeming while the camera runs (one at a time, a failed code skipped for 3 s, decoder failures reported with the new `server.connect.scan.failed` text) instead of stopping after the first failure. The global runtime records the credentials each HTTP server controller started with and replaces the controller when the listed connection's URL or password changes, so a server signed in again under the same address stops using the old password or token. Custom differences kept: the raw JSON, legacy query/fragment and base64url `/connect` decoders (tried first by the scanner), the `{ urls, password }` result shape, the single address/password form where a link is pasted (redeemed into base URL plus token, so a retry never reuses the spent code) and the unauthorized-server handling. Not ported: upstream's link/password method switch, pairing-link field and copy, signed-out notice and Authenticate actions in Settings/Home, legacy-link rejection message, camera hint helper, the scanner returning a link instead of credentials, and the GUI-extension pairing page (the custom product generates no pairing links).
- **Tests:** `pairing.test.ts` adds decoder cases (single-address link with the `urls` shape, OpenTunnel `https://<route>.<hostname>/auth/connect/<code>` link, `{ code, urls }` QR payloads including a tunnel address, malformed payloads, custom credential JSON rejected by the link decoder and the link/QR rejected by the custom decoders) and five redemption cases against real local `node:http` servers (token, spent code → expired, closed port → unreachable, any reachable address, first address kept); 8 of 13 fail with the `HEAD` `pairing.ts` (`8f209f2c3`). `e2e/regression/server-pairing.spec.ts` (mocked routes): two-address QR payload added under the first address, unreachable link message in the Add server dialog, and an Edit-dialog password change whose next `/api/event` requests carry the new password and none the old; all three fail on `8f209f2c3` (dialog stays open, "expired" shown, no request with the new password). App-custom unit suite 1332 pass/1 skip, typecheck and e2e typecheck pass; `server-dialog-focus.spec.ts` passes; `remote-tab-busy.spec.ts` and `cross-server-tab-close.spec.ts` fail identically on `8f209f2c3`. Real check against an isolated password-protected source server (port 4177, temporary runtime/XDG dirs, no inherited `OPENCODE_*`, built app served by it) at 1440×900 and 390×844 (touch): unauthorized lone server opens the connect screen prefilled; an unreachable link shows the unreachable message; a `{ code, urls: [LAN address (refused), loopback] }` payload from a real `POST /api/pair` code pairs and stores the loopback address with a token; the spent link shows the expired message and an unreachable link the unreachable message in the Add server dialog; a fresh link for `localhost:4177` adds that server; editing it to the server password opens an event stream with the password and closes the token's stream. With only `runtime.tsx` reverted to `8f209f2c3`, no event stream with the new password appeared within 30 s.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes pairing or the server runtime; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Every pairing address in QR codes — https://github.com/anomalyco/opencode/pull/53588

- **Kind:** adaptation
- **Reviewed upstream revision:** `4a0f273fa741047ce694b028ed1418fee406998d` (commit reviewed/applied), 2026-10-11; remote links checked against `0d07f915d2d3eb512ac8cde7c8feaade07a2eb08` (#53837), `53533fd0bfe1bf6911e60b1c706d0c2d1555c0f3` (#53844) and `19fb8918c649a09fcfaa79c5cad23c036134cd47` (#53962)
- **Local change:** `fix(app): port one-time pairing improvements`; `packages/app-custom/src/servers/connect/{pairing.ts,pairing.test.ts}`. Consumer side only, as upstream: `pairingLink()` returns `{ urls, code }` and also reads the CLI's QR text `{"code","urls"}` (every non-loopback address; rejected when the code is not base64url or any address is not plain HTTP(S)), and redemption tries every address (see the #53257 entry). Accepted exactly as the CLI in this tree emits it: printed links `new URL("/auth/connect/<code>", url)` for each server URL (including `--url` and `--remote` OpenTunnel `https://<random route>.<tunnel hostname>`), and the QR payload `JSON.stringify({ code, urls })`. The custom scanner tries its credential decoders first; they reject this payload (no `username`/`password`), so it reaches the link path; pasting the payload into the connect screen or the Add server dialog also pairs. Not changed: the CLI and server (`connectionURLs` loopback entry), outside the custom packages.
- **Tests:** see the #53257 entry (decoder and redemption unit tests, multi-address Playwright regression, real `POST /api/pair` code redeemed through a two-address payload). `opencode pair` itself was not run: it requires the background service, which would touch the user's service configuration; the format was taken from `packages/cli/src/commands/handlers/pair.ts` and `services/remote-tunnel.ts`. QR camera scanning was not exercised.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the pairing payload or `pairingLink()`
- **Installation:** none
- **Result after upstream:** pending

### Declarative external provider connections — https://github.com/anomalyco/opencode/pull/53672

- **Kind:** adaptation
- **Reviewed upstream revision:** `70c6c8cbc5d235d0be8b7066153eb76c61c670d7` (commit reviewed/applied), 2026-10-11
- **Local change:** `feat(app): port external provider connections and ChatGPT guidance`; `packages/app-custom/src/providers/connect/{controller.ts,dialog.tsx,remote.tsx}`, `src/runtime/i18n/en.ts`, `test-browser/{provider-connection.test.ts,fixtures/provider-external-connection.ts}` and `e2e/regression/provider-external-connect.spec.ts`. As upstream, the controller lists `external` methods next to key and OAuth ones, asks for their visible form first, then calls `integration.connect.external` with `integrationID`, `methodID`, the answer (hidden defaults merged, omitted when empty) and the Location, under the same generation/dispose guards; a rejection shows `formatServerError` text and Retry returns to the form; success refreshes the integration, provider and model catalogs. `busy()` also covers the refresh of an external method, so the dialog shows the existing "Authorization in progress" row from saving until the custom completion (dialog close and toast) and never an OAuth authorization view. Non-Console OAuth and code errors also use `formatServerError`, and array `when` conditions compare items as upstream. Custom difference: external methods use the server's credential sources (Azure CLI sign-in, AWS profiles, gcloud/ADC on the server machine), so on a non-loopback server the dialog shows the existing server-scope notice (`RemoteAuthNotice`, until now Console-only) with an external-specific description saying the credentials are on that server, not on this device. Kept: native authorization-link fallback, cancellation after transport failure, Go keys, account badges and integration-aware disconnect, model-visibility preferences (no `models.show`), `InlineServerSelect`/server-scoped settings and the hardcoded unsupported-fields message. Not ported: the CLI and TUI parts of the PR (outside the web product) and upstream's state typing refactor.
- **Tests:** seven controller cases in `provider-external-connection.ts` (method list, form first, saved answer with hidden defaults and busy refresh, immediate save without a form, server error without completion, late result after close, late result after going back); six fail with the base `controller.ts` (only the close case passes there). Playwright against the mock server at 1440×900 and 390×844: Bedrock-like profile choice with a typed answer, held pending row without an OAuth link, server error and retry, success toast and both request bodies, no notice on a loopback server; all fail on the base sources. Real check on an isolated source server (port 4177, temporary runtime and XDG dirs, no inherited `OPENCODE_*`, runtime deleted afterwards) through a `remote.test` alias: Vertex (no gcloud installed: typed project, default and typed location) and Azure (real `az` sign-in, resource listing found none, server pattern rejection shown, then a stored fixture resource whose deployment lookup failed as expected) at 1440×900, Bedrock (no AWS profiles: typed profile) at 390×844; the server listed one external credential per provider after each run and the remote notice showed the server name. No prompts or model calls.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Inline custom answers in connect forms — https://github.com/anomalyco/opencode/pull/53625

- **Kind:** adaptation
- **Reviewed upstream revision:** `1d610f90a04817c3e8b467f879e4d9a24daa0aff` (commit reviewed/applied), 2026-10-11
- **Local change:** `feat(app): port external provider connections and ChatGPT guidance`; `packages/app-custom/src/providers/connect/dialog.tsx` and `e2e/regression/provider-external-connect.spec.ts`. As upstream, a string field with `custom: true` renders the existing `ui-custom` `RadioGroup` with its options plus "Type your own answer" (no shared UI change was needed; upstream changed none either); the typed text is kept while switching to an option and back, visible defaults preselect their option without entering the answer until the field is submitted, Continue validates required answers, and the next field is chosen by its conditions. Fields with options and no `custom` keep the closed list that advances on selection. Custom differences: the radio block is keyed per field, because a reused group kept the previous field's native selection (the next field's default looked selected but its input was unchecked for assistive technology); and the form takes upstream's `px-3` so the closed list drops its own `px-3`, keeping its position. The TUI part of the PR is not ported.
- **Tests:** Playwright against the mock server at 1440×900 and 390×844: typed-answer retention while switching choices, required validation, and a Vertex-like two-field form (typed project, then the default `global` checked and submitted); they fail on the base sources, and the default case also fails with the unkeyed upstream structure. Real Vertex and Bedrock forms checked on the isolated source server (see the external connection entry).
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### ChatGPT usage limit and token-sharing guidance — https://github.com/anomalyco/opencode/pull/52153, https://github.com/anomalyco/opencode/pull/52160, https://github.com/anomalyco/opencode/pull/52163

- **Kind:** adaptation
- **Reviewed upstream revision:** `16ef62c8513e61329ed6d2410850d14afba66cf4`, `621a5b07068b97da51541a2983bdc3d3782e1457` and `4deda180370c3038877b0c35befb2e4a08cd3e31` (commits reviewed/applied), 2026-10-11
- **Local change:** `feat(app): port external provider connections and ChatGPT guidance`; `packages/app-custom/src/providers/connect/{chatgpt.ts,chatgpt-usage-limit.tsx,chatgpt-welcome.tsx,dialog.tsx}`, `src/session/{usage-exceeded-dialogs.tsx,usage-exceeded-dialogs.test.ts}`, `src/providers/models/select-dialog.tsx`, `src/runtime/i18n/en.ts` and `e2e/regression/provider-external-connect.spec.ts`. Final #52163 copy and `https://chatgpt.com/settings/usage` link. A `session.step.failed` for the open session that is a ChatGPT usage limit shows the usage-limit dialog (Manage usage opens the link) at most once per 24 hours (`chatgpt-usage-limit` global preference) and never over another dialog. After a successful `chatgpt-token-sharing` OpenAI connection, the custom completion still closes the dialog and shows the toast, then the one-time welcome dialog appears (`chatgpt-plan-welcome.v1`). The model picker shared by the composer popover and the model dialog shows "Using ChatGPT plan" with a Manage usage link when the current model is OpenAI and the active OpenAI connection is an OAuth credential. Custom differences: detection matches the message the current server sends since #52168 (`c2a39ac592293a4a3ff2344e3057bebd2be1827e`, also in 2.0.26) as well as the previous wording and the `subscription_sharing_usage_limit_exceeded` code in the provider response, because upstream still compares only the previous wording and never matches the current server; the integration list is synced by the picker; the row uses `ProviderIcon` (provider grouping and `ProviderModelIcon` are out of scope). Storybook stories are not ported.
- **Tests:** usage-limit detection unit cases (current and previous messages, response code, other rate limits) fail on the base sources (missing export). Playwright against the mock server at 1440×900 and 390×844: welcome after a token-sharing connection and not after the second one; usage-limit dialog only for the ChatGPT failure, link, no repeat inside the window; plan row for an OAuth connection and none for a key; all fail on the base sources except the two key-connection cases, which pass there by construction. No real ChatGPT sign-in or usage-limit response was exercised.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI or the usage-limit detection; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Full tool error text when expanded — https://github.com/anomalyco/opencode/pull/53816

- **Kind:** anticipated
- **Reviewed upstream revision:** `3f8c0285721dace1318dabb55c5de440819810c5` (commit on `upstream/v2`), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/components/{tool-error-card.tsx,tool-error-card.css}`, the `ExecuteFailed` story in `src/timeline/terminal-work.stories.tsx` and `component-tests/session-tool-projection.spec.ts`. As upstream: an expanded tool error always shows the whole cleaned error text in danger color with preserved line breaks (before, the body existed only when the text had a `": "` separator and showed only what followed it, so `Tool execution interrupted` or an Execute failure without a separator had no body, and the head was always dropped); the collapsed one-line summary is hidden while open; a plain subtitle that is clipped or multi-line in the collapsed header (measured when opening) moves into the open body as a scrollable `pre-wrap` block of up to 240px, so a failed Execute shows its whole code; edit, write and skill get their localized titles. The custom `--font-size-small` token is kept instead of upstream's fixed 13px; the body uses `--line-height-base` as upstream. Upstream's unrelated story refactors (`Match` in `LiveUserCommand`, `InteractiveCommandStory` typing) are not ported.
- **Tests:** two component cases: upstream's failed-Execute case (the open card shows the full code in the subtitle block and the full error) and a new case on `components-tool-error-card--all` (an open `Tool execution interrupted` card shows that text and no summary). Both fail on the base sources (no subtitle block; no description) and pass. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that contains `3f8c02857`: compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Selectable Markdown text — https://github.com/anomalyco/opencode/pull/53665

- **Kind:** adaptation
- **Reviewed upstream revision:** `fd99516e517e3dbce3d2298cd57dcfeb237aef98` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/components/markdown.css` and `component-tests/markdown.spec.ts`. As upstream, the Markdown root sets `user-select: text`, so Markdown stays selectable under containers that disable selection, notably rich artifact tabs (`packages/app-custom/src/session/files/artifact-view.tsx`) and the /btw panel under the shell's `select-none`. The transcript was already selectable through `message-part.css`. Controls inside Markdown keep their own `user-select: none` (`Button`/`IconButton` and the copy label). The custom artifact view never had upstream's `class="select-text"` workaround, so nothing is removed there.
- **Tests:** upstream's component case (triple-click selects Markdown text inside a `user-select: none` body) fails on the base sources and passes. The Markdown component spec otherwise keeps only its two known failures (sanitized local-link markup and path color), which also fail on the base sources. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Provider error icon on the first line — https://github.com/anomalyco/opencode/pull/52859

- **Kind:** adaptation
- **Reviewed upstream revision:** `9daf46b3272ab7ba45460fc9cd0bb61d1ae78068` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/components/session-error.tsx`, the new `src/timeline/error-card.stories.tsx` and `component-tests/session-timeline.spec.ts`. Same as upstream: the session error card aligns the icon to the start, so with the 16px icon and 16px line it stays centered on the first line of a wrapped error instead of the middle of the block.
- **Tests:** upstream's component case (short and wrapped provider errors, icon centered on the first line) fails on the base sources (the wrapped card's icon sat 16px below its first line) and passes. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Spacing for errors and grouped updates — https://github.com/anomalyco/opencode/pull/52876

- **Kind:** adaptation
- **Reviewed upstream revision:** `3ca0ac718bb4d93f5136196af6680089a6d88bd5` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/timeline/{projection.ts,session-timeline-row.tsx,session-timeline.tsx}`, `src/components/message-part.css`, the new `src/timeline/error-spacing.stories.tsx`, `src/timeline/rows-current.test.ts` and `component-tests/session-timeline.spec.ts`. As upstream: an Error row gets 24px top padding; a notice or shell row grouped after an Error gets the `tool` spacing (8px), as after an assistant part; context groups made only of notices are wrapped in `data-notices-only`, which zeroes the 8px content gap so the expanded notices sit right under the trigger. The custom "Updates" title and styling, the notice grouping and the final-answer divider are kept; the final-answer divider keeps its own `content` spacing, and an error after a final answer is spaced 24px from the answer. The custom `SessionTimeline` gains upstream's optional `timelineDetail` prop so stories can render grouped placements.
- **Tests:** upstream's component case (shell → error 24px, error → Updates 8px, aligned, expanded notice 0px below a 28px trigger and 12px inset) plus a custom case with a final answer before the error (divider row `content`/16px, answer → error 24px, error → Updates 8px), and a projection unit test (`spacing: "tool"` after an Error). All fail on the base sources (0px gaps, 8px notice gap, undefined spacing) and pass. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Moved notice as a timeline divider — https://github.com/anomalyco/opencode/pull/52009

- **Kind:** adaptation
- **Reviewed upstream revision:** `41d4a9c45cab93a55d390fc835d5441119ec3c4a` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/{components/timeline-separator.tsx,timeline/projection.ts,timeline/session-timeline-row.tsx,timeline/timeline-row.stories.tsx,timeline/rows-current.test.ts}` and `component-tests/session-timeline-notices.spec.ts`. As upstream: `location-switched` joins compaction and model switches as a row kept out of grouped notices, and renders as a `TimelineSeparator` divider with the "Moved to" label (tooltip "Session working directory changed"), the LTR directory truncating after it, 8px vertical padding and the separator's 440 weight; `TimelineSeparator` gains upstream's `value` and `tooltip` props, and its label gets the `session-timeline-notice-label` slot. Only this notice moves out of Updates; the other custom notice grouping is unchanged.
- **Tests:** upstream's projection unit test (moved notice stays a separate row between grouped context rows) fails on the base sources and passes; the component case now expects the divider (8px padding, 440 label weight). Its 18px line-height expectation reflects the custom mobile comfort scale at the test's 480px width; the old 16px expectation already failed on the base sources. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Latest thinking summary heading while streaming — https://github.com/anomalyco/opencode/pull/53815

- **Kind:** adaptation
- **Reviewed upstream revision:** `46c69bc35ccbc89f48fb2a64784d12025d7a9102` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/timeline/{projection.ts,projection.test.ts}`. Same helper as upstream: `reasoningHeading` returns the latest HTML, ATX or whole-line bold heading (setext only as a fallback), ignores a bold heading that is still streaming and inline bold spans, so the streaming Thinking row (`message-content.tsx`) follows the current summary section instead of the first.
- **Tests:** upstream's three unit cases (sections streaming in, incomplete next heading, mixed heading styles and inline bold); two fail on the base sources and all pass. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Model variant in user message metadata — https://github.com/anomalyco/opencode/pull/53112

- **Kind:** adaptation
- **Reviewed upstream revision:** `ecfa884ff82e9116e475b71a0c99383b8438d710` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/session-ui-custom/src/{message/message-content.tsx,components/message-part.css}` and `component-tests/session-timeline.spec.ts`. The user message metadata shows the model variant after `Agent · Model`, as its own `brain`-icon item with the raw variant text like the custom assistant metadata (`Build · Claude Sonnet 4 · [brain] balanced · 9:00 PM`); `default` and missing variants are omitted as upstream does. The agent/model part truncates first; the variant and time stay whole. As upstream's shared label helper does, the custom assistant metadata also treats a `default` variant as none: one `modelVariant` check in `message-content.tsx` serves both, and the assistant footer already skips empty items, so no icon or gap is left. Otherwise the custom assistant metadata (separate model, variant and agent items with icons) is unchanged, so upstream's concatenated `Model (Variant)` label and its `ui.message.modelVariant` key are not ported, nor its blank-line and `typeof` cleanups. The new `DefaultVariant` story in `src/message/message-content.stories.tsx` renders a turn whose user and assistant messages use `default`.
- **Tests:** new component cases at 1280px and 390px (variant item with icon and text, two separators, no overflow) fail on the base sources and pass; another checks a message without a variant keeps one separator and no variant item. A third case renders `default` on both messages: the user meta has no variant item and one separator, and the assistant footer lists model, agent, throughput, duration and time with five icons and no `brain` icon; on the base commit `c3efc8447` the assistant footer still showed a `default` item (the user part already passed there). Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Stuck timeline rows out of the title fade — https://github.com/anomalyco/opencode/pull/52639

- **Kind:** adaptation
- **Reviewed upstream revision:** `b47d8db9bc0c6abe14c635ed43bdaad551254de5` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/app-custom/src/session/{session-identity-header.tsx,session-identity-header.css}` and `e2e/regression/session-title-fade.spec.ts`. As upstream: the sticky `data-session-title` wrapper no longer paints the gradient and ignores pointer input; its bar has the opaque background and takes input; the fade is a separate `aria-hidden` sticky strip (`top: 48px`, 16px, `z-index: 5`) pulled back over the wrapper's bottom inset, so rows stuck under the bar (z-index 10–20) paint and take input above it, while scrolling content still fades. The wrapper keeps its 64px height, so the measurements that read `[data-session-title]` are unchanged. In custom the stuck row directly below the title is usually the sticky user message (z-index 20), whose top 16px was faded and unclickable before. The custom compact-width rules (52px bar, 18px fade) move to the bar and the fade strip (`top: 52px`, 18px). Upstream's `patch-sticky-header` e2e and story changes are not ported: custom has no such spec.
- **Tests:** a new Playwright regression at 1440×900 scrolls a long patch so the user message sticks under the title and checks the stuck message is hit at 1, 8 and 15px below the bar, the 48px bar, the 16px fade strip under it, and that the title heading still takes input; a 390×844 case checks the phone layout (no title header) has no fade. The 1440 case fails on the base sources (hits land on the title) and passes. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Subagent icon aligned with the progress spinner — https://github.com/anomalyco/opencode/pull/54027

- **Kind:** anticipated
- **Reviewed upstream revision:** `5b312918ecd673fdcc76094471a87067f0fa36e7` (commit on `upstream/v2`), 2026-10-11
- **Local change:** `fix(session-ui): port upstream timeline fixes`; `packages/ui-custom/src/icons/icon/additional-icons.ts`, `packages/session-ui-custom/src/{tools/tool-renderer.tsx,v2/components/session-progress-indicator-v2.tsx}` and `component-tests/session-timeline.spec.ts`. Same as upstream: the `subagent` glyph fills 1–15 of its 16-unit box, the completed subagent card and the delegating row use it at the 16px `normal` size like the spinner, and the spinner's dot clip and reduced-motion center dot move half a unit to the pixel grid the generator script already uses. The compact uses in the custom assistant metadata and `subagent-context.tsx` keep `small` (14px); the larger glyph now matches the other metadata icons' extent, checked at 1440×900 and 390×844.
- **Tests:** a new component case (reduced motion) checks the completed card icon and the running spinner share a 16×16 box, the glyph is inset 1px on every side and the center dot 7px; it fails on the base sources (14px icon) and passes. The existing delegating-row case passes. Package checks: session-ui-custom, ui-custom and app-custom typechecks (app and e2e), session-ui-custom unit suite (256 pass), ui-custom suite (114 pass), app-custom unit (1322, one skip) and browser suites (228 pass; the five known sidebar failures) and root `bun run check` pass. In the session-ui-custom component suite (177 cases) the seven failures also fail on the base sources (two Markdown, two localized tool-list and two referenced-user-image cases) or pass alone (one write-disclosure case); in the related app-custom Playwright specs (179 tests) every failure also fails on the base sources, except one chat-quote case that passes alone and three times repeated.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that contains `5b312918e`: compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Filled clear icon in searches — https://github.com/anomalyco/opencode/pull/53511, https://github.com/anomalyco/opencode/pull/52349

- **Kind:** adaptation
- **Reviewed upstream revision:** `2e3d3a735a06dc403a9dda03ae7b205bf1c0ec3a`, `592daf29f4ef59ec8164dc784bbf210ad57fe9eb` (commits reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/ui-custom/src/icons/icon/icon.tsx`, `packages/app-custom/src/providers/models/{select-dialog.tsx,manage.tsx}`, `src/new-session/{workspace,project}/selector.tsx` and `e2e/regression/search-clear-icon.spec.ts`. The custom icon set gains upstream's 16px `circle-xmark` (its `circle-x` is a different 20px drawing). The clear buttons of the custom ModelPicker popover search, the branch search and the project selector search use it as upstream does: transparent, faint at rest and base on hover, keyboard focus and press, instead of a muted `close`/`close-small` glyph with a hover fill. The manage-models dialog keeps its custom overlay `IconButton` (the `ui-custom` `TextInput` has no `clearIcon` prop, and the same overlay is shared by the settings searches) and only swaps its 20px `close` for the 16px `circle-xmark`, keeping the muted color and hover fill of upstream's `TextInput` clear button. Not ported: the row padding change (`pr-2.5` → `pr-1`) of both PRs, upstream's switch of the model and manage dialogs to `TextInput`'s built-in clear button (the custom ModelPicker is kept), and #52349's menu spacing, divider and structure changes.
- **Tests:** the new Playwright regression at 1440×900 types into the project, branch and model searches and checks the icon, faint rest color, base color on hover and with `:focus-visible`, no hover fill, and that clearing keeps focus; it also checks the manage-models clear icon. All three fail on the base commit (`close-small`, `close-small`, `close`) and pass. The four menus were also inspected at 1440×900 and 390×844. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Side panel tab clipping and alignment — https://github.com/anomalyco/opencode/pull/53315

- **Kind:** adaptation
- **Reviewed upstream revision:** `d1e610408794e9dfa943b912c5ab56879bde95f7` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/ui-custom/src/navigation/tabs/tabs.css`, `packages/app-custom/src/session/files/{session-side-panel.tsx,session-sortable-tab.tsx}`, `e2e/regression/review-tab-geometry.spec.ts` and `e2e/regression/review-toggle-position.spec.ts`. As upstream: the side panel's tab bar sets `--tabs-bar-height` (48px, or 51px when stacked above the side terminal) and both the tab strip and the actions slot use it, so tabs, the "+" button and the actions share the review toggle's centre (the 52px strip had made the bar 53px and put tabs 2px below the toggle); the file icon's `-2px` pull, which the trigger's `overflow: hidden` clipped, is replaced by an 8px start padding on `file://` pills plus an 8px icon gap, keeping icon and label where they were; the end gap moves from the strip's padding into the sticky "+" box (12px), and the background-coloured `::after` cover behind the "+" is removed, together with the custom sidebar-toggle slot's rule that cancelled it. Custom parts kept: the sidebar-toggle slot, the Open file pill, the tab-bar fade mask in `index.css`, and file tabs that keep their LTR content order inside the trigger in RTL (`dir="auto"`), so in RTL the 8px padding is next to the label. Upstream's `gui-extensions` files are not used; the equivalent rules live in `ui-custom` and the custom `FileVisual`.
- **Tests:** the new Playwright regression with twelve seeded file tabs at 1440×900 checks, in LTR and RTL, that an inactive tab's icon is wholly inside its trigger (in LTR 8px inside the pill, label 32px), that the selected tab, "+" and actions share the toggle's centre with a 48px strip, and that scrolled tabs stay hidden behind the "+" box (screenshot equal with tabs hidden); with the side terminal open, strip and actions are 51px and share the toggle's centre. `review-toggle-position.spec.ts` now also checks the "+" centre, as upstream's review spec does. On the base commit the icon and stacked cases and the four toggle-position cases fail (centre 35 instead of 33, strip 52px instead of 51px, icon clipped) and the overflow guard passes (the old cover hid the gap); all pass with the change. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Hide the closed side region over the side terminal — https://github.com/anomalyco/opencode/pull/54052

- **Kind:** anticipated
- **Reviewed upstream revision:** `f5309982d01ac72c63fc1b563bebb1e6febfd4b5` (commit on `upstream/v2`), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/app-custom/src/session/screen.tsx` and `e2e/regression/side-terminal-closed-region.spec.ts`. Same as upstream: the side region presence that stays mounted at zero height while the side terminal is open is `invisible` once the region is closed and its close animation is no longer running. Before, the `forwards` fill of the close animation hid it only until the motion state was recomputed (for example after leaving and re-entering the wide layout); then the region's frame drew its shadow as a line over the terminal's top edge.
- **Tests:** the new Playwright regression at 1440×900 opens the side terminal under the review, closes the review, checks the zero-height region on the terminal's top edge is hidden, resizes to 700px and back, and checks it is still hidden, then reopens the review. It fails on the base commit after the resize (`visibility: visible`) and passes (3/3 with `--repeat-each=3`). `review-toggle-position.spec.ts` and `terminal-hidden.spec.ts` pass. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that contains `f5309982d`: compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Installable PWA behind an authenticating proxy — https://github.com/anomalyco/opencode/pull/53905

- **Kind:** anticipated
- **Reviewed upstream revision:** `a2e3dd288485bce130f8beb943a4833a57103225` (commit on `upstream/v2`), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/app-custom/{manifest.json,index.html,vite.icons.test.ts}` and `e2e/service-worker/cache.spec.ts`. As upstream, the manifest lists the 192 and 512 icons with purpose `any` before the existing `maskable` ones (Chrome needs a non-maskable icon of at least 144px), and the manifest link has `crossorigin="use-credentials"`, because browsers fetch a manifest without cookies otherwise and an authenticating proxy (for example Cloudflare Access in front of the custom server) then rejects it. The OpenCode server itself serves the web shell and manifest without authentication, so the attribute only matters behind such a proxy; on the same origin it changes nothing else. The custom service worker, its prompt-based update policy and its `/api`/`/auth` navigation exclusions (`vite.pwa.ts`) are unchanged. The icon test now requires some, not all, icons to be maskable, as upstream.
- **Tests:** the ported service-worker case serves the production build behind a cookie-checking server and asks a persistent Chrome profile (installed Chrome locally, Chromium elsewhere) for `Page.getInstallabilityErrors`; it fails on the base build and passes. A one-off CDP check of both production builds reported: base without the proxy `manifest-missing-suitable-icon`, `no-acceptable-icon`; base behind the proxy an empty manifest and `manifest-parsing-or-network-error`, `start-url-not-valid`, `manifest-missing-name-or-short-name`, `manifest-display-not-supported`, `manifest-missing-suitable-icon`, `no-acceptable-icon`; with the change no errors in either case (`Page.getAppManifest` returns the 588-byte manifest without errors). `bun test ./vite.icons.test.ts` passes. Installation on a real phone was not tested. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that contains `a2e3dd288`: compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Phone titlebar clear of the iOS status bar blur — https://github.com/anomalyco/opencode/pull/53297, https://github.com/anomalyco/opencode/pull/53267

- **Kind:** adaptation
- **Reviewed upstream revision:** `eab83d63fd0fae268875801924c02f7f208d1ae0`, `80c4a6b7c873050f66457a95a71f90a4df5d4fa0` (commits reviewed; only the titlebar clearance of the second is applied), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/app-custom/src/shell/titlebar/titlebar.tsx` and `e2e/regression/mobile-titlebar-clearance.spec.ts`. With the phone titlebar at the top on the web, the header pads by upstream's final clearance, `max(8px, min(16px, env(safe-area-inset-top) * 1000))` plus the safe area: 16px below a top safe area, 8px without one; the inner row's own 8px top padding is dropped for that case. The custom 44px row is kept (upstream's row is 28px), so the header is `44px + clearance + safe area`: 52px without a safe area (unchanged geometry) and 107px with a 47px inset (91px before). Bottom titlebar, desktop web and Electron layouts are unchanged. Nothing else from #53267 (More navigation, drawers, composer, pickers) is ported.
- **Tests:** the new Playwright regression at 390×844 with touch emulation measures the row's offset inside the header without a safe area (8px) and with `Emulation.setSafeAreaInsetsOverride` setting a 47px top inset (63px, row 44px, flush with the header bottom), and checks the bottom titlebar keeps no top padding and the 34px bottom inset. The safe-area case fails on the base commit (offset 47px) and passes. The real iOS status-bar blur on a Home Screen web app could not be checked on an iPhone. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Submit hover only on hover-capable devices — https://github.com/anomalyco/opencode/pull/49461

- **Kind:** adaptation
- **Reviewed upstream revision:** `8eb2ebd96cb2e25f9607f753e892a533628b8d46` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/ui-custom/src/actions/submit.css` and `packages/app-custom/e2e/regression/submit-touch-hover.spec.ts`. Same as upstream: the hover overlay of submit buttons and submit/contrast icon buttons applies only under `@media (hover: hover)`, so a tap no longer leaves it stuck on touch screens. The custom colours and gradients are unchanged. In the custom composer, send is a ghost button and only Stop uses the submit variant, which is where a tap left the overlay.
- **Tests:** the new Playwright regression taps Stop in a busy session at 390×844 with touch emulation: one interrupt request, the button still matches `:hover`, and its background keeps two layers (fails on the base commit with three); a pointer at 1440×900 still gets the overlay on hover (passes on both). App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Touch scrolling in the directory picker — https://github.com/anomalyco/opencode/pull/51781

- **Kind:** adaptation
- **Reviewed upstream revision:** `2eff7da1b6802b0bec72d7a84b31df1ce098bcef` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream mobile and layout fixes`; `packages/app-custom/src/workspaces/selection/dialog.tsx`. Same as upstream: the tree container stops `touchmove` propagation, because the modal's scroll lock sees only the file tree's shadow host and cancels touch scrolling of its inner scroller. In the custom web product this `DirectoryPickerDialog` is reached only from SSH servers, which need the desktop platform's `sshServers`; opening projects uses the custom `ProjectExplorerDialog`, whose plain list already scrolls by touch.
- **Tests:** no regression test: the dialog cannot be opened in the web product or against the mock server, and the custom packages have no story for it. A one-off Playwright check at 390×844 with touch emulation scrolled the project explorer by 193px with a synthesized touch gesture on the base commit. App-custom typecheck passes. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures), ui-custom suite (114 pass) and root `bun run check` pass. In the full app-custom Playwright run (490 tests, 4 workers) every failure also failed on the base commit or passed when rerun alone.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### HTTP-safe UUID for attachment uploads — https://github.com/anomalyco/opencode/pull/51783

- **Kind:** adaptation
- **Reviewed upstream revision:** `cb11287ae65e454345aa151bd1df13be75d61483` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream robustness fixes`; `packages/app-custom/src/composer/attachments/{destination.ts,deliver.ts,deliver.test.ts}`, `src/settings/snippets/snippets.tsx`, `src/servers/ssh/dialog.tsx` and `e2e/regression/composer-binary-attachment.spec.ts`. As upstream, the upload path segment uses the existing `uuid()` helper (`src/runtime/persistence/uuid.ts`) instead of `crypto.randomUUID()`, which is undefined over plain HTTP on a LAN address. Beyond upstream's single call site: the custom upload tracker ID in `deliver.ts`, a new snippet's ID and a new SSH server's ID also used `crypto.randomUUID()` and now use the same helper (the snippet ID is any non-empty string and the SSH ID any string). No direct `crypto.randomUUID()` call remains in the three custom packages outside tests. Upstream's added `SAFETY` comment is not ported. #53501 (`da20865bb976eaede96d315a43eaa86e4b5d6e90`, restored comment notes) does not apply: the custom `comment-note.ts` has no `commentContextItem` and never mints a note ID with `crypto.randomUUID()` (new comment IDs already use `uuid()` in `composer/comments.tsx`), so its schema refactor is not ported.
- **Tests:** a new `deliver.test.ts` case removes `crypto.randomUUID`/`subtle` and sets `isSecureContext = false`; it fails on `03a2551fc` (`crypto.randomUUID is not a function`) and passes. A new Playwright case in `composer-binary-attachment.spec.ts` uploads with `randomUUID` removed and `isSecureContext` false; it fails on `03a2551fc` (no upload request) and passes. A one-off run of the unchanged upload case against the dev server bound to the Mac's LAN address (`http://192.168.0.246:3472`, a real non-secure context) also failed on `03a2551fc` and passed with the fix. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures) and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Keep live terminals through transient connect failures — https://github.com/anomalyco/opencode/pull/52232

- **Kind:** adaptation
- **Reviewed upstream revision:** `10b11ba9462f28e46311280578039ccce3aadffa` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream robustness fixes`; `packages/app-custom/src/session/terminal/terminal.tsx` and `e2e/regression/terminal-reconnect.spec.ts`. As upstream, a rejected `pty.connect` (for example a failed connect-ticket request) goes through the existing `retry()` backoff, which reports a connection error only when the PTY is exited or not found, instead of calling `fail()` directly. The custom terminal is otherwise unchanged. Upstream's mock-server additions (`MockPtyNotFound`, socket `close()`) are not ported; the custom regression routes the PTY endpoints and WebSocket in the spec itself.
- **Tests:** the new Playwright regression closes the live socket with 1011, fails the next connect ticket with 503, and expects a third ticket, a second socket for the same PTY, the same terminal DOM node with an editable input and a single PTY creation. It runs at 1440×900 (terminal opened with Ctrl+Backquote) and at 390×844 with touch (terminal opened as the phone view from the navigation's More options → Terminal); both fail on `03a2551fc` (stops after two tickets) and pass. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures) and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Alert only for open session tabs — https://github.com/anomalyco/opencode/pull/52204

- **Kind:** adaptation
- **Reviewed upstream revision:** `bf97a0443fc1c4f44178067aa2439d0a6b129617` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream robustness fixes`; `packages/app-custom/src/shell/notifications/notification.tsx` and `test-browser/{notification-alert.test.ts,fixtures/notification-alert.ts}`. Same as upstream: response-ready and error system notifications (`platform.notify`) now require an open tab for the session, the condition that already gated their sounds, while the in-app notification history (unseen counts and indicators) is still recorded for every root session.
- **Tests:** upstream's unit test is ported as an isolated browser-suite fixture (it substitutes platform, settings, language and tab contexts in its own process, as other custom fixtures do); both cases fail on `03a2551fc` (the alert fires without an open tab) and pass. No Playwright check: the web `notify` is suppressed while the page is visible and focused, so headless runs cannot observe it. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures) and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Select the new-session project by resolved ID — https://github.com/anomalyco/opencode/pull/52230

- **Kind:** adaptation
- **Reviewed upstream revision:** `dd68d6eb795e4501141c88489e6ecb0624c2b898` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream robustness fixes`; `packages/app-custom/src/new-session/project/{controller.ts,selector.tsx}`, `test-browser/{new-session-project-selection.test.ts,fixtures/new-session-project-selection.ts}` and `e2e/regression/new-session-project-resolved.spec.ts`. As upstream, the controls expose the Location's resolved `project.id`, and the selector, after the server filter and the exact worktree/sandbox match, falls back to a project with that ID, so a draft in a worktree missing from the inventory selects its project instead of the first listed one. Unlike upstream, when several opened projects share the ID (the shared-ID case of the #51288 entry), it prefers the most specific one whose root contains the draft directory and only then the first match. The custom Chats group and chat selection are unchanged (a chat draft still selects no project).
- **Tests:** the ported selector tests (resolved ID before inventory, no cross-server match) plus exact-path precedence and shared-ID ancestor cases; three fail on `03a2551fc` and pass (the exact-path guard passes on both). The Playwright regression at 1440×900 and 390×844 opens a draft in an unlisted worktree with another project listed first: the trigger shows and checks the resolved project, with Chats still listed; it fails on `03a2551fc` (the other project is selected) and passes. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures) and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Focus the model search when /model opens its dialog — https://github.com/anomalyco/opencode/pull/53707

- **Kind:** adaptation
- **Reviewed upstream revision:** `98d57d0dd2def1f1482205e36ff62236209d1a9f` (commit reviewed/applied), 2026-10-11
- **Local change:** `fix(app): port upstream robustness fixes`; `packages/app-custom/src/composer/{commands.tsx,editor/interaction.ts}` and `e2e/regression/{composer-model-dialog-focus,composer-slash-custom-focus}.spec.ts`. Both upstream parts are ported: `chooseModel` imports `DialogSelectModel` statically (the module is already in the composer's static graph through `ModelSelectorPopover`) so the dialog mounts and takes focus within the command, and a slash suggestion with an action no longer runs the machine's text replacement and `focus.editor` before the action (the existing prompt reset still clears `/model`). In the custom CodeMirror composer the static import is what fixes the lost keystrokes; the interaction change keeps parity with upstream and avoids briefly rewriting and refocusing the editor.
- **Tests:** the new Playwright regression at 1440×900 and at 390×844 with touch emulation types `/model`, presses Enter and types immediately: the text lands in the dialog's search field and the composer stays empty; Escape returns focus to the composer, and the Commands-menu path keeps the draft while typing into the search. It fails on `03a2551fc` at both viewports (search empty) and with only the interaction change, and passes with the fix (10/10 with `--repeat-each=5`). The existing `composer-command-draft.spec.ts` passes. Because slash actions no longer get the machine's text replacement and `focus.editor`, every built-in slash command was compared with `03a2551fc` from the popover with Enter and with click (1440×900) or tap (390×844 touch): focus target, URL, open dialog, main draft and where typed text lands are identical for the custom-only `/btw` (side composer focused and typed into, main draft empty) and `/terminal` (terminal input focused, keys reach the PTY), and for `/model`, `/new`, `/export`, `/open` and `/mcp`; `/agent`, `/undo`, `/redo`, `/compact` and `/fork` are disabled in that fixture and were not exercised. `e2e/regression/composer-slash-custom-focus.spec.ts` guards `/btw` and `/terminal` in both selection modes and viewports; it passes on `03a2551fc` and with the change. App-custom typecheck (app and e2e), unit suite (1321 pass), browser suite (228 pass; the five known sidebar failures) and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Calm diff word highlights with @pierre/diffs 1.5.1 — https://github.com/anomalyco/opencode/pull/51236

- **Kind:** adaptation
- **Reviewed upstream revision:** `a604b7f773d9807d160bda144150e0b50efd4caf` (merge commit, integrated by `5e73d5cb1`), 2026-10-11
- **Local change:** `chore: merge upstream v2 (2.0.26) into custom`; `packages/session-ui-custom/src/{components/file.tsx,components/file-ssr.tsx,components/session-review.tsx,context/data.tsx,pierre/index.ts,pierre/worker.ts}`, `performance/highlighting/{plain.correctness.ts,viewer.tsx}` and `component-tests/file.spec.ts`. The shared catalog moves `@pierre/diffs` to 1.5.1, so the session-ui change is applied unchanged to the custom package: two-argument diff option and preload types, `word-line` inline diffs instead of `word-alt`, the softer collapsed-row separator, the container-query annotation gutter, and the SSR fallback when either side is missing. In `file.spec.ts` only the expected whole-line deletion span is ported; the custom large-file assertions already expect no syntax tokens.
- **Tests:** session-ui-custom typecheck and unit suite (251 pass), app-custom typecheck, unit suite and production build, and root `bun run check` pass. The Storybook component spec was not run.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Deterministic timeline file links — https://github.com/anomalyco/opencode/pull/53641

- **Kind:** anticipated
- **Reviewed upstream revision:** `f43903d8496b4116596f1a9470572f6c46a4fa6f` (merge commit on `upstream/v2`), 2026-10-09
- **Local change:** `feat(app): resolve timeline file links deterministically`. Shared code is the upstream change: `packages/util/src/path.ts` (`parsePathLineSuffix`, `isLineRangeHash`), `packages/core/src/filesystem.ts` and its test (`list` fails with `NotFoundError` for a missing path or a file instead of a defect), `packages/server/src/handlers/fs.ts` and `packages/protocol/src/groups/fs.ts` (`fs.list` → 404 `FileNotFoundError`), the generated client, and only the `fs.list` 404 hunk of `packages/protocol/openapi.json` and `services/www/{,public/}openapi.json` (regenerating them also emits older, unrelated drift, which is left out). UI is ported into `packages/session-ui-custom/src/{components/markdown-inline-code-kind.ts,components/markdown.tsx,components/markdown-image.ts,context/markdown.tsx}` and `packages/app-custom/src/{session/files/resolve-link.ts,session/files/open-artifact.tsx,session/files/artifact-view.tsx,session/files/directory-view.tsx,session/files/file-tabs.tsx,session/files/session-file-browser-tab.tsx,session/files/session-mobile-files.tsx,session/screen.tsx,workspaces/files/model.tsx}`. Same behavior as upstream: inline code is a candidate path by syntax only and becomes a link after the block finishes streaming and the file is confirmed (absolute paths by listing the parent directory, relative ones by the literal path or a `/`-suffix match in the search index; `~` and `//host` paths are never checked); clicking opens the single match, opens the file picker filtered to the path when several files match, and falls back to the literal path; `:42`, `:42:7`, `:42-50`, `#L42-L50` select and scroll to the lines, also for Markdown links. Custom has no `gui-extensions`: `Links.exists`/`LinkHandler.exists` become `ArtifactOpener.exists` passed as `MarkdownProvider.localFileExists`. Upstream's per-session persisted picker filter, focus hand-off and reveal registry are replaced by one-shot `picker`/`reveal` signals in `ArtifactOpener` consumed by the existing file browser tab (filter and desktop focus), the mobile files view (switches to browsing) and `SessionFileView` (clears the transient selection and restores the stored scroll); the browser-pane HTML routing upstream removed was never in custom. Agent previews and directory-view entries are exact paths, as upstream's `exact`/`background` links. Path code keeps the custom `role="link"`/`tabindex` for Enter activation, now set when the file is confirmed. Directory paths in inline code no longer become links (the search is file-only, as upstream); Markdown links to directories still open the custom directory view. In git workspaces the `fff` index includes ignored files, so `.agent-artifacts/x.png` in inline code becomes a link; in non-VCS directories the ripgrep index skips hidden directories, so such a path stays plain code.
- **Tests:** ported `resolve-link.test.ts` (32 pass), `markdown-inline-code-kind.test.ts` and `markdown-image.test.ts` (69 pass), core `location-filesystem.test.ts` (7 pass); session-ui-custom unit suite 251 pass; app-custom unit suite 1320 pass; app-custom browser suite 226 pass with the five known sidebar failures; session-ui-custom markdown component spec 26 pass with the same two failures as on base `3bd4cc3e7` (sanitized local-link markup and path color); the ported `src/file.ts`/`missing.ts` assertion passes, and a new case (no path link while streaming, link plus `role="link"` once the stream completes) passes and fails with the base `src`; typecheck of util, core, protocol, server, client, session-ui-custom and app-custom and root `bun run check` pass. Against an isolated source server on 4177 (fixture git repository and imported fixture session), Playwright at 1440×900 and 390×844 verified: `convergida/comparativo.png` opens `docs/…/convergida/comparativo.png`; `write/edit`, a missing path and a `\\host\share` path stay plain code with no request; `src/app/arquivo.ts:42`, `[…](src/app/arquivo.ts:50-55)` and an absolute `#L10-L12` select and scroll to the lines, also with the tab already open; `index.ts` opens the picker filtered with two results and keyboard/tap selection opens one; `.agent-artifacts/x.png` opens and `![…](.agent-artifacts/x.png)` renders; `fs.list` of a missing path or a file returns 404.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** 2.0.26 does not contain `f43903d84`, so the anticipated change stays. The merge kept the shared code and moved `packages/util/src/path.ts` to the `upstream/v2` layout: `path.ts` and `packages/core/src/filesystem.ts` now equal `upstream/v2`, and upstream's streaming `fs.read` (#53088) coexists with the `list` 404.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that contains `f43903d84`: keep the shared changes as upstream's, and compare and update the custom UI port
- **Installation:** none
- **Result after upstream:** pending

### Structured notice and list i18n APIs — https://github.com/anomalyco/opencode/pull/50204

- **Kind:** adaptation
- **Reviewed upstream revision:** `5253661d36b9e6cb519b5465f74abbd2d9bd713f` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(i18n): port structured notices and localized lists`; `packages/app-custom/src/runtime/i18n/language{.tsx,.test.ts}`, `packages/ui-custom/src/context/i18n{.tsx,.test.ts}`, `packages/ui-custom/src/i18n/en.ts`, `packages/session-ui-custom/src/{components/session-retry.tsx,components/tool-count-summary.tsx,components/tool-count-summary.css,timeline/session-timeline-row.tsx,tools/tool-renderer.tsx}`, and `packages/app-custom/e2e/regression/structured-notices.spec.ts`. Ports tDynamic, localized string/rich lists, rich template interpolation and the source/derived UI i18n boundary while retaining independent custom layout direction. Notices prefer instructionSources/notice metadata and retain the old English-description fallback. Retry copy uses complete pluralized phrases. Animated count separators and tool-name lists use the locale APIs; active separators are no longer clipped to one character. Keeps custom segmented tool-group labels, tabular counts, 4px spacing, notice grouping, and custom tool handling; does not copy upstream's replacement of segmented group labels or its translation batch. Only the four English retry/restart keys needed by these consumers are added.
- **Tests:** UI i18n tests cover runtime English/fallback, localized list separators and complete retry phrases; app language tests cover rich placeholders and element identity in lists. Playwright at 1440×900 and 390×844 verifies metadata-only notices plus old-event fallback (2 pass), and existing custom tool-count spacing (2 pass). Root `bun run check` passes.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the same timeline and notice UI in #52009 (moved notice divider), #52207 (adjacent reads grouped), #52210 (sticky Used header), #52876 (error and update spacing), #53338 (queued/pending steer copy), #53832 (revealed tools under sticky headers) and the #52369 move into `gui-extensions`. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(session-ui): port upstream timeline fixes` ports #52009 (moved notice as a divider) and #52876 (error and notice-only spacing), see their entries; the structured notices, legacy fallback, localized lists, custom notice grouping and Updates styling are unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Project settings actions and question shortcuts — https://github.com/anomalyco/opencode/pull/49172

- **Kind:** adaptation
- **Reviewed upstream revision:** `95cfca73b0345885a122ff77fff06351cec9a382` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): add project settings actions and question shortcuts`; `packages/app-custom/src/settings/workspaces/{projects.tsx,project-row.tsx}`, `src/session/requests/session-question-dock.tsx`, and `e2e/regression/{settings-project-actions,question-shortcuts}.spec.ts`. Adds Open project in the header and empty state through the existing custom project explorer and SSH authentication hook, opening selected directories on the selected server. Keeps all-servers grouping and DialogEditProject. An explicit row options button opens the same custom menu as right click; closing still uses the custom confirmation and focus restoration. Clear notifications uses the existing per-server notification model for the project and its sandboxes. Question back shortcuts and back/submit hints are ported; unlike upstream's session-wide registration, the back command requires the keyboard event target to be inside the question dock, preserving CodeMirror and unrelated navigation shortcuts. Existing local submit handling remains. Finder/Electron paths, settings filters and timeline-detail slider changes are excluded.
- **Tests:** four Playwright regressions with the scoped mock at 1440×900 and 390×844 pass: explicit options, notification clearing, close cancellation/focus restoration, confirmed removal, empty-state project picker and re-add, question back preserving the answer, and shortcut submission with exact payload. Spec-local fixtures provide subscriptions, server info and family snapshots missing from the shared mock. App-custom typecheck and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the same settings and session UI in #52369/#52868 (GUI extensions), #53267 (mobile navigation and drawers), #53731 (configurable default server removed) and #53257 (one-time pairing links across the GUI). Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. Of #53267, only the phone titlebar clearance is ported, by `fix(app): port upstream mobile and layout fixes` with #53297 (see its entry); it does not touch these settings or session views.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Console device-flow feedback — https://github.com/anomalyco/opencode/pull/48501

- **Kind:** adaptation
- **Reviewed upstream revision:** `b7d707cd642642062e8bf89e29337804a6a280d2` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): clarify Console sign-in states and errors`; `packages/app-custom/src/providers/connect/{controller.ts,dialog.tsx,remote.tsx,remote.test.ts}`, `src/runtime/i18n/en.ts`, and `test-browser/fixtures/provider-connection.ts`. Ports conditional hidden defaults, explicit waiting/refreshing/ready states, Console-specific start/poll/denied/expired/catalog-refresh messages, catalog-only retry after successful authorization, and a server-scoped remote credential notice. Keeps custom completion toast/dialog close, native authorization-link fallback, cancellation after transport failure, Go-specific keys, integration-aware disconnect/account badges, model visibility preferences, and InlineServerSelect. The form area scrolls so adding the remote notice keeps the custom API-key switch reachable on phones. Excluded: `global.models.show`, retaining attempts after transport errors, model onboarding (`prepare`/`prepareConsoleCatalog`/`catalogPending`/`noModels`), InlineServerSelect replacement, provider grouping/ProviderModelIcon, `openBrowser`/`browserFailed`/copy-link, and `return_window`/Electron. #50204 only renames the unsupported-form i18n key in the upstream controller; that unrelated existing custom hardcoded error is not changed here.
- **Tests:** controller fixture 14/14 and remote-identity tests 3/3 pass; root `bun run check` passes. Full browser suite: 226 pass and the five previously reported sidebar failures. Playwright CLI with installed Chrome and an isolated source server (4731, temporary XDG/DB/config, no inherited OPENCODE variables) checked 1440×900 and 390×844: real device-code start/native link, injected denied/expired-token responses, catalog failure followed by Retry closing without another login, and remote notice through a browser-routed `remote.test` alias of the isolated backend. No remote notice on loopback. The mobile API-key switch remains reachable by scrolling and opens its form. No actual Console authorization completed.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed provider connection in #53672 (declarative external connection method), #53625 (inline custom answers in connect forms), #52160/#52163 (ChatGPT token-sharing guidance), #53731 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `feat(app): port external provider connections and ChatGPT guidance` ports #53672, #53625 and #52153/#52160/#52163 (see their entries): external methods and inline custom answers in the connect dialog, the server-scope notice extended to external methods, and the ChatGPT dialogs and picker row; the Console device flow, native link fallback, cancellation, Go keys, completion toast and every exclusion above are unchanged. #53731 and #52369 remain unported.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Worktree and branch in Home session rows — https://github.com/anomalyco/opencode/pull/49793

- **Kind:** adaptation
- **Reviewed upstream revision:** `bfcaf1b0cd1be8c081d67928c93f699f59bc362f` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): show session worktrees and branches on Home`; `packages/app-custom/src/home/sessions/{alt-hold.ts,alt-hold.test.ts,records.ts,records.test.ts,controller.tsx,region.tsx,view.tsx,view.css}` and `e2e/regression/home-session-location.spec.ts`. Enabled for the web rather than gated on Electron. Home session rows and search results show the session directory's worktree name and branch: pointer devices reveal it on row hover or while Alt is held, as upstream; touch devices (`hover: none`) show it without hover, on the phone layout's secondary line next to the project name, where it takes only the room left and truncates first. Branches come from the custom batched `custom.worktrees` locate RPC on the default Location (reusing `createSidebarWorktrees`, deduplicated per directory and per connection) instead of upstream's per-directory `vcs` sync, which would boot a Location for each session directory; hover requests one directory, Alt and touch request the listed directories in one call. Chat sessions show no location. The phone layout's label column now wraps title / secondary line instead of stacking every label, keeping rows at their existing height.
- **Tests:** ported alt-hold and location-label unit tests; a Playwright regression checks hover and Alt reveal with one locate request per new directory at 1440×900, and touch rows at 390×844 showing worktree and branch without hover from a single request. The touch case needs a warmed browser in the local Chrome channel (it passes when run with its file; as a first test in a worker Chrome ignores the touch media emulation, which also affects `composer-attachment-touch.spec.ts`). App-custom typecheck, unit suite, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream's Home session files changed only in #52369 (session-tree removal IDs, `displayName` import) and the #53444 spacing autofix; the worktree/branch reveal is unchanged, so the port stays as is.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Tool count spacing — https://github.com/anomalyco/opencode/pull/50356

- **Kind:** adaptation
- **Reviewed upstream revision:** `e31f78af78da624dd0c9aa487cdf47509a6bd2d7` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(session-ui): space tool counts with gaps`; `packages/session-ui-custom/src/{components/message-part.css,tools/tool-renderer.tsx}` and `packages/app-custom/e2e/regression/tool-count-spacing.spec.ts`. The custom tool-group summary already had upstream's split label structure but spaced it with literal trailing spaces; it now uses upstream's 4px flex gaps (which also separates a trailing locale suffix from the tool names) and tabular numerals for the count. The custom font-size token is kept; upstream's component-test updates are not ported (the custom packages have no Storybook stories).
- **Comparison:** #50204 subsequently flattened the upstream group label. The selective i18n port retains the custom segmented title, tabular count and 4px gaps while localizing the tool-name list; the original two viewport regressions still pass.
- **Tests:** a Playwright regression against the mock server at 1440×900 and 390×844 checks the tabular count and 4px gaps on both sides of the count; it fails on `cde61cb22`. Existing accessible-name checks (`Used 1 Agent`) still pass; session-ui-custom unit suite and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the tool-group timeline in #52207, #52210, #52876 and #53832. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(session-ui): port upstream timeline fixes` ports #52876 (see its entry): only the notices-only content gap and error spacing change; the tabular count and 4px gaps are unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### GitHub mark on Markdown links — https://github.com/anomalyco/opencode/pull/51000

- **Kind:** adaptation
- **Reviewed upstream revision:** `0bc8b8dbeb9540842ae5a69bb5c9af3182999522` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(session-ui): mark GitHub links in Markdown`; `packages/session-ui-custom/src/components/{markdown.css,markdown-github.svg}` and `packages/app-custom/e2e/regression/markdown-github-mark.spec.ts`. Ports only the GitHub mark: a `::before` pseudo-element masked with the local SVG (inlined as a data URI by the build) on `a.external-link` elements whose href is `github.com` or a path under it. Not ported: the Google favicon service, the globe fallback, and the favicon `<img>` handling in `markdown.tsx`/`image-preview.tsx`, so no third-party request is made; because the mark is not an image, the custom image-preview handling and local-link/inline-path references are untouched.
- **Tests:** a Playwright regression against the mock server at 1440×900 and 390×844 checks the 14px mark on a GitHub link, no mark on another site or a `github.com.evil.example` lookalike, no images or preview buttons in the message, and no request to a non-local host; it fails on `cde61cb22`. The app-custom production build inlines the SVG; root `bun run check` passes.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream Markdown changes in this range (#52231 session-ID links, #52389 bold weight, #53665 selectable text, #53444 spacing) do not touch link marks; they are tracked by the rich-artifact and image-preview entries. The mark is unchanged.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Nested session tabs and ancestor trail — https://github.com/anomalyco/opencode/pull/51064

- **Kind:** adaptation
- **Reviewed upstream revision:** `ad53e39d2e6c222ea35aa4b8331616a9f85b4ef5` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): group nested session tabs under their root`; `packages/app-custom/src/shell/titlebar/titlebar.tsx`, `src/session/{session-identity-header.tsx,timeline/message-timeline.tsx}`, and `e2e/regression/subagent-child-navigation.spec.ts`. As upstream, the titlebar resolves a routed session's root with the existing `rootSession` helper (cycle detection, fetched ancestors remembered in the data cache, `data.session.root` fallback) and keys descendant tabs by that root; the identity and timeline headers render `SessionAncestorTrail`, a scrollable breadcrumb of every ancestor that navigates through `rememberSessionRoute`, while the active title keeps up to 45% of the row. Chat identity, tab order and preferences, the drawer, touch gestures, and file/artifact tabs are unchanged; the timeline controller keeps its now unused `navigateParent` action as upstream does. The custom phone layout (below the desktop breakpoint) does not render the session title header, so the trail appears from the desktop breakpoint up; at 390×844 the mobile titlebar keeps the current title and the drawer lists the root session once.
- **Tests:** three Playwright regressions ported from upstream (direct nested link opens in the root tab, full ancestor path with navigation, active title and separator kept in view at 820×720 with keyboard navigation to the root) fail on `cde61cb22` and pass; they use the horizontal tab strip and pass the mock `subscriptions` shape. Checked at 1440×900 and at 390×844 (drawer shows only the root tab, titlebar shows the current title). App-custom typecheck, unit suite, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed tabs and session headers in #51973 (recently closed tabs menu), #53267 (mobile navigation), #53297, #53332/#53247 (running work in headers), #52639, #53761 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(app): port upstream mobile and layout fixes` ports #53297 with #53267's final phone titlebar clearance (see its entry); #53267's mobile navigation and the other changes are not ported yet. `fix(session-ui): port upstream timeline fixes` ports #52639's title fade split in `SessionTitleHeader` (see its entry); the ancestor trail and title row are unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Undo queued prompts into the composer — https://github.com/anomalyco/opencode/pull/51124

- **Kind:** adaptation
- **Reviewed upstream revision:** `beeb14e910775230d24355a7533b2e4d4e05a53b` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): undo queued prompts into the composer`; `packages/app-custom/src/session/composer/{queue.ts,queue.test.ts,queue-panel.tsx}`, `src/composer/{adapter.ts,model.ts,prompt.ts,composer.stories.tsx}`, `src/runtime/i18n/en.ts`, and `e2e/regression/session-queue.spec.ts`. A queued row has an Undo action that cancels the inbox item (`session.inbox.cancel`) and puts the prompt back into the draft after anything already typed, with its quotes merged by ID; submit is blocked while it runs. Instead of upstream's `queuedPromptUndoDraft()`, `queuedPromptUndo()` rebuilds the custom algebra from the full sent payload: `@file` mentions (path and line range from the file URI), agents, skills, app and session parts, cited and uncited inline images, staged `path` attachments with their mentions, and structured quotes. MCP resource reference lines stay as text. Before cancelling, the rebuilt draft is serialized again with `buildPromptRequest` and compared with the queued text, files, agents, skills, apps, and sessions; attachment reference lines are only counted, because attachments are redelivered on send. Anything the draft cannot hold, such as review-comment context or unmentioned file context, keeps the item queued and shows an English message. Existing guards stay: no undo in shell mode (message), while editing a queued item, or while a revert is pending; the queue panel remains hidden while `/btw` occupies the composer. `buildPrompt` and `selectionFromFileUrl` in `composer/prompt.ts` are exported for this. The upstream TUI keybind and upstream's read-only editor during undo are not ported (the draft is read after the cancel, so typing meanwhile is kept).
- **Tests:** unit tests cover the round trip (restored parts resubmit exactly the queued payload), MCP resource text, and refusal for comment and hidden file context; Playwright against the mock server at 1440×900 and 390×844 restores a queued prompt with its attachment after an existing draft, and leaves an unrestorable prompt queued with the message and no cancel request. App-custom typecheck, unit suite, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed queue, steer and revert handling in #53076 (match TUI inbox, steer, queue and revert behavior), #53338, #53880, #53445, #53268, #52620 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Provider account switching — https://github.com/anomalyco/opencode/pull/51266

- **Kind:** adaptation
- **Reviewed upstream revision:** `684721efb8c4e753431b2e9e851716e34e410e42` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): switch provider accounts in settings`; `packages/app-custom/src/settings/providers/{accounts.ts,accounts.test.ts,providers.tsx}`, `src/settings/settings.css`, and `src/runtime/i18n/en.ts`. A connected provider with stored credentials shows its active account (the server's active-first order) in a menu that activates another account (`credential.activate`), adds one through the existing connect dialog, and removes a single account (`credential.remove`), then invalidates and resyncs integration, provider, and model data. Differences from upstream: account removal is a flat menu group instead of a submenu, so the same menu works on touch screens (no `ui-custom` menu change is needed); the custom integration-aware "Disconnect all" stays in the menu as a separate action; providers without credentials keep the plain Disconnect button or the environment hint. Custom account badges, server-scoped settings (`InlineServerSelect`), the shared Console integration lookup, and model-visibility preferences are unchanged (no automatic `models.show`). English source strings only.
- **Tests:** the upstream account-order helper tests pass; app-custom typecheck, unit suite, and root `bun run check` pass. Against an isolated source server (temporary XDG/DB/config dirs, no inherited `OPENCODE_*`) with two fixture OpenAI API-key credentials, Playwright at 1440×900 and 390×844 switched the active account, removed one account, opened Add account, and disconnected all, checking the server's credential list after each step.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the provider settings files in #53511, #53257, #53305, #53267 and #53444. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(app): port upstream mobile and layout fixes` ports #53511's filled clear icon to the manage-models search, keeping the custom overlay button (see its entry); the account-switching files are unchanged. `feat(app): port external provider connections and ChatGPT guidance` lets Add account use external methods (Azure CLI, AWS profile, Google Cloud credentials) through the connect dialog (see the #53672 entry); account switching, removal, badges and Disconnect all are unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### One-time pairing links and unauthorized servers — https://github.com/anomalyco/opencode/pull/50970, https://github.com/anomalyco/opencode/pull/50972

- **Kind:** adaptation
- **Reviewed upstream revision:** `eccf0b3b7b70f6980f6f7ccdb0cad566bbc37ab5`, `2caba90a63e1eb0155ca43496ca6e8eed895e217` (commits reviewed/applied), 2026-09-28
- **Local change:** `fix(app): redeem one-time pairing links`; `packages/app-custom/src/servers/connect/{pairing.ts,pairing.test.ts,scanner.tsx,screen.tsx,dialog.tsx}`, `src/runtime/server/{health.ts,health.test.ts,runtime.tsx}`, `src/shell/routes/routes.tsx`, `src/runtime/i18n/en.ts`, `vite.pwa.ts`, and `e2e/service-worker/cache.spec.ts`. Ports `pairingLink()`/`redeemPairingLink()` but keeps the custom raw JSON, legacy query/fragment, and base64url `/connect` decoders (the scanner tries them first) and returns the custom `{ urls, password }` shape. The connect screen and the server dialog accept a pasted `/auth/connect/<code>` link, redeem it, and put the base URL and token into the form before the health check, so a retry never reuses the spent code; spent or expired codes show an English-only error. Health reports `{ healthy: false, unauthorized: true }` without retrying; the global runtime disposes an unauthorized server's controller and does not recreate it until health recovers. When the only server is an unauthorized HTTP server, the connect screen replaces the app with its URL prefilled. The PWA navigation fallback excludes `/auth` so opened links reach the server. Not ported: upstream's removal of password pairing and legacy decoders, the desktop/TUI pairing UI, and the `/connect` route removal (custom has no such route).
- **Tests:** pairing-link and unauthorized-health unit tests (ported from upstream) pass; the service-worker navigation test now covers `/auth/connect/<code>` and fails with the old denylist. Against an isolated password-protected source server (temporary XDG/DB/config dirs, no inherited `OPENCODE_*`) and the app-custom dev server, Playwright at 1440×900 and 390×844 verified: unauthorized lone server → connect screen with the URL prefilled; a real `POST /api/pair` link pasted into the connect screen and into the Add server dialog is redeemed and stored as the base URL plus token, surviving reload; a spent link shows the expired error in both places; the manual password path still connects; with a wrong stored password the credentialed `/api/event` requests drop from 5 to 0 in 5 s (base `cde61cb22` keeps reconnecting) and a fresh link recovers the server. QR scanning of links was not exercised (no camera). App-custom unit suite, typecheck, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream reworked pairing in #53257 (one-time pairing links across the GUI), #53588 (every pairing address in QR codes), #53837/#53844/#53962 (remote pairing through OpenTunnel), #53278 (QR scanner worker, whose CSP part is merged) and #53731. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`. `fix(app): port one-time pairing improvements` ports the functional parts of #53257 and the consumer side of #53588 (multi-address `{ code, urls }` payloads, expired versus unreachable, first-address preference, controller renewal on new credentials) while keeping the custom decoders, result shape and form (see their entries); remote OpenTunnel links need no app change. Upstream's link/password form redesign, Settings/Home re-authentication actions and #53731 remain unported.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Unified session project resolution — https://github.com/anomalyco/opencode/pull/51288

- **Kind:** adaptation
- **Reviewed upstream revision:** `ee5b67eb84358067c8119fca269bb58154e32250` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): unify session project resolution`; `packages/app-custom/src/shell/layout/{helpers.ts,helpers.test.ts}`, `src/runtime/server/runtime.tsx`, `src/shell/titlebar/{tab-nav.tsx,titlebar.tsx}`, `src/session/{session-identity-header.tsx,screen.tsx,timeline/message-timeline.tsx}`, `src/shell/commands/palette.ts`, and `src/home/sessions/{records.ts,records.test.ts,controller.tsx}`. Same resolver as upstream: a unique project-ID match wins, while projects sharing an ID resolve by exact directory, then sandbox, then the most specific ancestor root; `projects.forSession` prefers opened projects (keeping the custom per-workspace icon override from `enrich`) and `projects.detailsForSession` keeps synced worktree metadata with the opened project's name and icon for the summary and timeline. Wired into the horizontal tab strip, mobile titlebar, new-draft target, session identity header, timeline header/avatar, session summary, command palette, and Home session records. Chat sessions keep resolving to no project: the tab strip, header, palette, and Home records already skip chats, and the mobile titlebar now skips them too because the shared resolver also consults synced projects. The custom summary keeps its avatar prop rather than upstream's `ProjectIcon` swap. The custom sidebar keeps its own directory-first inventory and is not changed.
- **Tests:** new helper tests (shared-ID precedence; details metadata plus appearance) and a Home records test fail on `cde61cb22` and pass; app-custom unit suite, typecheck, and root `bun run check` pass. Against the mock server with two opened projects sharing an ID, the session in the worktree shows the worktree project's avatar in the 390×844 mobile titlebar (`cde61cb22` showed the main repository) and in the 1440×900 horizontal tab.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the same consumers in #53727 (recent sessions in the empty palette), #53761, #51973, #53268, #53247, #53332, #53297, #52639, #52620 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. The new-session project selector, not one of these consumers, gains #52230's resolved-ID fallback in `fix(app): port upstream robustness fixes`, applying the same shared-ID preference for the most specific containing root (see its entry). `fix(app): port upstream mobile and layout fixes` ports #53297's phone titlebar clearance (see its entry), which does not touch project resolution. `fix(session-ui): port upstream timeline fixes` ports #52639's title fade split in `SessionTitleHeader` (see its entry), which does not touch project resolution either.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Settings destination in the URL — https://github.com/anomalyco/opencode/pull/50364

- **Kind:** adaptation
- **Reviewed upstream revision:** `27dfac3d3640fc9285640c0e613e38b07309b206` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): keep settings destination across reloads`; `packages/app-custom/src/settings/{route.ts,route.test.ts,surface.tsx,shell.tsx}`, `packages/app-custom/src/runtime/server/registry.tsx`, `packages/app-custom/src/shell/titlebar/{history.ts,history.test.ts}`, `packages/app-custom/e2e/regression/settings-route-refresh.spec.ts`, and URL expectations in three existing settings specs. The settings `tab`, `server`, `project`, and `subtab` are parsed and validated from `/settings?...` using the custom page list (including `snippets`); search reveal state (`target`, `searchActivation`) stays in history state, and only those fields are read from older history entries that stored a whole view. Unlike upstream, a project page records `parent=server` when it was opened from a server's project list, because custom projects can also be opened from the root all-servers list and back navigation follows the origin rather than the server count. The redirect of a missing server waits for the persisted server list (`hydrated`, as upstream exposes it); custom has no WSL/SSH inventory in that list and no upstream single-server redirects, so none are added. Titlebar history replaces one entry across settings URLs. Not ported: `SettingsSearchField` and the keybind/model/project search changes of the same PR.
- **Tests:** route parse/serialize tests (custom pages, project origin, invalid combinations, stale history state) and the upstream titlebar history test pass; the new Playwright regression at 1440×900 and 390×844 reloads a root page (Snippets) and a project Extensions → LSPs page and returns to root Projects; it fails on `cde61cb22` (URL stays `/settings`). App-custom unit suite, typecheck, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the settings shell in #53731 (configurable default server removed), #53257, #53267, #53511 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(app): port upstream mobile and layout fixes` ports #53511's filled clear icon to the manage-models search (see its entry); the settings shell is unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### MCP resource mentions as read references — https://github.com/anomalyco/opencode/pull/50680

- **Kind:** adaptation
- **Reviewed upstream revision:** `33b686feb9f5c4b668b4584ae46746f1dfba2ef3` (commit reviewed), 2026-09-28
- **Local change:** `fix(app): send MCP resource mentions as references`; `packages/app-custom/src/composer/{request.ts,submit.ts,submit.test.ts}`. Upstream removed the composer `@resource` suggestion and exposed `list_mcp_resources`/`read_mcp_resource` as Code Mode tools. The custom composer keeps the suggestion, but no longer sends a selected resource as a `file` attachment (core accepts only `file:` URIs, and a `file:` URI would read a local server file). Each resource in the prompt or quote comments, including resources restored from old drafts or history with `source.type === "resource"`, is sent as the text line `MCP resource <uri> (server: <server>)` after the prompt text, for prompts and slash commands. It is a reference for the model to read, not pre-attached content. The model reads it through `read_mcp_resource`, which is only reachable inside Code Mode, so it requires the agent's `execute` permission and the tool's `opencode_read_mcp_resource` permission. The draft schema is unchanged.
- **Tests:** new submit tests for prompts and commands fail on `cde61cb22` (resource sent as a `file` attachment) and pass; app-custom unit suite, typecheck, and root `bun run check` pass. A one-off Playwright check against the mock server at 1440×900 and 390×844 selected the `@guide` suggestion and captured the admitted text line with no files.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** the `list_mcp_resources`/`read_mcp_resource` tools are unchanged, and the upstream composer changes in this range (#53076, #52620, #52217, #52868, #52369) do not touch resource mentions. The custom delivery stays.
- **Status:** active
- **Reconcile or remove when:** upstream changes composer resource mentions or the MCP resource tools; compare and update the custom delivery
- **Installation:** none
- **Result after upstream:** pending

### Theme seeds, light contrast, and token typos — https://github.com/anomalyco/opencode/pull/50517

- **Kind:** adaptation
- **Reviewed upstream revision:** `b4866520679e7a74c688223b30356d1c29f18e4f` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(ui): port theme contrast and seed fixes`; `packages/ui-custom/src/theme/{color.ts,color.test.ts}` and `packages/ui-custom/src/theme/themes/{catppuccin-frappe,catppuccin-macchiato,catppuccin,kanagawa,oc-2}.json`. `color.ts` and the four Catppuccin/Kanagawa themes were identical to upstream `8ce629be2`, so they now match upstream `dd786c62a` (WCAG green luminance weight, corrected light/dark seeds and overrides). In `oc-2.json` only the `icon-weak-base` typo (`#C7C7C7`) is ported; the custom theme name and `v2-icon-icon-faint` value are kept.
- **Tests:** new `color.test.ts` fails on `cde61cb22` (12.74 instead of 15.3 for green on black) and passes; ui-custom theme tests and typecheck and root `bun run check` pass. The four themes rendered a session in light and dark at 1440×900 and 390×844 against an isolated mock server.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream's theme files changed only in the #53444 blank-line autofix; no behavior to port.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Return composer focus after picking files — https://github.com/anomalyco/opencode/pull/50864

- **Kind:** adaptation
- **Reviewed upstream revision:** `9c8a63e852722a9bced4a0de1179de58a85dfa20` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): return composer focus after picking files`; `packages/app-custom/src/composer/{attachments/attachments.ts,editor/interaction.ts}` and `packages/app-custom/e2e/regression/composer-file-picker-focus.spec.ts`. Ports only the focus return: the native picker resolves through a completion callback and the browser file input's change handler restores focus to the composer that started the pick. The thumbnail `<Suspense>` is not ported; the custom keyed attachment rows, stable blob resource, and `url.latest` preview already avoid detaching the session. Focus targets only the picking composer; while `/btw` hides the main editor, focusing it is a no-op and CodeMirror does not move the DOM selection of an unfocused view, so the visible side composer keeps focus.
- **Tests:** the new Playwright regression at 1440×900 and 390×844 fails on `cde61cb22` (editor inactive after picking) and passes with the fix, including typing into the editor. A one-off Playwright check (not committed) completed a pending pick after opening `/btw`: the side composer kept focus and received the typed text. App-custom typecheck and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the composer files in #53076, #53267, #53707, #52217 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`. `fix(app): port upstream robustness fixes` ports #53707 (see its entry) without changing the picker focus return; the other changes are not ported yet, so compare and port selectively. Of #53267, only the phone titlebar clearance is ported, by `fix(app): port upstream mobile and layout fixes` (see its entry); it does not touch the composer.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Attachment remove buttons on touch devices — https://github.com/anomalyco/opencode/pull/51047

- **Kind:** adaptation
- **Reviewed upstream revision:** `dca73ba9e3782e2b41983faca5854a9d56a3c482` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): show attachment remove buttons on touch devices`; `packages/app-custom/src/composer/editor/editor.tsx` and `packages/app-custom/e2e/regression/composer-attachment-touch.spec.ts`. Comment and attachment remove buttons use the existing `hover-reveal` utility, so they stay visible when the device cannot hover. The custom staged-upload cancel button is already always visible and is unchanged; upstream's component story test is replaced by an e2e regression because the custom packages have no Storybook stories.
- **Tests:** the new Playwright regression (touch, 390×844) fails on `cde61cb22` (opacity 0) and passes with the fix, including tap-to-remove; app-custom typecheck and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the composer editor in #53076, #53267, #52217 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. Of #53267, only the phone titlebar clearance is ported, by `fix(app): port upstream mobile and layout fixes` (see its entry); it does not touch the composer editor.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Keep the session mounted when switching models — https://github.com/anomalyco/opencode/pull/50865

- **Kind:** adaptation
- **Reviewed upstream revision:** `fabf56781cee45b6ebe5aecd4b7b4c7bf5033fa5` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): keep timeline mounted when switching models`; `packages/app-custom/src/runtime/server/runtime.tsx` and `packages/app-custom/e2e/regression/session-model-switch-mount.spec.ts`. Same approach as upstream: model recents suspend readers only until persisted state loads, then read the store directly, so pushing a recent no longer puts the session route into its Suspense fallback. The custom `createGlobalModels` keeps its legacy `models` preference import, remote profile sync, and `user`/`variant` proxy.
- **Tests:** the new Playwright regression at 1440×900 and 390×844 fails on `cde61cb22` (timeline viewport detached, scroll lost) and passes with the fix (5 repeats each); app-custom typecheck and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream's `runtime.tsx` changed for per-credential server controllers (#53257) and `serverCtx` (#52369), not for model recents; the port stays as is. `fix(app): port one-time pairing improvements` ports the per-credential controllers (see the #53257 entry) without touching model recents.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Compatibility skill watcher storm — https://github.com/anomalyco/opencode/commit/7784b3ee0d033da3eab101e45882387f4a3e1eaa

- **Kind:** adaptation
- **Reviewed upstream revision:** `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26; `compatibility.ts` only lost an unused import), 2026-10-11; previously `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (`upstream/v2`, where `compatibility.ts` is still identical to the version introduced by `7784b3ee0d033da3eab101e45882387f4a3e1eaa`), 2026-09-28; previously `affa57e40f44fbd294c18199ecab5879c0ae0d70`, 2026-09-23
- **Local change:** `fix(core): stop compatibility skill watcher storms`; `packages/core/src/config/plugin/compatibility.ts`, `packages/core/test/config/skill.test.ts`. There is no upstream fix. Upstream reloads on every raw `config.changes()` event without a debounce, and every refresh runs `FiberMap.clear` and resubscribes all watches. Every Location runs the plugin, so a single event under `~/.agents` or `~/.claude` became N×events full rescans, native watcher restarts, and `skill.updated` notifications. That storm froze the shared server (observed on 2026-09-23: ~30k refreshes in 22 minutes). Locally: config changes are filtered to `.claude`/`.agents` roots and share the existing 100 ms debounce; watches are reconciled so only watches that left the source set are released; claude and agents roots that resolve to the same directory are scanned once; `ctx.skill.reload()` runs only when the loaded skills changed. Related open issues: https://github.com/anomalyco/opencode/issues/47505 and https://github.com/anomalyco/opencode/issues/50594.
- **Tests:** `bun test test/config test/filesystem` in `packages/core` (281 pass); the new `ConfigCompatibilityPlugin.Plugin` test fails against the upstream file (6 reloads for a 5-event burst) and passes locally; full `packages/core` suite passes except the environment-only `preload.test.ts` home isolation check; `bun run check` passes.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed `compatibility.ts` only by dropping an unused import (#52659); the storm fix is still needed.
- **Status:** active
- **Reconcile or remove when:** upstream changes `packages/core/src/config/plugin/compatibility.ts` to debounce or filter `config.changes()` and to stop restarting unchanged watches (for example, a fix for #47505 or #50594); then compare behavior and keep only what upstream still lacks.
- **Installation:** none
- **Result after upstream:** pending

### Custom timeline tool groups and notices — [#48594](https://github.com/anomalyco/opencode/pull/48594), [#48909](https://github.com/anomalyco/opencode/pull/48909), [#48932](https://github.com/anomalyco/opencode/pull/48932), [#49045](https://github.com/anomalyco/opencode/pull/49045), [#48895](https://github.com/anomalyco/opencode/pull/48895), [#47821](https://github.com/anomalyco/opencode/pull/47821)

- **Kind:** adaptation
- **Reviewed upstream revision:** `41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3`, `93a37958a78c81d211240dbe7cc53b04754e7221`, `f1149efee7ce08f7d819c48d8b69482441bd0592`, `4fa6ca00e5500cb8d6419bc013fcbb00ce9958c7`, `a71bb4d38c3397173726ac581c27a31e9f5eba99`, `2816d1c849cc1a103f90e0215966c8080d65e95f` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/session-ui-custom/src/{timeline,tools,components/message-part.css}`, related component tests, and `packages/ui-custom/src/i18n/en.ts`. Keep compaction/model dividers separate, narrow Notice to exclude idle, group edit/write/patch diffs, remove the titleless sticky gap, label arbitrary search providers, and use Updates styling for notice-only groups. Preserve custom empty-file write rows and custom imports; #47821 is type parity only because idle filtering and backend contracts already exist.
- **Comparison at `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`:** #50356's gap-based count spacing is ported; #50204's structured notice metadata, legacy fallback and localized lists are ported by `feat(i18n): port structured notices and localized lists`. Upstream's flattened tool-group title is intentionally not taken: the custom segmented count/title and grouping remain, verified by the spacing and structured-notice regressions.
- **Tests:** custom package typechecks and root `bun run check` passed; all 209 session-ui unit tests passed. All 30 focused file-tool, patch-group, tool-group, and session-tool-projection component cases passed across the initial run and focused reruns after adapting grouped-file assertions (installed Chrome channel). Notice disclosure also checked at 390×844 with English text and forced RTL.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the same timeline in #52207, #52210, #52876, #53815 (latest thinking heading while streaming), #51090, #52009, #53338 and #53832. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(session-ui): port upstream timeline fixes` ports #52876, #53815 and #52009 (see their entries) while keeping the segmented titles, grouped edit/write/patch diffs and Updates grouping; only the moved notice leaves Updates, as a divider. #52207, #52210, #51090, #53338 and #53832 are not ported yet.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom tab gestures and compact icons — [#49964](https://github.com/anomalyco/opencode/pull/49964), [#49460](https://github.com/anomalyco/opencode/pull/49460)

- **Comparison at `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`:** #51064 is ported in `97abe55e5` (root-grouped nested tabs and ancestor trail); #51288 in `bc4e2c9f7` supplies shared project identity to tab/sidebar consumers. Touch thresholds, non-modal menus, drag-navigation suppression, compact icons and the mobile drawer's no-reorder guard remain custom. Neither identity change replaces the gesture implementation; desktop and 390×844 navigation checks are recorded in those entries.
- **Kind:** adaptation
- **Reviewed upstream revision:** `7020944359f9d6500d743ad7ba03d5d441e475bf`, `a5b3802ca3fcb95331fb56f3532c2b28b293b7ca` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/src/shell/titlebar/{tab-gesture.ts,tab-gesture.test.ts,tab-nav.tsx,tab-nav.css,tab-strip.tsx}`. Port touch thresholds, non-modal context menus, vertical drag navigation suppression, and compact icon container rules. Retain the custom `onReorder` guard: the inventory-sorted mobile drawer intentionally supplies no reorder callback, while reorderable strips support touch.
- **Tests:** app-custom unit/browser suites, typecheck, and root `bun run check` passed. Isolated 390×844 browser checks confirmed touch menu dismissal and retained inventory order after touch movement; desktop custom draft-strip touch drag reversed two drafts without navigation.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the tab strip in #51973 (recently closed tabs menu), #53076 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom app startup compatibility — [#48621](https://github.com/anomalyco/opencode/pull/48621)

- **Kind:** adaptation
- **Reviewed upstream revision:** `c4fe0f676a070a78e76385bfd8c10470f24ac3bd` (commit reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/{package.json,src/entry.tsx,src/runtime/polyfills.ts}` and `bun.lock`. Import Map.groupBy and Promise.withResolvers polyfills before startup, reusing upstream's locked core-js 3.50.0 version. Custom-package paths only; lockfile updated with `bun install`.
- **Tests:** app-custom build, typecheck, unit/browser suites, and root `bun run check` passed. Isolated built UI loaded after deleting both APIs before page startup; grouping and deferred-promise resolution succeeded.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream's `polyfills.ts` adds `core-js/es/promise/try` for Safari before 18.2 (#52369); not ported. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom scrollbar mount measurement — [#49778](https://github.com/anomalyco/opencode/pull/49778)

- **Kind:** adaptation
- **Reviewed upstream revision:** `c3bf8864b9d4c82506c01bf9f47f8977bfbc197b` (commit reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/ui-custom/src/components/scroll-view.tsx`. Let ResizeObserver perform the first layout measurement and defer the reactive remeasurement effect. Same behavior in the custom component, preserving its other customizations.
- **Tests:** ui-custom typecheck and all 109 unit tests passed; root `bun run check` and app-custom production build passed. Built UI exercised at 1440×900 and 390×844.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream's `scroll-view.tsx` changed only in the #53444 blank-line autofix; no behavior to port.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom session and workspace UI polish — [#49668](https://github.com/anomalyco/opencode/pull/49668), [#50265](https://github.com/anomalyco/opencode/pull/50265), [#49122](https://github.com/anomalyco/opencode/pull/49122), [#49080](https://github.com/anomalyco/opencode/pull/49080), [#48927](https://github.com/anomalyco/opencode/pull/48927), [#50437](https://github.com/anomalyco/opencode/pull/50437), [#49779](https://github.com/anomalyco/opencode/pull/49779), [#48735](https://github.com/anomalyco/opencode/pull/48735)

- **Comparison at `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`:** `bc4e2c9f7` ports #51288's unified project resolution into the shared custom server context and its session/sidebar consumers. It uses canonical project identity without replacing explicit worktree selection, custom chat admission, non-VCS review behavior, file labels, closed-panel animation or untitled labels. The resolver tests and two-viewport checks are recorded in the dedicated #51288 entry.
- **Kind:** adaptation
- **Reviewed upstream revision:** `3355c93efdb5b5c69873d81eec0a93fa849d385e`, `8aebed170a14d3e3d841883dd2d3d171529d745c`, `73e7b7bc7935380f284c8b4607a973838c2f1424`, `23402629c59e3c8a68f88ddc86882ac5bf501ff5`, `0a3dc169613f98300d71a778a6cf7f40b04fee74`, `51d2b667600386684822ef6a9eff64f59542bdc5`, `b447627f5f6662b018e29e7769f5d02d3da2845c`, `b629b458f70ab46d0c2097007ee111e9b3de1fc2` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/src/{new-session/composer-adapter.ts,session/review,session/timeline/controller.tsx,workspaces/files/model.tsx,runtime/i18n/en.ts,index.css,settings/keybinds/keybinds.tsx}`. Use canonical roots for local sessions while preserving explicit worktree selection and custom chat admission; make non-VCS review ready/empty; derive listed basenames; shorten queued attachment/context labels; retain closed panel animation state; import the shortcut search icon eagerly; align untitled session labels. The custom timeline controller delegates deletion elsewhere, so only its three existing fallback sites change.
- **Tests:** app-custom typecheck, 1,118 unit tests (one existing skip), 219 browser-runtime tests, production build, and root `bun run check` passed. Isolated desktop UI showed the non-VCS review empty state instead of indefinite loading; shortcut search kept focus while typing at 1440×900 and 390×844.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed the same session/review files in #53445 (commit staged revert before switching selection), #53076, #52217 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Go monthly pricing copy — https://github.com/anomalyco/opencode/pull/50473

- **Kind:** adaptation
- **Reviewed upstream revision:** `643c4c35006f9aef6f8513c51c2e9a99f22aa0f0`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/ui-custom/src/i18n/*.ts`. Ported the exact upstream $10/month description into all 62 affected custom locales, preserving unrelated custom strings. Console service, billing, and documentation changes are outside this web product port.
- **Tests:** verified every changed locale value against the reviewed upstream diff; ui-custom `bun run test` (109 pass), ui-custom typecheck, app-custom build, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** the ported strings are unchanged upstream.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Anthropic connection copy — https://github.com/anomalyco/opencode/pull/49369

- **Kind:** adaptation
- **Reviewed upstream revision:** `54f23561668ede605ec764b22ee36158681bb14f`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/runtime/i18n/*.ts`. Ported the exact upstream English API-key/Anthropic wording and removed both stale Pro/Max keys from all 62 affected non-English locales so the English fallback applies.
- **Tests:** verified all 63 affected locale files against the reviewed upstream diff; app-custom unit/browser suites, typecheck/build, and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** the ported strings are unchanged upstream.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Failed-send history and bounded toasts — https://github.com/anomalyco/opencode/pull/49717

- **Kind:** adaptation
- **Reviewed upstream revision:** `dd71cdbd840f8bc875fd516c39c8e29f199c5b84`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer/{history,model.ts,submit.ts}`, `packages/ui-custom/src/feedback/toast`. Removes restored failed submissions from history with custom quote-aware matching. Bounds toast descriptions to 2,000 characters before deduplication and retention.
- **Tests:** actual failed admission/retry history tests, history matching tests, ui-custom toast bound test and suite, package typechecks and root check.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed composer history and submission in #53076, #53445, #53270, #53267, #52620 and #52868. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. Of #53267, only the phone titlebar clearance is ported, by `fix(app): port upstream mobile and layout fixes` (see its entry); it does not touch composer history or submission.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Preserve native clipboard paste — https://github.com/anomalyco/opencode/pull/49424

- **Kind:** adaptation
- **Reviewed upstream revision:** `acfacede2d96fb6adf59b826491d3339d5d95261`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer/editor/interaction.ts`. Uses upstream's attachment-paste guard while leaving ordinary and non-plain text paste to CodeMirror and preserving structured Session paste and custom image citation insertion.
- **Tests:** clipboard guard tests for missing data, HTML/RTF, native image reading, and files; existing attachment ownership/reference tests; desktop/mobile paste and remove/undo checks.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed `interaction.ts` in #53076 and #53707. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`. `fix(app): port upstream robustness fixes` ports #53707's slash-action change (see its entry), which does not touch paste handling; #53076 is not ported yet, so compare and port selectively.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Timeline attachment classification — https://github.com/anomalyco/opencode/pull/49932

- **Kind:** adaptation
- **Reviewed upstream revision:** `5848ee0d24ba273dea17daa084e4634ac8bf5b16`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/session-ui-custom/src/{components/message-file.ts,message/message-content.tsx}`. Ports final upstream `attached()` semantics: mentions and unmentioned file-URI context are not inline attachment cards. Staged paths continue to render through the custom attachment-reference metadata.
- **Tests:** classification tests, session-ui-custom suite (209 passing), package typecheck and root check.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed message rendering in #53112 (model variant in meta), #53338, #53880, #53076 and #52369. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(session-ui): port upstream timeline fixes` ports #53112 for user message metadata only (see its entry); attachment classification is unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Rich artifact tabs in the custom browser UI — https://github.com/anomalyco/opencode/pull/49882

- **Comparison at `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`:** #51000 is selectively ported in `87163c04d` as an inline-SVG GitHub mark on external Markdown links. It does not replace the custom local-link/inline-path resolver, rich file/directory tabs or sandboxed browser previews. Third-party favicons and upstream favicon image handling are excluded, so the mark introduces neither an external request nor an artifact-image preview target; desktop/mobile regression evidence is in that entry.
- **Kind:** adaptation
- **Reviewed upstream revision:** `60ed84ecd193ce09f1343cbea074fc2aa8e4a554`, 2026-09-23
- **Local change:** `feat(app): port rich artifact tabs and timeline image previews`; `packages/app-custom/src/session/files`, `src/session/screen.tsx`, `src/session/browser`, `src/workspaces/files`, `src/runtime`, `packages/session-ui-custom/src/components/markdown*`, `src/context/markdown.tsx`, and `packages/cli/src/services/web-ui.ts`. Local markdown links and inline path references open existing custom file tabs; mobile opens the existing Files view. Ported media/document/table/font classification and viewers with compact preview/source/download controls rather than upstream's metadata toolbar. Browser-only HTML stays in an opaque-origin sandbox instead of Electron file URL handoff; nested Markdown references resolve relative to the artifact. Preserves custom timeline, side-panel, and mobile layout. The shared web shell CSP minimally allows blob frames, media, and fonts so installed browser previews work; script policy is unchanged.
- **Tests:** app-custom unit and browser suites pass; session-ui-custom unit suite passes; app-custom and session-ui-custom typechecks and root `bun run check` pass; app-custom production build passes; CLI `bun test test/web-ui.test.ts` passes (2 tests). Playwright real built UI fixtures at 1440×900 and 390×844 verify rich tab opening, nested links, inline-reference keyboard activation, source/preview switching, touch tab closing, sandboxed HTML, and no horizontal viewport overflow.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed artifacts and Markdown in #53305 (Word, Excel and PowerPoint previews), #53100 (Windows-path Markdown images), #52231 (session-ID links), #53665, #53247/#53332 and #52369/#53078. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(session-ui): port upstream timeline fixes` ports #53665 (see its entry): Markdown in artifact tabs is now selectable under the shell's `select-none`; the artifact viewers and previews are unchanged.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Timeline image attachment previews in custom UI — https://github.com/anomalyco/opencode/pull/49111

- **Comparison at `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`:** #51000's GitHub mark (`87163c04d`) uses a CSS pseudo-element, preserving the custom Markdown/Read image preview and keyboard/touch controls. Upstream favicon `<img>` classification and preview changes are not copied because this port creates no image node. The GitHub-mark tests at both sizes assert no preview button/image is introduced by the mark.
- **Kind:** adaptation
- **Reviewed upstream revision:** `24dff6929dce6ed4a90f53e65dbd80df5f014e83`, 2026-09-23
- **Local change:** `feat(app): port rich artifact tabs and timeline image previews`; `packages/session-ui-custom/src/components/image-preview.tsx`, `src/components/markdown.tsx`, `src/components/markdown.css`, `src/components/message-part.css`, `src/tools/tool-renderer.tsx`, and component fixtures/tests. Reuses the existing `@opencode/ui-custom/image-preview` attachment dialog for Markdown and Read-tool images, including keyboard activation and touch-close controls. Custom message attachment behavior is preserved.
- **Tests:** session-ui-custom `bun run test` passes (221 tests); app-custom Playwright built UI tests at 1440×900 and 390×844 pass for Markdown and Read-tool image preview, keyboard activation, Escape, and close control; both custom package typechecks and root `bun run check` pass.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed Markdown and tool rendering in #52231, #52389, #53665, #52876 and #53832. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. `fix(session-ui): port upstream timeline fixes` ports #53665 and #52876 (see their entries); image previews keep their controls (images are not text and the controls keep `user-select: none`).
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Mobile-friendly /btw peek panel — https://github.com/anomalyco/opencode/pull/49750

- **Kind:** adaptation
- **Reviewed upstream revision:** `dcfe1ec7bd4922d4f44c141ba33047402bffc57e`, 2026-09-23
- **Local change:** `feat(app): add mobile-friendly side question panel` (`223dc0836`), `fix(app): refine side question history and cancellation`; `packages/app-custom/src/session/btw/`, custom composer command/selection integration, command shortcuts, and English source strings. Uses the same abortable `session.generate` backend and verbatim side-question instructions as upstream #49750. The Solid UI is modeled on OpenChamber's MIT-licensed `useBtwStore`, `BtwPanel`, and `ComposerFloatingPanel`: a responsive panel docked above the composer, compact collapsed chip, explicit cancel, and touch dismissal. Entry points are `/btw`, `/btw <question>`, command palette, Mod+Shift+B, and selected assistant text. Mobile Enter inserts a newline and desktop Enter submits. Up to five completed side Q&A pairs are kept per session, with bounded plain-text context included in subsequent generate prompts. State survives in-app navigation for the 20 most recently used sessions per server, but not reload; session changes/unmount cancel pending requests. OpenChamber is UI/UX inspiration only: no forks, metadata links, synthetic messages, plugin hooks, backend changes, or durable side history. The server chooses the current session model/context and returns the complete answer without token streaming.
  `fix(app): use compact composer for side questions` replaces the plain textarea with the production CodeMirror `ComposerEditor`, following `QuoteCommentEditor`: memory-backed rich drafts and the main composer's context/file/snippet completion. Compact mode has an opt-in to the standard composer submission keys; quote-comment behavior stays unchanged. Snippets expand through `expandSnippets`, app/session references use the shared context formatters, and file/agent/skill references remain textual mentions. Binary attachment parts are omitted (typed citations remain text); the side editor does not read or upload files. Rich drafts survive collapse, navigation, and cancellation.
  `feat(app): ask side questions from the main composer` follows OpenChamber's composer UX while keeping native `session.generate`: while the panel is expanded, a full-size `ComposerEditor` (`btw/composer.tsx`) takes the main composer's place and the main editor stays mounted but hidden, keeping its draft and editor state. The side composer has no add menu, attachments, shell mode, or agent/model/variant pickers; it shows the session's committed model read-only, because generate uses it. Submit clears the field immediately; cancellation or failure returns the draft unless something new was typed. The submit button stops a pending question (Esc also stops it). Esc otherwise collapses the panel, or closes it when nothing was asked yet; focus and type-to-focus follow the visible composer. The panel only shows the conversation (question bubbles, markdown answers, bottom-following scroll, header spinner), and the queue panel plus main-composer attach/shell commands are hidden or disabled while the side composer is active.
- **Tests (main-composer UX):** app-custom `bun typecheck`, `bun run test:unit` (1239 pass, 1 skip), root `bun run check`, and `git diff --check` pass. `bun run test:browser` has 219 pass and 3 sidebar failures (`sidebar-search`, `sidebar-pins`, `sidebar-worktrees`) that fail identically on the unchanged base. Playwright CLI verified an isolated source server with copied config and credentials against a real provider: Mod+Shift+B and `/btw <question>` entry, immediate clearing, stop with draft restoration, answer rendering, Esc collapse/close, header reopen/dismiss, preserved hidden main draft, type-to-focus into the side composer, and 1440×900 plus 390×844 layouts.
- **Tests:** after merging `origin/ui-integration`, app-custom `bun run typecheck`, `bun run test:unit` (1155 pass, 1 skip), `bun run test:browser` (221 pass), `bun run build`, root `bun run check`, and `git diff --check` pass. Tests exercise real generated-client HTTP boundaries, Q&A history/cancellation, rich draft retention, snippet expansion, app/session formatting, and binary omission. Playwright CLI verified the built app at 1440×900 and iPhone 390×844: `/btw`, `#` snippet suggestions/expansion, `@` file search/selection, rich drafts through collapse/reopen, desktop Enter, mobile Enter newline without sending, touch Ask, and focus restoration to the main composer. Prior checks also covered pending/cancel/error, navigation isolation, and all command entry points. The isolated server strips inherited `OPENCODE_*` variables and explicitly sets config paths/content; `/api/info` confirmed its PID/version and `/api/provider` returned `data: []` before sends. Generation uses HTTP-boundary fixtures; no real provider calls.
- **Comparison at `5e73d5cb1f788637b1b3d5cf1298ea694cbad0c5` (2.0.26):** upstream changed /btw in #53270 (keep each answer in its own tab until closed) and the surrounding session UI in #53267, #53445, #53727 and #53761. Custom port kept unchanged by `chore: merge upstream v2 (2.0.26) into custom`; upstream changes not ported yet, so compare and port selectively. Of #53267, only the phone titlebar clearance is ported, by `fix(app): port upstream mobile and layout fixes` (see its entry); it does not touch /btw.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

## Resolved entries

### Custom direct-link QR scanning — [#49971](https://github.com/anomalyco/opencode/pull/49971), prerequisite [#49291](https://github.com/anomalyco/opencode/pull/49291)

- **Kind:** adaptation
- **Reviewed upstream revision:** `788f0affcbec8b3609eb943977e6da36ae02ddf9`, `080b7671dea45a693b537c1e358e89ab14463d0d`, 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/src/servers/connect/{pairing.ts,pairing.test.ts,scanner.tsx}`. Raw JSON, legacy query/fragment codes and direct base64url /connect links, including optional URL payload/origin fallback; desktop pairing UI/link generation excluded.
- **Tests:** original three decoder cases, app-custom typecheck and root check passed; the one-time pairing entry records its additional redemption/unauthorized tests.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #49971/#49291 merged in the reviewed revisions; integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` adds #50970/#50972. Custom port kept and extended by `27ef86db6` (`fix(app): redeem one-time pairing links`): scanner, connect screen and server dialog redeem `/auth/connect/<code>` while retaining legacy decoders. The obsolete statement that CLI links were unsupported is superseded. Reconciliation recorded by `docs: reconcile upstream UI overrides` in this file; no upstream follow-up remains for the original port.

### Console account visibility with a Zen key — https://github.com/anomalyco/opencode/pull/50763

- **Kind:** adaptation
- **Reviewed upstream revision:** `3bf8a5a8cfb4826d9c06f35898b6cb42670385cf`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/settings/providers/{providers.tsx,popular.ts,popular.test.ts}`. Credential-method filtering in a tested helper, retaining custom server scope and ordering.
- **Tests:** original Popular-list cases cover fresh installs, stored keys, OAuth and catalog loading; unit suite 1120 pass/1 skip, package typecheck and root check passed.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #50763 merged as the reviewed revision; compared with integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`, `packages/app/src/settings/providers/providers.tsx` popular filter. Custom `popular.ts` uses the same first credential connection's `method !== "oauth"` rule and the same no-account deduplication. Port kept; account switching (`1f832d354`) and selective Console feedback (`549d22ec5`) preserve it. Decision recorded by `docs: reconcile upstream UI overrides` in this file; no follow-up remains.

### Console browser sign-in — https://github.com/anomalyco/opencode/pull/50267

- **Kind:** adaptation
- **Reviewed upstream revision:** `fbacf6a1268473e38788d196cf60ddfab3b47e27`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/providers/connect/{controller.ts,dialog.tsx}`, `src/settings/providers/providers.tsx`, `src/runtime/server/{types.ts,global-sync/utils.ts}`, `src/runtime/i18n/en.ts`, `test-browser/{provider-connection.test.ts,fixtures/provider-connection.ts}`. Shared Zen/Go OAuth, defaults, non-suspending loading, browser link, polling/retry/expiry/cancellation, Go keys, account badges and integration-aware disconnect. Native popup-blocked fallback, custom styling and visibility preferences retained; composer/icon redesign excluded.
- **Tests:** original unit suite 1120 pass/1 skip, browser suite 220 pass, controller fixture 10 pass, typecheck/build/root check passed; original isolated 4185 Chrome 1440×900 and WebKit 390×844 checks covered real start, native fallback, key switching/cancellation and injected failure/retry. `549d22ec5` adds 14 controller and 3 remote cases plus isolated Chrome checks at both sizes; no real Console authorization completed.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #50267 merged in the reviewed revision; compared against integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`. Port kept and selectively updated for #51266 in `1f832d354` and #48501 in `549d22ec5`. Conditional defaults, explicit refresh states/retry, actionable errors and remote disclosure adopted. Native links, cancellation after polling failure, Go keys, account badges/disconnect, model visibility and InlineServerSelect retained intentionally; model onboarding and Electron behavior excluded by decision. `docs: reconcile upstream UI overrides` records the completed reconciliation in this file; the newer selective-port entries document future comparisons.

### Center the conversation beside summaries — https://github.com/anomalyco/opencode/pull/49620

- **Kind:** adaptation
- **Reviewed upstream revision:** `1464545665ba892c2d2886f4456acc9a584aa156`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/index.css`. Centers the 1000px conversation beside the custom 280px panel within the 1320–1640px chat range, with RTL/reduced motion. #49429 was evaluated but excluded because the custom start screen has no summary cards.
- **Tests:** original root check, app typecheck/build, unit 1118 pass/1 skip, browser 219 pass, focused Playwright 8 pass and desktop/mobile inspection passed.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #49620 merged as reviewed; upstream diverged in #50386 (`f24fdeca7037804af8c30f21c9ddf65db1562b97`), integrated at `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`, removing the offset for an overlay. Custom `index.css` retains summary-open container-query translation and its RTL inverse deliberately, preserving custom centering. `docs: reconcile upstream UI overrides` records the keep-custom decision in this file; no pending port of #50386.

### Summary layout coordination — https://github.com/anomalyco/opencode/pull/48449

- **Kind:** adaptation
- **Reviewed upstream revision:** `9f3ba44c4a4a8ba3c9fa36694af06bb0a2baa367`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/session/{screen.tsx,review/model.ts,timeline/message-timeline.tsx}` and `src/index.css`. Summary-open coordination, edge anchoring, bounded scrolling and resize offset freezing in the custom popover; mobile drawer retained.
- **Tests:** original LTR/RTL translation, resize settlement, close and drawer dismissal regressions; app typecheck, unit/browser suites and build passed.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #48449 merged as reviewed; #50386 (`f24fdeca7037804af8c30f21c9ddf65db1562b97`) in integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` removes upstream's offset coordination. Custom layout coordination is intentionally kept together with conversation centering and the mobile drawer. Completed keep-custom decision recorded by `docs: reconcile upstream UI overrides` in this file, with no upstream follow-up remaining.

### Expandable services and configuration — https://github.com/anomalyco/opencode/pull/48445

- **Kind:** adaptation
- **Reviewed upstream revision:** `41430842506e8952580a2fa1af25aa88d8ea896d`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/shell/status/{body.tsx,service-status.ts}`, `src/session/timeline/message-timeline.tsx`. Compact expandable services reuse configuration, retries, refresh subscriptions and custom LSP derivation instead of nested upstream popovers. Browser copy-path actions retained without native reveal.
- **Tests:** original status derivation tests and pointer/keyboard expansion of all four services, configuration actions/unclipped labels; package checks/build and root check passed.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #48445 merged as reviewed; #51001 (`8d5eb3bf9`) in integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` starts MCP sign-in on row click. Custom `StatusBody` already calls `useMcpToggle` from its row and switch handlers, preserving the same sign-in action through the custom service layout. Equivalent behavior retained, not duplicated. `docs: reconcile upstream UI overrides` records the finished decision in this file.

### Services in the custom session summary — https://github.com/anomalyco/opencode/pull/48103

- **Kind:** adaptation
- **Reviewed upstream revision:** `d6c22b3bf531533980dc633a1dac5e38c64fe458`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/session/{timeline/message-timeline.tsx,header/session-header.tsx,review/view.tsx}`, `src/shell/status/`, `src/runtime/i18n/en.ts`. Compact MCP/plugins/skills/LSP row, preserving project/location/changes/move/background tasks. Reuses custom status body, suppresses duplicate session status entry points and retains standalone status for drafts/children.
- **Tests:** original unit/browser suites, typechecks/build, focused service/header/mobile drawer checks passed; screenshots at 1440×900, 1024×900 and 390×844.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #48103 merged as reviewed; compared with integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`. #50386's overlay-only layout is intentionally declined, #51001 sign-in is already supplied by StatusBody/useMcpToggle, and #51288 project identity is ported in `bc4e2c9f7` while preserving the custom avatar. The custom services summary is kept with all identified follow-ups decided/applied. `docs: reconcile upstream UI overrides` records this reconciliation in this file.

### Staged composer attachments — https://github.com/anomalyco/opencode/pull/49467

- **Kind:** adaptation
- **Reviewed upstream revision:** `f04c3fd82bf98cb911f5c1c7b25f9cded0b86722` (#49467), `469e1c035ee3f1343f02b60c0aab22136fdb4f2a` (https://github.com/anomalyco/opencode/pull/49647), `90112f52db59a8f2ec412c66c6677193bf5dc7b8` (https://github.com/anomalyco/opencode/pull/49682), 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer`, `src/session/composer/queue.ts`, `src/shell/shell.tsx`, `src/runtime/i18n/en.ts`, `packages/ui-custom/src/feedback/toast`. Cancellable streaming for non-native/text/over-20-MiB files; path parts preserve custom CodeMirror attachment/reference algebra, image citations, undo, snippets, drafts/history and queue edits. Legacy blob/model-capability delivery adapter retained.
- **Tests:** original unit/browser suites, three package typechecks, root check/build and isolated 1440×900/390×844 checks covered 21-MiB progress, picker/paste, staged reference removal/undo and reload. `fix(app): expose sent attachment paths` added full-path affordances, image/PDF fixture capabilities and dropped-text streaming; the collapsed-path assertion also failed on `db3a4d551`, documenting the pre-existing missing affordance. Follow-up port entries record touch, focus and queued-prompt round-trip regressions.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** the reviewed attachment revisions are integrated in upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`. Custom composer retained; #51047 is ported in `bb0c512ac`, #50864 focus return in `489817bfa`, and #51124 queue undo in `f93b17bee`, preserving the full custom payload algebra and refusing unrestorable drafts. `3ce21be39` makes touch specs deterministic. All identified follow-ups decided/applied; `docs: reconcile upstream UI overrides` records completion in this file.

### Lazy draft image bytes — https://github.com/anomalyco/opencode/pull/49703

- **Kind:** adaptation
- **Reviewed upstream revision:** `47f66de8dda535de9f2e2c3bfdbeaad774ad6e82`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/runtime/persistence/drafts.ts`, `src/composer/{schema.ts,model.ts,submit.ts,editor/editor.tsx}`. Reads image bytes only for thumbnail/preview/delivery, keeping IDs, citation metadata and legacy delivery. `fix(app): preserve composer focus with attachments` keys rows by ID and thumbnail resources by blob ID, with synchronous existing URLs and `url.latest` for cold previews, avoiding session/editor suspension during edits.
- **Tests:** original draft/cache/persistence suites, package/root checks/build, reload and desktop/mobile focus/caret/detachment/thumbnail/remove/undo regressions. Focus cases fail on `3413919c7`; isolated 31-key-event measurements: `db3a4d551` image = 0 detachments, `3413919c7` image = 21 with lost focus, fixed image/21-MiB path = 0 at both sizes. Servers used empty providers and no inherited OpenCode environment.
- **Status:** resolved
- **Installation:** none
- **Result after upstream:** #49703 merged as reviewed, compared with #50864 in integrated upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e`. `489817bfa` ports picker focus return; custom keyed rows, stable blob resource and `url.latest` already avoid detachment, so upstream thumbnail Suspense is intentionally not adopted. Custom implementation kept with no remaining follow-up; reconciliation recorded by `docs: reconcile upstream UI overrides` in this file.

### Reread artifacts when opening a preview — https://github.com/anomalyco/opencode/pull/51036

- **Kind:** adaptation
- **Reviewed upstream revision:** `7460d855ac906d9f604fdf7beb934cc19dc2614b`, 2026-09-25
- **Local change:** `packages/app-custom/src/session/files/open-artifact.tsx` forces `file.load(path, { force: true })` when an agent-referenced path opens, matching upstream. The same custom change also opens directory references as listing tabs (custom-only): a failed read that lists successfully stores `entries` in `packages/app-custom/src/workspaces/files/model.tsx` and renders `src/session/files/directory-view.tsx` instead of an error toast. Upstream's Playwright regression spec is not ported.
- **Tests:** app-custom typecheck passes. Playwright against the live backend at 1280×720 and 390×844 verified that absolute and workspace-relative directory references open listing tabs, listing entries open nested directories and image previews, file references still open, and missing paths still toast.
- **Status:** resolved
- **Reconcile or remove when:** the next upstream integration that changes `open-artifact.tsx`; compare and update the custom port
- **Installation:** none
- **Result after upstream:** upstream merged #51036 as `7460d855ac906d9f604fdf7beb934cc19dc2614b`, the reviewed revision, and no later upstream commit through `dd786c62a` changes `open-artifact.tsx`. Reconciled by `chore: merge upstream v2 (2.0.18) into custom` (`docs/upstream-overrides.md`). Outcome: custom port kept; `packages/app-custom` forces the reread exactly as upstream, and the directory listing tabs remain a custom-only behavior.
