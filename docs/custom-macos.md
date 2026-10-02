# Custom macOS runtime

## Manual releases

Run these commands from a clean, committed `custom` checkout on macOS:

```sh
bun run custom:prepare          # builds only; production keeps running
bun run custom:status
bun run custom:activate --dry-run
bun run custom:activate         # explicit interruption + backup + replacement

# Subsequent updates (does NOT fetch, pull, merge, commit or push Git):
bun run custom:update           # prepare, then activate without database backup

# Select an already-prepared release explicitly:
bun run custom:activate <full-40-character-sha>
```

`OPENCODE_CUSTOM_HOME` defaults to `~/.local/share/opencode-custom-v2`. Preparation
uses `git archive HEAD`, installs frozen dependencies in the snapshot, typechecks
CLI/TUI, app-custom and plugin-app-custom, builds the plugin and compiles the CLI
with `--custom` (embedding **app-custom**, not app). CLI `--version` and `--help`
are checked with isolated XDG directories. Before publication, `custom-parser-smoke.ts` checks
the compiled binary's rejection of an inherited `--server` on unsupported commands, version
actions triggered by `--version=false` / `--no-version`, `--` operand handling, and help actions.
It also inspects help for the local/API routes and their ancestors, rejecting local flags or aliases
named `--help`, `-h`, `--version`, or `-v` that could shadow the global actions.
The harmless `debug paths home` handler is the execution sentinel. A changed parser contract
fails preparation rather than silently changing launcher safety. No server is started during prepare.

Each `releases/<sha>` contains:

- `OpenCode Custom.app`: signed bundle (`local.opencode.custom`) holding the compiled CLI/TUI
  with version `0.0.0-custom.<sha>`;
- `bin/opencode`: relative symlink to the bundle executable, used by launchers and hashed
  through the link;
- `plugin/index.js`: standalone custom plugin bundle, with Standard Schema RPC codec boundaries;
- `server-config.json`: update disabled, the absolute release-owned plugin path, and the
  local `safari-devtools` MCP server (`/usr/bin/safaridriver --mcp`);
- `manual-release.json`: format 2, commit, version, platform, architecture and SHA-256 artifact hashes.

Published directories are read-only and are never rebuilt in place.
The release config is loaded after discovered global, explicit, and project documents. User
plugins and differently named MCP servers remain available, while the release-owned update
policy and `safari-devtools` definition win if an earlier document uses the same keys. It does
not edit `~/.config/opencode`.

MCP services are Location-scoped and connect eagerly, so each materialized Location retains one
process per local MCP server, for example `safaridriver --mcp` (about 3 MB) and
`codex-computer-use-mcp` (about 65 MB of Node). `LocationActivity` evicts a Location, stopping
those processes, after 60 minutes without session events and no active execution; the server log
records `location services evicted`. The custom sidebar resolves worktree roots and branch labels
for groups and Recent rows through the `custom.worktrees` `locate` RPC in the server default
Location, so listing worktrees or sessions does not boot their Locations. On first inventory load,
the web app lists stored rows and calls `custom.worktrees.check` without a Location override.
This read-only Git drift check refreshes through the official `worktree.refresh` endpoint only
for missing directories, newly discovered directories, or linked worktrees whose stored rows
are still unowned; RPC failures and unknown strategies also fall back to the official refresh.
An unchanged expanded project therefore does not boot its Location. Explicit refresh actions
are unchanged, and only core writes the inventory. When integrating upstream, reconcile this
check with `Worktree.refresh`, its insert/conflict ownership rules, and the built-in Git strategy;
the custom plugin currently registers no worktree strategies. Before syncing Location catalogs,
the custom app calls `custom.worktrees.available` in the default Location once per directory and
connection. A confirmed missing directory skips catalog requests while session history remains
readable. Catalog failures recheck availability to detect terminal removals after the cold check;
other failures retain normal error reporting. Reconnecting or reloading clears this availability
cache, allowing restored directories to load again. This does not change the inventory cache or
its cold drift check. Opening a session in an existing directory boots its Location as before.
Location keys compare directory strings exactly, so case variants of one directory on
the case-insensitive macOS filesystem (`~/Dev/x` and `~/dev/x`) become separate Locations with
duplicate processes. Initialization and tool discovery do not create Safari's automation window or consume its one
active WebDriver session. Once automation starts, Safari still permits only one active session
across Locations; a concurrent Location must report the conflict rather than fall back to the
user's ordinary Safari. The `@Safari DevTools` prompt context carries that instruction.
Staging remains writable until its atomic rename; read-only permissions are applied
at the published destination before selecting `prepared`. If preparation is interrupted
after rename, the next run verifies the existing hashes, normalizes permissions and
verifies again before selecting it. Corrupt artifacts are rejected without resealing.
Failed build directories are not reused or moved by subsequent preparations.

