# Local custom releases on macOS

After the one-time initial bootstrap release, the Mac first synchronizes
`upstream/v2` into `origin/custom`, then prepares releases locally from the
custom branch. Preparing a release never
selects it for startup. The Web titlebar/settings button (including mobile) or
the custom TUI's native `/update` dialog requests activation. The button click
itself is the Web confirmation; there is no additional confirmation modal. launchd supervises
the native CLI server; there is no permanent custom supervisor or maintenance
barrier.

## Components and ownership

- `packages/plugin-app-custom/src/updates/upstream-sync.ts`: finite upstream
  synchronization. It maintains the private bare repository's configured
  `upstream` remote, fetches exact remote-tracking refs, and either proves that
  `origin/custom` already contains the fetched upstream SHA or attempts a merge
  in a persistent automation worktree. Conflicts block preparation.
- `packages/plugin-app-custom/src/updates/prepare.ts`: finite preparation step.
  Fetches the configured branch into a private bare repository, archives the exact
  commit into an isolated build directory, installs dependencies, and invokes
  **`bun run packages/cli/script/build.ts --single`**. The native build includes
  `packages/app` in the executable. No GitHub Actions are required.
- A release contains the native executable, a bundled `plugin-app-custom`
  sidecar, its TUI adapter, finite preparation/handoff helpers, and a manifest.
  Bundling makes the sidecar independent of the development checkout's
  `node_modules`. All components come from the same source commit.
- `executor.ts`: one executor per installation per process, shared by Location
  plugin instances, plus the native `Flock` filesystem lock for serialization
  across processes/reloads. Manifest decoding, host/architecture checks,
  directory containment, and SHA-256 verification occur at the filesystem
  boundary. Preparation has a separate lock and never opens the session DB.
  `runtime.ts` is packaged as a sidecar dependency under `node_modules`, which
  the native plugin loader excludes from Location hot-reload invalidation.
- `updates/index.ts`: thin authenticated RPC facade. It requires the native
  release executable and a matching service registration to activate.
- `deployment/serve.sh`: resolves `current` once and **execs** native
  `opencode serve --service`. launchd owns that PID and restarts it on exit.
- `deployment/prepare.plist`: runs synchronization followed by preparation at
  login and every ten minutes.
  Failed checks/builds leave the active release and last verified candidate alone.
- The browser polls the serving installation every minute; selecting a different
  server in a session tab does not redirect the distribution updater. It uses the
  existing server credential registry and existing titlebar/settings controls.
  Custom builds disable new service-worker registration via the existing opt-out
  (and the build-version override also skips registration). The build still emits
  `sw.js`; the opt-out does not unregister an already installed worker. On a fresh
  origin this distribution does not enable offline caching. When reusing an origin
  with an older PWA worker, remove that old worker once during the initial cutover.

The official npm/curl installer and release catalog remain unchanged. They cannot
install this multi-file local release. Instead, the existing TUI `UpdateSource`
contract/dialog and Web `UpdaterPlatform` controls drive the custom executor.
The module-loading seam is new; the official `Updater.Service` and its npm/curl
installation implementation are not reused for custom installation. The launchers disable
the official automatic updater to prevent replacing the custom distribution.

## Layout

```text
<home>/
  deployment.json                 # origin/upstream, branches, worktrees, validation, Bun
  environment.sh                  # paths/environment used by the launchers
  config/opencode/service-custom.json
  bin/{serve,prepare,tui}.sh
  bin/prepare.js                  # first-build helper, before current exists
  plists/{serve,prepare}.plist     # rendered, not installed
  logs/{service,prepare}.log
  repository/                     # private bare Git clone
  state/upstream-sync.json        # frozen conflict/push state and session identity
  builds/                         # temporary work, removed after a normal job
  releases/<commit>/
    bin/opencode                  # native CLI + embedded Web UI
    plugin/{index,tui,prepare,handoff}.js
    plugin/node_modules/@opencode/plugin-app-custom/{package.json,runtime.js}
    server-config.json
    manifest.json
  prepared -> releases/<commit>   # latest successfully prepared candidate
  current  -> releases/<commit>   # ONLY explicit confirmation changes this
  state/opencode/service-custom.json
  data/opencode/custom.db
```

