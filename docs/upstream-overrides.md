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

## Resolved entries

_None._