Source and installed
dependencies exist only under `builds/prepare-*` while building and are removed after
successful publication. Neither source nor node_modules ships in a release. Artifact
hashes are verified before activation and reuse. Failed build directories are retained
for diagnosis and can be removed manually. The binary serves its embedded custom web
with `opencode serve`; there is no production source server or second Bun executable.
Its compiled version is the health version; no environment variable substitutes a commit.

### macOS privacy permissions

macOS attributes privacy grants such as Accessibility or Screen Recording, requested by child
tools like Computer Use MCP servers, to the launchd-owned server. Unbundled executables are
identified by path and ad-hoc signatures by cdhash, so each release previously appeared as a
new `opencode` entry and asked again. Prepare now places the binary in `OpenCode Custom.app`
with the fixed bundle identifier `local.opencode.custom` and signs it with a persistent local
certificate, giving every release the same designated requirement:
`identifier "local.opencode.custom" and certificate leaf = H"<certificate sha1>"`.

The first prepare creates `signing/signing.keychain-db` (directory 0700, file 0600) with a
self-signed "OpenCode Custom Local Signing" certificate. The keychain is not added to the
user search list; prepare unlocks it with an empty password and passes it to `codesign`
explicitly, so updates never show Keychain prompts. Keep this directory: deleting it creates a
new certificate and macOS asks for the grants once more. Releases prepared before this
change keep their old identity; rolling back to one asks again.

#### Granting permissions once

A background server whose identity lacks a grant often gets no prompt: Computer Use fails with
`bootstrapTimedOut` instead. This happened on every release before the stable identity; audit
records in `~/.direct-computer-use/audit/direct-computer-use.jsonl` show the first
`official_error` right after the activation that changed the identity. To grant the identity:

1. In System Settings → Privacy & Security, add
   `~/.local/share/opencode-custom-v2/current/OpenCode Custom.app` with **+** (use ⌘⇧G for the
   hidden path) or by dragging it from Finder, and enable it in:
   - Accessibility (listed as "Controle do Dispositivo e Acesso a Dados" in pt-BR);
   - Screen & System Audio Recording;
   - App Management, when requested.
2. Remove the obsolete `opencode` entries with the `exec` icon; they belong to old cdhashes.
3. Restart the server once so the running process picks up the grants, for example from a
   detached `tmux` session when it hosts the current conversation:
   `launchctl kickstart -k gui/$(id -u)/local.opencode.custom-manual`. This is the only
   lifecycle action outside `custom:*`; it keeps the current release and does not change pointers.
4. Verify with the Computer Use `list_apps` and `get_app_state` tools (the latter needs Screen
   Recording for its screenshot).

To tell a missing grant from a Computer Use regression, run the official client
(`~/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient mcp`)
from Terminal.app. It gets past bootstrap and reports `Sender process is not authenticated`,
because only an OpenAI-signed Codex parent is accepted. `bootstrapTimedOut` only from the
server context points to the server identity's grants.

Manual retention is explicit:

```sh
bun run custom:prune --dry-run --keep=3
bun run custom:prune --keep=3
```

Pruning protects current/previous/prepared, the responding server version and the newest
N manifests. It only prunes verified compact releases. It never runs during activation.

`prepared`, `current` and `previous` are atomic symlinks. A `.manual-lock` directory
serializes mutating manual commands; after a killed command, remove a stale lock only
after confirming that no manual operation is running. `--dry-run` writes nothing,
does not build and never changes launchd; migration may read `launchctl print` to
validate the incumbent. A prepare/update dry-run still requires a
clean `custom` checkout. Status performs only authenticated health reads and reports
prepared/current/previous commits plus the live server version; it never prints the password.

### Activation and persistence

Existing `password`, database and configuration are required. Optional
`<runtime>/manual.json` selects existing paths and service environment:

```json
{
  "port": 4178,
  "database": "/Users/you/.local/share/opencode-custom-v2/data/opencode/custom.db",
  "config": "/Users/you/.local/share/opencode-custom-v2/config/opencode",
  "environment": {
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  }
}
```

The defaults for a separately initialized runtime are port **4178**,
`<runtime>/data/opencode/custom.db` and `<runtime>/config/opencode`. Migration instead
copies the actual paths and environment from `environment.sh`. In the current installation
these are `~/.local/share/opencode/opencode.db` and `~/.config/opencode`.
The server launcher preserves explicit XDG roots, falling back to runtime-specific roots for
separately initialized runtimes. Identity/path variables override `environment`. Protect this file
if it contains credentials. Both generated launchers, `bin/serve` and `bin/opencode2`, also contain
these environment values and are private (mode 0700). Never configure
a second global or project-local copy of the custom plugin; every Location loads the
release-owned plugin build through normal plugin configuration.

