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

### Nested session tabs and ancestor trail — https://github.com/anomalyco/opencode/pull/51064

- **Kind:** adaptation
- **Reviewed upstream revision:** `ad53e39d2e6c222ea35aa4b8331616a9f85b4ef5` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): group nested session tabs under their root`; `packages/app-custom/src/shell/titlebar/titlebar.tsx`, `src/session/{session-identity-header.tsx,timeline/message-timeline.tsx}`, and `e2e/regression/subagent-child-navigation.spec.ts`. As upstream, the titlebar resolves a routed session's root with the existing `rootSession` helper (cycle detection, fetched ancestors remembered in the data cache, `data.session.root` fallback) and keys descendant tabs by that root; the identity and timeline headers render `SessionAncestorTrail`, a scrollable breadcrumb of every ancestor that navigates through `rememberSessionRoute`, while the active title keeps up to 45% of the row. Chat identity, tab order and preferences, the drawer, touch gestures, and file/artifact tabs are unchanged; the timeline controller keeps its now unused `navigateParent` action as upstream does. The custom phone layout (below the desktop breakpoint) does not render the session title header, so the trail appears from the desktop breakpoint up; at 390×844 the mobile titlebar keeps the current title and the drawer lists the root session once.
- **Tests:** three Playwright regressions ported from upstream (direct nested link opens in the root tab, full ancestor path with navigation, active title and separator kept in view at 820×720 with keyboard navigation to the root) fail on `cde61cb22` and pass; they use the horizontal tab strip and pass the mock `subscriptions` shape. Checked at 1440×900 and at 390×844 (drawer shows only the root tab, titlebar shows the current title). App-custom typecheck, unit suite, and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Undo queued prompts into the composer — https://github.com/anomalyco/opencode/pull/51124

- **Kind:** adaptation
- **Reviewed upstream revision:** `beeb14e910775230d24355a7533b2e4d4e05a53b` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): undo queued prompts into the composer`; `packages/app-custom/src/session/composer/{queue.ts,queue.test.ts,queue-panel.tsx}`, `src/composer/{adapter.ts,model.ts,prompt.ts,composer.stories.tsx}`, `src/runtime/i18n/en.ts`, and `e2e/regression/session-queue.spec.ts`. A queued row has an Undo action that cancels the inbox item (`session.inbox.cancel`) and puts the prompt back into the draft after anything already typed, with its quotes merged by ID; submit is blocked while it runs. Instead of upstream's `queuedPromptUndoDraft()`, `queuedPromptUndo()` rebuilds the custom algebra from the full sent payload: `@file` mentions (path and line range from the file URI), agents, skills, app and session parts, cited and uncited inline images, staged `path` attachments with their mentions, and structured quotes. MCP resource reference lines stay as text. Before cancelling, the rebuilt draft is serialized again with `buildPromptRequest` and compared with the queued text, files, agents, skills, apps, and sessions; attachment reference lines are only counted, because attachments are redelivered on send. Anything the draft cannot hold, such as review-comment context or unmentioned file context, keeps the item queued and shows an English message. Existing guards stay: no undo in shell mode (message), while editing a queued item, or while a revert is pending; the queue panel remains hidden while `/btw` occupies the composer. `buildPrompt` and `selectionFromFileUrl` in `composer/prompt.ts` are exported for this. The upstream TUI keybind and upstream's read-only editor during undo are not ported (the draft is read after the cancel, so typing meanwhile is kept).
- **Tests:** unit tests cover the round trip (restored parts resubmit exactly the queued payload), MCP resource text, and refusal for comment and hidden file context; Playwright against the mock server at 1440×900 and 390×844 restores a queued prompt with its attachment after an existing draft, and leaves an unrestorable prompt queued with the message and no cancel request. App-custom typecheck, unit suite, and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Provider account switching — https://github.com/anomalyco/opencode/pull/51266