The release version is `0.0.0-custom-<build-time-ms>.0`; the manifest also records
the full source commit and architecture. A commit's release directory is immutable
once published. Preparation verifies a cached release, including equality between
the fetched commit, manifest commit and canonical directory. Activation verifies
the candidate hashes again; UI status checks read manifests without rehashing the
executable. The custom executor compares commit/version identities, not semver
ordering. It does not call the official updater's version-comparison function.

## Bootstrap (operator-run; not performed during development)

Prerequisites: macOS, Git with non-interactive access to the source and upstream repositories,
and the Bun version required by the checkout's `packageManager`. The configured
branch must already include this implementation. The job fetches `origin custom`
and `upstream v2`, merges only when needed, validates a clean merge, and publishes
it with a normal non-force push before building.
Use `--bun /absolute/path/to/bun` if the Bun running bootstrap belongs to the
retired deployment. The selected runtime must remain available to the finite
preparation and handoff helpers; review its path in `deployment.json`.

From the checkout:

```sh
cd packages/plugin-app-custom
bun run script/bootstrap.ts \
  --home "$HOME/.local/share/opencode-custom-v2" \
  --repository /absolute/path/to/opencode2 \
  --branch custom \
  --upstream https://github.com/anomalyco/opencode.git \
  --upstream-branch v2 \
  --worktree-root "$HOME/Worktrees" \
  --worktree-name opencode2 \
  --port 4178
```

`--repository` and `--upstream` may also be Git HTTPS/SSH URLs. Use absolute
paths for local repositories. The upstream defaults to
`https://github.com/anomalyco/opencode.git`; its branch defaults to `v2`.
The worktree root defaults to `~/Worktrees`, `worktree-name` defaults to
`opencode2`, and the fixed automation branch is `upstream-merge`, producing
`~/Worktrees/opencode2-upstream-merge` by default. Both the root and repository
name remain configurable. Bootstrap
refuses an existing home, writes private configuration,
renders the two plists, and bundles the first preparation helper. It neither
starts a service nor installs a launchd job. A new password is generated into
`config/opencode/service-custom.json` (mode 0600).

Prepare the first release:

```sh
/bin/sh "$HOME/.local/share/opencode-custom-v2/bin/prepare.sh"
```

The first invocation is an intentional bootstrap exception: while `current`
does not exist, the entrypoint prepares `origin/custom` directly and does not
attempt upstream synchronization. This guarantees that an initial native server
can be built and explicitly activated even when upstream currently conflicts.
The exception is unavailable as soon as `current` exists; an invalid existing
pointer also fails rather than bypassing synchronization.

After initial activation, the same finite command performs both phases in
sequence. The very next cycle synchronizes upstream first and, if it conflicts,
preserves the worktree and creates the review Session through the now-available
custom server. Synchronization and preparation remain separate modules; a
blocked synchronization exits without invoking release preparation. Before
publishing a clean automatic merge, the
default gate runs one root `bun install --frozen-lockfile`, package-local
typechecks for App, CLI, Client, Core, Plugin, plugin-app-custom and Server,
`check:generated` in Client, focused custom/Server/CLI tests, and the native CLI
build with `--single --skip-install`. That build incorporates the Web UI. Only
after all gates pass does the job create `chore: merge upstream v2` and use a
normal push to `origin custom`.

This deliberately makes synchronization expensive: install, generated-client
verification and a native App/CLI build happen before publication, and release
preparation later builds the exact published archive again. The duplication is
the safety boundary that prevents a broken merge from reaching `origin/custom`;
`--skip-install` avoids a second install within the pre-push gate itself. Tests
are never launched from the repository root. Validation remains an explicit
ordered list of `{ cwd, argv }` entries in `deployment.json`, all using the Bun
path selected by bootstrap.