For the primary installation, set `environment.XDG_CONFIG_HOME` in `manual.json` to the user's
normal config root (`/Users/you/.config`). `OPENCODE_CONFIG_DIR` selects OpenCode configuration;
it does not override XDG for child tools such as `gh`, Homebrew, Stripe, or SwiftPM. Without this
explicit setting, those tools inherit `<runtime>/config` and may use a different login/configuration
from the user's terminal. Check their existing logins before changing it. This setting takes effect
on the next activation that actually starts the service, for example when selecting a different
release. Selecting an already healthy current release returns without rewriting either launcher
or restarting the service, so that no-op does not apply changes to `manual.json`.
Editing the file does not change the running server's environment. Keep `<runtime>/config`:
the 4096 proxy reads `<runtime>/config/opencode/service-custom.json` by its fixed path, independent
of XDG. The default remains isolated for development/test runtimes.

Routine `custom:update` skips the database backup and does not require `sqlite3`.
It still requires the existing database and password and verifies the authenticated
health response and exact running version after activation.

Explicit `custom:activate`, rollback and one-time migration retain the backup step.
Activation controls only `local.opencode.custom-manual`. It unloads that job, waits
up to 65 seconds for launchd registration removal and the previous PID to exit, then
up to 65 port checks for the port to close, takes a consistent SQLite `.backup` using the system `sqlite3`
and checks it with `PRAGMA quick_check`. Missing database, password or sqlite3 aborts
the operation. Backups live under `backups/<timestamp>-<uuid>/database.sqlite` with an
`activation.json` identifying the previous/target release and database path. These
are database backups, not backups of config, credentials, external files or services.

The job plist sets `ProcessType` to `Interactive`. Without it, launchd applies light CPU and
I/O throttling to agents, which makes the server lose scheduling priority under load.

Then activation writes runtime-owned launchers and the job plist, switches `current`, bootstraps the
job and waits up to 90 checks for **authenticated HTTP 200 with the exact target
version**. Before declaring success, the responding PID must match the PID reported by
`launchctl print` for the runtime-owned job. This check also applies to the already-active
shortcut: another process running the same binary/version is not proof of successful activation.
A missing or different PID fails verification; cleanup only unloads the owned job, never the
other listener. It preserves the password, database and config paths. This is an explicit
service interruption; schedule it between active work where possible. Existing TUI
processes keep their already-loaded version: reopen them with `opencode2` afterward.

Bootstrap reconciles an already registered, runtime-owned job through the same health
check. An explicit `Operation already in progress` response may be retried at most
three times for the same release, with registration queried before every attempt.
Generic input/output error 5 alone is not treated as transient. Query permission/domain
errors abort rather than masquerading as a missing job. Ownership is checked on every
successful query; an unexpected owner is never unloaded.

Manual operations retain private timestamped JSON results under
`<runtime>/logs/operations/`, including phases, times, outcome and original failure.
These remain after subsequent recovery. The detached skill runner additionally prints
a unique `$TMPDIR/opencode/opencode-custom-update.*/` directory containing `output.log`
and `result.txt`, including pull/build failures. Inspect those files after tmux closes;
successful activation and completion-notification delivery have separate outcomes.
Progress and result writes are best-effort: a write failure emits a diagnostic on
stderr but never interrupts activation or triggers service cleanup. If storage is
unavailable, the JSON result may be absent or stale; consult the command output.

If startup fails, the attempted service is unloaded, `current` remains on the failed
release, and `previous` plus any backup created are retained. There is deliberately **no
automatic downgrade**: startup may already have migrated the database. Inspect
`<runtime>/logs/server.log`, fix forward, or review the migrations before rollback:

```sh
bun run custom:rollback --database-compatible
# or choose a specific retained release:
bun run custom:rollback <full-sha> --database-compatible
```

`--database-compatible` is the operator's assertion, not an automatic schema
compatibility proof. Rollback backs up the current database and reuses it; it never
silently restores an old snapshot. If a previous schema is required, stop all writers,
retain the current database **and its WAL/SHM sidecars**, restore the selected consistent
backup at the configured database path without stale WAL/SHM files, then run the
explicit rollback. Restoring a snapshot discards later writes. A failure before the
pointer switch leaves the old pointer intact, possibly with the service stopped;
correct the reported problem and rerun activation.

### One-time migration from the old installation

Preparation is safe while the old service runs. Run the explicit migration in a
maintenance window after reviewing its dry-run:

```sh
bun run custom:migrate --dry-run
bun run custom:migrate --replace-launcher --stop-beta
```

It validates the legacy label, plist and loaded command against the known runtime's
`bin/serve.sh`; parses the generated `environment.sh` without executing shell code;
uses its actual `OPENCODE_DB`/`OPENCODE_CONFIG_DIR`; reads the existing credential from
`config/opencode/service-custom.json`; and creates `password`/`manual.json` with mode 0600.
It retires the known old LaunchAgent, preserves its plist and legacy pointer, activates
the prepared release, and installs the stable launcher and login plist links. Existing
launcher files are preserved in unique `.pre-custom-*` backups before atomic replacement.
The 4096 proxy is untouched.
The optional beta stop only accepts the exact `~/.opencode/bin/opencode2 serve --service`
process listening on 4097; any unknown listener aborts migration. A retry reuses the
same persistence and password and does not restart an already healthy target release.