- **Kind:** adaptation
- **Reviewed upstream revision:** `684721efb8c4e753431b2e9e851716e34e410e42` (commit reviewed/applied), 2026-09-28
- **Local change:** `feat(app): switch provider accounts in settings`; `packages/app-custom/src/settings/providers/{accounts.ts,accounts.test.ts,providers.tsx}`, `src/settings/settings.css`, and `src/runtime/i18n/en.ts`. A connected provider with stored credentials shows its active account (the server's active-first order) in a menu that activates another account (`credential.activate`), adds one through the existing connect dialog, and removes a single account (`credential.remove`), then invalidates and resyncs integration, provider, and model data. Differences from upstream: account removal is a flat menu group instead of a submenu, so the same menu works on touch screens (no `ui-custom` menu change is needed); the custom integration-aware "Disconnect all" stays in the menu as a separate action; providers without credentials keep the plain Disconnect button or the environment hint. Custom account badges, server-scoped settings (`InlineServerSelect`), the shared Console integration lookup, and model-visibility preferences are unchanged (no automatic `models.show`). English source strings only.
- **Tests:** the upstream account-order helper tests pass; app-custom typecheck, unit suite, and root `bun run check` pass. Against an isolated source server (temporary XDG/DB/config dirs, no inherited `OPENCODE_*`) with two fixture OpenAI API-key credentials, Playwright at 1440×900 and 390×844 switched the active account, removed one account, opened Add account, and disconnected all, checking the server's credential list after each step.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### One-time pairing links and unauthorized servers — https://github.com/anomalyco/opencode/pull/50970, https://github.com/anomalyco/opencode/pull/50972

- **Kind:** adaptation
- **Reviewed upstream revision:** `eccf0b3b7b70f6980f6f7ccdb0cad566bbc37ab5`, `2caba90a63e1eb0155ca43496ca6e8eed895e217` (commits reviewed/applied), 2026-09-28
- **Local change:** `fix(app): redeem one-time pairing links`; `packages/app-custom/src/servers/connect/{pairing.ts,pairing.test.ts,scanner.tsx,screen.tsx,dialog.tsx}`, `src/runtime/server/{health.ts,health.test.ts,runtime.tsx}`, `src/shell/routes/routes.tsx`, `src/runtime/i18n/en.ts`, `vite.pwa.ts`, and `e2e/service-worker/cache.spec.ts`. Ports `pairingLink()`/`redeemPairingLink()` but keeps the custom raw JSON, legacy query/fragment, and base64url `/connect` decoders (the scanner tries them first) and returns the custom `{ urls, password }` shape. The connect screen and the server dialog accept a pasted `/auth/connect/<code>` link, redeem it, and put the base URL and token into the form before the health check, so a retry never reuses the spent code; spent or expired codes show an English-only error. Health reports `{ healthy: false, unauthorized: true }` without retrying; the global runtime disposes an unauthorized server's controller and does not recreate it until health recovers. When the only server is an unauthorized HTTP server, the connect screen replaces the app with its URL prefilled. The PWA navigation fallback excludes `/auth` so opened links reach the server. Not ported: upstream's removal of password pairing and legacy decoders, the desktop/TUI pairing UI, and the `/connect` route removal (custom has no such route).
- **Tests:** pairing-link and unauthorized-health unit tests (ported from upstream) pass; the service-worker navigation test now covers `/auth/connect/<code>` and fails with the old denylist. Against an isolated password-protected source server (temporary XDG/DB/config dirs, no inherited `OPENCODE_*`) and the app-custom dev server, Playwright at 1440×900 and 390×844 verified: unauthorized lone server → connect screen with the URL prefilled; a real `POST /api/pair` link pasted into the connect screen and into the Add server dialog is redeemed and stored as the base URL plus token, surviving reload; a spent link shows the expired error in both places; the manual password path still connects; with a wrong stored password the credentialed `/api/event` requests drop from 5 to 0 in 5 s (base `cde61cb22` keeps reconnecting) and a fresh link recovers the server. QR scanning of links was not exercised (no camera). App-custom unit suite, typecheck, and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Unified session project resolution — https://github.com/anomalyco/opencode/pull/51288

- **Kind:** adaptation
- **Reviewed upstream revision:** `ee5b67eb84358067c8119fca269bb58154e32250` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): unify session project resolution`; `packages/app-custom/src/shell/layout/{helpers.ts,helpers.test.ts}`, `src/runtime/server/runtime.tsx`, `src/shell/titlebar/{tab-nav.tsx,titlebar.tsx}`, `src/session/{session-identity-header.tsx,screen.tsx,timeline/message-timeline.tsx}`, `src/shell/commands/palette.ts`, and `src/home/sessions/{records.ts,records.test.ts,controller.tsx}`. Same resolver as upstream: a unique project-ID match wins, while projects sharing an ID resolve by exact directory, then sandbox, then the most specific ancestor root; `projects.forSession` prefers opened projects (keeping the custom per-workspace icon override from `enrich`) and `projects.detailsForSession` keeps synced worktree metadata with the opened project's name and icon for the summary and timeline. Wired into the horizontal tab strip, mobile titlebar, new-draft target, session identity header, timeline header/avatar, session summary, command palette, and Home session records. Chat sessions keep resolving to no project: the tab strip, header, palette, and Home records already skip chats, and the mobile titlebar now skips them too because the shared resolver also consults synced projects. The custom summary keeps its avatar prop rather than upstream's `ProjectIcon` swap. The custom sidebar keeps its own directory-first inventory and is not changed.
- **Tests:** new helper tests (shared-ID precedence; details metadata plus appearance) and a Home records test fail on `cde61cb22` and pass; app-custom unit suite, typecheck, and root `bun run check` pass. Against the mock server with two opened projects sharing an ID, the session in the worktree shows the worktree project's avatar in the 390×844 mobile titlebar (`cde61cb22` showed the main repository) and in the 1440×900 horizontal tab.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Settings destination in the URL — https://github.com/anomalyco/opencode/pull/50364

- **Kind:** adaptation
- **Reviewed upstream revision:** `27dfac3d3640fc9285640c0e613e38b07309b206` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): keep settings destination across reloads`; `packages/app-custom/src/settings/{route.ts,route.test.ts,surface.tsx,shell.tsx}`, `packages/app-custom/src/runtime/server/registry.tsx`, `packages/app-custom/src/shell/titlebar/{history.ts,history.test.ts}`, `packages/app-custom/e2e/regression/settings-route-refresh.spec.ts`, and URL expectations in three existing settings specs. The settings `tab`, `server`, `project`, and `subtab` are parsed and validated from `/settings?...` using the custom page list (including `snippets`); search reveal state (`target`, `searchActivation`) stays in history state, and only those fields are read from older history entries that stored a whole view. Unlike upstream, a project page records `parent=server` when it was opened from a server's project list, because custom projects can also be opened from the root all-servers list and back navigation follows the origin rather than the server count. The redirect of a missing server waits for the persisted server list (`hydrated`, as upstream exposes it); custom has no WSL/SSH inventory in that list and no upstream single-server redirects, so none are added. Titlebar history replaces one entry across settings URLs. Not ported: `SettingsSearchField` and the keybind/model/project search changes of the same PR.
- **Tests:** route parse/serialize tests (custom pages, project origin, invalid combinations, stale history state) and the upstream titlebar history test pass; the new Playwright regression at 1440×900 and 390×844 reloads a root page (Snippets) and a project Extensions → LSPs page and returns to root Projects; it fails on `cde61cb22` (URL stays `/settings`). App-custom unit suite, typecheck, and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### MCP resource mentions as read references — https://github.com/anomalyco/opencode/pull/50680

