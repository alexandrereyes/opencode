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
integration's own notes, such as `upstream-beta-merge.md`).

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

### Custom timeline tool groups and notices — [#48594](https://github.com/anomalyco/opencode/pull/48594), [#48909](https://github.com/anomalyco/opencode/pull/48909), [#48932](https://github.com/anomalyco/opencode/pull/48932), [#49045](https://github.com/anomalyco/opencode/pull/49045), [#48895](https://github.com/anomalyco/opencode/pull/48895), [#47821](https://github.com/anomalyco/opencode/pull/47821)

- **Kind:** adaptation
- **Reviewed upstream revision:** `41e5d1b6b69b768a1d79c1c012a2bc5de1dc9bf3`, `93a37958a78c81d211240dbe7cc53b04754e7221`, `f1149efee7ce08f7d819c48d8b69482441bd0592`, `4fa6ca00e5500cb8d6419bc013fcbb00ce9958c7`, `a71bb4d38c3397173726ac581c27a31e9f5eba99`, `2816d1c849cc1a103f90e0215966c8080d65e95f` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/session-ui-custom/src/{timeline,tools,components/message-part.css}`, related component tests, and `packages/ui-custom/src/i18n/en.ts`. Keep compaction/model dividers separate, narrow Notice to exclude idle, group edit/write/patch diffs, remove the titleless sticky gap, label arbitrary search providers, and use Updates styling for notice-only groups. Preserve custom empty-file write rows and custom imports; #47821 is type parity only because idle filtering and backend contracts already exist.
- **Tests:** custom package typechecks and root `bun run check` passed; all 209 session-ui unit tests passed. All 30 focused file-tool, patch-group, tool-group, and session-tool-projection component cases passed across the initial run and focused reruns after adapting grouped-file assertions (installed Chrome channel). Notice disclosure also checked at 390×844 with English text and forced RTL.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom tab gestures and compact icons — [#49964](https://github.com/anomalyco/opencode/pull/49964), [#49460](https://github.com/anomalyco/opencode/pull/49460)

- **Kind:** adaptation
- **Reviewed upstream revision:** `7020944359f9d6500d743ad7ba03d5d441e475bf`, `a5b3802ca3fcb95331fb56f3532c2b28b293b7ca` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/src/shell/titlebar/{tab-gesture.ts,tab-gesture.test.ts,tab-nav.tsx,tab-nav.css,tab-strip.tsx}`. Port touch thresholds, non-modal context menus, vertical drag navigation suppression, and compact icon container rules. Retain the custom `onReorder` guard: the inventory-sorted mobile drawer intentionally supplies no reorder callback, while reorderable strips support touch.
- **Tests:** app-custom unit/browser suites, typecheck, and root `bun run check` passed. Isolated 390×844 browser checks confirmed touch menu dismissal and retained inventory order after touch movement; desktop custom draft-strip touch drag reversed two drafts without navigation.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom app startup compatibility — [#48621](https://github.com/anomalyco/opencode/pull/48621)

- **Kind:** adaptation
- **Reviewed upstream revision:** `c4fe0f676a070a78e76385bfd8c10470f24ac3bd` (commit reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/{package.json,src/entry.tsx,src/runtime/polyfills.ts}` and `bun.lock`. Import Map.groupBy and Promise.withResolvers polyfills before startup, reusing upstream's locked core-js 3.50.0 version. Custom-package paths only; lockfile updated with `bun install`.
- **Tests:** app-custom build, typecheck, unit/browser suites, and root `bun run check` passed. Isolated built UI loaded after deleting both APIs before page startup; grouping and deferred-promise resolution succeeded.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom direct-link QR scanning — [#49971](https://github.com/anomalyco/opencode/pull/49971), prerequisite [#49291](https://github.com/anomalyco/opencode/pull/49291)

- **Kind:** adaptation
- **Reviewed upstream revision:** `788f0affcbec8b3609eb943977e6da36ae02ddf9`, `080b7671dea45a693b537c1e358e89ab14463d0d` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/src/servers/connect/{pairing.ts,pairing.test.ts,scanner.tsx}`. Scan raw JSON, legacy query/fragment codes, and direct base64url /connect links. Port the prerequisite optional URL payload and URL decoder from #49291, but not desktop pairing UI or link generation. CLI/backend already contain the direct-link changes.
- **Tests:** app-custom typecheck and root `bun run check` passed; three focused tests passed covering raw/legacy codes, origin fallback, Unicode credentials, malformed payloads, and rejected schemes.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom scrollbar mount measurement — [#49778](https://github.com/anomalyco/opencode/pull/49778)

- **Kind:** adaptation
- **Reviewed upstream revision:** `c3bf8864b9d4c82506c01bf9f47f8977bfbc197b` (commit reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/ui-custom/src/components/scroll-view.tsx`. Let ResizeObserver perform the first layout measurement and defer the reactive remeasurement effect. Same behavior in the custom component, preserving its other customizations.
- **Tests:** ui-custom typecheck and all 109 unit tests passed; root `bun run check` and app-custom production build passed. Built UI exercised at 1440×900 and 390×844.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Custom session and workspace UI polish — [#49668](https://github.com/anomalyco/opencode/pull/49668), [#50265](https://github.com/anomalyco/opencode/pull/50265), [#49122](https://github.com/anomalyco/opencode/pull/49122), [#49080](https://github.com/anomalyco/opencode/pull/49080), [#48927](https://github.com/anomalyco/opencode/pull/48927), [#50437](https://github.com/anomalyco/opencode/pull/50437), [#49779](https://github.com/anomalyco/opencode/pull/49779), [#48735](https://github.com/anomalyco/opencode/pull/48735)

- **Kind:** adaptation
- **Reviewed upstream revision:** `3355c93efdb5b5c69873d81eec0a93fa849d385e`, `8aebed170a14d3e3d841883dd2d3d171529d745c`, `73e7b7bc7935380f284c8b4607a973838c2f1424`, `23402629c59e3c8a68f88ddc86882ac5bf501ff5`, `0a3dc169613f98300d71a778a6cf7f40b04fee74`, `51d2b667600386684822ef6a9eff64f59542bdc5`, `b447627f5f6662b018e29e7769f5d02d3da2845c`, `b629b458f70ab46d0c2097007ee111e9b3de1fc2` (commits reviewed/applied), 2026-09-23
- **Local change:** `fix(app): port upstream UI polish to custom packages`; `packages/app-custom/src/{new-session/composer-adapter.ts,session/review,session/timeline/controller.tsx,workspaces/files/model.tsx,runtime/i18n/en.ts,index.css,settings/keybinds/keybinds.tsx}`. Use canonical roots for local sessions while preserving explicit worktree selection and custom chat admission; make non-VCS review ready/empty; derive listed basenames; shorten queued attachment/context labels; retain closed panel animation state; import the shortcut search icon eagerly; align untitled session labels. The custom timeline controller delegates deletion elsewhere, so only its three existing fallback sites change.
- **Tests:** app-custom typecheck, 1,118 unit tests (one existing skip), 219 browser-runtime tests, production build, and root `bun run check` passed. Isolated desktop UI showed the non-VCS review empty state instead of indefinite loading; shortcut search kept focus while typing at 1440×900 and 390×844.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Console account visibility with a Zen key — https://github.com/anomalyco/opencode/pull/50763

- **Kind:** adaptation
- **Reviewed upstream revision:** `3bf8a5a8cfb4826d9c06f35898b6cb42670385cf`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/settings/providers/{providers.tsx,popular.ts,popular.test.ts}`. Ported the upstream credential-method filter into a tested helper while preserving custom server-scoped settings and ordering.
- **Tests:** app-custom `bun run test:unit` (1120 pass, 1 skip); four focused Popular-list cases cover fresh installs, stored keys, OAuth accounts, and catalog loading. App-custom typecheck and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Console browser sign-in — https://github.com/anomalyco/opencode/pull/50267

- **Kind:** adaptation
- **Reviewed upstream revision:** `fbacf6a1268473e38788d196cf60ddfab3b47e27`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/providers/connect/{controller.ts,dialog.tsx}`, `src/settings/providers/providers.tsx`, `src/runtime/server/{types.ts,global-sync/utils.ts}`, `src/runtime/i18n/en.ts`, and `test-browser/{provider-connection.test.ts,fixtures/provider-connection.ts}`. Shared Console OAuth for Zen/Go, hidden defaults, non-suspending loading, browser opening, polling, retry, expiry, cancellation, Go-specific key storage, account badges, and integration-aware disconnect. Retains native authorization links for popup-blocked browsers and custom dialog/settings styling; cancels still-open attempts on polling transport failure. Preserves custom model-visibility preferences rather than copying upstream's automatic show-all preference mutation. Composer commands and icon redesign are outside this port.
- **Tests:** app-custom `bun run test:unit` (1120 pass, 1 skip), `bun run test:browser` (220 pass), and the isolated controller fixture (10 pass); app-custom typecheck/build and root `bun run check` (39 tasks) pass. Playwright CLI checked Chrome at 1440×900 and iPhone WebKit at 390×844 against isolated source port 4185: real OAuth start/browser URL/polling, visible-link fallback with automatic opening suppressed, API-key switch/cancellation, and injected failure/retry. No OAuth login completed or real credentials submitted; test processes stopped.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Go monthly pricing copy — https://github.com/anomalyco/opencode/pull/50473

- **Kind:** adaptation
- **Reviewed upstream revision:** `643c4c35006f9aef6f8513c51c2e9a99f22aa0f0`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/ui-custom/src/i18n/*.ts`. Ported the exact upstream $10/month description into all 62 affected custom locales, preserving unrelated custom strings. Console service, billing, and documentation changes are outside this web product port.
- **Tests:** verified every changed locale value against the reviewed upstream diff; ui-custom `bun run test` (109 pass), ui-custom typecheck, app-custom build, and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Anthropic connection copy — https://github.com/anomalyco/opencode/pull/49369

- **Kind:** adaptation
- **Reviewed upstream revision:** `54f23561668ede605ec764b22ee36158681bb14f`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/runtime/i18n/*.ts`. Ported the exact upstream English API-key/Anthropic wording and removed both stale Pro/Max keys from all 62 affected non-English locales so the English fallback applies.
- **Tests:** verified all 63 affected locale files against the reviewed upstream diff; app-custom unit/browser suites, typecheck/build, and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Center the conversation beside summaries — https://github.com/anomalyco/opencode/pull/49620

- **Kind:** adaptation
- **Reviewed upstream revision:** `1464545665ba892c2d2886f4456acc9a584aa156`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/index.css`. Center the existing 1000px conversation beside the custom 280px panel in the upstream 1320–1640px chat-width range, preserving RTL and reduced motion. The custom start screen has no summary cards, so #49429 was evaluated but not ported.
- **Tests:** root `bun run check`, app-custom typecheck and build passed; unit suite 1118 passed/1 skipped, browser suite 219 passed, focused Playwright regressions 8 passed; desktop and mobile browser inspection passed.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Summary layout coordination — https://github.com/anomalyco/opencode/pull/48449

- **Kind:** adaptation
- **Reviewed upstream revision:** `9f3ba44c4a4a8ba3c9fa36694af06bb0a2baa367`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/session/{screen.tsx,review/model.ts,timeline/message-timeline.tsx}` and `src/index.css`. Port summary-open coordination, fixed edge anchoring, bounded scrolling, and resize offset freezing to the existing custom popover; retain the mobile drawer.
- **Tests:** focused Playwright LTR/RTL tests verify timeline/composer translation, resize settlement and closing; drawer dismissal regression; app-custom typecheck, unit/browser suites and build all passed.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Expandable services and configuration — https://github.com/anomalyco/opencode/pull/48445

- **Kind:** adaptation
- **Reviewed upstream revision:** `41430842506e8952580a2fa1af25aa88d8ea896d`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/shell/status/{body.tsx,service-status.ts}` and `src/session/timeline/message-timeline.tsx`. Reuse existing service configuration actions, retries, refresh subscriptions, and custom LSP derivation in compact expandable tabs instead of adding upstream's nested service popovers. Browser clients retain working copy-path actions even for a local server without native reveal APIs.
- **Tests:** status derivation unit tests; focused Playwright tests expand/collapse all four services using pointer and keyboard and verify configuration actions and unclipped labels; app-custom typecheck, unit/browser suites and build all passed.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Services in the custom session summary — https://github.com/anomalyco/opencode/pull/48103

- **Kind:** adaptation
- **Reviewed upstream revision:** `d6c22b3bf531533980dc633a1dac5e38c64fe458`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/session/{timeline/message-timeline.tsx,header/session-header.tsx,review/view.tsx}`, `src/shell/status/`, and `src/runtime/i18n/en.ts`. Preserve project, location, changes, move actions and background tasks; add a compact MCP/plugins/skills/LSP status row. Reuse the custom status body, suppress redundant session titlebar/mobile status entry points when a summary exists, and retain standalone status for drafts and child sessions.
- **Tests:** app-custom unit/browser suites, typecheck and build; focused Playwright service, session-header and mobile drawer regressions all passed; screenshots inspected at 1440×900, 1024×900 and 390×844.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Staged composer attachments — https://github.com/anomalyco/opencode/pull/49467

- **Kind:** adaptation
- **Reviewed upstream revision:** `f04c3fd82bf98cb911f5c1c7b25f9cded0b86722` (#49467), `469e1c035ee3f1343f02b60c0aab22136fdb4f2a` (https://github.com/anomalyco/opencode/pull/49647), `90112f52db59a8f2ec412c66c6677193bf5dc7b8` (https://github.com/anomalyco/opencode/pull/49682), 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer`, `packages/app-custom/src/session/composer/queue.ts`, `packages/app-custom/src/shell/shell.tsx`, `packages/app-custom/src/runtime/i18n/en.ts`, `packages/ui-custom/src/feedback/toast`. Streams non-native, text, and over-20-MiB files directly to the server with cancellable progress. Path parts extend the custom CodeMirror attachment/reference algebra, including image citations, undo, snippets, drafts, history, and queued edits. Retains a delivery adapter for legacy blob drafts and model capability changes; keeps the custom composer rather than adopting upstream's editor.
- **Tests:** app-custom unit and browser-condition suites, all three affected package typechecks, root `bun run check`, app-custom production build; isolated-server browser checks at 1440×900 and 390×844 include 21-MiB streaming progress, picker attachment, image paste, staged reference removal/undo, and draft reload.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Lazy draft image bytes — https://github.com/anomalyco/opencode/pull/49703

- **Kind:** adaptation
- **Reviewed upstream revision:** `47f66de8dda535de9f2e2c3bfdbeaad774ad6e82`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/runtime/persistence/drafts.ts`, `packages/app-custom/src/composer/{schema.ts,model.ts,submit.ts,editor/editor.tsx}`. Restored image references keep IDs without reading bytes until thumbnail, preview, or delivery; retains custom image citation metadata and legacy path-delivery support. `fix(app): preserve composer focus with attachments` keys attachment rows by ID and loads thumbnail bytes by stable blob ID without suspending the surrounding session. Existing URLs render synchronously; cold previews use an empty initial value and the resource's latest value. This avoids a Promise-backed thumbnail detaching the editor and Context panel on each document edit.
- **Tests:** lazy draft/cache/persistence tests, app-custom unit and browser-condition suites, typechecks, root check, production build, browser draft reload. Added desktop/mobile Playwright focus, caret, DOM-detachment, thumbnail-identity, and remove/undo regressions; both focus cases fail on integrated `3413919c7` and pass with the fix. Real isolated-backend measurements over 31 key events: image on `db3a4d551` = 0 editor/Context detachments, image on `3413919c7` = 21 each with lost focus, fixed image and 21-MiB path attachment = 0 at 1440×900 and 390×844. All three servers used empty provider lists and no inherited OpenCode environment.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Failed-send history and bounded toasts — https://github.com/anomalyco/opencode/pull/49717

- **Kind:** adaptation
- **Reviewed upstream revision:** `dd71cdbd840f8bc875fd516c39c8e29f199c5b84`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer/{history,model.ts,submit.ts}`, `packages/ui-custom/src/feedback/toast`. Removes restored failed submissions from history with custom quote-aware matching. Bounds toast descriptions to 2,000 characters before deduplication and retention.
- **Tests:** actual failed admission/retry history tests, history matching tests, ui-custom toast bound test and suite, package typechecks and root check.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Preserve native clipboard paste — https://github.com/anomalyco/opencode/pull/49424

- **Kind:** adaptation
- **Reviewed upstream revision:** `acfacede2d96fb6adf59b826491d3339d5d95261`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer/editor/interaction.ts`. Uses upstream's attachment-paste guard while leaving ordinary and non-plain text paste to CodeMirror and preserving structured Session paste and custom image citation insertion.
- **Tests:** clipboard guard tests for missing data, HTML/RTF, native image reading, and files; existing attachment ownership/reference tests; desktop/mobile paste and remove/undo checks.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Timeline attachment classification — https://github.com/anomalyco/opencode/pull/49932

- **Kind:** adaptation
- **Reviewed upstream revision:** `5848ee0d24ba273dea17daa084e4634ac8bf5b16`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/session-ui-custom/src/{components/message-file.ts,message/message-content.tsx}`. Ports final upstream `attached()` semantics: mentions and unmentioned file-URI context are not inline attachment cards. Staged paths continue to render through the custom attachment-reference metadata.
- **Tests:** classification tests, session-ui-custom suite (209 passing), package typecheck and root check.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Rich artifact tabs in the custom browser UI — https://github.com/anomalyco/opencode/pull/49882

- **Kind:** adaptation
- **Reviewed upstream revision:** `60ed84ecd193ce09f1343cbea074fc2aa8e4a554`, 2026-09-23
- **Local change:** `feat(app): port rich artifact tabs and timeline image previews`; `packages/app-custom/src/session/files`, `src/session/screen.tsx`, `src/session/browser`, `src/workspaces/files`, `src/runtime`, `packages/session-ui-custom/src/components/markdown*`, `src/context/markdown.tsx`, and `packages/cli/src/services/web-ui.ts`. Local markdown links and inline path references open existing custom file tabs; mobile opens the existing Files view. Ported media/document/table/font classification and viewers with compact preview/source/download controls rather than upstream's metadata toolbar. Browser-only HTML stays in an opaque-origin sandbox instead of Electron file URL handoff; nested Markdown references resolve relative to the artifact. Preserves custom timeline, side-panel, and mobile layout. The shared web shell CSP minimally allows blob frames, media, and fonts so installed browser previews work; script policy is unchanged.
- **Tests:** app-custom unit and browser suites pass; session-ui-custom unit suite passes; app-custom and session-ui-custom typechecks and root `bun run check` pass; app-custom production build passes; CLI `bun test test/web-ui.test.ts` passes (2 tests). Playwright real built UI fixtures at 1440×900 and 390×844 verify rich tab opening, nested links, inline-reference keyboard activation, source/preview switching, touch tab closing, sandboxed HTML, and no horizontal viewport overflow.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Timeline image attachment previews in custom UI — https://github.com/anomalyco/opencode/pull/49111

- **Kind:** adaptation
- **Reviewed upstream revision:** `24dff6929dce6ed4a90f53e65dbd80df5f014e83`, 2026-09-23
- **Local change:** `feat(app): port rich artifact tabs and timeline image previews`; `packages/session-ui-custom/src/components/image-preview.tsx`, `src/components/markdown.tsx`, `src/components/markdown.css`, `src/components/message-part.css`, `src/tools/tool-renderer.tsx`, and component fixtures/tests. Reuses the existing `@opencode/ui-custom/image-preview` attachment dialog for Markdown and Read-tool images, including keyboard activation and touch-close controls. Custom message attachment behavior is preserved.
- **Tests:** session-ui-custom `bun run test` passes (221 tests); app-custom Playwright built UI tests at 1440×900 and 390×844 pass for Markdown and Read-tool image preview, keyboard activation, Escape, and close control; both custom package typechecks and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

_None recorded yet. The register began with this document, without a retroactive
audit (see above)._

### Mobile-friendly /btw peek panel — https://github.com/anomalyco/opencode/pull/49750

- **Kind:** adaptation
- **Reviewed upstream revision:** `dcfe1ec7bd4922d4f44c141ba33047402bffc57e`, 2026-09-23
- **Local change:** `feat(app): add mobile-friendly side question panel` (`223dc0836`), `fix(app): refine side question history and cancellation`; `packages/app-custom/src/session/btw/`, custom composer command/selection integration, command shortcuts, and English source strings. Uses the same abortable `session.generate` backend and verbatim side-question instructions as upstream #49750. The Solid UI is modeled on OpenChamber's MIT-licensed `useBtwStore`, `BtwPanel`, and `ComposerFloatingPanel`: a responsive panel docked above the composer, compact collapsed chip, explicit cancel, and touch dismissal. Entry points are `/btw`, `/btw <question>`, command palette, Mod+Shift+B, and selected assistant text. The separate question field preserves the main draft; mobile Enter inserts a newline and desktop Enter submits. Up to five completed side Q&A pairs are kept per session, with bounded plain-text context included in subsequent generate prompts. State survives in-app navigation for the 20 most recently used sessions per server, but not reload; session changes/unmount cancel pending requests. OpenChamber is UI/UX inspiration only: no forks, metadata links, synthetic messages, plugin hooks, backend changes, or durable side history. The server chooses the current session model/context and returns the complete answer without token streaming.
  `fix(app): use compact composer for side questions` replaces the plain textarea with the production CodeMirror `ComposerEditor`, following `QuoteCommentEditor`: memory-backed rich drafts and the main composer's context/file/snippet completion. Compact mode has an opt-in to the standard composer submission keys; quote-comment behavior stays unchanged. Snippets expand through `expandSnippets`, app/session references use the shared context formatters, and file/agent/skill references remain textual mentions. Binary attachment parts are omitted (typed citations remain text); the side editor does not read or upload files. Rich drafts survive collapse, navigation, and cancellation.
- **Tests:** after merging `origin/ui-integration`, app-custom `bun run typecheck`, `bun run test:unit` (1155 pass, 1 skip), `bun run test:browser` (221 pass), `bun run build`, root `bun run check`, and `git diff --check` pass. Tests exercise real generated-client HTTP boundaries, Q&A history/cancellation, rich draft retention, snippet expansion, app/session formatting, and binary omission. Playwright CLI verified the built app at 1440×900 and iPhone 390×844: `/btw`, `#` snippet suggestions/expansion, `@` file search/selection, rich drafts through collapse/reopen, desktop Enter, mobile Enter newline without sending, touch Ask, and focus restoration to the main composer. Prior checks also covered pending/cancel/error, navigation isolation, and all command entry points. The isolated server strips inherited `OPENCODE_*` variables and explicitly sets config paths/content; `/api/info` confirmed its PID/version and `/api/provider` returned `data: []` before sends. Generation uses HTTP-boundary fixtures; no real provider calls.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

_None recorded yet. The register began with this document, without a retroactive
audit (see above)._

## Resolved entries

_None._