`serve` is intentionally foreground under launchd rather than `serve --service`: this
keeps the legacy global configuration directory while using the preserved password
without rewriting its managed-service configuration/registration or entering election.

The stable launcher resolves `current` once and disables automatic CLI updates. For the TUI,
`run`, `mini`, `api`, `models`, `stats`, `reload`, and the supported `auth`/`session` subcommands,
it reads the existing password into `OPENCODE_PASSWORD` and injects `--server` with the configured
runtime URL (normally `http://127.0.0.1:4178`). It inserts the flag immediately after the command
path, before operands or `--`, preserving the working directory and argument boundaries.
For example, `opencode run -- service` sends the word `service`; it is not a lifecycle request.
Known global flags such as `--print-logs` and `--log-level debug` can precede command names.

The launcher provides read-only service adapters without native service discovery:

- `service status`: authenticated health check; prints the configured URL when ready, otherwise
  `stopped`. Both states exit successfully, matching the native status command. Credentials go to
  curl through stdin, not its command arguments. No service is started.
- `service get password`: prints the existing runtime password; never generates one.
- `service get port` / `service get hostname`: prints the configured port / `127.0.0.1`.
- `service get`: prints hostname and port as JSON, omitting the password and environment.

These adapters support `bun run dev:live` and `bun run dev:vite:live`. The installation still uses
launchd supervision rather than the native managed-service registry.

`mcp add`, `plugin add`, `plugin remove`, and `debug paths` use only local configuration/files and
pass through without `--server`, using the runtime's configured environment and persistence paths.
`mcp add example -- command args` retains the native `--` behavior. Commands whose native handlers
would discover/start a server are rejected with a specific alternative:

| Native command            | Custom-server alternative                                                                          |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| `mcp list`                | `opencode api mcp.list --param "location[directory]=$PWD"`                                         |
| `mcp auth` / `mcp logout` | `/mcps` in the TUI or `opencode auth login` / `opencode auth logout`                               |
| `plugin list`             | `opencode api plugin.list --param "location[directory]=$PWD"` (server plugins)                     |
| `plugin check`            | `opencode api plugin.check --param "location[directory]=$PWD" --data '{}'`                         |
| `plugin update`           | `opencode api plugin.update --param "location[directory]=$PWD" --data '{"targets":["<package>"]}'` |
| `debug agents`            | `opencode api agent.list --param "location[directory]=$PWD"`                                       |
| `debug config`            | `opencode api config.get --param "location[directory]=$PWD"`                                       |
| `pair`                    | `opencode api server.pair`, then open `/auth/connect/<code>` on the custom server                  |

`--help` or `-h` before `--` passes through to native help without a server flag only for the
audited local/API routes, including `mcp list --help` and `pair --help`. Normal client commands
such as `run` retain their explicit server flag on help requests. Lifecycle commands, including
`serve`, `upgrade`/`update`, `uninstall`, mutating `service` commands and `acp`, remain blocked
even with help. The compiled-binary parser smoke verifies global action handling and rejects
shadowing local help/version aliases on the pass-through routes. It requests help before the
command path so that inspecting a newly shadowing alias does not execute that command.
Server/password/standalone overrides remain blocked even on help requests. A literal `--help`
after `--` remains an operand.

Use `custom:*` for lifecycle. The launcher rejects top-level `serve`, `upgrade`/`update`,
`uninstall`, and `service start/stop/restart/set/unset`. It also rejects `acp`, which creates a
private server. User-supplied `--standalone*`, `--server*`, and `--password*` are rejected anywhere,
including after `--`. Native wizard mode is unavailable because it can generate and execute a
different command without passing through the launcher again. Ordinary prompt words such as
`update`, `service`, and `serve` are not blocked. As in the native CLI, use `./service` for a
project named `service`. For non-default runtimes, adjust the paths above consistently.

Migration installs `~/.opencode/bin/opencode2`; an existing `opencode` alias/symlink to it continues
to resolve the updated launcher. Migration and activation do not create that extra alias.

The retired periodic updater, maintenance API, admission barrier, controller and
updater LaunchAgent are not part of this flow. Nothing polls Git or schedules updates.

### Isolated source development

Compact artifact verification is available from `packages/cli`:

```sh
bun script/custom-smoke.ts /absolute/path/to/compiled/custom/opencode
```

It bundles the real plugin, seals/verifies the four-file release, asserts the release-owned
Safari MCP command, starts only a temporary server with a fresh database and random port, checks matching CLI/server versions,
embedded web, plugin RPC save/list and invalid-input rejection, then stops its own process.
The measured macOS arm64 fixture was **184,056,606 bytes (175.53 MiB)**, including the
201.64 KB plugin. Builds from a dirty development checkout are fixture evidence only;
production preparation always archives the committed SHA.