- **Kind:** adaptation
- **Reviewed upstream revision:** `33b686feb9f5c4b668b4584ae46746f1dfba2ef3` (commit reviewed), 2026-09-28
- **Local change:** `fix(app): send MCP resource mentions as references`; `packages/app-custom/src/composer/{request.ts,submit.ts,submit.test.ts}`. Upstream removed the composer `@resource` suggestion and exposed `list_mcp_resources`/`read_mcp_resource` as Code Mode tools. The custom composer keeps the suggestion, but no longer sends a selected resource as a `file` attachment (core accepts only `file:` URIs, and a `file:` URI would read a local server file). Each resource in the prompt or quote comments, including resources restored from old drafts or history with `source.type === "resource"`, is sent as the text line `MCP resource <uri> (server: <server>)` after the prompt text, for prompts and slash commands. It is a reference for the model to read, not pre-attached content. The model reads it through `read_mcp_resource`, which is only reachable inside Code Mode, so it requires the agent's `execute` permission and the tool's `opencode_read_mcp_resource` permission. The draft schema is unchanged.
- **Tests:** new submit tests for prompts and commands fail on `cde61cb22` (resource sent as a `file` attachment) and pass; app-custom unit suite, typecheck, and root `bun run check` pass. A one-off Playwright check against the mock server at 1440×900 and 390×844 selected the `@guide` suggestion and captured the admitted text line with no files.
- **Status:** active
- **Reconcile or remove when:** upstream changes composer resource mentions or the MCP resource tools; compare and update the custom delivery
- **Installation:** none
- **Result after upstream:** pending

### Theme seeds, light contrast, and token typos — https://github.com/anomalyco/opencode/pull/50517

