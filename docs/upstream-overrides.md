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

## Resolved entries

_None._