The source entrypoint remains available for development:

```sh
bun install --frozen-lockfile
bun --cwd packages/app-custom run build
bun --cwd packages/plugin-app-custom run build

export OPENCODE_CUSTOM_HOME=/path/to/isolated/runtime
export OPENCODE_CUSTOM_COMMIT="$(git rev-parse HEAD)"
mkdir -p "$OPENCODE_CUSTOM_HOME/data/opencode" "$OPENCODE_CUSTOM_HOME/config/opencode"
umask 077
openssl rand -base64 48 > "$OPENCODE_CUSTOM_HOME/password"
bun packages/cli/script/custom-server.ts
```

This password initialization is only for a **new isolated development runtime**.
Direct source invocation defaults to port 4177. Do not point development at production
persistence. Closing stdin shuts down source smoke invocations. This development
entrypoint is not used by the compact production release, but it uses the same shared
release config generator so its plugin, update policy, and native Safari MCP match production.

## Agent dashboard

The desktop sidebar has **Agent dashboard** immediately below **New session**. The
`/agent-dashboard` route fills the central workspace with compact or comfortable cards;
selecting a card opens its normal Session. The route also fits narrow windows, while its
navigation entry follows the existing desktop-only sidebar breakpoint (768px).

The selected server's global navigation index includes sessions outside the recent page.
The default view shows active sessions, pending permissions/questions, and conversation
activity or completion in the last 24 hours. Search covers title, project name, and directory;
filters cover project, status, and subagents. Cards keep creation order during live updates.
Filters, density, the displayed
page size, and return scroll position persist per window.

Top-level sessions are the default; their cards include descendant running/attention state
and a subagent count. **Include subagents** exposes child cards individually. Completed and
error states come from execution outcomes; interrupted or never-run sessions remain idle.
Unread responses alone do not mean **Needs you**.

Navigation refreshes reconcile complete rows, removing omitted request/unread timestamps.
This clears **Needs you** in both the dashboard and sidebar after a question or permission is resolved.

The dashboard reuses existing APIs and SSE. It pages lightweight navigation metadata,
renders 60 cards at a time with **Show more** (running/attention cards bypass this limit), and reads only the three latest messages for
visible/near-visible cards, with four preview requests at most in flight. Previews retain
up to 600 text characters, omit reasoning and tool payloads, and follow live text/tool events.
Current branch reads are deduplicated by Location and requested as cards become visible;
branches are displayed on cards but are not a search criterion. A text response outside the
three-message window is not loaded. No per-card timeline or periodic history polling is mounted.

New source copy is English-only, including the **Agent dashboard** title; other locales use
the runtime fallback. This change adds a route and sidebar integration, without changing
session/timeline code; no session production-benchmark comparison is applicable. Unit
coverage exercises request/status transitions, the 24-hour boundary, filters, stable order,
descendant aggregation, preview omission, and bounded read concurrency. Reactive unit tests in
`test-browser/agent-dashboard-preview.test.ts` exercise the production preview's SSE updates,
stale reads, execution completion/interruption, and viewport/unmount cancellation using the
browser Solid runtime. Browser verification
is prepared in `e2e/regression/agent-dashboard.spec.ts` for an isolated reviewer-run server.

## iOS timeline history

TanStack Virtual defers scroll corrections on iOS WebKit while a touch, momentum or any reported
scroll is active, because a programmatic write would cancel momentum. An older page admitted then
moved the rows under the reader and snapped back when scrolling stopped. On iOS (including iPadOS
touch and trackpad), older pages are still fetched during the gesture but enter the timeline only
200ms after scrolling settles, so the prepend anchors with one immediate write. Later automatic
pages wait until the held page is admitted; explicit navigation admits it at once.

Row size corrections made during a touch, momentum, any reported scroll or the 200ms after release
use the existing visual translation. On iOS that translation is transferred to the native offset only
after the same settle point, never at release or near the top: Safari applies a write made during a
gesture or momentum one frame late, after the rows have already dropped their translation. Other
platforms are unchanged.

`e2e/regression/mobile-history-admission.spec.ts` covers the held drag with an iPhone user agent in
Chromium. The fix was also measured in Safari on an iOS 26.1 Simulator (Xcode), driving touch swipes
with AXe against the real BTW improve session and sampling row positions every frame: the production
build before the fix showed reversals of 670–2,700 px; afterward at most two shifts of up to 180 px remained,
at the top of history when the loaded content shrinks at scroll position zero.

## New session layout

The new-session screen shows a compact wordmark (at most 240px wide) above the location
selectors and the composer. The project selector, followed by the worktree selector, sits
above the composer's left edge. The project list is searchable and marks the current choice.
Each project uses its custom image, or a folder tinted with the project color from the sidebar;
projects without a color use a muted folder. The worktree menu lists **Project root** with the
root checkout's branch, then **Worktrees**, with **New** to create one on submit. Worktrees
appear by branch name, using the folder name when the branch is unavailable. The branches
come from one `custom.worktrees` `branches` RPC (`git worktree list`), so opening the menu
does not boot each worktree's Location. Choosing **New** keeps the **from branch** base selector.