- **Kind:** adaptation
- **Reviewed upstream revision:** `b4866520679e7a74c688223b30356d1c29f18e4f` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(ui): port theme contrast and seed fixes`; `packages/ui-custom/src/theme/{color.ts,color.test.ts}` and `packages/ui-custom/src/theme/themes/{catppuccin-frappe,catppuccin-macchiato,catppuccin,kanagawa,oc-2}.json`. `color.ts` and the four Catppuccin/Kanagawa themes were identical to upstream `8ce629be2`, so they now match upstream `dd786c62a` (WCAG green luminance weight, corrected light/dark seeds and overrides). In `oc-2.json` only the `icon-weak-base` typo (`#C7C7C7`) is ported; the custom theme name and `v2-icon-icon-faint` value are kept.
- **Tests:** new `color.test.ts` fails on `cde61cb22` (12.74 instead of 15.3 for green on black) and passes; ui-custom theme tests and typecheck and root `bun run check` pass. The four themes rendered a session in light and dark at 1440×900 and 390×844 against an isolated mock server.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Return composer focus after picking files — https://github.com/anomalyco/opencode/pull/50864

- **Kind:** adaptation
- **Reviewed upstream revision:** `9c8a63e852722a9bced4a0de1179de58a85dfa20` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): return composer focus after picking files`; `packages/app-custom/src/composer/{attachments/attachments.ts,editor/interaction.ts}` and `packages/app-custom/e2e/regression/composer-file-picker-focus.spec.ts`. Ports only the focus return: the native picker resolves through a completion callback and the browser file input's change handler restores focus to the composer that started the pick. The thumbnail `<Suspense>` is not ported; the custom keyed attachment rows, stable blob resource, and `url.latest` preview already avoid detaching the session. Focus targets only the picking composer; while `/btw` hides the main editor, focusing it is a no-op and CodeMirror does not move the DOM selection of an unfocused view, so the visible side composer keeps focus.
- **Tests:** the new Playwright regression at 1440×900 and 390×844 fails on `cde61cb22` (editor inactive after picking) and passes with the fix, including typing into the editor. A one-off Playwright check (not committed) completed a pending pick after opening `/btw`: the side composer kept focus and received the typed text. App-custom typecheck and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Attachment remove buttons on touch devices — https://github.com/anomalyco/opencode/pull/51047

- **Kind:** adaptation
- **Reviewed upstream revision:** `dca73ba9e3782e2b41983faca5854a9d56a3c482` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): show attachment remove buttons on touch devices`; `packages/app-custom/src/composer/editor/editor.tsx` and `packages/app-custom/e2e/regression/composer-attachment-touch.spec.ts`. Comment and attachment remove buttons use the existing `hover-reveal` utility, so they stay visible when the device cannot hover. The custom staged-upload cancel button is already always visible and is unchanged; upstream's component story test is replaced by an e2e regression because the custom packages have no Storybook stories.
- **Tests:** the new Playwright regression (touch, 390×844) fails on `cde61cb22` (opacity 0) and passes with the fix, including tap-to-remove; app-custom typecheck and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Keep the session mounted when switching models — https://github.com/anomalyco/opencode/pull/50865

- **Kind:** adaptation
- **Reviewed upstream revision:** `fabf56781cee45b6ebe5aecd4b7b4c7bf5033fa5` (commit reviewed/applied), 2026-09-28
- **Local change:** `fix(app): keep timeline mounted when switching models`; `packages/app-custom/src/runtime/server/runtime.tsx` and `packages/app-custom/e2e/regression/session-model-switch-mount.spec.ts`. Same approach as upstream: model recents suspend readers only until persisted state loads, then read the store directly, so pushing a recent no longer puts the session route into its Suspense fallback. The custom `createGlobalModels` keeps its legacy `models` preference import, remote profile sync, and `user`/`variant` proxy.
- **Tests:** the new Playwright regression at 1440×900 and 390×844 fails on `cde61cb22` (timeline viewport detached, scroll lost) and passes with the fix (5 repeats each); app-custom typecheck and root `bun run check` pass.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

### Compatibility skill watcher storm — https://github.com/anomalyco/opencode/commit/7784b3ee0d033da3eab101e45882387f4a3e1eaa