### Conflict review

A merge conflict is intentionally left in place, including its index, under the
persistent automation worktree. Before creating that worktree, format-2
`state/upstream-sync.json` freezes the exact custom SHA, upstream SHA, worktree,
branch, deterministic canonical Session/Message IDs, status, phase, error, and
prompt status. Phases cover planning, worktree creation, merge, validation,
commit, push, publication and cleanup. Later jobs continue fetching but do not
merge a newer upstream target while this state is active or blocked.

The job connects to the configured custom service at
`config/opencode/service-custom.json` with its existing credential. It creates
one deterministic V2 Session in the worktree Location titled **Resolve upstream
merge** and asks the agent to analyze the conflicts without editing, staging,
resolving, committing, or pushing until the user explicitly replies. This makes
the review visible in the Agent Dashboard. If the service is unavailable, the
conflict remains untouched and a later run retries the same Session ID and
message ID.

There is no `/complete-upstream-sync` command. The user completes the work in the
Session: resolve, validate, create the merge commit, and push to
`origin/custom`. A later job detects that the remote contains the frozen upstream
SHA. It removes the automation worktree only after verifying its repository,
branch, clean status, and published HEAD, then marks the state resolved and
continues to preparation. It never force-removes a worktree or deletes human
changes.

A normal push rejected without a remote change is retried later from the same
clean commit. If `origin/custom` advanced, that commit and worktree are preserved
for review. Validation and commit-hook failures also preserve the worktree and
block with their summarized error in the review Session; validation is allowed
to have changed files, so it is never automatically aborted. No force push,
rebase, hard reset, destructive checkout, force removal, or temporary conflict
worktree is used.

On restart, the job reconciles the durable phase with Git. It can safely resume
an unstarted merge, recognize a clean merge with `MERGE_HEAD`, publish a verified
local two-parent merge commit, or detect that a previous push already published
the frozen upstream SHA. A crash during a potentially mutating validation or
commit hook is ambiguous and therefore blocks for human review. Even when the
remote already contains upstream, cleanup occurs only if repository ownership,
branch, cleanliness and published HEAD are all proven; otherwise the same
Session is created/reused and preparation remains blocked.

Read the reported commit and explicitly select that exact initial release:

```sh
bun run script/bootstrap.ts \
  --home "$HOME/.local/share/opencode-custom-v2" \
  --activate <full-prepared-commit>
```

This initial activation is accepted only while `current` is absent. It verifies
the manifest and every artifact. Running preparation or restarting launchd before
this confirmation never substitutes `prepared` for `current`.

After reviewing the rendered paths and configuration, install the jobs manually:

```sh
launchctl bootstrap "gui/$(id -u)" "$HOME/.local/share/opencode-custom-v2/plists/serve.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/.local/share/opencode-custom-v2/plists/prepare.plist"
```

To register them persistently for subsequent logins, place the rendered files at
`~/Library/LaunchAgents/local.opencode.custom-service.plist` and
`~/Library/LaunchAgents/local.opencode.custom-prepare.plist` before bootstrapping
those paths instead. Do not load both copies. The service uses KeepAlive,
ten-second throttling, and a 120-second graceful-exit allowance. The preparation
job has no KeepAlive and runs with background/low-I/O priority.

Open `http://127.0.0.1:4178` with username `opencode` and the generated password.
An existing proxy can forward to that listener after its operator changes the
upstream and authentication configuration. No legacy proxy, password, port,
launchd registration, or installed deployment pointer is modified by bootstrap.

Start the TUI with:

```sh
/bin/sh "$HOME/.local/share/opencode-custom-v2/bin/tui.sh" /path/to/project
```

This is a TUI launcher, not a general replacement for every CLI subcommand. It
discovers the running service without starting it, passes an explicit `--server`,
and loads the sidecar via `OPENCODE_TUI_UPDATER`. `/update` uses the native
check/install/error dialog. Installation waits for the selected server version
to become healthy. The dialog's existing Restart action exits the old TUI;
launch `tui.sh` again to run the selected CLI version. A raw CLI connected to a
remote server without this adapter retains its original local updater behavior.