Both the new-session and session composers put the add menu on the left. The thinking
variant, model, and agent follow on the right, before the send button. The default variant
stays visible but muted. Other variants use the info color. The agent uses its configured
color, the built-in agent tone, or a stable palette color.

## Mobile composer

On mobile layouts (below 768px), Enter inserts a new line and Shift+Enter submits the
composer. Desktop keeps Enter to submit and Shift+Enter for a new line. Mod+Enter
retains alternate delivery, and Enter still selects an open suggestion before submission.

Touch devices (a coarse primary pointer, including iPhone and iPad) enable autocorrection,
sentence capitalization, and spellcheck in normal chat mode. Desktop pointer input and shell
mode keep these disabled. Writing assistance follows the input device, not viewport width.

### Reference editing

The web composer uses CodeMirror 6 for its document, selection, composition, and undo history.
Files, agents, apps, sessions, skills, and snippets remain ordinary editable text with inline
decorations; they are not atomic `contenteditable=false` chips. Selecting a suggestion associates
its metadata with that exact text range. Edits outside the range move it, while an edit that changes
any character inside the range removes the old association so submission cannot send stale metadata.
Undo and redo restore the text and association together. Copying a complete Session reference emits
its portable `opencode://` form for same-server structured paste; copying only part of its text stays
plain text.

Pasting one or more images inserts editable `[filename]` references at the current selection and keeps
each range associated with that image's attachment identity. Generic and repeated clipboard names are
made unique before insertion. Editing or deleting a reference removes its image from the payload;
removing the preview removes the matching reference. Both directions are one CodeMirror history change,
so undo and redo restore or remove the text and image together. Drafts, history, and queued-message edits
retain the association. Pending image reads track intervening edits and reserve filenames across concurrent
pastes; their references remain in paste order even when storage completes out of order. Snippet expansion
and prompt concatenation remap each image range before image file parts carry the matching mention in the
multimodal request. Cited images follow document order; uncited picker attachments retain their existing order.

### Attachment staging

The custom composer accepts arbitrary files. Supported images and PDFs up to 20 MiB
remain inline; text, unsupported types, and larger files stream directly to the server's
temporary upload directory. They appear as path attachments after upload, without storing
their bytes in the browser's draft database. Upload cards and a persistent toast show
progress and offer cancellation; sending is disabled while this composer's uploads finish.
Uploads remain owned by the draft where selection or paste started, including after navigation.

Pasted images retain their editable `[filename]` references even when delivered by path.
Path references survive draft reloads, history, snippet expansion, and queued-message edits.
Removing a queued attachment also removes its model-visible path note. Restored inline images
load their bytes only when shown or sent. Failed sends restore the draft and remove its
duplicate history entry; toast error descriptions are bounded before retention.

## Prompt snippets

Settings → Snippets manages reusable text with a name, description, comma-separated search aliases,
and content. Snippets are stored persistently in the OpenCode server database, globally or scoped
to a project. Settings selects the server to manage; all its devices share the same catalog and
receive live updates. Existing device-local snippets are not migrated.
Project snippets override global snippets with the same name. Type `#` in the composer, search,
and select with Enter, Tab, or a click. Selected references use the theme accent and expand to their
captured content on submission, including when a command is prefixed from the composer menu.
Drafts and prompt history retain the structured association while its text remains unchanged.
Snippets do not require server config files.

## Project explorer

**Add project** on Home and in the new-session project menu opens a flat directory explorer
instead of the tree picker; the desktop native picker and the SSH project dialog are unchanged.
The path field is both location and filter: text up to the last `/` is the browsed directory
and the rest filters its children by prefix, starting at `~/`. Arrow keys move, Enter opens the
highlighted folder (or `..`), and Cmd/Ctrl+Enter adds the typed path. Home also allows batch
selection with the checkboxes or Space while browsing; each row's `+` adds that folder at once.
Existing projects are marked **Added**, and **Show hidden** reveals dot folders. The server
home directory and filesystem roots cannot be added, so browsing `~/` never adds home by accident.

When the typed final segment does not exist, the action becomes **Create and add**. The
`custom.directories` plugin RPC creates only that final folder, so a missing parent fails
instead of creating a tree; it also reports the server home directory, which V2 sync does not
publish. Servers without the custom plugin start at the current location and cannot create folders.

## Chat quotes

Select prose or code inside one assistant text part and choose **Comment**. The composer
keeps the selected passage and an optional editable comment in **Chat quotes** above the
prompt. Quotes can be removed, collapsed, or sent without additional prompt text.
Confirming with the checkmark, Escape, or Cmd/Ctrl+Enter finishes editing and collapses
the quotes panel; plain Enter inserts a line break. The chip reopens saved quotes.