- **Kind:** adaptation
- **Reviewed upstream revision:** `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (`upstream/v2`, where `compatibility.ts` is still identical to the version introduced by `7784b3ee0d033da3eab101e45882387f4a3e1eaa`), 2026-09-28; previously `affa57e40f44fbd294c18199ecab5879c0ae0d70`, 2026-09-23
- **Local change:** `fix(core): stop compatibility skill watcher storms`; `packages/core/src/config/plugin/compatibility.ts`, `packages/core/test/config/skill.test.ts`. There is no upstream fix. Upstream reloads on every raw `config.changes()` event without a debounce, and every refresh runs `FiberMap.clear` and resubscribes all watches. Every Location runs the plugin, so a single event under `~/.agents` or `~/.claude` became N×events full rescans, native watcher restarts, and `skill.updated` notifications. That storm froze the shared server (observed on 2026-09-23: ~30k refreshes in 22 minutes). Locally: config changes are filtered to `.claude`/`.agents` roots and share the existing 100 ms debounce; watches are reconciled so only watches that left the source set are released; claude and agents roots that resolve to the same directory are scanned once; `ctx.skill.reload()` runs only when the loaded skills changed. Related open issues: https://github.com/anomalyco/opencode/issues/47505 and https://github.com/anomalyco/opencode/issues/50594.
- **Tests:** `bun test test/config test/filesystem` in `packages/core` (281 pass); the new `ConfigCompatibilityPlugin.Plugin` test fails against the upstream file (6 reloads for a 5-event burst) and passes locally; full `packages/core` suite passes except the environment-only `preload.test.ts` home isolation check; `bun run check` passes.
- **Status:** active
- **Reconcile or remove when:** upstream changes `packages/core/src/config/plugin/compatibility.ts` to debounce or filter `config.changes()` and to stop restarting unchanged watches (for example, a fix for #47505 or #50594); then compare behavior and keep only what upstream still lacks.
- **Installation:** none
- **Result after upstream:** pending

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
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #50970 and #50972 replace password pairing with single-use `/auth/connect/<code>` links, and `opencode pair` now prints only that format, which the custom scanner does not decode or redeem. The custom port is unchanged; comparison is deferred to the next custom UI port. Reconciled in `fix(app): redeem one-time pairing links`: the custom decoders stay, and the scanner, connect screen, and server dialog now also redeem `/auth/connect/<code>` links (see that entry).

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
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #48501 (Console and Go device-flow sign-in) and #51266 (provider account switching) change `settings/providers`. The custom port is unchanged; comparison is deferred to the next custom UI port. #51266 is ported by `feat(app): switch provider accounts in settings` (see its entry); #48501 remains.

### Console browser sign-in — https://github.com/anomalyco/opencode/pull/50267

- **Kind:** adaptation
- **Reviewed upstream revision:** `fbacf6a1268473e38788d196cf60ddfab3b47e27`, 2026-09-23
- **Local change:** `feat(app): port Console sign-in and provider copy`; `packages/app-custom/src/providers/connect/{controller.ts,dialog.tsx}`, `src/settings/providers/providers.tsx`, `src/runtime/server/{types.ts,global-sync/utils.ts}`, `src/runtime/i18n/en.ts`, and `test-browser/{provider-connection.test.ts,fixtures/provider-connection.ts}`. Shared Console OAuth for Zen/Go, hidden defaults, non-suspending loading, browser opening, polling, retry, expiry, cancellation, Go-specific key storage, account badges, and integration-aware disconnect. Retains native authorization links for popup-blocked browsers and custom dialog/settings styling; cancels still-open attempts on polling transport failure. Preserves custom model-visibility preferences rather than copying upstream's automatic show-all preference mutation. Composer commands and icon redesign are outside this port.
- **Tests:** app-custom `bun run test:unit` (1120 pass, 1 skip), `bun run test:browser` (220 pass), and the isolated controller fixture (10 pass); app-custom typecheck/build and root `bun run check` (39 tasks) pass. Playwright CLI checked Chrome at 1440×900 and iPhone WebKit at 390×844 against isolated source port 4185: real OAuth start/browser URL/polling, visible-link fallback with automatic opening suppressed, API-key switch/cancellation, and injected failure/retry. No OAuth login completed or real credentials submitted; test processes stopped.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #48501 moves Console and Go sign-in to the device flow and #51266 adds provider account switching in `providers/connect` and `settings/providers`. The custom port is unchanged; comparison is deferred to the next custom UI port. #51266 is ported by `feat(app): switch provider accounts in settings` (see its entry); #48501 remains.

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
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #50386 keeps the session summary as an overlay and changes `index.css`. The custom port is unchanged; comparison is deferred to the next custom UI port.

### Summary layout coordination — https://github.com/anomalyco/opencode/pull/48449

- **Kind:** adaptation
- **Reviewed upstream revision:** `9f3ba44c4a4a8ba3c9fa36694af06bb0a2baa367`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/session/{screen.tsx,review/model.ts,timeline/message-timeline.tsx}` and `src/index.css`. Port summary-open coordination, fixed edge anchoring, bounded scrolling, and resize offset freezing to the existing custom popover; retain the mobile drawer.
- **Tests:** focused Playwright LTR/RTL tests verify timeline/composer translation, resize settlement and closing; drawer dismissal regression; app-custom typecheck, unit/browser suites and build all passed.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #50386 keeps the session summary as an overlay. The custom port is unchanged; comparison is deferred to the next custom UI port.