## Adopting an existing custom installation

The retired `~/.local/share/opencode-custom` deployment is not upgraded in place.
Create a **new** deployment home. Bootstrap accepts:

- `--database /absolute/path/to/existing/custom.db`
- `--data-home /absolute/path/to/existing/xdg-data-root`

These only record paths in `environment.sh`; bootstrap does not open/migrate the
database. Preserve both the database and its associated data/blob directories.
Keep a backup before the first new binary opens them. The defaults instead create
an independent new data directory/database.

Copy the desired global OpenCode configuration into the new
`config/opencode` directory before starting. Preserve providers, credentials,
skills, and other settings; replace any old `plugin-app-custom` path rather than
loading both copies of the same plugin ID. `server-config.json` injects the
release's sidecar at highest configuration precedence. Review external plugin
paths for continued availability outside the checkout.

The operator must stop/unload the legacy owner before starting another process
against the same DB, and explicitly hand over any proxy endpoint. This development
change does not perform that operational cutover. Native service registration is
isolated under the new home's `state`, not the retired controller's `server.json`.

## Activation and failure semantics

1. The client confirms an exact `{commit, version}` obtained from `check`.
2. For a new selection, under the activation lock, the executor validates the current/candidate
   manifests and candidate hashes. A replaced candidate requires another check
   and confirmation. Corruption or native PTY handoff failure leaves `current`
   unchanged.
3. Native `PtyHandoff.prepare` creates the normal persistent-terminal handoff.
   Then one atomic symlink rename selects `current`.
4. The RPC returns its validated result. Only a successful Node HTTP `finish`
   invokes the shutdown callback. `finish` means flushed to the OS, not an
   acknowledgement from the browser. In-process/SDK RPC calls have no such
   capability and cannot activate this deployment.
5. SIGTERM closes the native NodeRuntime/server scopes. launchd runs the stable
   launcher again. A finite helper reads the native handoff environment, and the
   native CLI consumes it. Normal Session recovery remains responsible for
   suspended execution claims; no updater-specific durable events or barriers
   are introduced.
6. The client waits up to two minutes for the exact selected version to become
   healthy. The browser then reloads its assets from that version.

A response closed before `finish` does not trigger shutdown. A client disconnect
after `finish` cannot undo the callback or prove that the client received it. The confirmed selection is
retained, and the old process exposes it as retryable/ready; repeating confirmation
can refresh the native handoff and re-arm shutdown. A later ordinary restart may
run this **already confirmed** selection. An unconfirmed `prepared` release can
never do that.

**There is no automatic rollback.** After selection, a failed boot, migration,
health timeout, or process death leaves the selected release in `current`.
Inspect the service log and native logs under the configured data directory.
Repair/recovery is an operator action; blindly selecting an older binary after a
database migration is not a recovery strategy. A native boot failure may remain
alive serving failure health status, so KeepAlive is not a health supervisor.

Active model work retains native interruption/recovery behavior; this does
not promise preservation of a network stream. Persistent-terminal handoff keeps
the native ticket/expiry semantics. Other process-local resources retain their
normal shutdown behavior. No idle waiting or admission gate was added.

Old release directories are retained. Manual cleanup must exclude `current` and
`prepared`; build directories left by a killed preparation can be cleaned after
that job has stopped. The stable shell/plist format remains bootstrap-owned;
changes to those files require an explicit operator refresh. The preparation
implementation itself follows the active release's sidecar.

## Integration seams and verification

Generic upstream-facing additions:

- Optional `RpcCallContext.afterResponse` in Effect and Promise plugins, passed
  per invocation by Core and armed only after valid output in Server.
- Node-only `AfterResponse` capability installed by `ServerProcess`. The public
  HTTP contract is unchanged, so no generated client edits are needed.
- Export of existing native `@opencode/client/pty-handoff` helpers.
- Optional trusted `OPENCODE_TUI_UPDATER` module in the CLI composition root.
  Without it, the native updater remains unchanged.