Drafts are scoped to their Session and server and survive reloads. Submission appends the
quoted passages, source message/part IDs, and comments to the model-visible text while
keeping structured quote metadata for history, queue editing, and revert. Failed prompt
admission restores the submitted quotes. Selection cannot span different text parts.

Sent quotes use a shared desktop/mobile renderer inside the user bubble, with a caption and subtle quote line.
Long passages initially show four lines and expand independently; comments remain fully visible.
Copy retains the complete underlying message, including quote context, regardless of the collapsed state.

The implementation uses existing prompt APIs; no Protocol or generated client changes.
This ports the chat-comment workflow, not OpenChamber's separate Notes feature.

Validation: production-build browser scenarios at 1440px and 390px cover selection,
editing, persistence, quote-only submission, history recall, and removal. Existing queue
regressions and composer/persistence tests also pass. A cold-session entry benchmark
measured 307ms first correct / 333ms stable on the base and 236ms / 266ms with the feature
(one local sample each, not a statistically significant performance comparison).

## Session mentions

Type `@` in the web composer to search recent top-level sessions on the current server by
title or exact ID. Sessions from other projects are included; the current session, archived
sessions, and subagents with a parent are excluded. The existing mention query ends at a space.
Session suggestions show a conversation icon, title, directory, and shortened ID. Selected
references use a distinct inline decoration alongside Mac app, file, and agent references while
remaining directly editable.

References retain their identity through drafts, history, queue edits, and same-server copy/paste.
Submission adds compact, deduplicated references. The `opencode.session_read` tool retrieves
text on demand in newest-first pages: 20 messages by default, up to 50, with a 20,000-character
message-text budget. Tool payloads and reasoning are omitted; truncated messages are marked.

Pending autocomplete searches keep the composer visible and focused. Browser regressions cover
delayed results, duplicate titles, Mac apps with the same label, and long chips on mobile.

## Inference footer

Assistant response metadata stays visible on desktop and mobile, with trailing copy actions.
Icon-labelled items show model, recorded reasoning variant, agent, output tokens per second,
processing duration, and local date/time (`dd/MM HH:mm`). TPS uses existing output-token and
provider-stream timestamps; unavailable metrics are omitted. No API changes are required.

## Session context overview

The existing Context tab prioritizes context usage, session and descendant costs, project/branch,
LLM proxy subscriptions, subagent navigation, background tasks, and MCP connection controls above the detailed statistics.
Project and branch share the context header. Subagents precede Subscriptions, followed by
background tasks and MCPs; there is no separate Project section.
The current Session's Context label, ring and usage value stay together at the start edge.
Its token count uses a fixed K suffix for thousands (for example 701K), with localized decimals.
Each subagent's metadata line shows its agent icon/name and the production context ring,
compact token count, and percentage for its most recent measured assistant call. This is
not cumulative token consumption. The model and limit belong to the child; unknown limits
do not produce an invented percentage. These reads load locally without suspending Usage.
The latest measurement remains visible during an unmeasured streaming step; the next measured
step reflects compaction. A bounded recent-assistant read revalidates on opening, reconnection,
and committed revert, while live step events update the indicator without periodic polling.
Session data follows the live event stream. Subscription snapshots refresh every 60 seconds while
the tab is visible (and on manual refresh); they are read-only and do not trigger upstream polling.
Usage renders cached Session information immediately. Pending subscription and subagent requests
show the shared Spinner locally rather than suspending the whole route or mobile navigation.
MCP catalogs keep their loading state until a response arrives. Closing Usage or changing Session
invalidates its family loader before it can publish late results to the shared cache.

