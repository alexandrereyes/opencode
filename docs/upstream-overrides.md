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

## Resolved entries

_None._