### Expandable services and configuration — https://github.com/anomalyco/opencode/pull/48445

- **Kind:** adaptation
- **Reviewed upstream revision:** `41430842506e8952580a2fa1af25aa88d8ea896d`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/shell/status/{body.tsx,service-status.ts}` and `src/session/timeline/message-timeline.tsx`. Reuse existing service configuration actions, retries, refresh subscriptions, and custom LSP derivation in compact expandable tabs instead of adding upstream's nested service popovers. Browser clients retain working copy-path actions even for a local server without native reveal APIs.
- **Tests:** status derivation unit tests; focused Playwright tests expand/collapse all four services using pointer and keyboard and verify configuration actions and unclipped labels; app-custom typecheck, unit/browser suites and build all passed.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #51001 starts MCP sign-in from a row click in the session summary services. The custom port is unchanged; comparison is deferred to the next custom UI port.

### Services in the custom session summary — https://github.com/anomalyco/opencode/pull/48103

- **Kind:** adaptation
- **Reviewed upstream revision:** `d6c22b3bf531533980dc633a1dac5e38c64fe458`, 2026-09-23
- **Local change:** `feat(app): consolidate services in custom session summaries`; `packages/app-custom/src/session/{timeline/message-timeline.tsx,header/session-header.tsx,review/view.tsx}`, `src/shell/status/`, and `src/runtime/i18n/en.ts`. Preserve project, location, changes, move actions and background tasks; add a compact MCP/plugins/skills/LSP status row. Reuse the custom status body, suppress redundant session titlebar/mobile status entry points when a summary exists, and retain standalone status for drafts and child sessions.
- **Tests:** app-custom unit/browser suites, typecheck and build; focused Playwright service, session-header and mobile drawer regressions all passed; screenshots inspected at 1440×900, 1024×900 and 390×844.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #50386, #51001, and #51288 change the session summary and its project icon resolution. The custom port is unchanged; comparison is deferred to the next custom UI port. #51288 is ported by `fix(app): unify session project resolution` (see its entry); the summary keeps the custom avatar rendering.

### Staged composer attachments — https://github.com/anomalyco/opencode/pull/49467

- **Kind:** adaptation
- **Reviewed upstream revision:** `f04c3fd82bf98cb911f5c1c7b25f9cded0b86722` (#49467), `469e1c035ee3f1343f02b60c0aab22136fdb4f2a` (https://github.com/anomalyco/opencode/pull/49647), `90112f52db59a8f2ec412c66c6677193bf5dc7b8` (https://github.com/anomalyco/opencode/pull/49682), 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/composer`, `packages/app-custom/src/session/composer/queue.ts`, `packages/app-custom/src/shell/shell.tsx`, `packages/app-custom/src/runtime/i18n/en.ts`, `packages/ui-custom/src/feedback/toast`. Streams non-native, text, and over-20-MiB files directly to the server with cancellable progress. Path parts extend the custom CodeMirror attachment/reference algebra, including image citations, undo, snippets, drafts, history, and queued edits. Retains a delivery adapter for legacy blob drafts and model capability changes; keeps the custom composer rather than adopting upstream's editor.
- **Tests:** app-custom unit and browser-condition suites, all three affected package typechecks, root `bun run check`, app-custom production build; isolated-server browser checks at 1440×900 and 390×844 include 21-MiB streaming progress, picker attachment, image paste, staged reference removal/undo, and draft reload. Follow-up `fix(app): expose sent attachment paths` checks the full path on both collapsed summaries and expanded attachment cards, declares image/PDF capabilities in the shared model fixture, and exercises the dropped-text streaming endpoint. The collapsed-path title expectation also failed on `db3a4d551`; the follow-up adds the missing collapsed affordance rather than weakening that assertion.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #51047 shows attachment remove buttons on touch devices, #50864 keeps composer focus after attaching files, and #51124 undoes queued prompts back into the input. The custom port is unchanged; comparison is deferred to the next custom UI port. #51047 is ported by `fix(app): show attachment remove buttons on touch devices` the focus part of #50864 by `fix(app): return composer focus after picking files`, and #51124 by `feat(app): undo queued prompts into the composer` (see their entries).