- Web entrypoint adapter wiring, gated by `VITE_OPENCODE_CUSTOM_UPDATES=1`.

Policy, manifests, preparation, locks, launchd templates and adapters live in
`packages/plugin-app-custom` (the Solid-specific Web binding lives in App).
No Core Session/Job execution body, maintenance API, official updater installer,
native build body, Desktop updater, or TUI dialogue body is copied or replaced.
Only the deployment entrypoint `updates/sidecar.ts` adapts RPC registration through
`updates/transport.ts`. Input codecs decode; output/error/event codecs encode in
the sidecar runtime. The host receives plain Standard Schema validators, avoiding
cross-runtime AST interpretation. All seven pre-existing RPC contract files are
byte-for-byte unchanged from the custom base; the `standard/standardOutput`
contract-wide changes from the first iteration were removed.

Installing a normal package remains an alternative; these tests do not establish
that every such layout is incompatible. This iteration keeps a self-contained
sidecar and fixes the observed compiled-bundle case at its registration boundary,
without adding an external dependency tree or changing the plugin loader/contracts.
The focused bundle test verifies validator isolation, input validation and
optional-field encoding; the real executable smoke verifies the compiled host.

### Why keep the optional TUI adapter?

`OPENCODE_TUI_UPDATER` is a trusted local executable-module path selected by the
launcher, not by project configuration, RPC input or server discovery. It receives
the resolved endpoint, including credentials, so it must have the same trust as
the CLI and its sidecar. Invalid adapters fail loading rather than silently
falling back to the official installer.

Generalizing the official installer to own this release would involve installation
method detection, release lookup and staging/activation semantics. Replacing only
`Updater.Service.check/apply/run` in the TUI is possible, but would still need the
resolved endpoint and another adapter to the same `UpdateSource`; its other
installation methods would not be reused. The smaller seam here is the existing
`UpdateSource` injection after resolving the server. The
custom launcher uses explicit `--server` to avoid managed-service replacement.
This reuses the native dialog and notification flow, not the official installer,
Desktop updater, or automatic TUI relaunch. No `Updater.Service` body was changed.

Tests are package-local:

```sh
# packages/plugin-app-custom
bun test
bun typecheck

# packages/server
bun test test/after-response.test.ts test/rpc-handler-errors.test.ts test/process.test.ts
bun typecheck

# packages/cli
bun test test/tui-updater.test.ts test/updater-install.test.ts test/updater-poll.test.ts src/services/updater.test.ts
bun typecheck

# packages/app — dedicated test-owned Vite ports, fixture HTTP only
VITE_OPENCODE_CUSTOM_UPDATES=1 PLAYWRIGHT_PORT=45831 bun run test:e2e -- e2e/regression/settings-updates.spec.ts --workers=1
VITE_OPENCODE_CUSTOM_UPDATES=0 PLAYWRIGHT_PORT=45832 bun run test:e2e -- e2e/regression/settings-updates.spec.ts --workers=1
bun typecheck
bun typecheck:e2e
```

`test/upstream-sync.test.ts` uses test-owned temporary bare repositories,
persistent worktrees, bounded phase checkpoints and a test-owned HTTP API
endpoint. It covers clean merge, gate argv composition, conflict preservation,
deterministic Session idempotency, unavailable service retry, frozen upstream,
crashes around worktree/merge/validation/commit/push, validation and commit-hook
failures, concurrent origin advancement, rejected push retry, unsafe stale-state
retention, and safe cleanup after a human-style resolution. It does not contact
GitHub, operate launchd, or use an installed repository/service.