Set `OPENCODE_LLM_PROXY_URL` on the backend to the internal proxy base URL. The authenticated
`GET /api/server/subscriptions` endpoint reads `/_admin/status` server-side and returns only quota
metadata. Weekly percentages are shown as remaining quota; dates are quota resets, not subscription
or OAuth expirations. Missing/stale usage is marked explicitly. No credits balance is displayed.
The same `custom.subscriptions` RPC also reads the separate Anthropic pool from
`/_admin/anthropic/status`, normalizing `*_max_20x`/`*_max_5x` tiers to Max 20x/Max 5x and
counting banked resets from unpaused Anthropic grants. A 404 or 503 means the proxy has no
enabled Anthropic pool, so the pool is hidden instead of reported as a failure. The sidebar
footer, under an "LLM proxy" heading, shows one row per pool (Codex and Claude) with its
combined weekly meter, balance in Pro 20x or Max 20x equivalents (each Pro Max account counts as
one Pro 20x quota), days to the next renewal, and banked resets; Claude also shows a chip with the average five-hour quota, tinted when it runs
low. Selecting a row opens the details popover (desktop) or panel (mobile) on that pool's tab
and highlights the row. Each tab is one card: plans and account count, balance with the
combined meter and pace marker, accounts grouped by plan with availability, each account's weekly
meter and renewal countdown (`7.3d`, `7h`, or `10m`), and a short status badge. Five-hour windows
retain their `5h` label, followed by the percentage and the time until that window renews
(`5h 60% (2h 15m)`), and appear alongside the weekly meter only while the weekly quota is not
exhausted. The email occupies the first row with a trailing banked-reset summary, including zero:
`2 reset (7d 8h)`. Minutes appear only below one day, for example `8h 10m` or `10m`.
The parenthesized countdown is the nearest banked-reset expiration when dated,
with the exact timestamp in a tooltip; unknown inventory shows a dash. The next row pairs a status
badge (green `available` for ready accounts) with the single weekly quota aligned at the end.
Weekly-exhausted accounts omit empty quota bars while retaining their status and percentage.
A hairline separates every pair of consecutive accounts in the same plan. Quota meters belong to
their account; plan headings and the footer provide separation at group boundaries instead.
The footer shows the next renewal weekday, numeric date,
24-hour time (`dom., 04/10 08:33`), and pooled banked resets. Exact renewal and expiry times are
in tooltips; the update time and refresh button sit below the card. The two pools are never
combined, matching the proxy's lack of cross-provider failover.
Panel tab selection is persisted per server and Session, including across Location changes.
The chat/side-panel divider width is a shared local preference: resizing it in any Session
applies to existing and new Sessions and survives reloads. Narrow windows clamp the rendered
width without overwriting the saved preference.
Entering a desktop Session opens the side panel automatically, selecting Context when no
previous panel tab is saved. Existing selections are restored; mobile navigation is unchanged.

Subscriptions initially shows a collapsed available-Pro-pool overview. The weekly percentage is
the mean remaining quota of enabled, authenticated Pro accounts with fresh capacity and no cooldown
(observed plan wins over the login claim). Exhausted or cooling-down accounts do not dilute the
available balance; availability still reports available accounts over total Pro membership.
Missing or stale participating measurements make the balance unknown rather than zero or a partial
average. Account details explicitly label remaining/used quota, plan, and confirmed or
unconfirmed capacity; non-Pro accounts are marked outside the active pool.
The update time reflects the oldest measurement included. Expanding reveals every subscription,
including accounts outside the Pro pool. Banked resets are not added to the balance.
Subscription details list available Pro accounts first, followed by other Pro accounts,
Plus, and other plans. Accounts retain their source order within the same priority group;
the ordering follows quota refreshes without changing pool calculations or proxy selection.
The always-visible summary also shows the fresh banked-reset inventory for the Pro pool, with
the first and last expiration (or no expiration). Unknown inventory is not reported as zero.
Each expanded account shows its own banked-reset count beside the plan, including zero;
unavailable inventory is marked explicitly. Dividers separate the account rows.
On mobile, Usage and its live context ring occupy the fourth tab; Terminal is in More options.
Background task rows are single-line previews. Selecting one opens its full text in a dialog,
with an Open subagent link for agent tasks.
Background activity follows current runtime state and the selected Session. Historical tool
metadata saying a task was backgrounded is not evidence that it is still running after completion,
cancellation, or a server restart.
Movement messages are queried by type to discover previous Locations after a cold reload, so a
Session still shows its live shells in the original Location until they exit. Fork-copied history
does not transfer ownership, and a child reused in foreground is not duplicated in background.

## OpenChamber theme

Settings → General → Appearance → Theme offers an **OpenChamber** theme (`packages/ui-custom/src/theme/themes/openchamber.json`)
with light and dark variants adapted from OpenChamber's signature palette: warm ink neutrals,
orange accent, Vitesse-style syntax, teal links, green inline code and a tinted user-message
bubble. Two optional pairs of theme variables drive the custom session UI; every other theme keeps
its default colors: `v2-user-message-background`/`v2-user-message-text` (user bubble in both
local and worktree sessions, replacing the worktree accent bubble) and `v2-inline-code-background`/`v2-inline-code-text` (Markdown inline code and paths,
which otherwise follow `syntax-string`).

## Model picker

The composer model picker and the **Select model** dialog (`mod+'`) share one list. Search matches
model name, ID and provider, keeps the sections and disables reordering while a query is active.
The star adds a model to **Favorites** (new favorites go first) without selecting it; favorites
also stay in their provider section, and hidden models stay out of both. Drag the grip handles to
reorder favorites or provider sections; collapsed sections are remembered per browser.
The pin makes a model and the thinking level shown in its row the **web default** for new
sessions; pin it again to clear it. The default takes precedence over agent and `opencode.json`
models in new-session drafts but never changes existing sessions, the TUI or the config file.
Favorites, provider order and the default live in the server-side preferences profile
(`plugin-app-custom` `custom.preferences`), so every browser shares them. ↑↓ navigate, Enter
selects and ←→ cycles the highlighted model's thinking level before selecting it.