### Lazy draft image bytes — https://github.com/anomalyco/opencode/pull/49703

- **Kind:** adaptation
- **Reviewed upstream revision:** `47f66de8dda535de9f2e2c3bfdbeaad774ad6e82`, 2026-09-23
- **Local change:** `feat(app): stage attachments in the custom composer`; `packages/app-custom/src/runtime/persistence/drafts.ts`, `packages/app-custom/src/composer/{schema.ts,model.ts,submit.ts,editor/editor.tsx}`. Restored image references keep IDs without reading bytes until thumbnail, preview, or delivery; retains custom image citation metadata and legacy path-delivery support. `fix(app): preserve composer focus with attachments` keys attachment rows by ID and loads thumbnail bytes by stable blob ID without suspending the surrounding session. Existing URLs render synchronously; cold previews use an empty initial value and the resource's latest value. This avoids a Promise-backed thumbnail detaching the editor and Context panel on each document edit.
- **Tests:** lazy draft/cache/persistence tests, app-custom unit and browser-condition suites, typechecks, root check, production build, browser draft reload. Added desktop/mobile Playwright focus, caret, DOM-detachment, thumbnail-identity, and remove/undo regressions; both focus cases fail on integrated `3413919c7` and pass with the fix. Real isolated-backend measurements over 31 key events: image on `db3a4d551` = 0 editor/Context detachments, image on `3413919c7` = 21 each with lost focus, fixed image and 21-MiB path attachment = 0 at 1440×900 and 390×844. All three servers used empty provider lists and no inherited OpenCode environment.
- **Status:** reconcile
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending. Integration of upstream `dd786c62af18b8f53c1eea1b30c5b53460ea9f6e` (2026-09-28) changed the same upstream UI: #50864 keeps composer focus after attaching files, overlapping the custom focus fix. The custom port is unchanged; comparison is deferred to the next custom UI port. Compared in `fix(app): return composer focus after picking files`: the custom keyed rows, stable blob resource, and `url.latest` thumbnail already keep the session attached, so upstream's thumbnail `<Suspense>` is not adopted; only its picker focus return is ported (see its entry).

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

### Mobile-friendly /btw peek panel — https://github.com/anomalyco/opencode/pull/49750

- **Kind:** adaptation
- **Reviewed upstream revision:** `dcfe1ec7bd4922d4f44c141ba33047402bffc57e`, 2026-09-23
- **Local change:** `feat(app): add mobile-friendly side question panel` (`223dc0836`), `fix(app): refine side question history and cancellation`; `packages/app-custom/src/session/btw/`, custom composer command/selection integration, command shortcuts, and English source strings. Uses the same abortable `session.generate` backend and verbatim side-question instructions as upstream #49750. The Solid UI is modeled on OpenChamber's MIT-licensed `useBtwStore`, `BtwPanel`, and `ComposerFloatingPanel`: a responsive panel docked above the composer, compact collapsed chip, explicit cancel, and touch dismissal. Entry points are `/btw`, `/btw <question>`, command palette, Mod+Shift+B, and selected assistant text. Mobile Enter inserts a newline and desktop Enter submits. Up to five completed side Q&A pairs are kept per session, with bounded plain-text context included in subsequent generate prompts. State survives in-app navigation for the 20 most recently used sessions per server, but not reload; session changes/unmount cancel pending requests. OpenChamber is UI/UX inspiration only: no forks, metadata links, synthetic messages, plugin hooks, backend changes, or durable side history. The server chooses the current session model/context and returns the complete answer without token streaming.
  `fix(app): use compact composer for side questions` replaces the plain textarea with the production CodeMirror `ComposerEditor`, following `QuoteCommentEditor`: memory-backed rich drafts and the main composer's context/file/snippet completion. Compact mode has an opt-in to the standard composer submission keys; quote-comment behavior stays unchanged. Snippets expand through `expandSnippets`, app/session references use the shared context formatters, and file/agent/skill references remain textual mentions. Binary attachment parts are omitted (typed citations remain text); the side editor does not read or upload files. Rich drafts survive collapse, navigation, and cancellation.
  `feat(app): ask side questions from the main composer` follows OpenChamber's composer UX while keeping native `session.generate`: while the panel is expanded, a full-size `ComposerEditor` (`btw/composer.tsx`) takes the main composer's place and the main editor stays mounted but hidden, keeping its draft and editor state. The side composer has no add menu, attachments, shell mode, or agent/model/variant pickers; it shows the session's committed model read-only, because generate uses it. Submit clears the field immediately; cancellation or failure returns the draft unless something new was typed. The submit button stops a pending question (Esc also stops it). Esc otherwise collapses the panel, or closes it when nothing was asked yet; focus and type-to-focus follow the visible composer. The panel only shows the conversation (question bubbles, markdown answers, bottom-following scroll, header spinner), and the queue panel plus main-composer attach/shell commands are hidden or disabled while the side composer is active.