The opt-in `packages/plugin-app-custom/test/release-smoke.test.ts` takes
`OPENCODE_CUSTOM_TEST_BINARY` and `OPENCODE_CUSTOM_TEST_NEXT_BINARY`, pointing to
two native builds with distinct custom versions. It packages the real sidecars,
uses new temporary config/data/ports, runs only test-owned processes through the
launcher, and verifies HTTP activation, graceful registration cleanup, persisted
Session identity, and persistent PTY PID continuity. It never invokes launchctl.
The two executables are prebuilt test inputs; this smoke is not proof of a launchd
installation, real LLM in-flight recovery, migration rollback safety, or interactive
TUI rendering. Its test-owned second process exercises the launcher that launchd
would run. The separate preparation test covers building from a single checkout.

`OPENCODE_CUSTOM_BUILD_TEST=1 bun test test/prepare-build.test.ts` (from the plugin
package) snapshots the working checkout into a temporary Git repository and runs
the complete local preparation job, including the native build. It verifies that
the preparation lock remains held through the build, all artifacts are verified,
and only `prepared` is published. This is opt-in because it compiles the CLI and
Web UI and needs the normal build dependencies/network access.

### Measured overlap

Fixed upstream: `0f26ad878`. Custom starting commit: `ffb761810`.

| Scope                              | Existing upstream files touched | Task additions/deletions |
| ---------------------------------- | ------------------------------: | -----------------------: |
| Production source/package surfaces |                              10 |                +69 / -16 |
| Existing server regression test    |                               1 |                 +61 / -0 |
| Workspace lockfile                 |                               1 |                  +2 / -0 |
| Total existing upstream files      |                              12 |               +132 / -16 |

The production paths are the Web entrypoint, CLI default-command composition,
Client export map, Core RPC invocation, three Plugin RPC context/adapter files,
Server RPC handler/process composition, and the Settings update-section gate. The generic helpers and custom
modules are new files rather than replacements of upstream bodies.

The cumulative diff against fixed upstream includes custom work predating this
task, especially the Settings layout; do not equate it with the task delta. These counts intentionally
distinguish this task's overlap from the existing fork delta; they are not the
total size of all custom modules/tests/docs.

The upstream-synchronization increment changes only the already-new custom
deployment/script/docs area and adds `updates/upstream-sync.ts` plus its focused
test. It adds no further integration point to an existing upstream source file.

### Implementation verification

- Package-local typechecks: App, CLI, Client, Core, Plugin and plugin-app-custom,
  plus Server in the first iteration. The second iteration reran App (including
  E2E types), CLI, plugin-app-custom and Server, the affected consumers.
- The synchronization increment reran the complete plugin-app-custom suite and
  package typecheck. Its focused Git fixtures also verify that the finite
  entrypoint does not enter preparation while a conflict is blocked.
- Native CLI updater installation/polling/policy tests and the optional TUI
  adapter loader test.
- Core RPC failure parity; Server after-response/invalid-output/embedded-call
  tests; existing custom app/navigation/snippets/worktree HTTP regressions.
- Manifest/checksum, competing confirmations, initial-bootstrap lock release,
  failed preparation, no automatic selection, no rollback, and native packaged
  release continuity tests.
- Existing App updater action tests with its `solid` condition/happy-dom preload.
- First-iteration browser review at desktop and 390×844 mobile sizes covered the titlebar
  activation action and reload after a test-owned replacement became healthy;
  no uncaught page errors. Test browser/service processes were cleaned up.
- Second-iteration `settings-updates.spec.ts` exercises the real Settings screen
  and Check now action at 1280px/390px, with and without the custom Web adapter.
  HTTP responses are deterministic fixtures; this does not start an OpenCode server.
  The existing Desktop branch is retained in the visibility condition; Electron
  was not exercised by these Web tests.
- Second-iteration packaged smoke also verifies existing snippet save/list wire
  normalization and a declared native-app error, without launching host apps.
  The full preparation/build test passed in the first iteration and was not
  repeated in the second; cached preparation and current sidecar packaging were
  retested separately.
- Native builds embed the real App through `script/build.ts --single`; local
  development builds used `--skip-install` after workspace dependencies were
  installed. The actual preparation job uses the unmodified normal install/build
  path.

No installed launchd job, legacy proxy, live service or production database was
operated during implementation. Launchd installation remains the explicit
operator bootstrap above.
