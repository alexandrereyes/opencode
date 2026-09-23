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
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/runtime/persistence/drafts.ts`, `packages/app-custom/src/composer/{schema.ts,model.ts,submit.ts,editor/editor.tsx}`. Restored image references keep IDs without reading bytes until thumbnail, preview, or delivery; retains custom image citation metadata and legacy path-delivery support.
- **Tests:** lazy draft/cache/persistence tests, app-custom unit and browser-condition suites, typechecks, root check, production build, browser draft reload.
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

## Resolved entries

_None._