- **Tests (main-composer UX):** app-custom `bun typecheck`, `bun run test:unit` (1239 pass, 1 skip), root `bun run check`, and `git diff --check` pass. `bun run test:browser` has 219 pass and 3 sidebar failures (`sidebar-search`, `sidebar-pins`, `sidebar-worktrees`) that fail identically on the unchanged base. Playwright CLI verified an isolated source server with copied config and credentials against a real provider: Mod+Shift+B and `/btw <question>` entry, immediate clearing, stop with draft restoration, answer rendering, Esc collapse/close, header reopen/dismiss, preserved hidden main draft, type-to-focus into the side composer, and 1440×900 plus 390×844 layouts.
- **Tests:** after merging `origin/ui-integration`, app-custom `bun run typecheck`, `bun run test:unit` (1155 pass, 1 skip), `bun run test:browser` (221 pass), `bun run build`, root `bun run check`, and `git diff --check` pass. Tests exercise real generated-client HTTP boundaries, Q&A history/cancellation, rich draft retention, snippet expansion, app/session formatting, and binary omission. Playwright CLI verified the built app at 1440×900 and iPhone 390×844: `/btw`, `#` snippet suggestions/expansion, `@` file search/selection, rich drafts through collapse/reopen, desktop Enter, mobile Enter newline without sending, touch Ask, and focus restoration to the main composer. Prior checks also covered pending/cancel/error, navigation isolation, and all command entry points. The isolated server strips inherited `OPENCODE_*` variables and explicitly sets config paths/content; `/api/info` confirmed its PID/version and `/api/provider` returned `data: []` before sends. Generation uses HTTP-boundary fixtures; no real provider calls.
- **Status:** active
- **Reconcile or remove when:** the next upstream integration that changes the same UI; compare and update the custom port
- **Installation:** none
- **Result after upstream:** pending

## Resolved entries

### Reread artifacts when opening a preview — https://github.com/anomalyco/opencode/pull/51036

- **Kind:** adaptation
- **Reviewed upstream revision:** `7460d855ac906d9f604fdf7beb934cc19dc2614b`, 2026-09-25
- **Local change:** `packages/app-custom/src/session/files/open-artifact.tsx` forces `file.load(path, { force: true })` when an agent-referenced path opens, matching upstream. The same custom change also opens directory references as listing tabs (custom-only): a failed read that lists successfully stores `entries` in `packages/app-custom/src/workspaces/files/model.tsx` and renders `src/session/files/directory-view.tsx` instead of an error toast. Upstream's Playwright regression spec is not ported.
- **Tests:** app-custom typecheck passes. Playwright against the live backend at 1280×720 and 390×844 verified that absolute and workspace-relative directory references open listing tabs, listing entries open nested directories and image previews, file references still open, and missing paths still toast.
- **Status:** resolved
- **Reconcile or remove when:** the next upstream integration that changes `open-artifact.tsx`; compare and update the custom port
- **Installation:** none
- **Result after upstream:** upstream merged #51036 as `7460d855ac906d9f604fdf7beb934cc19dc2614b`, the reviewed revision, and no later upstream commit through `dd786c62a` changes `open-artifact.tsx`. Reconciled by `chore: merge upstream v2 (2.0.18) into custom` (`docs/upstream-overrides.md`). Outcome: custom port kept; `packages/app-custom` forces the reread exactly as upstream, and the directory listing tabs remain a custom-only behavior.
