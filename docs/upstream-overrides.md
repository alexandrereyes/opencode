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

### Unify compatibility skill loading — https://github.com/anomalyco/opencode/pull/48881

- **Kind:** adaptation
- **Reviewed upstream revision:** `17f6cd601e39fc34e8e032916b5ed7357aa26f33` (PR head, open, base `v2`), 2026-09-22
- **Local change:** `fix(core): skip skill rescans for unrelated file changes` (base `origin/custom` `b5c92b3d8aea004bfc55ca77b2d0156a360e0292`, upstream baseline `e5ecb5719de37759e06c57ff05ffc668e98f6f30`); `packages/core/src/config.ts`, `packages/core/src/config/plugin/compatibility.ts` (deleted), `packages/core/src/config/plugin/skill.ts`, `packages/core/src/plugin/internal.ts`, `packages/core/test/config/config.test.ts`, `packages/core/test/config/skill.test.ts`, `packages/core/test/config/reload.test.ts`. The PR diff applies unchanged. Adaptations: `reload.test.ts` (absent from the reviewed PR) now starts `ConfigSkillPlugin` instead of the deleted `ConfigCompatibilityPlugin`. Local addition without an upstream counterpart, in `ConfigSkillPlugin.watch`: watcher events are filtered by a `relevant` predicate before they reach the debounced rescan. It keeps `SKILL.md`, root-level `*.md`, paths that contain a loaded source root or skill file (scanned or canonical path), and created or updated directories; it drops other files such as `~/.agents/skills/synced/<bucket>/manifest.json`, whose periodic updates made every Location rescan and resubscribe. `load` returns its roots and scanned files so `refresh` can store them for that predicate.
- **Tests:** in `packages/core`: `bun typecheck` passed; `bun test test/config/ test/plugin` 523 pass; `bun test test/*skill* test/skill` 43 pass. New cases: `skill.test.ts` "ignores unrelated files in watched sources but reloads skill changes", "reloads when a symlinked skill inside a source is created or retargeted", "keeps isolated Location catalogs idle for unrelated files in a shared source" (three Locations with separate Skill catalogs, shared Bus and Watcher); `reload.test.ts` "ignores unrelated files under compatibility skills while hot reloading skill changes" (real native watcher: manifest writes, directory move in/rename/move out, symlink, removal). Without the filter the three manifest cases fail. Root `bun run check` passed (oxlint 0 warnings/errors, 39/39 typecheck tasks).
- **Status:** active
- **Reconcile or remove when:** upstream merges #48881 (or closes/revises it) and the result reaches the integrated upstream branch. Then keep the upstream implementation, drop the `reload.test.ts` adaptation if upstream covers it, and keep only the event relevance filter unless upstream provides an equivalent; re-run the manifest and hot-reload cases.
- **Installation:** none
- **Result after upstream:** pending

### Skip skill rescans for unrelated config changes — https://github.com/anomalyco/opencode/pull/47397

- **Kind:** adaptation
- **Reviewed upstream revision:** `a1a3359c68732e19a95e3d501836a2f6eb018e71` (PR head, open, base `v2`), 2026-09-22
- **Local change:** `fix(core): skip skill rescans for unrelated file changes`; `packages/core/src/config/plugin/skill.ts`, `packages/core/test/config/skill.test.ts`. Applied on top of #48881, whose `config.updated` handler it replaces: the source comparison also covers the compatibility roots, so the handler reloads `config.entries()` and `config.compatibility()` before comparing `sources()`. The regression test is carried unchanged except for the current `@opencode/*` package names.
- **Tests:** `bun test test/config/skill.test.ts` in `packages/core`, including the PR's "skips unchanged config sources but refreshes ordered sources and watched files"; it fails when the unchanged-sources early return is removed.
- **Status:** active
- **Reconcile or remove when:** upstream merges #47397 (or closes/revises it) and the result reaches the integrated upstream branch; reconcile together with #48881 because both edit the same handler.
- **Installation:** none
- **Result after upstream:** pending

## Resolved entries

_None._
